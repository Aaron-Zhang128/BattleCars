--[[ DailyRewardService (server service)
	The 7-day login track behind the uploaded kit's Daily window. One free reward per UTC
	day, escalating, wrapping 7 -> 1, with a car as the week's hero prize.

	THE SERVER IS THE ONLY CLOCK. The client renders whatever `state` says and asks; it
	never decides claimability, never computes a day, and never sees a reward it was not
	sent. A claim is idempotent: the commit happens with no yield after the readiness test,
	so a double tap cannot pay twice.

	WHY UTC DAYS, NOT "24h SINCE THE LAST CLAIM"
		A rolling 24h cooldown drifts. Claim at 19:00, then 19:40, then 20:15, and inside a
		week the reward has walked out of the player's play window — the classic "I have to
		wait until tomorrow to keep my streak" complaint. A calendar boundary is also what a
		kid already expects the words "daily reward" to mean: it resets overnight, at the
		same moment for everybody. So the entire model is ONE integer:
			today = floor(os.time() / 86400)     -- UTC day index
			claimed today = (today == profile.lastDailyDay)

	MISS POLICY — one missed day is forgiven, two are not.
			gap = today - lastDailyDay
			gap <= 0                       already claimed today
			gap <= MISS_GRACE_DAYS + 1     streak continues (gap 1 = yesterday,
			                               gap 2 = one skipped day; both keep it)
			gap >  MISS_GRACE_DAYS + 1     streak restarts at day 1
		One busy day never punishes. The window cannot hide a lapse: `day` and `claimed` are
		recomputed from the live clock on every sync, so a broken streak shows as day 1 the
		moment it breaks, not at the next claim.

	REMOTE (pinned in Net) — DailyAction
		C->S (action)   "claim" | "sync"           gated by Net.throttle()
		S->C (state)    { day, ready, nextAt, claimed, rewards }
			day      1..DAYS — the day a claim right now would pay, else the next one up
			ready    true only when a claim would actually succeed
			nextAt   NEXT UTC midnight, in the workspace:GetServerTimeNow() domain — the
			         same clock PhaseEndsAt uses, so a wrong device clock cannot skew the
			         countdown. ZERO is the sentinel for "unavailable for this player right
			         now" (profile not loaded, temp profile, or streak fields not persisted);
			         the client paints that as offline instead of as a countdown.
			claimed  per-day booleans for THIS loop
			rewards  per-day { day, kind, amount, label } — the EFFECTIVE reward, already
			         substituted, so a card can never promise something the grant path
			         would not actually deliver.

	GRANTS run through ProfileService only (addMoney / addGems / grantCar / owns). This
	service writes no attribute and owns none — all of its state rides the remote.

	SUBSTITUTION (why `rewards` is per player instead of read straight from the track)
		* The day-7 car is a one-time prize. A player who already owns it is paid gems, on
		  this loop and every loop after — so week two is honest rather than empty.
		* Spins are banked by MonetizationService, which has no public mutator for them yet
		  (HANDOFF: MonetizationService.addSpins). Until it lands, a spins day pays its
		  documented money equivalent rather than stalling the whole track on one bad day.

	PERSISTENCE — profile.dailyStreak + profile.lastDailyDay.
		ProfileService does not carry them through serialize() yet (HANDOFF has the lines).
		DETECTED, never assumed: with no persistence the streak would reset on every rejoin,
		which is a free-reward farm, so claims are REFUSED and warned about once instead of
		granting something guaranteed to evaporate. Exactly the reasoning MonetizationService
		applies to profile.spins / profile.flags.

	INIT ORDER third, after ProfileService (grants) and MonetizationService (the spins
	seam). Siblings resolve LAZILY through ctx.svc at call time, never at init.

	PUBLIC API
		claim(player)      -> payload | nil     the remote's "claim" path; payload for tests
		stateFor(player)   -> state             exactly what the client is sent
		_claimStatus(streak, lastDay, today)    pure, player-free, exposed for smoke tests
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local Net = require(core:WaitForChild("Net"))
local MathUtil = require(core:WaitForChild("Shared"):WaitForChild("MathUtil"))

local DailyRewardService = {}

local ATTR = Config.ATTR -- read only: PROFILE_LOADED (ProfileService owns it)

-- ==========================================================================
-- §1) constants + the reward track
-- ==========================================================================
local SECONDS_PER_DAY = 86400
local SWEEP_SECONDS = 60 -- re-push so `ready` flips at midnight mid-session, not at rejoin

--[[ Config has NO DAILY section yet (HANDOFF has the paste-ready block), so these are the
	tunables for now. Config.DAILY wins the moment it exists, key by key, with no code
	change here — which is also what stops a half-filled Config.DAILY from breaking the
	track. Amounts are sized against Config.ECONOMY: a round pays roughly 200-600 money, so
	a day is worth about half a round up to two, and the whole week is worth less than the
	cheapest mid-tier car. Meaningful to collect, never needed to compete. ]]
local DEFAULTS = {
	MISS_GRACE_DAYS = 1,
	SPIN_MONEY = 400, -- what one banked spin pays while the spins seam is missing
	CAR_OWNED_GEMS = 20, -- day 7 when that car is already in the garage
	REWARDS = {
		{ day = 1, kind = "money", amount = 250, label = "+250 Money" },
		{ day = 2, kind = "money", amount = 500, label = "+500 Money" },
		{ day = 3, kind = "gems", amount = 5, label = "+5 Gems" },
		{ day = 4, kind = "money", amount = 1000, label = "+1,000 Money" },
		{ day = 5, kind = "spins", amount = 3, label = "+3 Spins" },
		{ day = 6, kind = "gems", amount = 15, label = "+15 Gems" },
		{ day = 7, kind = "car", carId = "police", label = "Police Car" },
	},
}

local CFG = type(Config.DAILY) == "table" and Config.DAILY or DEFAULTS

local function tuned(key: string)
	local value = CFG[key]
	if value == nil then
		return DEFAULTS[key]
	end
	return value
end

local REWARDS = tuned("REWARDS")
local DAYS = #REWARDS
local MISS_GRACE_DAYS = tuned("MISS_GRACE_DAYS")
local SPIN_MONEY = tuned("SPIN_MONEY")
local CAR_OWNED_GEMS = tuned("CAR_OWNED_GEMS")

local serverCtx = nil
local initialized = false
local remote = nil
local gate = nil

local lastSignature = {} -- [Player] = string, so the sweep only pushes real changes
local loadedConn = {} -- [Player] = ProfileLoaded listener, disconnected on leave

-- warn-once latches: a half-wired build must not spam the log every single claim.
local warnedNoFields = false
local warnedNoSpins = false

-- ==========================================================================
-- §2) claim status — the ONE piece of claim logic, pure and player-free
-- ==========================================================================
local function utcDay(epochSeconds: number): number
	return math.floor(epochSeconds / SECONDS_PER_DAY)
