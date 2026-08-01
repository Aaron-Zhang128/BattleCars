--[[ BountyService
	Bounty mode: everyone is hunting exactly ONE named car, and everyone is worth a
	price that grows for as long as they stay alive.

	OWNS — nothing else in the game may write either of these:
		Player  Config.ATTR.BOUNTY_TARGET  userId of the car they are sent after, 0 = none
		Player  Config.ATTR.BOUNTY         what THEY are worth to whoever wrecks them

	DATA FLOW
		MatchState.onPhaseChanged  -> arms on Match, stands down on anything else. PHASE
		                              driven rather than called by MatchService, so this
		                              whole mode needed no edit to the round loop (the
		                              same shape LuckyBlockService already uses).
		ModeService.onKill         -> onKill(killer, victim). The ONE branch this mode
		                              adds to another service: here the PRICE is the kill
		                              payment, so ModeService hands the payout over
		                              instead of paying its flat KILL_POINTS.
		Heartbeat every Config.BOUNTY.TICK -> prices grow; anyone whose mark is gone gets
		                              a fresh roller.

	REMOTES (S->C, fire only)
		BountyEvent  "roll" | "claim" | "lost"   payloads pinned in Net.

	SERVICES USED — resolved LAZILY through ctx.svc at call time, never at init:
		SpawnService  isAlive
		ScoreService  addPoints

	THE ROLLER IS THE REVEAL. A contract is decided the moment it is needed, but
	BOUNTY_TARGET is NOT written until the reel lands, Config.BOUNTY.ROLL_SECONDS
	later. Writing it up front would paint the car red a second and a half before its
	name came up, which is the one thing that would make a roller pointless. Both sides
	key off one workspace:GetServerTimeNow() stamp, so a laggy client gets a SHORT spin
	and never a wrong name -- the same contract the lucky-block reel runs on.

	PRICES ARE SERVER TRUTH, published as attributes. Every client draws every car's
	price straight off the Player, so a nametag needs no remote and a joiner is correct
	on the frame they arrive.

	PUBLIC API
		onKill(killer, victim)  priceOf(player)  isArmed()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))

local ATTR = Config.ATTR
local CFG = Config.BOUNTY

local BountyService = {}

local ctxRef
local bountyRemote
local rng = Random.new()
local warned = {}

