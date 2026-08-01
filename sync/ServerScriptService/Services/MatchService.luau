--[[ MatchService
	The round state machine: Lobby -> Match -> Results, forever.

	PURPOSE
		ONE long-lived driver loop owns "what phase are we in and what happens next".
		No web of task.delay timers, so a transition can never double-fire.

	TIMINGS
		Every duration this service runs on -- phase lengths, the Studio short-loop
		profile, and every cadence the loop ticks at -- is Config.ROUND. Nothing in this
		file hardcodes a number of seconds. Phase lengths are re-read at the top of each
		phase through MatchState.phaseSeconds (so a Config change lands on the next
		round); the loop cadences are read once at load, below.

	DATA FLOW — attributes on ReplicatedStorage.CrashCore (this service is the only writer):
		Phase        "Lobby" | "Match" | "Results"      (via MatchState.setPhase)
		PhaseEndsAt  workspace:GetServerTimeNow() deadline of the current phase
		RoundId      increments on entering Match
		AliveCount   players holding a car right now, refreshed during Match
		Attributes are the source of truth for late joiners; the MatchEvent "phase"
		broadcast is only the animation trigger, fired on real transitions ONLY.

		LOBBY HOLD: while the server is short of players the lobby holds and PhaseEndsAt
		keeps rolling forward, so clients show a live "waiting" countdown instead of a
		frozen 0:00 that never fires. No extra "phase" event is sent during the hold —
		clients must read PhaseEndsAt (or its GetAttributeChangedSignal) for the timer,
		and detect the waiting state with #Players:GetPlayers() < Config.ROUND.MIN_PLAYERS.

	REMOTES (S->C)
		MatchEvent "phase"   { phase = string, endsAt = number, roundId = number }
		MatchEvent "board"   { { name, crowns, kills, userId }, ... }  top 5, ~every 2s in Match
		MatchEvent "results" { board = { ... }, payouts = { [userId] = money },
		                       teams = { { index, name, color, score }, ... } | nil }
		                     `teams` is present only in a team mode; the card draws the
		                     head-to-head banner off it and skips it otherwise.

	SERVICES USED — resolved LAZILY through ctx.svc at call time, never captured at init:
		SpawnService    resetLives spawnAll dropInAll despawnAll spawnCar isAlive getLives
		PickupService   startRound stopRound
		ScoreService    resetRound getBoard payoutRound
		ProfileService  isLoaded  (a mid-match joiner waits for their profile first)
		ArenaService    nextMap   (fallback only, now that the map is voted for)
		MapVoteService  openVote tick resolveVote
		                (the lobby ballot. It BUILDS the winning map when the vote
		                 closes, a few seconds before Lobby ends — cars are despawned
		                 and nobody is driving for the whole phase, so any moment in
		                 Lobby is a safe moment to tear the ground out)
		ModeService     nextMode startMatch finishRound shouldEndRound teamTotals
		                (the round's ruleset: it rotates beside the map, for the same
		                 reason — Lobby is the only window where nobody is driving)
		LobbyService    enterAll exitAll   (the on-foot hub; owns every humanoid)

	INIT ORDER
		Main inits ScoreService before MatchService. Every sibling call goes through the
		guarded `call` helper, so a fault in another service can never kill the driver.

	PUBLIC API
		getPhase() -> string    canRespawn(player) -> boolean    forceEndRound()
		setEndless(on) -> boolean    isEndless() -> boolean
		    The "/test game" dev round: starts one now and never ends it. See the
		    comment on setEndless — it is a PHASE control, not a rules change.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))

local CFG = Config.MATCH
local ATTR = Config.ATTR
local PHASES = MatchState.PHASES

--[[ The driver's cadences, all of them Config.ROUND. Read ONCE here because they run in
	hot loops; the PHASE LENGTHS are deliberately not cached (see phaseSeconds below), so
	changing how long a round lasts takes effect on the next round, not the next server. ]]