end

--[[ `streak` in the RESULT is the streak BEFORE this claim (0 once a lapse has reset it),
	so a commit is always status.streak + 1. Everything else in the file reads from here. ]]
local function claimStatus(streak: number, lastDay: number, today: number)
	local held = type(streak) == "number" and math.max(0, math.floor(streak)) or 0
	local last = type(lastDay) == "number" and math.floor(lastDay) or 0

	if last <= 0 then
		return { day = 1, ready = true, streak = 0 } -- never claimed: the first one is free
	end

	local gap = today - last
	if gap <= 0 then
		--[[ Claimed today. A NEGATIVE gap means a stored day in the future — a clock that
			moved backwards, or a save from a machine that was ahead. Refuse rather than
			hand out a second reward for the same day. ]]
		return { day = held % DAYS + 1, ready = false, streak = held }
	elseif gap <= MISS_GRACE_DAYS + 1 then
		return { day = held % DAYS + 1, ready = true, streak = held }
	end
	return { day = 1, ready = true, streak = 0 } -- grace spent: the loop restarts
end

DailyRewardService._claimStatus = claimStatus

-- ==========================================================================
-- §3) profile access
-- ==========================================================================
local function isPlayer(value): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

-- Lazy sibling lookup: services after this one in ORDER do not exist yet at init.
local function profileService()
	return serverCtx and serverCtx.svc and serverCtx.svc.ProfileService or nil
