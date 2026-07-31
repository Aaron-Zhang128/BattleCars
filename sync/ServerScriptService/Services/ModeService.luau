--[[ ModeService
	The round's ruleset made real: picks the mode, splits the teams, crowns the
	juggernaut, pays the mode's points, and answers "may this hit land?".

	Shared/GameModes is the CONTRACT both sides read. This service is the only WRITER
	of everything that contract describes:
		CrashCore  Config.ATTR.MODE_ID / MODE_NAME
		Player     Config.ATTR.TEAM / Config.ATTR.JUGGERNAUT
	Nothing else in the game may write those four, exactly as MatchService alone owns
	Phase and ScoreService alone owns Crowns.

	DATA FLOW
		MatchService.runLobby  -> nextMode()          rotate. The one safe window, and it
		                                              sits beside ArenaService.nextMap for
		                                              the same reason: nobody is driving.
		MatchService.runMatch  -> startMatch()        teams + juggernaut, BEFORE the first
		                                              car is built — CarFactory reads the
		                                              juggernaut flag to size the body.
		MatchService (tick)    -> shouldEndRound()    last car driving
		MatchService (results) -> finishRound()       the survivor bonus
		SpawnService.resetLives-> livesFor(player)
		SpawnService.spawnCar  -> carModifiersFor(player) -> CarFactory.build(.., mods)
		CombatService          -> canDamage(a, b) ahead of every ram and every weapon hit
		CombatService.killCar  -> onKill(killer, victim)  points + juggernaut succession
		PickupService          -> asks GameModes.usesCrowns() directly; no call needed

	REMOTES (S->C, fire only)
		Notify  the juggernaut headlines. Deliberately the only thing this service says
		        out loud: everything else it does is visible in the world already.

	SERVICES USED — resolved LAZILY through ctx.svc at call time, never captured at init:
		SpawnService  isAlive getLives spawnCar despawnCar
		ScoreService  addPoints

	INIT ORDER
		Before SpawnService (which asks for lives the moment a player joins) and before
		MatchService. Every sibling call goes through the guarded `call` helper, so a
		service that is still loading degrades to one warn instead of killing a round.

	PUBLIC API
		nextMode() startMatch() finishRound() shouldEndRound()
		livesFor(player) carModifiersFor(player) canDamage(attacker, victim)
		onKill(killer, victim) getJuggernaut() teamTotals()
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
local CFG = Config.MODES

local SWEEP_INTERVAL = 0.5 -- how often a vacant juggernaut crown is refilled
local RESET_CAUSE = "reset" -- SpawnService charges no life for this one

local ModeService = {}

local ctxRef
local notifyRemote
local rng = Random.new()
local juggernaut = nil -- the Player driving the monster car right now, or nil
--[[ True until the first round actually starts. init() has to leave ModeId non-nil (a
	client can connect before the first Lobby ticks), which would otherwise make the very
	first nextMode() rotate PAST the flagship mode and open a fresh server on the second
	entry in the rotation. So the first call plays what init already advertised. ]]
local pristine = true
local warned = {}

-- ==========================================================================
-- helpers
-- ==========================================================================
local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player") and value.Parent ~= nil
end

--[[ Resolves ctx.svc[service][fn] at CALL time (Main fills ctx.svc as it goes) and
	pcalls it. Warns once per call site, so a sweep can never flood the output. ]]
local function call(serviceName: string, fnName: string, ...)
	local service = ctxRef and ctxRef.svc[serviceName]
	local fn = type(service) == "table" and service[fnName] or nil
	local key = serviceName .. "." .. fnName

	if type(fn) ~= "function" then
		if not warned[key] then
			warned[key] = true
			warn("ModeService: " .. key .. " unavailable")
		end
		return nil
	end

	local ok, result = pcall(fn, ...)
	if not ok then
		if not warned[key] then
			warned[key] = true
			warn("ModeService: " .. key .. " failed -> " .. tostring(result))
		end
		return nil
	end
	return result
end

local function notify(player, text: string, mood: string?)
	if notifyRemote and isPlayer(player) then
		notifyRemote:FireClient(player, text, mood or "gold")
	end
end

local function notifyOthers(skip, text: string, mood: string?)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= skip then
			notify(player, text, mood)
		end
	end
end

local function isDriving(player): boolean
	return call("SpawnService", "isAlive", player) == true
end

-- ==========================================================================
-- teams
-- ==========================================================================
--[[ Shuffled, then dealt round-robin, so the sides are as even as the roster allows
	and team-mates are never just "whoever joined together". ]]
local function assignTeams()
	local roster = Players:GetPlayers()
	for i = #roster, 2, -1 do
		local j = rng:NextInteger(1, i)
		roster[i], roster[j] = roster[j], roster[i]
	end

	local count = math.max(1, GameModes.teamCount())
	for index, player in ipairs(roster) do
		player:SetAttribute(ATTR.TEAM, (index - 1) % count + 1)
	end
end

-- Where a mid-match joiner goes: whichever side is short, ties to the lower index.
local function smallestTeam(): number
	local count = math.max(1, GameModes.teamCount())
	local sizes = table.create(count, 0)
	for _, player in ipairs(Players:GetPlayers()) do
		local team = GameModes.teamOf(player)
		if team >= 1 and team <= count then
			sizes[team] += 1
		end
	end

	local best, bestSize = 1, math.huge
	for index = 1, count do
		if sizes[index] < bestSize then
			best, bestSize = index, sizes[index]
		end
	end
	return best
end

-- ==========================================================================
-- juggernaut
-- ==========================================================================
local function announceJuggernaut(player)
	if not isPlayer(player) then
		return
	end
	notify(player, "YOU ARE THE JUGGERNAUT!", "gold")
	notifyOthers(player, player.DisplayName .. " is the JUGGERNAUT!", "red")
end

--[[ Exactly one crown at a time. Clearing the previous holder FIRST matters: every
	consumer (CarFactory sizing a body, FxController colouring a car, canDamage) reads
	the attribute, and two players wearing it for even a frame reads as two monsters. ]]
local function setJuggernaut(player)
	if juggernaut == player then
		return
	end
	local previous = juggernaut
	juggernaut = isPlayer(player) and player or nil

	if previous and previous.Parent then
		previous:SetAttribute(ATTR.JUGGERNAUT, false)
	end
	if juggernaut then
		juggernaut:SetAttribute(ATTR.JUGGERNAUT, true)
	end
end

--[[ Crowning a NEW monster mid-round has to REBUILD their car. The 2x body, the hull
	that fits it, the mass and the ride height are all baked in by CarFactory at build
	time — there is no growing a car that is already driving, and faking it with a
	Model:ScaleTo would leave the hull, the hover height and the ram mass at 1x.

	So the swap is a despawn with cause "reset" (SpawnService charges no life for that)
	followed straight away by a spawn, which also hands them fresh spawn protection.
	They need it: everyone in the arena is about to come for them.

	DEFERRED on purpose — this is reached from inside CombatService.killCar, and
	re-entering SpawnService while it is mid-teardown of the victim is the kind of
	ordering you only ever get away with by accident. ]]
local function promoteJuggernaut(player)
	if not isPlayer(player) then
		return
	end
	setJuggernaut(player)
	announceJuggernaut(player)

	task.defer(function()
		if not isPlayer(player) or juggernaut ~= player or not MatchState.isMatch() then
			return
		end
		if isDriving(player) then
			call("SpawnService", "despawnCar", player, RESET_CAUSE)
		end
		local lives = call("SpawnService", "getLives", player)
		if type(lives) == "number" and lives > 0 then
			call("SpawnService", "spawnCar", player)
		end
	end)
end

--[[ Fills a vacant crown. Prefers somebody actually driving — handing it to a player
	sitting on the death card would make the monster invisible for a respawn delay —
	and falls back to anyone still in the server so the mode can never be juggernaut-less. ]]
local function crownSomeone()
	local driving, anyone = {}, {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(anyone, player)
		if isDriving(player) then
			table.insert(driving, player)
		end
	end

	local pool = #driving > 0 and driving or anyone
	if #pool == 0 then
		return
	end
	promoteJuggernaut(pool[rng:NextInteger(1, #pool)])
end

--[[ ONE sweep, and the only thing it watches is the crown: the monster leaving the
	server, or dying with nobody to hand it to, would otherwise leave the whole mode
	pointless for the rest of the round. Everything else here is event driven. ]]
local sweepAccum = 0
local function onHeartbeat(dt: number)
	sweepAccum += dt
	if sweepAccum < SWEEP_INTERVAL then
		return
	end
	sweepAccum = 0

	if not MatchState.isMatch() or not GameModes.hasJuggernaut() then
		return
	end
	if juggernaut and juggernaut.Parent then
		return
	end
	juggernaut = nil
	crownSomeone()
end

-- ==========================================================================
-- public: round lifecycle
-- ==========================================================================
--[[ Rotates to the next ruleset. MatchService calls this at the top of Lobby — the one
	window where changing the rules is safe, since no car exists to be resized and no
	score has been earned under the old rules yet. ]]
function ModeService.nextMode(): string
	ModeService.clearRoundState()

	local forced = RunService:IsStudio() and Config.TEST.FORCE_MODE or nil
	local id
	if type(forced) == "string" and GameModes.byId(forced) then
		id = forced -- Studio only: iterate on one ruleset without waiting for the rotation
	elseif pristine then
		id = GameModes.currentId() -- first round of the server: play what init advertised
	else
		id = GameModes.nextId(core:GetAttribute(ATTR.MODE_ID))
	end
	pristine = false

	local def = GameModes.byId(id) or GameModes.current()
	core:SetAttribute(ATTR.MODE_ID, def.id)
	core:SetAttribute(ATTR.MODE_NAME, def.name)
	return def.id
end

--[[ Everything a mode needs decided BEFORE the first car exists. MatchService calls
	this after the phase flips to Match and before SpawnService.dropInAll, because
	SpawnService asks carModifiersFor() while it builds. ]]
function ModeService.startMatch()
	local def = GameModes.current()

	if GameModes.isTeams(def) then
		assignTeams()
	end

	if GameModes.hasJuggernaut(def) then
		local roster = Players:GetPlayers()
		if #roster > 0 then
			--[[ Straight setJuggernaut, NOT promoteJuggernaut: no car exists yet, so
				there is nothing to rebuild and a deferred respawn would race the
				round-opening drop-in. ]]
			setJuggernaut(roster[rng:NextInteger(1, #roster)])
			announceJuggernaut(juggernaut)
		end
	end
end

-- Zeroes every per-round side effect. Safe to call at any time.
function ModeService.clearRoundState()
	setJuggernaut(nil)
	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute(ATTR.TEAM, 0)
		player:SetAttribute(ATTR.JUGGERNAUT, false)
	end
end

--[[ Paid at the END of Match while the field is still standing — MatchService calls
	this before Results despawns everything, because by then nobody is alive to reward. ]]
function ModeService.finishRound()
	if not GameModes.isLastStanding() then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if isDriving(player) then
			call("ScoreService", "addPoints", player, CFG.SURVIVOR_POINTS)
		end
	end
end

--[[ Last car driving. ONLY elimination ends early on this; every other mode runs its
	clock out. The #players guard keeps a solo Studio round from ending on frame one —
	MatchService's own "everybody is out of lives" check still covers a solo player who
	actually died. ]]
function ModeService.shouldEndRound(): boolean
	if not GameModes.isLastStanding() then
		return false
	end

	local players = Players:GetPlayers()
	if #players <= 1 then
		return false
	end

	local alive = 0
	for _, player in ipairs(players) do
		if isDriving(player) then
			alive += 1
			if alive > 1 then
				return false
			end
		end
	end
	return true
end

-- ==========================================================================
-- public: per-player rules
-- ==========================================================================
function ModeService.livesFor(player): number
	return GameModes.livesFor()
end

--[[ What CarFactory should build this player. nil means "the ordinary car", which is
	every player in four of the five modes. The keys are the contract CarFactory and
	ChassisSpec.resolve both read; Config.MODES.JUGG is the only place they are tuned. ]]
function ModeService.carModifiersFor(player)
	if not GameModes.hasJuggernaut() or not GameModes.isJuggernaut(player) then
		return nil
	end
	local J = CFG.JUGG
	return {
		scale = J.SCALE,
		mass = J.MASS_MULT,
		hp = J.HP_MULT,
		speed = J.SPEED_MULT,
	}
end

--[[ The friendly-fire veto, asked by CombatService ahead of every ram and every weapon
	hit. Defaults to TRUE for anything it cannot classify — environmental damage, a
	missing attacker, self damage — because failing closed here would silently make a
	whole mode unplayable, while failing open is just the game as it already is. ]]
function ModeService.canDamage(attacker, victim): boolean
	if not isPlayer(attacker) or not isPlayer(victim) or attacker == victim then
		return true
	end
	return not GameModes.sameTeam(attacker, victim)
end

--[[ CombatService calls this once per resolved death, after the crown transfer.
	Two jobs: pay the mode's points, and pass the juggernaut crown on. ]]
function ModeService.onKill(killer, victim)
	if not MatchState.isMatch() then
		return
	end

	local def = GameModes.current()
	local tookTheMonster = GameModes.hasJuggernaut(def) and juggernaut ~= nil and juggernaut == victim
	local credited = isPlayer(killer) and killer ~= victim

	if credited then
		call("ScoreService", "addPoints", killer, tookTheMonster and CFG.JUGG_KILL_POINTS or CFG.KILL_POINTS)
	end

	if not tookTheMonster then
		return
	end

	if credited then
		-- The crown goes to whoever took it down. That IS the mode.
		promoteJuggernaut(killer)
	else
		-- Drove into the void on their own time: the crown re-rolls on the next sweep.
		setJuggernaut(nil)
	end
end

function ModeService.getJuggernaut()
	return juggernaut and juggernaut.Parent and juggernaut or nil
end

--[[ Team standings for the results card: one row per team, scored by summing its
	members' own mode score. Returns nil outside a team mode, so the caller can simply
	not draw the banner rather than test the mode itself. ]]
function ModeService.teamTotals()
	if not GameModes.isTeams() then
		return nil
	end

	local rows = {}
	for index = 1, GameModes.teamCount() do
		rows[index] = {
			index = index,
			name = GameModes.teamName(index),
			color = GameModes.teamColor(index),
			score = 0,
		}
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local row = rows[GameModes.teamOf(player)]
		if row then
			row.score += tonumber(player:GetAttribute(ATTR.SCORE)) or 0
		end
	end

	table.sort(rows, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.index < b.index
	end)
	return rows
end

-- ==========================================================================
-- players
-- ==========================================================================
local function onPlayerAdded(player)
	-- Defaults immediately, so no consumer ever reads nil off a fresh player.
	player:SetAttribute(ATTR.TEAM, 0)
	player:SetAttribute(ATTR.JUGGERNAUT, false)

	-- Mid-match joiner in a team mode: put them on the short side straight away, since
	-- MatchService spawns them a car within a second or two.
	if MatchState.isMatch() and GameModes.isTeams() then
		player:SetAttribute(ATTR.TEAM, smallestTeam())
	end
end

local function onPlayerRemoving(player)
	if juggernaut == player then
		juggernaut = nil -- the sweep re-crowns; the leaver's attributes go with them
	end
end

function ModeService.init(ctx)
	ctxRef = ctx
	notifyRemote = ctx.net and ctx.net.Notify or nil

	-- Never leave the mode attributes nil: a client can connect before the first Lobby.
	if type(core:GetAttribute(ATTR.MODE_ID)) ~= "string" then
		local def = GameModes.current()
		core:SetAttribute(ATTR.MODE_ID, def.id)
		core:SetAttribute(ATTR.MODE_NAME, def.name)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return ModeService