local ROUND = Config.ROUND
local TICK = ROUND.TICK -- driver loop granularity, seconds
local BOARD_INTERVAL = ROUND.BOARD_INTERVAL -- live leaderboard broadcast cadence during Match
local BOARD_TOP_N = ROUND.BOARD_TOP_N -- entries in a live "board" push
local HOLD_REFRESH = ROUND.HOLD_REFRESH -- while short of players, roll PhaseEndsAt forward this often
local LOBBY_TOPUP = ROUND.LOBBY_TOPUP -- how often Lobby re-checks that everyone has a hub car
local EARLY_END_GRACE = ROUND.EARLY_END_GRACE -- ignore the all-eliminated check this long after spawnAll
local ENDLESS_REFRESH = ROUND.ENDLESS_REFRESH -- while endless, roll PhaseEndsAt forward this often
local JOIN_PROFILE_TIMEOUT = ROUND.JOIN_PROFILE_TIMEOUT -- max seconds to wait for a joiner's profile
local JOIN_PROFILE_POLL = ROUND.JOIN_PROFILE_POLL
--[[ How long an eliminated player keeps looking at their own wreck before being walked
	back up to the hub. Long enough for the death card to land and for them to see what
	hit them; short enough that "out of the round" never turns into "out of the game". ]]
local ELIMINATED_TO_LOBBY = ROUND.ELIMINATED_TO_LOBBY

local MatchService = {}

local ctx
local matchEvent
local matchEndRequested = false
local warned = {}

--[[ ENDLESS — the "/test game" dev round (see MatchService.setEndless). While it is on,
	Match has no end: the clock is rolled forward, the early-end checks are skipped, the
	lobby stops waiting for players, and nobody is ever out of lives. Nothing else about
	the round changes — same modes, same map vote, same scoring. ]]
local endless = false
local endlessRespawnAt = {} -- [player] = os.clock() at which the courtesy respawn is due

-- ==========================================================================
-- Guarded lazy sibling calls
-- ==========================================================================

--[[ Resolves ctx.svc[serviceName] at CALL time (Main fills ctx.svc as it goes) and
	pcalls the method. Returns nil on any failure. Warns once per call site so a
	per-tick call can never flood the output. ]]
local function call(serviceName: string, fnName: string, ...)
	local service = ctx and ctx.svc[serviceName]
	local fn = type(service) == "table" and service[fnName] or nil
	local key = serviceName .. "." .. fnName

	if type(fn) ~= "function" then
		if not warned[key] then
			warned[key] = true
			warn("MatchService: " .. key .. " unavailable")
		end
		return nil
	end

	local ok, result = pcall(fn, ...)
	if not ok then
		if not warned[key] then
			warned[key] = true
			warn("MatchService: " .. key .. " failed -> " .. tostring(result))
		end
		return nil
	end
	return result
end

-- ==========================================================================
-- Phase lengths
--
-- All four resolve through MatchState, which is the single place Config.ROUND's
-- Studio profile is applied. This service used to own an IsStudio() branch per
-- value, and so did MapVoteService and LobbyUI -- three copies of one rule, each
-- carrying a comment asking the next person to keep them in sync, and three ways
-- for the ballot, the "waiting for players" card and the actual clock to disagree.
-- ==========================================================================

local function minPlayers(): number
	return MatchState.minPlayers()
end

local function lobbySeconds(): number
	return MatchState.phaseSeconds(PHASES.LOBBY)
end

local function matchSeconds(): number
	return MatchState.phaseSeconds(PHASES.MATCH)
end

local function resultsSeconds(): number
	return MatchState.phaseSeconds(PHASES.RESULTS)
end

-- ==========================================================================
-- Broadcast helpers
-- ==========================================================================

local function broadcastPhase(phase: string)
	if not matchEvent then
		return
	end
	matchEvent:FireAllClients("phase", {
		phase = phase,
		endsAt = core:GetAttribute(ATTR.PHASE_ENDS) or workspace:GetServerTimeNow(),
		roundId = MatchState.getRoundId(),
	})
end

-- Strips the Player instance out of ScoreService rows; remotes carry plain data.
local function serializeBoard(board: { any }, limit: number?): { any }
	local out = {}
	for index, row in ipairs(board) do
		if limit and index > limit then
			break
		end
		out[index] = {
			name = row.name or "?",
			userId = row.userId or 0,
			crowns = row.crowns or 0,
			kills = row.kills or 0,
			-- `score` is the number this MODE places on (ScoreService derives it via
			-- GameModes.scoreOf); `team` is 0 outside a team mode.
			score = row.score or row.crowns or 0,
			team = row.team or 0,
		}
	end
	return out
end

local function broadcastBoard()
	if not matchEvent then
		return
	end
	local board = call("ScoreService", "getBoard")
	if type(board) ~= "table" then
		return
	end
	matchEvent:FireAllClients("board", serializeBoard(board, BOARD_TOP_N))
end

