--[[ ProfileService
	Persistent player data. The only writer of persistent state in the game.

	PROFILE SHAPE (this is what lives in the DataStore):
		{
			money        = number   -- soft currency, integer, >= 0
			gems         = number   -- hard currency, integer, >= 0
			owned        = { carId, ... }   -- ARRAY of car ids, starter car always index 1
			equipped     = carId    -- always a car present in `owned`
			bestCrowns   = number   -- lifetime record, single round
			totalKills   = number   -- lifetime
			roundsPlayed = number
			version      = number   -- schema version, see SCHEMA_VERSION / migrate()
		}
	Runtime-only fields live on the same in-memory table but are NEVER persisted
	(see RUNTIME_KEYS): ready, dirty, temp, tempWarned, saving.

	DATA FLOW
		join -> UpdateAsync load (read + normalize in ONE pass, so a first-time player is
		created atomically) -> mirror to attributes -> ProfileLoaded = true LAST.
		mutate -> memory + attribute + dirty flag -> autosave / leave / shutdown flush.

	ATTRIBUTES OWNED (exactly one writer — this service; siblings go through the API):
		Money  Gems  EquippedCar  OwnedCars(JSON via CarRegistry.encodeOwned)
		BestCrowns  TotalKills  ProfileLoaded

	REMOTES: none. GarageService owns GarageAction; this service is pure API.

	LOAD GUARD: a profile that never loaded cleanly becomes a TEMP profile — the player can
	still play, but no save path will ever persist it. Losing one session beats overwriting
	real progress with defaults.

	INIT ORDER: first service in Main's ORDER. Nothing may be read from here during another
	service's init; resolve this service lazily via ctx.svc.ProfileService at call time.

	PUBLIC API
		get(player)                          -> profile | nil
		isLoaded(player)                     -> boolean   (SpawnService gates on the attribute)
		addMoney(player, n) / addGems(...)   -> newBalance | nil
		spend(player, currency, amount)      -> boolean    (ONLY debit path)
		grantCar(player, carId)              -> boolean
		setEquipped(player, carId)           -> boolean    (applies on NEXT spawn)
		owns(player, carId)                  -> boolean
		noteRoundResult(player, crowns, kills)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local CarRegistry = require(core:WaitForChild("Shared"):WaitForChild("CarRegistry"))

local ProfileService = {}

local CFG = Config.DATA
local ATTR = Config.ATTR

local SCHEMA_VERSION = 2 -- v2 renamed the soft-currency field coins -> money; see migrate()

--[[ Module-scoped, deliberately NOT in Config: these bound this service's shutdown and
	write behaviour, not game feel. Nothing tunes them for design reasons. ]]
local CLOSE_BUDGET_SECONDS = 25 -- BindToClose gets ~30s; leave headroom so the server closes
local CLOSE_RETRY_ATTEMPTS = 2 -- fewer retries at shutdown so the budget covers every player
local SAVE_WAIT_TIMEOUT = 6 -- how long a final save waits on an in-flight autosave
local SAVE_WAIT_POLL = 0.1

-- Currency name (as used by Config.CARS[].currency) -> profile field.
local CURRENCY_FIELD = {
	[ATTR.MONEY] = "money",
	[ATTR.GEMS] = "gems",
}
-- Profile field -> attribute name.
local CURRENCY_ATTR = {
	money = ATTR.MONEY,
	gems = ATTR.GEMS,
}

-- Never written to the DataStore.
local RUNTIME_KEYS = {
	ready = true,
	dirty = true,
	temp = true,
	tempWarned = true,
	saving = true,
}

local profiles = {} -- [Player] = profile
local loading = {} -- [Player] = true while a load is in flight
local initialized = false

--[[ A GetDataStore failure (API access off, unpublished place) must not stop the game:
	`store` stays nil and every player gets a temp profile instead. ]]
local store = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(CFG.STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("ProfileService: DataStore unavailable -> temp profiles only (" .. tostring(result) .. ")")
	end
end

-- ==========================================================================
-- helpers
-- ==========================================================================

local function isPlayer(value): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function isFiniteNumber(value): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function wholeAtLeastZero(value, fallback: number): number
	if not isFiniteNumber(value) then
		return fallback
	end
	return math.max(0, math.floor(value))
end

local function keyFor(player: Instance): string
	return CFG.KEY_PREFIX .. tostring(player.UserId)
end

local function ownedSet(profile): { [string]: boolean }
	local set = { [Config.STARTER_CAR] = true }
	for _, id in ipairs(profile.owned) do
		set[id] = true
	end
	return set
end

--[[ Normalizes ANY stored payload into the current profile shape.
	Forward compatible on purpose:
	  * unknown top-level keys survive the round trip, so a field written by a future
	    schema version is not destroyed by an older server,
	  * a stored version NEWER than ours is kept as-is rather than downgraded.
	When the schema changes, add a `if out.version < N then ... end` step below — never wipe. ]]
local function migrate(data)
	local out = {}
	if type(data) == "table" then
		for key, value in pairs(data) do
			if not RUNTIME_KEYS[key] then
				out[key] = value
			end
		end
	end

	out.version = isFiniteNumber(out.version) and math.floor(out.version) or 0

	--[[ v1 -> v2: the soft currency was renamed coins -> money everywhere, including this
		field. A v1 payload carries the balance under `coins` and nothing under `money`, so
		it is MOVED here — reading it as a missing field would silently zero the wallet of
		every player who banked anything before the rename. The old key is then dropped so
		the next save does not carry a stale second balance forward. Only an ABSENT `money`
		takes the old value: if both exist, the new field is already authoritative. ]]
	if out.version < 2 and out.money == nil and isFiniteNumber(out.coins) then
		out.money = out.coins
	end
	out.coins = nil

	-- v0 -> v1: original shape. Nothing to move, only normalize.
	out.money = wholeAtLeastZero(out.money, 0)
	out.gems = wholeAtLeastZero(out.gems, 0)
	out.bestCrowns = wholeAtLeastZero(out.bestCrowns, 0)
	out.totalKills = wholeAtLeastZero(out.totalKills, 0)
	out.roundsPlayed = wholeAtLeastZero(out.roundsPlayed, 0)
	-- Daily login track. DailyRewardService owns what these mean; without them it
	-- refuses to grant at all, because serialize() would drop them and a rejoin would
	-- hand out the same reward again.
	out.dailyStreak = wholeAtLeastZero(out.dailyStreak, 0)
	out.lastDailyDay = wholeAtLeastZero(out.lastDailyDay, 0)

	-- Ownership: starter first, known ids only, no duplicates.
	local seen = { [Config.STARTER_CAR] = true }
	local owned = { Config.STARTER_CAR }
	local rawOwned = type(data) == "table" and data.owned or nil
	if type(rawOwned) == "table" then
		for _, id in ipairs(rawOwned) do
			if type(id) == "string" and not seen[id] and CarRegistry.exists(id) then
				seen[id] = true
				table.insert(owned, id)
			end
		end
	end
	out.owned = owned

	if type(out.equipped) ~= "string" or not seen[out.equipped] then
		out.equipped = Config.STARTER_CAR
	end

	if out.version < SCHEMA_VERSION then
		out.version = SCHEMA_VERSION
	end
	return out
end

-- pcall + exponential backoff. Yields, so callers must re-check the player afterwards.
local function retryAsync(label: string, attempts: number, fn)
	local delay = CFG.RETRY_BASE_DELAY
	local lastErr = nil

	for attempt = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < attempts then
			task.wait(delay)
			delay = delay * 2
		end
	end

	warn(string.format("ProfileService: %s failed after %d attempts -> %s", label, attempts, tostring(lastErr)))
	return false, nil
end

local function mirror(player: Instance, profile)
	player:SetAttribute(ATTR.MONEY, profile.money)
	player:SetAttribute(ATTR.GEMS, profile.gems)
	player:SetAttribute(ATTR.EQUIPPED, profile.equipped)
	player:SetAttribute(ATTR.OWNED, CarRegistry.encodeOwned(ownedSet(profile)))
	player:SetAttribute(ATTR.BEST_CROWNS, profile.bestCrowns)
	player:SetAttribute(ATTR.TOTAL_KILLS, profile.totalKills)
end

-- Returns the profile only when it is safe to read AND mutate.
local function readyProfile(player)
	if not isPlayer(player) then
		return nil
	end
	local profile = profiles[player]
	if not profile or not profile.ready then
		return nil
	end
	return profile
end

-- ==========================================================================
-- load
-- ==========================================================================

--[[ Studio-only test conveniences. Gated at the point of use, per house rules.
	Deliberately does NOT mark the profile dirty: a test grant is not written to the live
	DataStore on its own, so testing cannot inflate a real account. ]]
local function applyStudioTestFlags(profile)
	if not RunService:IsStudio() then
		return
	end

	if Config.TEST.GRANT_ALL_CARS then
		local set = ownedSet(profile)
		for _, car in ipairs(CarRegistry.all()) do
			if not set[car.id] then
				set[car.id] = true
				table.insert(profile.owned, car.id)
			end
		end
	end

	local startMoney = Config.TEST.START_MONEY
	if isFiniteNumber(startMoney) and startMoney > 0 and profile.money < startMoney then
		profile.money = math.floor(startMoney)
	end
end

local function onPlayerAdded(player: Instance)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true

	-- Definite false up front: nothing may read a nil/stale ProfileLoaded.
	player:SetAttribute(ATTR.PROFILE_LOADED, false)

	local loaded = nil
	if store then
		-- One UpdateAsync does read + normalize + first-time create atomically.
		local ok, data = retryAsync("load " .. player.Name, CFG.RETRY_ATTEMPTS, function()
			return store:UpdateAsync(keyFor(player), function(raw)
				return migrate(raw)
			end)
		end)
		if ok and type(data) == "table" then
			loaded = data
		end
	end

	-- The load yields; the player may have left.
	if not player:IsDescendantOf(Players) then
		loading[player] = nil
		return
	end

	local profile = loaded
	local isTemp = false
	if not profile then
		profile = migrate(nil)
		isTemp = true
		warn(
			"ProfileService: TEMP profile for "
				.. player.Name
				.. " — load failed, this session will NOT be saved"
		)
	end

	profile.temp = isTemp
	profile.dirty = false
	profile.saving = false
	profile.ready = false

	applyStudioTestFlags(profile)

	profiles[player] = profile
	loading[player] = nil

	mirror(player, profile)
	profile.ready = true

	-- LAST, always: SpawnService gates spawning on this. Setting it earlier would let a
	-- player spawn against a blank profile.
	player:SetAttribute(ATTR.PROFILE_LOADED, true)
end

-- ==========================================================================
-- save
-- ==========================================================================

--[[ Builds the persisted payload. Starts from migrate(raw) so unknown/future keys already in
	the store survive, then overwrites every field this server owns from memory. ]]
local function serialize(profile, raw)
	local out = migrate(raw)
	out.money = profile.money
	out.gems = profile.gems
	out.bestCrowns = profile.bestCrowns
	out.totalKills = profile.totalKills
	out.roundsPlayed = profile.roundsPlayed
	out.dailyStreak = wholeAtLeastZero(profile.dailyStreak, out.dailyStreak)
	out.lastDailyDay = wholeAtLeastZero(profile.lastDailyDay, out.lastDailyDay)
	out.owned = table.clone(profile.owned)
	out.equipped = profile.equipped
	if out.version < SCHEMA_VERSION then
		out.version = SCHEMA_VERSION
	end
	return out
end

local function save(player: Instance, isFinal: boolean, attempts: number?): boolean
	local profile = profiles[player]
	if not profile or not profile.ready then
		return false
	end

	-- LOAD GUARD: never let a profile that failed to load overwrite real progress.
	if profile.temp then
		if not profile.tempWarned then
			profile.tempWarned = true
			warn("ProfileService: refusing to persist TEMP profile for " .. player.Name)
		end
		return false
	end
	if not store then
		return false
	end

	if profile.saving then
		if not isFinal then
			return false
		end
		local deadline = os.clock() + SAVE_WAIT_TIMEOUT
		while profile.saving and os.clock() < deadline do
			task.wait(SAVE_WAIT_POLL)
		end
		if profile.saving then
			warn("ProfileService: final save for " .. player.Name .. " gave up waiting on an in-flight save")
			return false
		end
	end

	profile.saving = true
	-- Cleared BEFORE the write: a mutation during the write re-marks it for the next pass.
	profile.dirty = false

	local ok = retryAsync("save " .. player.Name, attempts or CFG.RETRY_ATTEMPTS, function()
		return store:UpdateAsync(keyFor(player), function(raw)
			return serialize(profile, raw)
		end)
	end)

	profile.saving = false
	if not ok then
		profile.dirty = true
	end
	return ok
end

local function onPlayerRemoving(player: Instance)
	loading[player] = nil
	local profile = profiles[player]
	if not profile then
		return
	end
	if profile.dirty then
		save(player, true)
	end
	profiles[player] = nil
end

local function autosaveLoop()
	while true do
		task.wait(CFG.AUTOSAVE_SECONDS)

		-- Snapshot first: save() yields and PlayerRemoving may mutate `profiles` mid-pass.
		local pending = {}
		for player, profile in pairs(profiles) do
			if profile.dirty and not profile.temp then
				table.insert(pending, player)
			end
		end

		for _, player in ipairs(pending) do
			local profile = profiles[player]
			if profile and profile.dirty and player:IsDescendantOf(Players) then
				save(player, false)
			end
		end
	end
end

--[[ Sequential flush with a hard time budget so the server actually closes. Anything left
	over is warned about rather than silently dropped. ]]
local function onClose()
	local deadline = os.clock() + CLOSE_BUDGET_SECONDS

	local remaining = {}
	for player, profile in pairs(profiles) do
		if profile.dirty and not profile.temp then
			table.insert(remaining, player)
		end
	end

	for index, player in ipairs(remaining) do
		if os.clock() >= deadline then
			warn(
				string.format(
					"ProfileService: BindToClose budget spent, %d profile(s) unsaved",
					#remaining - index + 1
				)
			)
			break
		end
		if profiles[player] then
			save(player, true, CLOSE_RETRY_ATTEMPTS)
		end
	end
end

-- ==========================================================================
-- public API
-- ==========================================================================

--[[ Returns the LIVE in-memory table, not a copy. READ-ONLY by convention: mutating it
	directly bypasses attribute mirroring and the dirty flag, so the change never replicates
	and never saves. Every write goes through a mutator below. ]]
function ProfileService.get(player: Instance)
	if not isPlayer(player) then
		return nil
	end
	return profiles[player]
end

-- True only for a profile (real or temp) that is fully mirrored and safe to read.
function ProfileService.isLoaded(player: Instance): boolean
	local profile = readyProfile(player)
	return profile ~= nil
end

--[[ Shared by addMoney / addGems. Negative amounts are allowed (they are how a refundable
	adjustment is expressed) and the balance clamps at 0. spend() is the guarded debit path. ]]
local function addCurrency(player: Instance, field: string, amount: number)
	local profile = readyProfile(player)
	if not profile then
		return nil
	end
	if not isFiniteNumber(amount) then
		warn("ProfileService: bad " .. field .. " amount " .. tostring(amount))
		return nil
	end

	local delta = math.floor(amount + 0.5)
	if delta == 0 then
		return profile[field]
	end

	profile[field] = math.max(0, profile[field] + delta)
	player:SetAttribute(CURRENCY_ATTR[field], profile[field])
	profile.dirty = true
	return profile[field]
end

function ProfileService.addMoney(player: Instance, amount: number)
	return addCurrency(player, "money", amount)
end

function ProfileService.addGems(player: Instance, amount: number)
	return addCurrency(player, "gems", amount)
end

--[[ The ONLY debit path. `currency` must be exactly Config.ATTR.MONEY or Config.ATTR.GEMS
	(i.e. the strings Config.CARS[].currency uses). Balance check and deduction happen with
	no yield between them, so a double-spend cannot slip through. ]]
function ProfileService.spend(player: Instance, currency: string, amount: number): boolean
	local profile = readyProfile(player)
	if not profile then
		return false
	end

	local field = type(currency) == "string" and CURRENCY_FIELD[currency] or nil
	if not field then
		warn("ProfileService.spend: unknown currency " .. tostring(currency))
		return false
	end
	if not isFiniteNumber(amount) or amount < 0 then
		warn("ProfileService.spend: bad amount " .. tostring(amount))
		return false
	end

	local cost = math.floor(amount + 0.5)
	if cost == 0 then
		return true
	end
	if profile[field] < cost then
		return false
	end

	profile[field] = profile[field] - cost
	player:SetAttribute(CURRENCY_ATTR[field], profile[field])
	profile.dirty = true
	return true
end

function ProfileService.grantCar(player: Instance, carId: string): boolean
	local profile = readyProfile(player)
	if not profile then
		return false
	end
	if type(carId) ~= "string" or not CarRegistry.exists(carId) then
		warn("ProfileService.grantCar: unknown car " .. tostring(carId))
		return false
	end
	if ownedSet(profile)[carId] then
		return true -- already owned: a no-op success, callers can grant idempotently
	end

	table.insert(profile.owned, carId)
	player:SetAttribute(ATTR.OWNED, CarRegistry.encodeOwned(ownedSet(profile)))
	profile.dirty = true
	return true
end

--[[ Takes effect on the player's NEXT spawn: SpawnService reads the equipped car at spawn
	time, so changing it mid-match never swaps the car out from under the player. ]]
function ProfileService.setEquipped(player: Instance, carId: string): boolean
	local profile = readyProfile(player)
	if not profile then
		return false
	end
	if type(carId) ~= "string" or not CarRegistry.exists(carId) then
		return false
	end
	if carId ~= Config.STARTER_CAR and not ownedSet(profile)[carId] then
		return false
	end
	if profile.equipped == carId then
		return true
	end

	profile.equipped = carId
	player:SetAttribute(ATTR.EQUIPPED, carId)
	profile.dirty = true
	return true
end

function ProfileService.owns(player: Instance, carId: string): boolean
	local profile = readyProfile(player)
	if not profile or type(carId) ~= "string" then
		return false
	end
	return ownedSet(profile)[carId] == true
end

-- Called once per player at round end (ScoreService payout).
function ProfileService.noteRoundResult(player: Instance, crowns: number, kills: number)
	local profile = readyProfile(player)
	if not profile then
		return
	end

	local roundCrowns = wholeAtLeastZero(crowns, 0)
	local roundKills = wholeAtLeastZero(kills, 0)

	if roundCrowns > profile.bestCrowns then
		profile.bestCrowns = roundCrowns
		player:SetAttribute(ATTR.BEST_CROWNS, profile.bestCrowns)
	end

	profile.totalKills = profile.totalKills + roundKills
	player:SetAttribute(ATTR.TOTAL_KILLS, profile.totalKills)

	profile.roundsPlayed = profile.roundsPlayed + 1
	profile.dirty = true
end

-- ==========================================================================
-- init
-- ==========================================================================

-- ctx is unused: this service owns no remotes and calls no siblings.
function ProfileService.init(ctx)
	if initialized then
		return
	end
	initialized = true

	-- Connected directly (no task.spawn) so the engine waits on the flush at shutdown.
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Anyone already present (Studio start, script hot-reload).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(autosaveLoop)
	game:BindToClose(onClose)
end

--[[ Force this player's profile to disk NOW and report whether it landed.
	Paid currency needs this: without it a grant that happens seconds before a server
	dies is lost, and the player paid Robux for nothing. MonetizationService calls it
	before returning PurchaseGranted. Returns false for a temp profile, which is the
	signal to answer NotProcessedYet so Roblox retries the receipt later. ]]
function ProfileService.flush(player: Instance): boolean
	return save(player, true) == true
end

return ProfileService
