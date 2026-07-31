--[[ MatchState
	Phase contract shared by MatchService (writer) and every client reader.

	Match state is replicated as attributes on ReplicatedStorage.CrashCore, NOT via a remote,
	so a joining player reads the current phase immediately with no handshake.

	Attributes (Config.ATTR): Phase, PhaseEndsAt, RoundId, AliveCount

	ROUND TIMINGS. This module is also the ONE place Config.ROUND's Studio profile is
	applied (roundValue / phaseSeconds / minPlayers). Everything that needs a round
	duration goes through it -- MatchService's driver, MapVoteService's ballot lead,
	LobbyUI's "waiting for players" copy, ResultsUI's dismiss fallback -- so the
	server's clock and every client's idea of it cannot drift apart.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)

local MatchState = {}

MatchState.PHASES = {
	LOBBY = "Lobby",
	MATCH = "Match",
	RESULTS = "Results",
}

-- ==========================================================================
-- Round clock (Config.ROUND) -- the only Studio-profile branch in the game
-- ==========================================================================

--[[ Reads one key out of Config.ROUND, preferring Config.ROUND.STUDIO's value while we
	are in Studio and STUDIO_OVERRIDES is on. A key the STUDIO table does not mention
	falls through to the live value, which is what lets that table hold only the handful
	of timings a test round actually wants shortened.

	The table is looked up per CALL, never captured: a value edited live in the command
	bar (or in Config while the server runs) then lands on the next round rather than
	the next server. ]]
function MatchState.roundValue(key: string): any
	local round = Config.ROUND
	local studio = round.STUDIO
	if RunService:IsStudio() and round.STUDIO_OVERRIDES ~= false and type(studio) == "table" then
		local override = studio[key]
		if override ~= nil then
			return override
		end
	end
	return round[key]
end

local PHASE_SECONDS_KEY = {
	[MatchState.PHASES.LOBBY] = "LOBBY_SECONDS",
	[MatchState.PHASES.MATCH] = "MATCH_SECONDS",
	[MatchState.PHASES.RESULTS] = "RESULTS_SECONDS",
}

--[[ How many seconds `phase` runs for under the profile this machine is on.
	Floored at 1: a zero-length phase would spin MatchService's driver loop through
	whole rounds per second, and a typo in Config should slow the game down, not melt
	the server. ]]
function MatchState.phaseSeconds(phase: string): number
	local key = PHASE_SECONDS_KEY[phase]
	local seconds = key and tonumber(MatchState.roundValue(key)) or nil
	return math.max(seconds or 0, 1)
end

-- Players needed before the intermission stops holding and a round starts.
function MatchState.minPlayers(): number
	return math.max(1, math.floor(tonumber(MatchState.roundValue("MIN_PLAYERS")) or 1))
end

local function core(): Instance
	local found = ReplicatedStorage:FindFirstChild("CrashCore")
	if not found and not RunService:IsServer() then
		found = ReplicatedStorage:WaitForChild("CrashCore", 20)
	end
	assert(found, "MatchState: CrashCore missing")
	return found
end

MatchState.root = core

function MatchState.getPhase(): string
	return core():GetAttribute(Config.ATTR.PHASE) or MatchState.PHASES.LOBBY
end

function MatchState.getRoundId(): number
	return core():GetAttribute(Config.ATTR.ROUND_ID) or 0
end

function MatchState.getAliveCount(): number
	return core():GetAttribute(Config.ATTR.ALIVE_COUNT) or 0
end

-- Seconds remaining in the current phase (never negative).
function MatchState.timeLeft(): number
	local endsAt = core():GetAttribute(Config.ATTR.PHASE_ENDS) or 0
	return math.max(0, endsAt - workspace:GetServerTimeNow())
end

function MatchState.isMatch(): boolean
	return MatchState.getPhase() == MatchState.PHASES.MATCH
end

--[[ Fires cb(phase) on every change AND once immediately with the current phase,
	so callers never miss the state they joined into.
	Returns the RBXScriptConnection. ]]
function MatchState.onPhaseChanged(cb: (string) -> ()): RBXScriptConnection
	local conn = core():GetAttributeChangedSignal(Config.ATTR.PHASE):Connect(function()
		cb(MatchState.getPhase())
	end)
	task.spawn(cb, MatchState.getPhase())
	return conn
end

-- Server only. Sets phase + deadline atomically enough for clients to read together.
function MatchState.setPhase(phase: string, durationSeconds: number)
	assert(RunService:IsServer(), "MatchState.setPhase is server-only")
	local root = core()
	root:SetAttribute(Config.ATTR.PHASE_ENDS, workspace:GetServerTimeNow() + durationSeconds)
	root:SetAttribute(Config.ATTR.PHASE, phase)
end

-- Formats seconds as M:SS for the HUD timer.
function MatchState.formatClock(seconds: number): string
	local whole = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

return MatchState