-- ==========================================================================
-- Alive tracking / early end
-- ==========================================================================

local function refreshAliveCount()
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if call("SpawnService", "isAlive", player) == true then
			count += 1
		end
	end
	if core:GetAttribute(ATTR.ALIVE_COUNT) ~= count then
		core:SetAttribute(ATTR.ALIVE_COUNT, count)
	end
end

--[[ True ONLY when we can positively confirm nobody is left in the round: no cars up
	and no lives banked. If SpawnService cannot answer we return false and let the
	match clock decide, rather than cutting a live round short. ]]
local function everyoneEliminated(): boolean
	local players = Players:GetPlayers()
	if #players == 0 then
		return true
	end

	local spawnService = ctx and ctx.svc.SpawnService
	if
		type(spawnService) ~= "table"
		or type(spawnService.isAlive) ~= "function"
		or type(spawnService.getLives) ~= "function"
	then
		return false
	end

	for _, player in ipairs(players) do
		if call("SpawnService", "isAlive", player) == true then
			return false
		end
		local lives = call("SpawnService", "getLives", player)
		if type(lives) == "number" and lives > 0 then
			return false
		end
	end
	return true
end

--[=[ ELIMINATED -> THE HUB.

	A player who is out of lives has no car, and until this existed had no body either:
	they sat in an empty camera over an arena they had just been lifted out of, for the
	rest of the round. In Elimination that is one life and up to three minutes of it.
	Sending them up to the terrace gives them somewhere to BE -- and since the hub
	overlooks the valley, "watch the rest of the round" is still exactly what they are
	doing, just on their feet and able to walk to the shop while they do it.

	A POLL rather than a hook on the death, for two reasons. "Out of the round" is a
	STATE, not an event: an ordinary elimination, a mid-round joiner with no lives and a
	respawn that never came all land in it, and one poll covers all three. And this loop
	already ticks for refreshAliveCount, so it costs nothing new.

	sentToHub latches so admit() fires ONCE per elimination -- after that LobbyService's
	own sweep owns them, including putting them back if they walk off the mountain. ]=]
local outSince = {} -- [Player] = os.clock() we first confirmed they were out
local sentToHub = {} -- [Player] = true once admitted

local function clearEliminated()
	table.clear(outSince)
	table.clear(sentToHub)
end

local function sweepEliminated(now: number)
	for _, player in ipairs(Players:GetPlayers()) do
		--[[ POSITIVE confirmation only, exactly like everyoneEliminated above: `call`
			answers nil for a service that is missing or that threw, and reading that as
			"this player is out" would lift a live driver out of a round they are
			winning. Both facts have to come back, and both have to say they are done. ]]
		local alive = call("SpawnService", "isAlive", player)
		local lives = call("SpawnService", "getLives", player)
		local known = type(alive) == "boolean" and type(lives) == "number"
		local out = known and alive == false and lives <= 0

		if not known then
			-- UNKNOWN is its own answer, and it must not be read as either one. Clearing
			-- here would restart the countdown every time a call hiccuped; advancing
			-- would send a live driver home. Hold the state and try again next tick.
		elseif not out then
			outSince[player] = nil
			sentToHub[player] = nil
		elseif not sentToHub[player] then
			local since = outSince[player]
			if not since then
				outSince[player] = now
			elseif now - since >= ELIMINATED_TO_LOBBY then
				sentToHub[player] = true
				call("LobbyService", "admit", player)
			end
		end
	end
end

local function enoughPlayers(): boolean
	return #Players:GetPlayers() >= minPlayers()
end

-- ==========================================================================
-- Phases
-- ==========================================================================

--[[ There MUST be an arena before a round starts, whatever became of the ballot.
	resolveVote is latched, so this is a no-op once the vote has closed on its own clock;
	it only does real work when a Lobby ended sooner than the ballot expected. A false
	return means there is no vote service at all, and the original straight rotation is
	the fallback — a round must never open on ground that was never rebuilt. ]]
local function ensureMapBuilt()
	if call("MapVoteService", "resolveVote") ~= true then
		call("ArenaService", "nextMap")
	end
end