end

local function profileCall(fnName: string, ...): (boolean, any)
	local Profile = profileService()
	local fn = type(Profile) == "table" and Profile[fnName] or nil
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn("DailyRewardService: ProfileService." .. fnName .. " failed -> " .. tostring(result))
		return false, nil
	end
	return true, result
end

--[[ The live profile ONLY when the streak can be read, written AND actually persisted.
	Three refusals, one branch, because they all mean the same thing to a player: we cannot
	safely give you today's reward right now. ]]
local function writableProfile(player: Instance)
	--[==[ Deliberately NOT isPlayer-gated. The remote boundary validates the caller, and
		ProfileService validates again inside every call below, so a second check here would
		buy nothing — while blocking the duck-typed stub player the smoke tests drive this
		path with. push() is where the Instance check that actually matters lives. ]==]
	if player == nil then
		return nil
	end
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

	-- TEMP profile = the DataStore is down for this player. ProfileService will refuse to
	-- persist anything, so granting here would be a gift that vanishes at the end of the
	-- session AND a streak that restarts tomorrow. Refuse instead.
	if profile.temp then
		return nil
	end

	if type(profile.dailyStreak) ~= "number" or type(profile.lastDailyDay) ~= "number" then
		if not warnedNoFields then
			warnedNoFields = true
			warn(
				"DailyRewardService: ProfileService profiles have no `dailyStreak` / `lastDailyDay` — "
					.. "daily rewards are DISABLED so the streak cannot be farmed by rejoining "
					.. "(see DailyRewardService HANDOFF)"
			)
		end
		return nil
	end

	return profile
end

-- ==========================================================================
-- §4) reward resolution + grants
-- ==========================================================================

-- The spins seam. MonetizationService owns the Spins attribute and profile.spins, so a
-- daily spin has to go through it; it has no public mutator yet (HANDOFF).
local function spinsMutator()
	local mon = serverCtx and serverCtx.svc and serverCtx.svc.MonetizationService
	local fn = type(mon) == "table" and mon.addSpins or nil
	return type(fn) == "function" and fn or nil
end

local function ownsCar(player: Instance, carId: string): boolean
	local ok, owned = profileCall("owns", player, carId)
	return ok and owned == true
end

local function moneyReward(day: number, amount: number)
	return { day = day, kind = "money", amount = amount, label = "+" .. MathUtil.comma(amount) .. " Money" }
end

--[[ What day `day` would ACTUALLY pay THIS player right now. The client is sent this rather
	than the raw track, which is what makes it impossible for a card to advertise a reward
	the grant path cannot deliver. ]]
local function effectiveReward(player: Instance, day: number)
	local base = REWARDS[day]
	if type(base) ~= "table" then
		return nil
	end

	if base.kind == "car" then
		-- Already in the garage (or a misconfigured id): pay gems instead of nothing.
		if type(base.carId) ~= "string" or ownsCar(player, base.carId) then
			return { day = day, kind = "gems", amount = CAR_OWNED_GEMS, label = "+" .. CAR_OWNED_GEMS .. " Gems" }
		end
	elseif base.kind == "spins" and not spinsMutator() then
		if not warnedNoSpins then
			warnedNoSpins = true
			warn(
				"DailyRewardService: MonetizationService.addSpins is missing — day "
					.. day
					.. " pays money instead of spins (see DailyRewardService HANDOFF)"
			)
		end
		return moneyReward(day, math.max(1, math.floor((tonumber(base.amount) or 0) * SPIN_MONEY)))
	end

	return { day = day, kind = base.kind, amount = base.amount, carId = base.carId, label = base.label }
end

DailyRewardService._effectiveReward = effectiveReward

--[[ Grant dispatch keyed by kind — a table, not an if-chain, so a new reward kind is one
	entry here and one line in the track. A handler returns TRUE only when the grant is
	CONFIRMED; anything else refuses the claim and commits nothing. ]]
local GRANTS = {
	money = function(player: Instance, reward): boolean
		local ok, balance = profileCall("addMoney", player, reward.amount)
		return ok and type(balance) == "number"
	end,

	gems = function(player: Instance, reward): boolean
		local ok, balance = profileCall("addGems", player, reward.amount)
		return ok and type(balance) == "number"
	end,

	spins = function(player: Instance, reward): boolean
		local add = spinsMutator()
		if not add then
			return false -- effectiveReward substitutes before we ever get here
		end
		local ok, granted = pcall(add, player, reward.amount)
		return ok and granted == true
	end,

	car = function(player: Instance, reward): boolean
		local ok, granted = profileCall("grantCar", player, reward.carId)
		return ok and granted == true
	end,
}

-- ==========================================================================
-- §5) state + push
-- ==========================================================================