local armed = false
--[[ Per-player round state. aliveSince is the clock the CURRENT life began -- the only
	input to a price -- and it is nil for anyone not driving, which is what makes "dead
	men stop appreciating" fall out for free rather than needing its own branch. ]]
local aliveSince = {} -- [Player] = os.clock() their current life started
local pendingRoll = {} -- [Player] = the Player their spinning reel will land on
local lostAt = {} -- [Player] = os.clock() they lost a mark; the next roll waits REGRAB_DELAY

-- ==========================================================================
-- helpers
-- ==========================================================================
local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player") and value.Parent ~= nil
end

--[[ Resolves ctx.svc[service][fn] at CALL time and pcalls it. Warns once per call site,
	so a half-second tick can never flood the output. Mirrors ModeService's helper. ]]
local function call(serviceName: string, fnName: string, ...)
	local service = ctxRef and ctxRef.svc[serviceName]
	local fn = type(service) == "table" and service[fnName] or nil
	local key = serviceName .. "." .. fnName

	if type(fn) ~= "function" then
		if not warned[key] then
			warned[key] = true
			warn("BountyService: " .. key .. " unavailable")
		end
		return nil
	end

	local ok, result = pcall(fn, ...)
	if not ok then
		if not warned[key] then
			warned[key] = true
			warn("BountyService: " .. key .. " failed -> " .. tostring(result))
		end
		return nil
	end
	return result
end

local function fire(player, kind: string, payload)
	if bountyRemote and isPlayer(player) then
		bountyRemote:FireClient(player, kind, payload or {})
	end
end

local function isDriving(player): boolean
	return call("SpawnService", "isAlive", player) == true
end

--[[ The whole economy in one line: a life opens at START and gains PER_SECOND for every
	second it survives, quantised to STEP because this number hangs over a car in world
	space -- a price that steps up in readable jumps beats one churning every frame. ]]
local function priceFor(seconds: number): number
	local raw = CFG.START + CFG.PER_SECOND * math.max(0, seconds)
	local stepped = math.floor(raw / CFG.STEP + 0.5) * CFG.STEP
	return math.clamp(stepped, CFG.START, CFG.MAX)
end

local function setPrice(player, value: number)
	if player:GetAttribute(ATTR.BOUNTY) ~= value then
		player:SetAttribute(ATTR.BOUNTY, value)
	end
end

local function setTarget(player, userId: number)
	if player:GetAttribute(ATTR.BOUNTY_TARGET) ~= userId then
		player:SetAttribute(ATTR.BOUNTY_TARGET, userId)
	end
end

-- ==========================================================================
-- picking a mark
-- ==========================================================================
--[[ Every driver except the hunter themselves. A contract on a car nobody can reach --
	someone sitting on the death card, or gone from the server -- is the one thing that
	would break the mode's promise that you ALWAYS have somewhere to be. ]]
local function candidates(hunter)
	local pool = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= hunter and isDriving(player) then
			table.insert(pool, player)
		end
	end
	return pool
end

--[[ Spread the contracts. Among everyone eligible, the LEAST hunted go in the hat, and
	the hat is drawn from at random -- so eight players produce eight different marks
	rather than eight copies of whoever the first roll happened to like. The hunter's
	own previous mark is dropped from the hat whenever anybody else is available, which
	is what stops a two-car duel re-rolling the same name forever. ]]
local function pickTarget(hunter)
	local pool = candidates(hunter)
	if #pool == 0 then
		return nil
	end

	local hunted = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local id = GameModes.targetIdOf(player)
		if id ~= 0 then
			hunted[id] = (hunted[id] or 0) + 1
		end
		local pendingTarget = pendingRoll[player]
		if pendingTarget then
			hunted[pendingTarget.UserId] = (hunted[pendingTarget.UserId] or 0) + 1
		end
	end

	local previousId = GameModes.targetIdOf(hunter)
	local best, bestCount = {}, math.huge
	for _, player in ipairs(pool) do
		local count = hunted[player.UserId] or 0
		if player.UserId == previousId then
			count += 1 -- a tie-break penalty, not a ban: with one rival left they win it back
		end
		if count < bestCount then
			best, bestCount = { player }, count
		elseif count == bestCount then
			table.insert(best, player)
		end
	end

	return best[rng:NextInteger(1, #best)]
end

--[[ The strip the reel scrolls. Tiles before the winner, tiles after it (REEL_TAIL, so
	the landing settle never runs off the end), and the winner at landIndex. Drawn from
	the same pool the pick came from, so every face on the reel is a car that really is
	out there -- with a small server the pool repeats, which is what a reel does anyway. ]]
local function buildReel(pool, winner)
	local reel = {}
	local function tile(player)
		table.insert(reel, {
			userId = player.UserId,
			name = player.DisplayName,
			bounty = GameModes.bountyOf(player),
		})
	end

	for _ = 1, CFG.REEL_TILES do
		tile(pool[rng:NextInteger(1, #pool)])
	end
	tile(winner)
	local landIndex = #reel
	for _ = 1, CFG.REEL_TAIL do
		tile(pool[rng:NextInteger(1, #pool)])
	end
	return reel, landIndex
end

--[[ Opens a roller and hands the contract over when it LANDS. Everything is re-checked
	after the delay: the round may have ended, the mark may have left or been wrecked by
	somebody else mid-spin, or a later roll may have superseded this one. In any of those
	cases the target is simply left at 0 and the next tick opens a fresh roller -- a
	stale contract would be worse than a one-tick gap. ]]
local function beginRoll(hunter)
	local pool = candidates(hunter)
	if #pool == 0 then
		return
	end
	local winner = pickTarget(hunter)
	if not winner then
		return
	end

	--[[ A reel that can only land on one name is theatre, and on a two-car server it is
		theatre that plays every few seconds -- a 2.8 second card between you and the
		road, telling you the thing you already knew. With a single candidate the
		contract is handed over silently and the client just flashes the chip. ]]
	if #pool < 2 then
		lostAt[hunter] = nil
		setTarget(hunter, winner.UserId)
		fire(hunter, "assign", {
			targetId = winner.UserId,
			targetName = winner.DisplayName,
			targetBounty = GameModes.bountyOf(winner),
		})
		return
	end

	pendingRoll[hunter] = winner
	lostAt[hunter] = nil
	setTarget(hunter, 0)

	local reel, landIndex = buildReel(pool, winner)
	local duration = CFG.ROLL_SECONDS
	fire(hunter, "roll", {
		targetId = winner.UserId,
		targetName = winner.DisplayName,
		targetBounty = GameModes.bountyOf(winner),
		reel = reel,
		landIndex = landIndex,
		startedAt = workspace:GetServerTimeNow(),
		duration = duration,
	})

	task.delay(duration, function()
		if pendingRoll[hunter] ~= winner then
			return -- superseded by a later roll, or stood down
		end
		pendingRoll[hunter] = nil
		if not armed or not isPlayer(hunter) or not isPlayer(winner) then
			return
		end
		setTarget(hunter, winner.UserId)
	end)
end

-- ==========================================================================
-- the tick — prices grow, empty contracts refill
-- ==========================================================================
local function stepPlayer(player, now: number)
	local driving = isDriving(player)

	if not driving then
		--[[ Dying takes a price back to START (Config.BOUNTY.RESET_ON_DEATH). That is
			what stops one player snowballing an unclaimable number and what makes a long
			life something to defend rather than something that just happened. ]]
		aliveSince[player] = nil
		if CFG.RESET_ON_DEATH then
			setPrice(player, CFG.START)
		end
		return
	end

	local since = aliveSince[player]
	if not since then
		since = now
		aliveSince[player] = since
	end
	setPrice(player, priceFor(now - since))

	if pendingRoll[player] then
		return -- their reel is still spinning
	end

	local mark = GameModes.targetOf(player)
	if mark and isDriving(mark) then
		return
	end

	-- No mark, or a mark that cannot be chased. Hold the beat, then roll a new one.
	if mark or GameModes.targetIdOf(player) ~= 0 then
		setTarget(player, 0)
		lostAt[player] = lostAt[player] or now
	end
	local waitingSince = lostAt[player]
	if waitingSince and now - waitingSince < CFG.REGRAB_DELAY then
		return
	end
	beginRoll(player)
end

local accum = 0
local function onHeartbeat(dt: number)
	accum += dt
	if accum < CFG.TICK then
		return
	end
	accum = 0

	if not armed then
		return
	end
	if not MatchState.isMatch() or not GameModes.hasBounty() then
		BountyService.standDown()
		return
	end

	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		stepPlayer(player, now)
	end
end

-- ==========================================================================
-- arming
-- ==========================================================================
local function armUp()
	if armed then
		return
	end
	armed = true
	table.clear(aliveSince)
	table.clear(pendingRoll)
	table.clear(lostAt)
	for _, player in ipairs(Players:GetPlayers()) do
		setTarget(player, 0)
		setPrice(player, CFG.START)
	end
end

--[[ Safe to call at any time, and called on every phase that is not a bounty Match --
	the attributes must not survive the round, or a Crown Rush nametag would still be
	quoting a price and somebody would still be wearing red. ]]
function BountyService.standDown()
	armed = false
	table.clear(aliveSince)
	table.clear(pendingRoll)
	table.clear(lostAt)
	for _, player in ipairs(Players:GetPlayers()) do
		setTarget(player, 0)
		setPrice(player, 0)
	end
end

function BountyService.isArmed(): boolean
	return armed
end

function BountyService.priceOf(player): number
	return GameModes.bountyOf(player)
end

-- ==========================================================================
-- kills
-- ==========================================================================
--[[ ModeService.onKill hands the whole payout over in this mode, because here the PRICE
	is the payment -- a flat KILL_POINTS beside it would quietly make the price cosmetic.

	Your contract pays its full price plus CLAIM_BONUS; anybody else pays a fraction of
	theirs, because a shot that lands should never be worth literally nothing, while
	taking the car you were actually sent after has to be worth several times more.

	Everyone ELSE hunting the same victim is told they lost their mark and re-rolls on
	the next tick -- including, deliberately, the killer, whose contract is now complete. ]]
function BountyService.onKill(killer, victim)
	if not armed or not isPlayer(victim) then
		return
	end

	local price = GameModes.bountyOf(victim)
	local now = os.clock()

	if isPlayer(killer) and killer ~= victim then
		local wasTarget = GameModes.isTargetOf(killer, victim)
		local paid = price * (wasTarget and CFG.CLAIM_FRACTION or CFG.OFF_TARGET_FRACTION)
		if wasTarget then
			paid += CFG.CLAIM_BONUS
		end
		paid = math.floor(paid)
		if paid > 0 then
			call("ScoreService", "addPoints", killer, paid)
		end
		fire(killer, "claim", {
			victimName = victim.DisplayName,
			amount = paid,
			wasTarget = wasTarget,
		})
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if GameModes.isTargetOf(player, victim) then
			setTarget(player, 0)
			lostAt[player] = now
			if player ~= killer then
				fire(player, "lost", {})
			end
		end
	end

	--[[ The victim's own price is not reset here: stepPlayer does it the moment it sees
		they are not driving, which is the same rule a fall-kill and a disconnect go
		through. One place decides what a dead player is worth. ]]
end

-- ==========================================================================
-- players
-- ==========================================================================
local function onPlayerAdded(player)
	-- Defaults immediately, so nothing ever reads nil off a fresh player.
	setTarget(player, 0)
	setPrice(player, armed and CFG.START or 0)
end

local function onPlayerRemoving(player)
	aliveSince[player] = nil
	pendingRoll[player] = nil
	lostAt[player] = nil
	--[[ Anyone hunting the leaver keeps a dead contract for at most one tick: the mark
		resolves to nil there and stepPlayer rolls them a fresh one. No special case. ]]
end

function BountyService.init(ctx)
	ctxRef = ctx
	bountyRemote = ctx.net and ctx.net.BountyEvent or nil

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	--[[ Phase driven, which is why MatchService needed no edit for this mode. The mode
		itself is checked here as well as on the tick: the phase flips to Match before
		ModeService has necessarily settled, and arming into a Crown Rush would paint
		half the field white. ]]
	MatchState.onPhaseChanged(function(phase)
		if phase == MatchState.PHASES.MATCH and GameModes.hasBounty() then
			armUp()
		else
			BountyService.standDown()
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return BountyService