local function runLobby()
	call("SpawnService", "despawnAll", "roundEnd")
	call("PickupService", "stopRound")
	call("ScoreService", "resetRound")
	--[[ The RULESET rotates here — the one window where changing the rules is safe:
		no car exists to be resized, no score has been earned under the old rules, and
		the lobby card has the whole of Lobby to tell everyone what is coming. ]]
	call("ModeService", "nextMode")
	core:SetAttribute(ATTR.ALIVE_COUNT, 0)

	MatchState.setPhase(PHASES.LOBBY, lobbySeconds())
	broadcastPhase(PHASES.LOBBY)

	--[[ The map is VOTED for now, not rotated, and the ballot opens AFTER the phase
		above — deliberately. MapVoteService derives its closing time from PhaseEndsAt
		(which is what makes a held lobby hold its vote open), so opening it one line
		earlier would broadcast a ballot whose deadline was still the Results screen's,
		i.e. already in the past.

		Closing the vote is what BUILDS the winner, a few seconds before Lobby ends
		(MapVoteService.tick, in the loop below). Cars are despawned, pickups are stopped
		and nobody is driving for the whole of Lobby, so any moment in it is a safe
		moment to tear the ground out — and building at the CLOSE rather than at the top
		is what lets players watch the map they just picked assemble in the valley. ]]
	call("MapVoteService", "openVote")

	--[[ The hub is a place, not a menu: everybody gets their ordinary Roblox character
		on the mountaintop for the whole Lobby and walks around up there while the next
		map builds in the valley below. LobbyService owns those characters end to end —
		loading, respawning, and taking them away again — and it is the only thing in
		the game that touches a humanoid. ]]
	call("LobbyService", "enterAll")

	local lastRefresh = os.clock()
	local lastTopUp = os.clock()
	while true do
		--[[ The endless test round does not wait — not for the clock and not for a lobby
			full of people. It takes the ballot exactly as it stands (ensureMapBuilt
			resolves it, latched, and builds the winner) and drops straight into Match.
			A round must never open on ground that was never rebuilt, test round or not. ]]
		if endless then
			ensureMapBuilt()
			return
		end

		--[[ Closes the ballot and builds the winner ONCE, a few seconds before the phase
			ends. It reads the phase deadline rather than a clock of its own, so the hold
			below — which keeps pushing that deadline forward — keeps the vote open too
			instead of resolving into an empty server. ]]
		call("MapVoteService", "tick")

		if enoughPlayers() then
			if MatchState.timeLeft() <= 0 then
				ensureMapBuilt()
				return
			end
		else
			local now = os.clock()
			if now - lastRefresh >= HOLD_REFRESH then
				lastRefresh = now
				-- Holding for players: keep the deadline ahead of the clients so the
				-- countdown reads as "waiting" instead of freezing at 0:00.
				core:SetAttribute(ATTR.PHASE_ENDS, workspace:GetServerTimeNow() + lobbySeconds())
			end
		end

		--[[ hub top-up: enterAll is a no-op for anyone who already has a live character,
			so this is cheap belt-and-braces over LobbyService's own sweep — somebody who
			joins mid-Lobby should never stand around with no body. ]]
		if os.clock() - lastTopUp >= LOBBY_TOPUP then
			lastTopUp = os.clock()
			call("LobbyService", "enterAll")
		end
		task.wait(TICK)
	end
end

--[[ Endless only: nobody may ever be OUT for the round, or a test round decays into
	a spectate screen you cannot leave. Two cases, deliberately kept apart:

	  alive on the last life  ->  top the lives back up, so the ordinary death card,
	                              respawn delay and respawn button keep doing the work.
	  dead with none left     ->  after the same delay the death card shows, hand a life
	                              back and put a car under them. Nothing else ever
	                              auto-respawns a player at zero lives — see the comment
	                              in SpawnService.despawnCar.

	This RUNS INSTEAD OF sweepEliminated, never beside it: that sweep walks anyone who
	is out up to the hub on foot, and a player who is both on the terrace and in a car
	breaks the one invariant LobbyService and SpawnService share. ]]
local function endlessKeepAlive()
	for _, player in ipairs(Players:GetPlayers()) do
		local lives = call("SpawnService", "getLives", player)
		if type(lives) ~= "number" then
			continue
		end
		if call("SpawnService", "isAlive", player) == true then
			endlessRespawnAt[player] = nil
			if lives <= 1 then
				call("SpawnService", "resetLives", player)
			end
		elseif lives <= 0 then
			local due = endlessRespawnAt[player]
			if not due then
				endlessRespawnAt[player] = os.clock() + (CFG.RESPAWN_DELAY or 3)
			elseif os.clock() >= due then
				endlessRespawnAt[player] = nil
				call("SpawnService", "resetLives", player)
				-- Belt and braces: if the sweep had already walked them up to the hub
				-- before endless came on, take the character away first.
				call("LobbyService", "exitHub", player)
				call("SpawnService", "spawnCar", player)
			end
		end
	end