-- Next UTC midnight, expressed in the clock the client counts down with.
local function nextMidnight(today: number): number
	return Workspace:GetServerTimeNow() + ((today + 1) * SECONDS_PER_DAY - os.time())
end

local function rewardList(player: Instance)
	local list = table.create(DAYS)
	for day = 1, DAYS do
		list[day] = effectiveReward(player, day)
	end
	return list
end

-- nextAt = 0 is the pinned sentinel for "not available right now" (see the header).
local function unavailableState(player: Instance)
	local claimed = table.create(DAYS)
	for day = 1, DAYS do
		claimed[day] = false
	end
	return { day = 1, ready = false, nextAt = 0, claimed = claimed, rewards = rewardList(player) }
end

function DailyRewardService.stateFor(player: Instance)
	local profile = writableProfile(player)
	if not profile then
		return unavailableState(player)
	end

	local today = utcDay(os.time())
	local status = claimStatus(profile.dailyStreak, profile.lastDailyDay, today)
	local loopIndex = status.streak % DAYS

	--[[ A finished loop stays fully collected until it rolls at midnight, instead of
		blanking all seven cards the instant the seventh is taken. ]]
	local collected = loopIndex
	if not status.ready and status.streak > 0 and loopIndex == 0 then
		collected = DAYS
	end

	local claimed = table.create(DAYS)
	for day = 1, DAYS do
		claimed[day] = day <= collected
	end

	return {
		day = status.day,
		ready = status.ready,
		nextAt = nextMidnight(today),
		claimed = claimed,
		rewards = rewardList(player),
	}
end

local function signatureOf(state): string
	local collected = 0
	for _, done in ipairs(state.claimed) do
		if done then
			collected += 1
		end
	end
	-- The hero day's kind is in the signature so buying the day-7 car repaints that card
	-- on the next sweep instead of waiting for a rejoin.
	local hero = state.rewards[DAYS]
	return string.format(
		"%d|%s|%d|%d|%s",
		state.day,
		tostring(state.ready),
		math.floor(state.nextAt),
		collected,
		hero and tostring(hero.kind) or "?"
	)
end

local function push(player: Instance, state)
	-- typeof-gated so a duck-typed stub player in a smoke test cannot reach FireClient.
	if not remote or not isPlayer(player) or not player.Parent then
		return
	end
	state = state or DailyRewardService.stateFor(player)
	lastSignature[player] = signatureOf(state)
	remote:FireClient(player, state)
end

-- ==========================================================================
-- §6) claim
-- ==========================================================================

--[[ Returns the granted payload, or nil for any refusal. Every refusal still pushes the
	current state, so the window always repaints itself into the truth rather than sitting
	on a stale "Claim" button. ]]
