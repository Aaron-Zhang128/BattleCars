--[[ MapVoteService
	The lobby ballot: a handful of maps, one vote each, and the winner builds under
	everyone's feet before they drop into it.

	WHY THE TIMING IS WHAT IT IS
		Rebuilding the arena DELETES the ground, so it may only happen while no car
		exists — which is ANY moment during Lobby, not just the top of it. The ballot
		therefore opens with Lobby and closes Config.MAPVOTE.BUILD_LEAD seconds before
		it ends: late enough that everyone has had a chance to vote, early enough that
		the winning map visibly assembles in the valley below while people are still
		standing on the mountaintop hub watching it. That beat is the one the old
		straight rotation gave for free, and it is deliberately kept.

	THE CLOCK IS THE PHASE DEADLINE, never a timer of our own. MatchService rolls
	PhaseEndsAt forward while it holds Lobby open for players, so reading
	MatchState.timeLeft() means a held lobby holds its ballot open too — a private
	countdown would close the vote into an empty server and build a map nobody picked.

	DATA FLOW
		MatchService.runLobby -> openVote()     at the top of Lobby
		                      -> tick()         every driver tick; closes + builds ONCE
		                      -> resolveVote()  before the phase flips, as the guarantee
		ArenaService          -> getMapId()     what is already built (never on the ballot)
		                      -> build(mapId)   the winner
		                      -> nextMap()      fallback when the ballot came up empty

		Studio's Config.TEST.FORCE_MAP still wins: ArenaService.build applies it
		internally, so a pinned map can never be overridden by a vote — and this service
		does not open a ballot at all while it is set, because a vote that cannot change
		anything is a lie told to the player.

	REMOTES
		MapVote  C->S  ("vote", mapId) | ("sync")
		         S->C  ("state", { open, endsAt, roundId, winner,
		                           choices = { { id, name, blurb, votes }, ... },
		                           voters  = { [userId] = mapId } })
		ONE broadcast for everybody. `voters` is how a client finds its OWN pick inside
		a shared payload, and how the UI can show who is backing what. The client draws
		only: the server owns the tally, the clock and the winner.

	ATTRIBUTES
		Writes none. The map itself replicates as Config.ATTR.MAP_ID / MAP_NAME, and
		ArenaService is and stays the only writer of those.

	INIT ORDER
		After ArenaService (it reads the built map when it opens a ballot) and before
		MatchService (which drives it). Siblings are resolved LAZILY at call time, so
		only that second half actually has to hold.

	PUBLIC API
		openVote()  tick()  resolveVote() -> boolean
		isOpen()  getChoices()  getTally()  getWinner()  closesAt()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local Net = require(core:WaitForChild("Net"))
local Maps = require(core:WaitForChild("Maps"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))

local CFG = Config.MAPVOTE
local ATTR = Config.ATTR
local PHASES = MatchState.PHASES

local MapVoteService = {}

local ctxRef
local voteRemote
local voteGate
local syncGate
local rng = Random.new()
local warned = {}

-- ==========================================================================
-- ballot state — one at a time, replaced wholesale by openVote
-- ==========================================================================
local choices = {} -- { { id, name, blurb }, ... } in display order
local onBallot = {} -- [mapId] = true; a vote for anything else is rejected outright
local votes = {} -- [Player] = mapId
local open = false
local resolved = true -- LATCHED: openVote arms it, resolveVote fires it exactly once
local winner = nil

-- ==========================================================================
-- helpers
-- ==========================================================================
--[[ Resolves ctx.svc[service][fn] at CALL time and pcalls it. Warns once per call site,
	so a per-tick call can never flood the output. Mirrors MatchService's own helper. ]]
local function call(serviceName: string, fnName: string, ...)
	local service = ctxRef and ctxRef.svc[serviceName]
	local fn = type(service) == "table" and service[fnName] or nil
	local key = serviceName .. "." .. fnName

	if type(fn) ~= "function" then
		if not warned[key] then
			warned[key] = true
			warn("MapVoteService: " .. key .. " unavailable")
		end
		return nil
	end

	local ok, result = pcall(fn, ...)
	if not ok then
		if not warned[key] then
			warned[key] = true
			warn("MapVoteService: " .. key .. " failed -> " .. tostring(result))
		end
		return nil
	end
	return result
end

-- The one round clock (Config.ROUND, Studio profile applied inside MatchState), so the
-- lead below can never be computed against a lobby length the driver is not running on.
local function lobbySeconds(): number
	return MatchState.phaseSeconds(PHASES.LOBBY)
end

--[[ How long before the end of Lobby the ballot closes. Capped as a FRACTION of the
	lobby as well as an absolute: Studio's lobby is 5 seconds and a flat 8 would close
	the ballot before it ever opened. Never allowed to reach the whole lobby, so there
	is always a window in which a vote can actually be cast. ]]
local function closeLead(): number
	local lobby = math.max(lobbySeconds(), 1)
	local lead = math.min(CFG.BUILD_LEAD, lobby * CFG.MAX_LEAD_FRACTION)
	return math.clamp(lead, 0.5, lobby - 0.5)
end

--[[ The server time the ballot closes, DERIVED from the phase deadline rather than
	stamped when the ballot opened. That is what makes a held lobby hold its vote: the
	deadline keeps rolling forward and this rolls with it. ]]
function MapVoteService.closesAt(): number
	local endsAt = core:GetAttribute(ATTR.PHASE_ENDS)
	if type(endsAt) ~= "number" then
		return workspace:GetServerTimeNow()
	end
	return endsAt - closeLead()
end

-- Studio only: the pinned map, when it is a real one.
local function forcedMapId(): string?
	if not RunService:IsStudio() then
		return nil
	end
	local id = Config.TEST.FORCE_MAP
	if type(id) == "string" and Maps.indexOf(id) then
		return id
	end
	return nil
end

--[[ Counts only votes that still MEAN something: the voter is still in the server and
	the map they picked is still on this ballot. Returns { [mapId] = count }, total. ]]
local function tally()
	local counts = {}
	for _, choice in ipairs(choices) do
		counts[choice.id] = 0
	end

	local total = 0
	for player, mapId in pairs(votes) do
		if player.Parent and counts[mapId] then
			counts[mapId] += 1
			total += 1
		end
	end
	return counts, total
end

local function payload()
	local counts = tally()

	local rows = table.create(#choices)
	for index, choice in ipairs(choices) do
		rows[index] = {
			id = choice.id,
			name = choice.name,
			blurb = choice.blurb,
			votes = counts[choice.id] or 0,
		}
	end

	local voters = {}
	for player, mapId in pairs(votes) do
		if player.Parent then
			voters[player.UserId] = mapId
		end
	end

	return {
		open = open,
		endsAt = MapVoteService.closesAt(),
		roundId = MatchState.getRoundId(),
		winner = winner,
		choices = rows,
		voters = voters,
	}
end

local function broadcast()
	if voteRemote then
		voteRemote:FireAllClients("state", payload())
	end
end

--[[ Most votes wins; ties break at RANDOM among the leaders, INCLUDING the all-zero tie
	when nobody voted at all. Deterministic tie-breaking (say, first on the ballot) would
	make the leftmost card win every quiet lobby, which is how a vote quietly decays into
	a fixed rotation of one map. ]]
local function pickWinner(): string?
	if #choices == 0 then
		return nil
	end

	local counts = tally()
	local best, leaders = -1, {}
	for _, choice in ipairs(choices) do
		local n = counts[choice.id] or 0
		if n > best then
			best = n
			leaders = { choice.id }
		elseif n == best then
			table.insert(leaders, choice.id)
		end
	end

	if #leaders == 0 then
		return choices[1].id
	end
	return leaders[rng:NextInteger(1, #leaders)]
end

-- ==========================================================================
-- public: the ballot
-- ==========================================================================
--[[ Opens a fresh ballot. MatchService calls this at the top of Lobby, replacing the
	straight `ArenaService.nextMap()` that used to sit there — the map is now DECIDED
	here and BUILT at resolveVote, a few seconds before the round starts. ]]
function MapVoteService.openVote()
	votes = {}
	choices = {}
	onBallot = {}
	winner = nil
	open = false
	resolved = false -- armed; resolveVote is what disarms it, and only once

	--[[ A pinned Studio map means the ballot cannot change anything, so we do not draw
		one. resolveVote still runs and still builds — through ArenaService.build, which
		applies the pin itself. ]]
	if forcedMapId() then
		broadcast()
		return
	end

	--[[ The pool is every map EXCEPT the one currently under everyone's feet, so the
		ballot can never offer "the map you are already looking at" and a round can never
		fail to change the map. A one-map game falls back to that single map rather than
		to an empty ballot. ]]
	local currentId = call("ArenaService", "getMapId")
	local pool = {}
	for _, def in ipairs(Maps.LIST) do
		if def.id ~= currentId then
			table.insert(pool, def)
		end
	end
	if #pool == 0 then
		pool = table.clone(Maps.LIST)
	end

	-- Fisher-Yates: shuffles WHICH maps make the ballot and the order they are drawn in,
	-- so the same map is not permanently the leftmost card.
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	for i = 1, math.min(CFG.CHOICES, #pool) do
		local def = pool[i]
		choices[i] = {
			id = def.id,
			name = def.name or def.id,
			blurb = def.blurb or "",
		}
		onBallot[def.id] = true
	end

	open = #choices > 0
	broadcast()
end

--[[ Driven from MatchService's Lobby loop. Closes the ballot and builds the winner
	exactly once, closeLead() seconds before the phase ends. Cheap after that: the latch
	makes every later call a single boolean test. ]]
function MapVoteService.tick()
	if resolved then
		return
	end
	if MatchState.getPhase() ~= PHASES.LOBBY then
		return -- not our phase; resolveVote is the guarantee if Lobby ended abruptly
	end
	if workspace:GetServerTimeNow() >= MapVoteService.closesAt() then
		MapVoteService.resolveVote()
	end
end

--[[ Closes the ballot and BUILDS the winner. LATCHED: the first call does the work and
	every later call this Lobby is a cheap `true`.

	Returns false ONLY when there was no arena to build with — MatchService's cue to fall
	back to the original straight rotation rather than start a round on stale ground. ]]
function MapVoteService.resolveVote(): boolean
	if resolved then
		return true
	end
	resolved = true
	open = false

	local picked = forcedMapId() or pickWinner()
	winner = picked

	local built
	if picked then
		built = call("ArenaService", "build", picked)
	else
		-- Empty ballot (no maps at all): behave exactly like the code this replaced.
		built = call("ArenaService", "nextMap")
	end

	broadcast()
	return built ~= nil
end

-- ==========================================================================
-- public: reads
-- ==========================================================================
function MapVoteService.isOpen(): boolean
	return open
end

-- A copy, so a caller cannot edit the live ballot.
function MapVoteService.getChoices()
	local out = table.create(#choices)
	for index, choice in ipairs(choices) do
		out[index] = { id = choice.id, name = choice.name, blurb = choice.blurb }
	end
	return out
end

function MapVoteService.getTally()
	local counts, total = tally()
	return counts, total
end

-- nil until the ballot closes.
function MapVoteService.getWinner(): string?
	return winner
end

-- ==========================================================================
-- remote
-- ==========================================================================
--[[ Every refusal here is SILENT. A vote arriving a frame after the ballot closed, a
	double tap inside the throttle, a map id that is not on the ballot — all of them are
	ordinary client behaviour, not attacks, and warning on each would turn a busy lobby
	into a wall of log noise. The client re-reads its own state from the next broadcast. ]]
local function onVoteEvent(player: Instance, action: any, mapId: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	if action == "sync" then
		if syncGate(player) and voteRemote then
			voteRemote:FireClient(player, "state", payload())
		end
		return
	end

	if action ~= "vote" then
		return
	end
	if not voteGate(player) then
		return
	end
	if not open or type(mapId) ~= "string" or not onBallot[mapId] then
		return
	end
	if votes[player] == mapId then
		return -- same pick again: nothing moved, so nothing to replicate
	end

	-- One vote each, changeable until the ballot closes: re-voting MOVES your vote
	-- rather than adding one.
	votes[player] = mapId
	broadcast()
end

-- ==========================================================================
-- players
-- ==========================================================================
local function onPlayerAdded(player: Instance)
	--[[ Fired straight away so a joiner sees the ballot without asking. Their client
		also fires "sync" once it is listening, which is what actually covers the race —
		this is just the fast path for a client that was already up. ]]
	if open and voteRemote then
		voteRemote:FireClient(player, "state", payload())
	end
end

local function onPlayerRemoving(player: Instance)
	if votes[player] == nil then
		return
	end
	votes[player] = nil
	if open then
		broadcast() -- their vote leaves with them, so everyone's tally must move
	end
end

function MapVoteService.init(ctx)
	ctxRef = ctx

	local net = ctx and ctx.net or {}
	voteRemote = net.MapVote or Net.server("MapVote")
	voteGate = Net.throttle(CFG.VOTE_GAP)
	syncGate = Net.throttle(CFG.SYNC_GAP)

	voteRemote.OnServerEvent:Connect(onVoteEvent)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return MapVoteService