end

local function runMatch()
	matchEndRequested = false
	clearEliminated()

	core:SetAttribute(ATTR.ROUND_ID, MatchState.getRoundId() + 1)
	for _, player in ipairs(Players:GetPlayers()) do
		call("SpawnService", "resetLives", player)
	end

	-- Phase first: SpawnService gates spawning/respawning on MatchService.canRespawn.
	MatchState.setPhase(PHASES.MATCH, matchSeconds())
	broadcastPhase(PHASES.MATCH)

	--[[ Everyone is on foot on the mountaintop right now: take the character away, then
		drop a car into the valley. Order matters — nobody may ever hold both. ]]
	--[[ MUST be before the first car is built: the mode decides teams and crowns the
		juggernaut here, and SpawnService reads that flag while building a body. ]]
	call("ModeService", "startMatch")

	call("LobbyService", "exitAll")
	call("SpawnService", "dropInAll")
	call("PickupService", "startRound")

	local startedAt = os.clock()
	local nextBoard = startedAt + BOARD_INTERVAL
	local nextRoll = startedAt

	while endless or MatchState.timeLeft() > 0 do
		refreshAliveCount()

		local now = os.clock()
		--[[ ENDLESS: roll the deadline forward exactly as the lobby hold does rather than
			parking it at some huge number — HudUI's final-ten-seconds tick is the only
			thing still reading this during Match, and on a clock frozen at 0:00 it would
			tick forever. The eliminated sweep is REPLACED rather than raced: in an
			endless round nobody is ever out, and endlessKeepAlive is what keeps it so. ]]
		if endless then
			if now >= nextRoll then
				nextRoll = now + ENDLESS_REFRESH
				core:SetAttribute(ATTR.PHASE_ENDS, workspace:GetServerTimeNow() + matchSeconds())
			end
			endlessKeepAlive()
		else
			-- Anybody whose round is over goes home; see sweepEliminated.
			sweepEliminated(now)
		end

		if now >= nextBoard then
			nextBoard = now + BOARD_INTERVAL
			broadcastBoard()
		end

		if matchEndRequested then
			return
		end
		--[[ Early end. Two ways a round can be over before its clock: everybody is out
			of lives (true in any mode), or the MODE says so — Elimination ends the
			instant one car is left driving. Both sit behind the same grace window, so
			the round-opening drop-in can never trip either of them. ]]
		if not endless and now - startedAt >= EARLY_END_GRACE then
			if everyoneEliminated() or call("ModeService", "shouldEndRound") == true then
				return
			end
		end

		task.wait(TICK)
	end
end

local function runResults()
	--[[ BEFORE the despawn: Elimination pays its survivor bonus to whoever is still
		driving, and one line further down nobody is. ]]
	call("ModeService", "finishRound")

	call("SpawnService", "despawnAll", "roundEnd")
	call("PickupService", "stopRound")
	core:SetAttribute(ATTR.ALIVE_COUNT, 0)

	--[[ The intermission starts HERE, not at the top of Lobby. Results used to leave
		everybody bodyless for its whole ten seconds -- no car, no character, a camera
		staring at an arena they had just been lifted out of. The hub is where a round
		that is over belongs, so they go up the moment the field is cleared and simply
		stay there through the Lobby that follows: runLobby's enterAll is a no-op for
		anyone who already has a body. ]]
	call("LobbyService", "enterAll")

	-- Board before payout, payout before the phase flip: the results card should be
	-- populated the instant clients switch to it.
	local board = call("ScoreService", "getBoard")
	local payouts = call("ScoreService", "payoutRound")

	MatchState.setPhase(PHASES.RESULTS, resultsSeconds())
	broadcastPhase(PHASES.RESULTS)

	if matchEvent then
		matchEvent:FireAllClients("results", {
			board = serializeBoard(type(board) == "table" and board or {}),
			payouts = type(payouts) == "table" and payouts or {},
			-- nil outside a team mode, which is exactly how the card decides to draw it
			teams = call("ModeService", "teamTotals"),
		})
	end

	while MatchState.timeLeft() > 0 do
		task.wait(TICK)
	end
end