function DailyRewardService.claim(player: Instance)
	local profile = writableProfile(player)
	if not profile then
		push(player, unavailableState(player))
		return nil
	end

	local today = utcDay(os.time())
	local status = claimStatus(profile.dailyStreak, profile.lastDailyDay, today)
	if not status.ready then
		push(player) -- a double tap lands here: refused, and the client re-renders
		return nil
	end

	local reward = effectiveReward(player, status.day)
	local grant = reward and GRANTS[reward.kind] or nil
	if not grant then
		warn(
			"DailyRewardService: no grant handler for day "
				.. status.day
				.. " (kind "
				.. tostring(reward and reward.kind)
				.. ")"
		)
		push(player)
		return nil
	end

	--[[ NOTHING from the readiness test to the commit yields, so check-grant-commit is one
		atomic step: a second claim in the same frame cannot pass the test twice, and the
		streak can never advance without the grant having actually landed. ]]
	if not grant(player, reward) then
		warn("DailyRewardService: grant refused for " .. player.Name .. " day " .. status.day)
		push(player)
		return nil
	end

	-- Commit BEFORE replicating, so what the client is told always matches the profile.
	profile.dailyStreak = status.streak + 1
	profile.lastDailyDay = today
	profile.dirty = true

	push(player)
	return { day = status.day, streak = profile.dailyStreak, reward = reward }
end

-- ==========================================================================
-- §7) init
-- ==========================================================================
local function onPlayerAdded(player: Instance)
	if not isPlayer(player) then
		return
	end

	local conn
	local function settle()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		loadedConn[player] = nil
		if player.Parent then
			push(player)
		end
	end

	--[[ Seeded off ProfileService's own readiness attribute rather than a poll, so the
		window is correct the moment the profile lands instead of up to a sweep tick later. ]]
	conn = player:GetAttributeChangedSignal(ATTR.PROFILE_LOADED):Connect(function()
		if player:GetAttribute(ATTR.PROFILE_LOADED) == true then
			settle()
		end
	end)
	loadedConn[player] = conn

	-- A definite first paint before the profile lands: the window opens honest, never blank.
	push(player, unavailableState(player))

	-- Already loaded (script hot-reload, or the load simply beat us here).
	if player:GetAttribute(ATTR.PROFILE_LOADED) == true then
		settle()
	end
end

local function onPlayerRemoving(player: Instance)
	local conn = loadedConn[player]
	if conn then
		conn:Disconnect()
	end
	loadedConn[player] = nil
	lastSignature[player] = nil
end

--[[ The lazy sweep. Its whole job is the midnight rollover: `ready` has to flip for a
	player who is already in the server, and a lapsed streak has to recompute mid-session.
	Pushes only when the state actually changed, so an idle lobby sends nothing. ]]
local function sweepLoop()
	while true do
		task.wait(SWEEP_SECONDS)
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Parent then
				local state = DailyRewardService.stateFor(player)
				if signatureOf(state) ~= lastSignature[player] then
					push(player, state)
				end
			end
		end
	end
end

function DailyRewardService.init(ctx)
	if initialized then
		return
	end
	initialized = true
	serverCtx = ctx
	gate = Net.throttle()

	remote = ctx and ctx.net and ctx.net.DailyAction or nil
	if not remote then
		warn("DailyRewardService: ctx.net.DailyAction missing — the daily window cannot reach the server")
	else
		remote.OnServerEvent:Connect(function(player, action)
			if not isPlayer(player) or type(action) ~= "string" then
				return
			end
			if action ~= "claim" and action ~= "sync" then
				return -- the only two shapes the pinned contract allows
			end
			if not gate(player) then
				return -- spam: the reply to their first press is already on its way
			end

			-- pcall'd: a throwing claim must not kill the connection for everyone else.
			local ok, err = pcall(function()
				if action == "claim" then
					DailyRewardService.claim(player)
				else
					push(player)
				end
			end)
			if not ok then
				warn("DailyRewardService: " .. action .. " failed -> " .. tostring(err))
			end
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Anyone already present (Studio start, script hot-reload).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(sweepLoop)
end

return DailyRewardService
