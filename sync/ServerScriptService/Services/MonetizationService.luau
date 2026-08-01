--[[ MonetizationService
	Dev products, game passes, perks and the free/limited offers. The ONLY place in the game
	that talks to MarketplaceService.

	PURPOSE
		* Owns ProcessReceipt end to end: dedup ring, grant dispatch, grant-then-confirm.
		* Resolves game-pass ownership once per join and mirrors every perk to an attribute,
		  so the shop UI reads perks with zero remotes.
		* Publishes the ONE money multiplier ScoreService applies at payout.

	INERT UNTIL CONFIGURED
		Every id in Config.PRODUCTS / Config.PASSES is 0 until the products exist in the
		Creator Hub. An entry with id 0 is SKIPPED everywhere — no query, no prompt, no
		per-player warn. init() logs a single summary line so the gap is obvious at a glance.

	DATA FLOW
		join
		  -> perk attributes written as definite false / 0 / 1 (the UI never reads nil)
		  -> UserOwnsGamePassAsync per configured pass (each in its own pcall; a Marketplace
		     outage degrades to "no perks this session" and never blocks the join)
		  -> perk attributes + MoneyMultiplier
		ProfileLoaded flips true
		  -> mirror Spins, settle any outstanding one-time pass grant
		buy product
		  -> MarketplaceService.ProcessReceipt -> dedup ring -> grant through ProfileService
		     -> flush -> PurchaseGranted, in that order and never before
		buy pass
		  -> PromptGamePassPurchaseFinished -> RE-VERIFY with UserOwnsGamePassAsync
		     -> perk attributes -> one-time grants (flag guarded, once ever)

	ATTRIBUTES OWNED (sole writer, per Main's ownership table)
		Vip             boolean  VIP pass held
		DoubleMoney     boolean  2x Money pass held
		Magnet          boolean  Crown Magnet pass held (no gameplay consumer yet — HANDOFF)
		GoldenCar       boolean  Golden Car pass held
		Spins           number   lucky spins banked
		MoneyMultiplier number   VIP x DoubleMoney x Premium, clamped to MAX_TOTAL_MONEY_MULTIPLIER
		Reads only: Config.ATTR.PROFILE_LOADED (ProfileService), to know when a profile is safe.
		Writes NO other service's attribute — notably not Lives (SpawnService) and not
		Money/Gems/OwnedCars (ProfileService), which move only through their APIs.

	REMOTES
		Monetization  C->S  (action: "product"|"pass"|"claimGroup"|"claimFavourite", key: string?)
		              S->C  ("failed", { reason: string })
		Wired in init() to the four public entry points below. Only the REFUSAL is pushed back;
		every success already lands as an attribute or a currency the client is watching, so
		there is no second success channel to keep in sync.
		The client never sends a price or an amount — it sends an action and a Config KEY, and
		this service looks up everything that matters. Validation, id-not-pasted skipping and
		throttling all live inside the entry points (see the note above promptProduct), so the
		handler is a bridge and deliberately adds no second policy layer.

	SERVICES USED — resolved LAZILY through ctx.svc at call time, never captured at init:
		ProfileService  isLoaded get addMoney addGems grantCar  (+ flush: see HANDOFF)
		SpawnService    addLives  (does NOT exist yet: see HANDOFF. Until it does, the Extra
		                Life product returns NotProcessedYet, so nobody is charged for nothing)

	INIT ORDER
		Second in Main's ORDER, right after ProfileService and before every registrant that
		reads a perk. Touches no sibling during init.

	FAIRNESS
		Money is progression and is safe to multiply. Crowns are the competitive score and
		are deliberately NOT multiplied anywhere in this file — see the fairness flag in
		Config's monetization comment before adding anything that touches crowns.

	PUBLIC API
		moneyMultiplier(player)      -> number    the ONE call ScoreService makes at payout
		hasPerk(player, perk)        -> boolean   perk name ("vip") or pass key ("VIP")
		extraLives(player)           -> number    perk-derived extra lives, for resetLives
		spins(player)                -> number
		promptProduct(player, key)   -> ok, message
		promptPass(player, key)      -> ok, message
		claimGroupReward(player)     -> ok, message
		claimFavouriteReward(player) -> ok, message
		currentLimited()             -> key?, endsAt   clock-derived; every machine agrees
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local Net = require(core:WaitForChild("Net"))
local CarRegistry = require(core:WaitForChild("Shared"):WaitForChild("CarRegistry"))

local MonetizationService = {}

local CFG = Config.MONETIZATION
local ATTR = Config.ATTR -- read only: PROFILE_LOADED

--[[ Attributes this service owns. The names are exactly the ones recorded in Main's
	ownership table (Vip DoubleMoney Magnet GoldenCar Spins MoneyMultiplier). They are not in
	Config.ATTR yet — HANDOFF has the paste-ready block — so they live here as a local table
	rather than as bare strings scattered through the file. ]]
local MON_ATTR = {
	VIP = "Vip",
	DOUBLE_MONEY = "DoubleMoney",
	MAGNET = "Magnet",
	GOLDEN_CAR = "GoldenCar",
	SPINS = "Spins",
	MONEY_MULTIPLIER = "MoneyMultiplier",
}

--[[ Config.PASSES[*].perk -> the attribute mirroring it. Driven by perk name, not pass key,
	so renaming a catalog key cannot silently orphan an attribute.
	`starterPack` is deliberately ABSENT: it is a one-time grant, not a standing perk, and
	Main grants this service only the six attributes above. hasPerk("starterPack") still
	answers from the ownership cache; see HANDOFF if the shop needs it replicated too. ]]
local PERK_ATTR = {
	vip = MON_ATTR.VIP,
	doubleMoney = MON_ATTR.DOUBLE_MONEY,
	magnet = MON_ATTR.MAGNET,
	goldenCar = MON_ATTR.GOLDEN_CAR,
}

-- Perk -> money multiplier. Only these two perks touch earn rate; nothing here touches crowns.
local PERK_MULTIPLIER = {
	vip = CFG.VIP_MONEY_MULTIPLIER,
	doubleMoney = CFG.DOUBLE_MONEY_MULTIPLIER,
}

--[[ Group id for the free-gems reward. 0 = UNCONFIGURED, exactly like every product id:
	claimGroupReward does nothing, warns nothing, and never latches until a real id is pasted
	here. Paste the group id and the feature turns on with no other change. ]]
local GROUP_ID = 0

--[[ Once-ever latches. They live in profile.flags — a field ProfileService does not persist
	yet (HANDOFF has the four lines). Prefixed so this service can never collide with another
	system's flag. ]]
local FLAG_GROUP_REWARD = "monGroupReward"
local FLAG_FAVOURITE_REWARD = "monFavouriteReward"
local FLAG_PASS_PREFIX = "monPass_" -- .. pass key

-- Receipt dedup ring size, from Config so the policy is tunable in one place.
local RING_SIZE = math.max(1, math.floor(CFG.RECEIPT_RING_SIZE))

-- Kid copy: ~5 words, one clause. Returned to callers so a remote can echo it verbatim.
local MSG = {
	OK = "Thanks!",
	NOT_READY = "One second...",
	UNAVAILABLE = "Not available yet!",
	ALREADY = "Already claimed!",
	NEED_GROUP = "Join the group first!",
}

local serverCtx = nil
local initialized = false
local promptGate = nil -- Net.throttle(), built in init

local ownedByPlayer = {} -- [Player] = { [passKey] = true }
local scannedByPlayer = {} -- [Player] = true once the join ownership scan finished
local readiedByPlayer = {} -- [Player] = true once the profile-ready pass ran
local loadedConnByPlayer = {} -- [Player] = ProfileLoaded listener, disconnected on leave

-- Dedup ring: rolling array + set for O(1) lookup + write index.
local receiptRing = table.create(RING_SIZE)
local receiptSeen = {}
local receiptIndex = 0

-- warn-once latches. An unconfigured or half-wired build must not spam the log.
local warnedNoFlagsField = false
local warnedNoSpinsField = false
local warnedNoAddLives = false
local warnedNoFlush = false

-- ==========================================================================
-- catalog — derived once. Entries with id 0 are simply absent, which is what
-- makes every code path below inert instead of broken.
-- ==========================================================================

local productById = {} -- [productId] = { key = string, def = table }
local passById = {} -- [gamePassId] = { key = string, def = table }
local perkToKey = {} -- [perk name] = pass key
local configuredProducts, totalProducts = 0, 0
local configuredPasses, totalPasses = 0, 0

for key, def in pairs(Config.PRODUCTS) do
	totalProducts += 1
	if type(def.id) == "number" and def.id ~= 0 then
		-- Two catalog entries on one id would make grants ambiguous: say so once, at load.
		if productById[def.id] then
			warn(
				string.format(
					"MonetizationService: product id %s is used by both %s and %s",
					tostring(def.id),
					productById[def.id].key,
					key
				)
			)
		end
		productById[def.id] = { key = key, def = def }
		configuredProducts += 1
	end
end

for key, def in pairs(Config.PASSES) do
	totalPasses += 1
	if type(def.perk) == "string" then
		perkToKey[def.perk] = key
	end
	if type(def.id) == "number" and def.id ~= 0 then
		if passById[def.id] then
			warn(
				string.format(
					"MonetizationService: pass id %s is used by both %s and %s",
					tostring(def.id),
					passById[def.id].key,
					key
				)
			)
		end
		passById[def.id] = { key = key, def = def }
		configuredPasses += 1
	end
end

-- ==========================================================================
-- helpers
-- ==========================================================================

local function isPlayer(value): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function positiveAmount(value): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value > 0
end

-- Lazy sibling lookup: services after this one in ORDER do not exist yet at init.
local function profileService()
	return serverCtx and serverCtx.svc and serverCtx.svc.ProfileService or nil
end

--[[ pcall wrapper for ProfileService calls. A bad call must become a clean failure, never an
	error thrown out of ProcessReceipt — an error there is an unhandled receipt. ]]
local function profileCall(fnName: string, ...): (boolean, any)
	local Profile = profileService()
	local fn = type(Profile) == "table" and Profile[fnName] or nil
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn("MonetizationService: ProfileService." .. fnName .. " failed -> " .. tostring(result))
		return false, nil
	end
	return true, result
end

-- The live profile when it is safe to READ (may be a temp profile).
local function readyProfile(player: Instance)
	local Profile = profileService()
	if not Profile or type(Profile.get) ~= "function" or type(Profile.isLoaded) ~= "function" then
		return nil
	end
	local okLoaded, loaded = pcall(Profile.isLoaded, player)
	if not okLoaded or loaded ~= true then
		return nil
	end
	local okGet, profile = pcall(Profile.get, player)
	if not okGet or type(profile) ~= "table" then
		return nil
	end
	return profile
end

--[[ The live profile when it is safe to read AND to bank something paid into: loaded, ready,
	and NOT a temp profile. ProfileService refuses to persist a temp profile, so "cannot
	persist" and "must not grant" are deliberately the same branch. ]]
local function persistableProfile(player: Instance)
	local profile = readyProfile(player)
	if not profile or profile.temp then
		return nil
	end
	return profile
end

--[[ Once-ever latches live in profile.flags, which ProfileService does not know about yet.
	Feature-detected rather than assumed: with no persistence a "once ever" reward would reset
	on every rejoin, which is a farm. So when the field is missing we REFUSE the grant rather
	than hand out something we cannot latch. HANDOFF has the four lines that fix this. ]]
local function flagsTable(profile)
	if type(profile.flags) ~= "table" then
		if not warnedNoFlagsField then
			warnedNoFlagsField = true
			warn(
				"MonetizationService: ProfileService profiles have no `flags` field — "
					.. "once-ever grants are DISABLED until it is added (see MonetizationService HANDOFF)"
			)
		end
		return nil
	end
	return profile.flags
end

--[[ Forces a durable write before we report a paid grant as delivered. ProfileService has NO
	public flush yet — the exact 3-line addition is in this service's HANDOFF — so the call is
	defensive and starts working the moment that function lands. Without it a grant is only
	autosaved, and a server that dies in between loses paid currency. ]]
local function flushProfile(player: Instance)
	local Profile = profileService()
	if not Profile or type(Profile.flush) ~= "function" then
		if not warnedNoFlush then
			warnedNoFlush = true
			warn(
				"MonetizationService: ProfileService.flush is missing — paid grants rely on autosave "
					.. "(see MonetizationService HANDOFF)"
			)
		end
		return
	end
	pcall(Profile.flush, player)
end

-- ==========================================================================
-- perk queries — the public read surface siblings use
-- ==========================================================================

function MonetizationService.hasPerk(player: Instance, perkName: string): boolean
	if not isPlayer(player) or type(perkName) ~= "string" then
		return false
	end
	local owned = ownedByPlayer[player]
	if not owned then
		return false
	end
	-- Accepts a perk name ("vip") or the pass key itself ("VIP"); both are pinned contract.
	local key = perkToKey[perkName] or (Config.PASSES[perkName] and perkName or nil)
	return key ~= nil and owned[key] == true
end

local function isPremium(player: Instance): boolean
	-- Wrapped: MembershipType can throw on a player instance that is being torn down.
	local ok, premium = pcall(function()
		return player.MembershipType == Enum.MembershipType.Premium
	end)
	return ok and premium == true
end

--[[ The ONE multiplier ScoreService applies at payout: VIP x DoubleMoney x Premium, clamped
	to CFG.MAX_TOTAL_MONEY_MULTIPLIER so stacked perks cannot break the money economy.
	Returns 1 for an unknown player, and 1 (plus Premium) during the brief join window before
	the ownership scan lands — never nil, so a caller can always multiply by it. ]]
function MonetizationService.moneyMultiplier(player: Instance): number
	if not isPlayer(player) then
		return 1
	end

	local multiplier = 1
	local owned = ownedByPlayer[player]
	if owned then
		for key in pairs(owned) do
			local def = Config.PASSES[key]
			local perkMultiplier = def and PERK_MULTIPLIER[def.perk] or nil
			if positiveAmount(perkMultiplier) then
				multiplier *= perkMultiplier
			end
		end
	end
	if isPremium(player) then
		multiplier *= CFG.PREMIUM_MONEY_MULTIPLIER
	end

	return math.clamp(multiplier, 1, CFG.MAX_TOTAL_MONEY_MULTIPLIER)
end

--[[ Extra lives a player's perks are worth at round start. SpawnService.resetLives adds this
	on top of Config.MATCH.LIVES (see HANDOFF); this service never writes the Lives attribute. ]]
function MonetizationService.extraLives(player: Instance): number
	if not MonetizationService.hasPerk(player, "vip") then
		return 0
	end
	if not positiveAmount(CFG.VIP_EXTRA_LIFE) then
		return 0
	end
	return math.floor(CFG.VIP_EXTRA_LIFE)
end

function MonetizationService.spins(player: Instance): number
	local profile = readyProfile(player)
	if not profile or type(profile.spins) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(profile.spins))
end

-- ==========================================================================
-- attribute mirroring — this service's six attributes, written nowhere else
-- ==========================================================================

local function writePerkAttributes(player: Instance)
	if not player.Parent then
		return
	end
	for perk, attrName in pairs(PERK_ATTR) do
		player:SetAttribute(attrName, MonetizationService.hasPerk(player, perk))
	end
	player:SetAttribute(MON_ATTR.MONEY_MULTIPLIER, MonetizationService.moneyMultiplier(player))
end

local function writeSpinsAttribute(player: Instance, value: number)
	if not player.Parent then
		return
	end
	local whole = 0
	if type(value) == "number" and value == value and value ~= math.huge then
		whole = math.max(0, math.floor(value))
	end
	player:SetAttribute(MON_ATTR.SPINS, whole)
end

--[[ Spins are stored on profile.spins, another field ProfileService does not persist yet.
	Written here directly — field + attribute + dirty flag, which is exactly what a
	ProfileService.addSpins mutator would do (requested in HANDOFF as its proper home).
	If the field is missing the grant is REFUSED, because the caller is ProcessReceipt and a
	spin that evaporates on rejoin is a paid item the player lost. ]]
local function grantSpins(player: Instance, amount: number): boolean
	local profile = persistableProfile(player)
	if not profile or not positiveAmount(amount) then
		return false
	end
	if type(profile.spins) ~= "number" then
		if not warnedNoSpinsField then
			warnedNoSpinsField = true
			warn(
				"MonetizationService: ProfileService profiles have no `spins` field — spin grants "
					.. "REFUSED so receipts retry instead of vanishing (see MonetizationService HANDOFF)"
			)
		end
		return false
	end

	profile.spins = math.max(0, math.floor(profile.spins) + math.floor(amount))
	profile.dirty = true
	writeSpinsAttribute(player, profile.spins)
	return true
end

-- ==========================================================================
-- one-time pass grants
-- ==========================================================================

--[[ Applies a pass's one-time grants (Config.PASSES[*].grantMoney / grantCar) once EVER,
	latched in profile.flags.

	Called from BOTH the purchase event and the join ownership scan on purpose: a pass bought
	while a server was dying, or bought in a previous session, still lands the next time we
	SEE the ownership. That is what makes onceOnly "once ever" instead of "once per purchase
	event", and the latch is what stops the join scan re-granting it every join.

	The config is validated BEFORE anything is mutated, and there is no yield between the
	latch and the grants — and money, car and latch are all fields of the SAME profile table,
	so one UpdateAsync persists them together or not at all. There is no window where the
	money persists without the latch, or the latch without the money.

	Returns true only when it actually granted something (the caller then flushes). ]]
local function applyPassGrants(player: Instance, passKey: string): boolean
	local def = Config.PASSES[passKey]
	if not def then
		return false
	end

	local money = positiveAmount(def.grantMoney) and math.floor(def.grantMoney) or 0
	local carId = type(def.grantCar) == "string" and def.grantCar or nil
	if money == 0 and not carId then
		return false -- nothing one-time about this pass
	end
	if carId and not CarRegistry.exists(carId) then
		warn("MonetizationService: " .. passKey .. ".grantCar is not a car id -> " .. tostring(carId))
		return false
	end

	-- Not loaded, or a temp profile: skip and retry next join rather than grant unlatchably.
	local profile = persistableProfile(player)
	if not profile then
		return false
	end
	local flags = flagsTable(profile)
	if not flags then
		return false
	end
	local flag = FLAG_PASS_PREFIX .. passKey
	if flags[flag] then
		return false
	end

	flags[flag] = true
	profile.dirty = true
	if money > 0 then
		profileCall("addMoney", player, money)
	end
	if carId then
		profileCall("grantCar", player, carId)
	end
	return true
end

-- Settles every owned pass's one-time grants. Safe to call repeatedly; the latch decides.
local function applyOutstandingGrants(player: Instance)
	if not scannedByPlayer[player] then
		return -- ownership unknown yet; the scan calls this again when it lands
	end
	local owned = ownedByPlayer[player]
	if not owned then
		return
	end

	local granted = false
	for key in pairs(owned) do
		if applyPassGrants(player, key) then
			granted = true
		end
	end
	if granted then
		flushProfile(player)
	end
end

-- ==========================================================================
-- ownership
-- ==========================================================================

--[[ One ownership query, retried a few times on the purchase path only.
	UserOwnsGamePassAsync caches per user/pass, so the query immediately after a purchase can
	still answer false; a short bounded retry usually rides that out. If it never flips, the
	next join's scan picks the pass up and the latch keeps the grant to once ever. ]]
local RETRY_WAIT = 2
local function verifyOwnership(player: Instance, gamePassId: number, attempts: number): (boolean, boolean)
	for attempt = 1, attempts do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
		end)
		-- The query yields; the player may have left.
		if not player:IsDescendantOf(Players) then
			return false, false
		end
		if ok and result == true then
			return true, true
		end
		if attempt < attempts then
			task.wait(RETRY_WAIT)
			if not player:IsDescendantOf(Players) then
				return false, false
			end
		elseif ok then
			return true, false -- queried cleanly, genuinely not owned
		else
			warn("MonetizationService: pass query failed -> " .. tostring(result))
			return false, false
		end
	end
	return false, false
end

--[[ Resolves pass ownership for one player at join. Every configured pass is its own query
	in its own pcall: a Marketplace outage degrades this session to "no perks" and must never
	block the join or error out. Failures are counted and reported as ONE line, so an outage
	cannot turn into a warn flood. ]]
local function scanOwnership(player: Instance)
	local owned = {}
	local failures = 0

	for key, def in pairs(Config.PASSES) do
		if type(def.id) == "number" and def.id ~= 0 then
			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
			end)
			-- Yields per query: bail out entirely if they left mid-scan.
			if not player:IsDescendantOf(Players) then
				return
			end
			if ok then
				if result == true then
					owned[key] = true
				end
			else
				failures += 1
			end
		end
	end

	if failures > 0 then
		warn(
			string.format(
				"MonetizationService: %d pass check(s) failed for %s — perks off this session",
				failures,
				player.Name
			)
		)
	end

	ownedByPlayer[player] = owned
	scannedByPlayer[player] = true
	writePerkAttributes(player)
	applyOutstandingGrants(player)
end

--[[ Runs when ProfileService flips ProfileLoaded true. Mirrors Spins — this service owns that
	attribute, so ProfileService's own mirror() cannot write it — and settles any one-time
	pass grant that was waiting on the profile. ]]
local function onProfileReady(player: Instance)
	if readiedByPlayer[player] then
		return
	end
	local profile = readyProfile(player)
	if not profile then
		return
	end
	readiedByPlayer[player] = true

	writeSpinsAttribute(player, type(profile.spins) == "number" and profile.spins or 0)
	applyOutstandingGrants(player)
end

local function onPlayerAdded(player: Instance)
	if not isPlayer(player) then
		return
	end

	--[[ Definite values BEFORE any async work: the shop UI and the HUD must never read a nil
		perk or a nil multiplier. ]]
	ownedByPlayer[player] = {}
	scannedByPlayer[player] = nil
	readiedByPlayer[player] = nil
	writePerkAttributes(player)
	writeSpinsAttribute(player, 0)

	--[[ Profile load and pass ownership resolve independently, so whichever finishes last
		settles the one-time grants. Both paths are latch-guarded, so "both" is safe. ]]
	local conn
	conn = player:GetAttributeChangedSignal(ATTR.PROFILE_LOADED):Connect(function()
		if player:GetAttribute(ATTR.PROFILE_LOADED) == true then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			loadedConnByPlayer[player] = nil
			onProfileReady(player)
		end
	end)
	loadedConnByPlayer[player] = conn

	-- Already loaded (script hot-reload, or the load simply beat us here).
	if player:GetAttribute(ATTR.PROFILE_LOADED) == true then
		if conn then
			conn:Disconnect()
			conn = nil
		end
		loadedConnByPlayer[player] = nil
		onProfileReady(player)
	end

	task.spawn(scanOwnership, player)
end

local function onPlayerRemoving(player: Instance)
	local conn = loadedConnByPlayer[player]
	if conn then
		conn:Disconnect()
	end
	loadedConnByPlayer[player] = nil
	ownedByPlayer[player] = nil
	scannedByPlayer[player] = nil
	readiedByPlayer[player] = nil
end

--[[ Pass purchase. The event alone is NEVER trusted — it is a client-driven signal and the
	perk it unlocks is worth Robux — so ownership is re-verified against Marketplace before
	anything is granted. ]]
local VERIFY_ATTEMPTS = 3
local function onPassPurchaseFinished(player: Instance, gamePassId: number, wasPurchased: boolean)
	if not isPlayer(player) or wasPurchased ~= true then
		return
	end
	local entry = passById[gamePassId]
	if not entry then
		return -- a pass we do not sell, or an id that is still 0 in Config
	end

	local queried, owns = verifyOwnership(player, gamePassId, VERIFY_ATTEMPTS)
	if not player:IsDescendantOf(Players) then
		return
	end
	if not queried then
		-- Could not confirm. The next join's scan settles it; the latch keeps it once ever.
		warn("MonetizationService: could not verify " .. entry.key .. " for " .. player.Name .. " — retried at next join")
		return
	end
	if not owns then
		return
	end

	local owned = ownedByPlayer[player]
	if not owned then
		owned = {}
		ownedByPlayer[player] = owned
	end
	owned[entry.key] = true
	writePerkAttributes(player)

	if applyPassGrants(player, entry.key) then
		flushProfile(player)
	end
end

-- ==========================================================================
-- ProcessReceipt
-- ==========================================================================

--[[ Grant dispatch, keyed by Config.PRODUCTS[*].grant — a table, not an if-chain, so adding a
	product type is one entry here and one line in Config.
	A handler returns TRUE only when the grant is CONFIRMED. Anything else becomes
	NotProcessedYet, so a failed or unhandled grant costs the player nothing. ]]
local GRANTS = {
	gems = function(player: Instance, amount: number): boolean
		local ok, balance = profileCall("addGems", player, amount)
		return ok and type(balance) == "number"
	end,

	money = function(player: Instance, amount: number): boolean
		local ok, balance = profileCall("addMoney", player, amount)
		return ok and type(balance) == "number"
	end,

	spins = function(player: Instance, amount: number): boolean
		return grantSpins(player, amount)
	end,

	--[[ An extra life is live-round state and SpawnService is the sole writer of the Lives
		attribute, so this has to go through a SpawnService mutator. addLives does not exist
		yet (HANDOFF has it). Rather than reach across and write another service's attribute,
		we refuse: the receipt stays unconsumed and Roblox re-delivers it once the function
		lands, so the player keeps their purchase instead of losing it. ]]
	extraLife = function(player: Instance, amount: number): boolean
		local spawnService = serverCtx and serverCtx.svc and serverCtx.svc.SpawnService
		local fn = type(spawnService) == "table" and spawnService.addLives or nil
		if type(fn) ~= "function" then
			if not warnedNoAddLives then
				warnedNoAddLives = true
				warn(
					"MonetizationService: SpawnService.addLives is missing — Extra Life purchases are HELD "
						.. "(NotProcessedYet) until it exists (see MonetizationService HANDOFF)"
				)
			end
			return false
		end
		local ok, result = pcall(fn, player, amount)
		return ok and result == true
	end,
}

--[[ Rolling ring of the last RING_SIZE purchase ids. Roblox re-delivers a receipt until it is
	consumed, so a second delivery of something we already granted must be idempotent.
	LIMIT, stated plainly: the ring is server memory. A receipt re-delivered to a DIFFERENT
	server is not deduped by it, so a crash between granting and returning can double-grant —
	always in the player's favour, never against. Closing that needs a persisted receipt
	ledger; it is deliberately out of scope here. ]]
local function rememberReceipt(purchaseId: string)
	receiptIndex = receiptIndex % RING_SIZE + 1
	local evicted = receiptRing[receiptIndex]
	if evicted then
		receiptSeen[evicted] = nil
	end
	receiptRing[receiptIndex] = purchaseId
	receiptSeen[purchaseId] = true
end

local function processReceipt(info)
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet

	if type(info) ~= "table" or info.PurchaseId == nil then
		return RETRY
	end
	local purchaseId = tostring(info.PurchaseId)

	-- Already granted: consume it again without granting again.
	if receiptSeen[purchaseId] then
		return GRANTED
	end

	--[[ Unknown id: do NOT consume. Either it is not ours, or an id went missing from Config —
		and in the second case the purchase is still recoverable once the id is back. ]]
	local entry = productById[info.ProductId]
	if not entry then
		return RETRY
	end

	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player or not player:IsDescendantOf(Players) then
		return RETRY -- left mid-purchase; Roblox re-delivers on their next join
	end

	--[[ TEMP PROFILE = the DataStore is down for this player, and ProfileService will refuse
		to persist anything we write. Returning PurchaseGranted here would take Robux and hand
		back something guaranteed to vanish at the end of the session. NotProcessedYet keeps
		the receipt alive so Roblox re-delivers it into a session that can actually keep it. ]]
	if not persistableProfile(player) then
		return RETRY
	end

	local handler = GRANTS[entry.def.grant]
	if type(handler) ~= "function" then
		warn(
			"MonetizationService: no grant handler for '"
				.. tostring(entry.def.grant)
				.. "' ("
				.. entry.key
				.. ") — receipt held"
		)
		return RETRY
	end
	if not positiveAmount(entry.def.amount) then
		warn("MonetizationService: " .. entry.key .. " has no positive amount — receipt held")
		return RETRY
	end

	local okHandler, granted = pcall(handler, player, math.floor(entry.def.amount))
	if not okHandler then
		warn("MonetizationService: grant errored for " .. entry.key .. " -> " .. tostring(granted))
		return RETRY
	end
	if granted ~= true then
		return RETRY -- never report a purchase we did not actually deliver
	end

	--[[ Marked ONLY after a confirmed grant. Marking earlier would make a FAILED grant look
		delivered on the next delivery, which is exactly how a player loses paid currency. ]]
	rememberReceipt(purchaseId)

	-- Durable before we say "granted", so a crash after this cannot lose the purchase.
	flushProfile(player)

	return GRANTED
end

-- ==========================================================================
-- prompts — the functions a Monetization remote gets wired to (see HANDOFF)
-- ==========================================================================

--[[ Throttled inside rather than at a future remote boundary, deliberately: these ARE the
	remote handlers, and nobody legitimately opens two purchase prompts inside Net.REQUEST_GAP. ]]
function MonetizationService.promptProduct(player: Instance, key: string): (boolean, string)
	if not isPlayer(player) then
		return false, MSG.UNAVAILABLE
	end
	local def = type(key) == "string" and Config.PRODUCTS[key] or nil
	if not def then
		warn("MonetizationService.promptProduct: unknown product key " .. tostring(key))
		return false, MSG.UNAVAILABLE
	end
	if type(def.id) ~= "number" or def.id == 0 then
		return false, MSG.UNAVAILABLE -- id not pasted yet: inert, not broken
	end
	if promptGate and not promptGate(player) then
		return false, MSG.NOT_READY
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, def.id)
	end)
	if not ok then
		warn("MonetizationService: PromptProductPurchase failed for " .. key .. " -> " .. tostring(err))
		return false, MSG.UNAVAILABLE
	end
	return true, ""
end

function MonetizationService.promptPass(player: Instance, key: string): (boolean, string)
	if not isPlayer(player) then
		return false, MSG.UNAVAILABLE
	end
	local def = type(key) == "string" and Config.PASSES[key] or nil
	if not def then
		warn("MonetizationService.promptPass: unknown pass key " .. tostring(key))
		return false, MSG.UNAVAILABLE
	end
	if type(def.id) ~= "number" or def.id == 0 then
		return false, MSG.UNAVAILABLE
	end
	if MonetizationService.hasPerk(player, def.perk) then
		return false, MSG.ALREADY
	end
	if promptGate and not promptGate(player) then
		return false, MSG.NOT_READY
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, def.id)
	end)
	if not ok then
		warn("MonetizationService: PromptGamePassPurchase failed for " .. key .. " -> " .. tostring(err))
		return false, MSG.UNAVAILABLE
	end
	return true, ""
end

-- ==========================================================================
-- free rewards — both once ever, both persisted
-- ==========================================================================

--[[ Free gems for joining the group. GROUP_ID is 0 until a real id is pasted, and at 0 the
	whole feature is skipped: no check, no latch, no warn — exactly like a product id of 0. ]]
function MonetizationService.claimGroupReward(player: Instance): (boolean, string)
	if not isPlayer(player) or GROUP_ID == 0 then
		return false, MSG.UNAVAILABLE
	end
	if not positiveAmount(CFG.FREE_GEMS_GROUP) then
		return false, MSG.UNAVAILABLE
	end
	if promptGate and not promptGate(player) then
		return false, MSG.NOT_READY
	end

	local profile = persistableProfile(player)
	local flags = profile and flagsTable(profile) or nil
	if not profile or not flags then
		return false, MSG.NOT_READY
	end
	if flags[FLAG_GROUP_REWARD] then
		return false, MSG.ALREADY
	end

	-- Verified server-side. A client claim is never taken at face value.
	local ok, inGroup = pcall(function()
		return player:IsInGroup(GROUP_ID)
	end)
	if not player:IsDescendantOf(Players) then
		return false, MSG.UNAVAILABLE
	end
	if not ok then
		warn("MonetizationService: IsInGroup failed -> " .. tostring(inGroup))
		return false, MSG.NOT_READY
	end
	if inGroup ~= true then
		return false, MSG.NEED_GROUP
	end

	-- IsInGroup yielded: re-fetch the profile and re-check the latch before granting.
	profile = persistableProfile(player)
	flags = profile and flagsTable(profile) or nil
	if not profile or not flags then
		return false, MSG.NOT_READY
	end
	if flags[FLAG_GROUP_REWARD] then
		return false, MSG.ALREADY
	end

	-- No yield from here: latch and gems land in the same profile table, saved together.
	flags[FLAG_GROUP_REWARD] = true
	profile.dirty = true
	local okGems, balance = profileCall("addGems", player, math.floor(CFG.FREE_GEMS_GROUP))
	if not okGems or type(balance) ~= "number" then
		flags[FLAG_GROUP_REWARD] = nil -- grant failed: give the latch back
		return false, MSG.NOT_READY
	end

	flushProfile(player)
	return true, MSG.OK
end

--[[ Free spins for favouriting the game. There is NO server API to verify a favourite, so
	this one is taken on trust — which is precisely why it is a once-ever grant of
	CFG.FREE_SPINS_FAVOURITE, latched in the profile, and worth no Robux. Worst case is a
	player who did not favourite getting three spins, once, ever. ]]
function MonetizationService.claimFavouriteReward(player: Instance): (boolean, string)
	if not isPlayer(player) or not positiveAmount(CFG.FREE_SPINS_FAVOURITE) then
		return false, MSG.UNAVAILABLE
	end
	if promptGate and not promptGate(player) then
		return false, MSG.NOT_READY
	end

	local profile = persistableProfile(player)
	local flags = profile and flagsTable(profile) or nil
	if not profile or not flags then
		return false, MSG.NOT_READY
	end
	if flags[FLAG_FAVOURITE_REWARD] then
		return false, MSG.ALREADY
	end

	-- No yield: latch and spins are the same profile table, saved together or not at all.
	flags[FLAG_FAVOURITE_REWARD] = true
	profile.dirty = true
	if not grantSpins(player, math.floor(CFG.FREE_SPINS_FAVOURITE)) then
		flags[FLAG_FAVOURITE_REWARD] = nil
		return false, MSG.NOT_READY
	end

	flushProfile(player)
	return true, MSG.OK
end

-- ==========================================================================
-- limited rotation
-- ==========================================================================

--[[ The current limited offer, derived from the clock ALONE.
	os.time() is UTC epoch seconds, so every server and every client computes the same key and
	the same endsAt with zero replication — which is what lets the shop show a countdown that
	physically cannot lie about when the offer rotates (Config's honesty rule).
	`endsAt` is an absolute epoch second: the client's countdown is endsAt - os.time().
	The returned key may name a PRODUCTS entry OR a PASSES entry (LIMITED_POOL mixes both),
	so a caller must look in both. Returns nil when the pool or rotation is misconfigured. ]]
function MonetizationService.currentLimited(): (string?, number)
	local shop = Config.SHOP
	local pool = shop and shop.LIMITED_POOL or nil
	local period = shop and shop.LIMITED_ROTATION_SECONDS or nil
	if type(pool) ~= "table" or #pool == 0 then
		return nil, 0
	end
	if not positiveAmount(period) then
		return nil, 0
	end

	local slot = math.floor(os.time() / period)
	local index = slot % #pool + 1
	return pool[index], (slot + 1) * period
end

-- ==========================================================================
-- init
-- ==========================================================================

--[[ ONE line, so an unconfigured catalog is obvious at a glance instead of presenting as
	silence. In Studio it rides Config.VERBOSE_BOOT with every other boot diagnostic (so no
	print ever reaches a player); in a LIVE server a completely empty catalog is a real
	problem, and that case warns exactly once. ]]
local function summarize()
	local line = string.format(
		"MonetizationService: %d/%d products, %d/%d passes configured",
		configuredProducts,
		totalProducts,
		configuredPasses,
		totalPasses
	)
	if Config.VERBOSE_BOOT then
		print(line)
	elseif configuredProducts == 0 and configuredPasses == 0 then
		warn(line .. " — monetization is INERT (paste ids into Config.PRODUCTS / Config.PASSES)")
	end
end

function MonetizationService.init(ctx)
	if initialized then
		return
	end
	initialized = true
	serverCtx = ctx
	promptGate = Net.throttle()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Anyone already present (Studio start, script hot-reload).
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	-- Premium can start or lapse mid-session; the multiplier must follow it.
	Players.PlayerMembershipChanged:Connect(function(player)
		if isPlayer(player) and player.Parent then
			writePerkAttributes(player)
		end
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchaseFinished)

	--[[ Set exactly once, from here. ProcessReceipt is a single global callback — a second
		assignment anywhere in the game would silently replace this one and every receipt with
		it, so this service is the only place that may touch it. ]]
	MarketplaceService.ProcessReceipt = processReceipt

	--[[ The Monetization remote. Each entry point already checks isPlayer, resolves the key
		against Config.PRODUCTS / Config.PASSES, treats an unpasted id (0) as inert and gates on
		promptGate — the note above promptProduct states outright that those ARE the remote
		handlers. So this bridge owns exactly two things: rejecting a malformed action, and
		echoing back the MSG string the API already returns. ]]
	local monetization = ctx.net and ctx.net.Monetization
	if monetization then
		local ACTIONS = {
			product = MonetizationService.promptProduct,
			pass = MonetizationService.promptPass,
			claimGroup = MonetizationService.claimGroupReward,
			claimFavourite = MonetizationService.claimFavouriteReward,
		}

		monetization.OnServerEvent:Connect(function(player, action, key)
			if not isPlayer(player) then
				return
			end
			local handler = type(action) == "string" and ACTIONS[action] or nil
			if not handler then
				return -- unknown action: ignore, the same as an unknown remote
			end
			if key ~= nil and type(key) ~= "string" then
				return -- the only shape the pinned contract allows
			end

			-- pcall'd: a throwing entry point must not kill the connection for everyone else.
			local called, ok, message = pcall(handler, player, key)
			if not called then
				warn("MonetizationService: " .. action .. " handler errored -> " .. tostring(ok))
				monetization:FireClient(player, "failed", { reason = MSG.UNAVAILABLE })
				return
			end
			if not ok then
				monetization:FireClient(player, "failed", { reason = message or MSG.UNAVAILABLE })
			end
		end)
	else
		warn("MonetizationService: ctx.net.Monetization missing — the shop cannot reach the server")
	end

	summarize()
end

return MonetizationService