local function driver()
	while true do
		local okLobby, lobbyErr = pcall(runLobby)
		if not okLobby then
			warn("MatchService: Lobby failed -> " .. tostring(lobbyErr))
		end

		local okMatch, matchErr = pcall(runMatch)
		if not okMatch then
			warn("MatchService: Match failed -> " .. tostring(matchErr))
		end

		local okResults, resultsErr = pcall(runResults)
		if not okResults then
			warn("MatchService: Results failed -> " .. tostring(resultsErr))
		end

		-- Guarantees a yield even if every phase above errored before yielding.
		task.wait(TICK)
	end
end

-- ==========================================================================
-- Mid-match join
-- ==========================================================================

--[[ A joiner who lands mid-MATCH gets full lives and a car straight away — this is a
	casual kids game, so playing immediately beats late-join fairness.
	Lobby and Results deliberately do nothing here: in Lobby the hub is on foot and
	LobbyService's sweep gives them a body within half a second, and a car spawned
	during either phase would land in an arena nobody is playing in yet. ]]
local function onPlayerAdded(player: Player)
	if MatchState.getPhase() ~= PHASES.MATCH then
		return -- Lobby: the hub is on foot and LobbyService owns it. Results: nothing.
	end

	-- Wait for the profile so the car uses their equipped skin.
	local deadline = os.clock() + JOIN_PROFILE_TIMEOUT
	while os.clock() < deadline do
		if not player.Parent then
			return -- left while we waited
		end
		if call("ProfileService", "isLoaded", player) == true then
			break
		end
		task.wait(JOIN_PROFILE_POLL)
	end

	-- Re-check everything after the yield.
	if not player.Parent then
		return
	end
	if MatchState.getPhase() ~= PHASES.MATCH then
		return -- the round ended while we waited
	end

	call("SpawnService", "resetLives", player)
	local lives = call("SpawnService", "getLives", player)
	if type(lives) == "number" and lives <= 0 then
		return
	end
	if call("SpawnService", "isAlive", player) == true then
		return
	end
	call("SpawnService", "spawnCar", player)
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function MatchService.getPhase(): string
	return MatchState.getPhase()
end

-- True only during Match. SpawnService layers its own lives / respawn-delay checks.
function MatchService.canRespawn(player: Player): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	return MatchState.getPhase() == PHASES.MATCH
end

-- Cuts the current Match short (used by the early-end check, admin and testing).
function MatchService.forceEndRound()
	if MatchState.getPhase() ~= PHASES.MATCH then
		return
	end
	matchEndRequested = true
end
--[[ ENDLESS ROUND — the "/test game" dev switch (WeaponTestService owns the command,
	this owns the phase machine).

	ON   starts a round NOW — whatever phase we are sitting in is cut short — and then
	     stops it ever finishing: the match clock is rolled forward every couple of
	     seconds, the early-end checks are skipped, the lobby stops waiting for a
	     minimum player count, and endlessKeepAlive means nobody is ever out of lives.
	OFF  ends the round that is running. That is not a side effect, it is the only
	     honest way back: the clock has been pushed minutes into the future, so leaving
	     it to expire would strand the server in a round nobody asked for.

	It is a PHASE control and nothing more. The mode still rotates, the map is still
	voted for, scores and payouts still behave exactly as they do in a real round. ]]
function MatchService.setEndless(on: boolean): boolean
	endless = on == true
	table.clear(endlessRespawnAt)

	if endless then
		if MatchState.getPhase() ~= PHASES.MATCH then
			-- Results reads this deadline to know it is done; Lobby bails on `endless`
			-- itself, one tick later.
			core:SetAttribute(ATTR.PHASE_ENDS, workspace:GetServerTimeNow())
		end
	elseif MatchState.getPhase() == PHASES.MATCH then
		matchEndRequested = true
	end
	return endless
end

function MatchService.isEndless(): boolean
	return endless
end

function MatchService.init(context)
	ctx = context
	matchEvent = ctx.net.MatchEvent

	-- Never leave the phase attributes nil: a client can connect before the driver ticks.
	core:SetAttribute(ATTR.ROUND_ID, 0)
	core:SetAttribute(ATTR.ALIVE_COUNT, 0)
	MatchState.setPhase(PHASES.LOBBY, lobbySeconds())

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)

	Players.PlayerRemoving:Connect(function()
		-- Deferred so the leaver is already out of Players:GetPlayers().
		if MatchState.isMatch() then
			task.defer(refreshAliveCount)
		end
	end)

	task.spawn(driver)
end

return MatchService
