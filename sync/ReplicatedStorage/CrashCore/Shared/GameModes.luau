--[[ GameModes
	Which ruleset this round is running, and every read either side needs to obey it.

	Config.MODES is the DATA (the rotation, the shared tunables, the mode list); this
	module is the pure logic over it, so the server and the client can never disagree
	about what "Deathmatch" means. It READS the state ModeService replicates and writes
	NOTHING itself — ModeService is the only writer, exactly as MatchService is the only
	writer of the phase MatchState reads.

	REPLICATED STATE IT READS (attributes, never a remote, so a late joiner needs no
	handshake to know the rules of the round they just walked into)
		CrashCore  Config.ATTR.MODE_ID / MODE_NAME   the mode this round is running
		Player     Config.ATTR.TEAM                  1-based team index, 0 / nil = none
		Player     Config.ATTR.JUGGERNAUT            boolean: driving the monster car

	THE MODES (authored in Config.MODES.LIST)
		crowns       Crown Rush   grab crowns, most crowns wins   (the original game)
		deathmatch   Deathmatch   no crowns on the field, most wrecks wins
		teams        Team Battle  red vs blue, no friendly fire, team wrecks decide it
		juggernaut   Juggernaut   one 2x monster car; big points for taking it down
		bounty       Bounty       one named target each, worth more the longer they live
		elimination  Elimination  one life each, last car driving wins

	SCORE
		Every mode places out of ONE round entry — { crowns, kills, points } — kept by
		ScoreService. `scoreKey` picks which of the three is the placing number, and
		`points` is the generic bucket ModeService pays into (a juggernaut takedown,
		surviving an elimination), so a new mode needs no new attribute anywhere.

	PUBLIC
		current() currentId() displayName() byId(id) all() nextId(afterId)
		scoreOf(entry, def) scoreNoun(def) usesCrowns(def) isTeams(def)
		hasJuggernaut(def) isLastStanding(def) livesFor(def)
		teamCount() teamName(i) teamColor(i) teamOf(player) sameTeam(a, b)
		isJuggernaut(player) colorFor(player, viewer) onModeChanged(cb)
		hasBounty(def) targetIdOf(p) targetOf(p) isTargetOf(hunter, victim) bountyOf(p)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)

local ATTR = Config.ATTR
local CFG = Config.MODES

local GameModes = {}

-- LIST is the authoring order; ROTATION is the play order. Built once, at load.
local byId = {}
for _, def in ipairs(CFG.LIST) do
	byId[def.id] = def
end

--[[ What a client that connected before the first round — or a server whose ModeService
	failed to init — answers with. The first entry of the rotation, so the fallback is a
	REAL mode instead of a nil every caller has to guard. ]]
local DEFAULT = byId[CFG.ROTATION[1]] or CFG.LIST[1]

GameModes.DEFAULT_ID = DEFAULT.id
-- The juggernaut's colour is its own mode's accent, so the two can never drift apart.
GameModes.JUGG_COLOR = (byId.juggernaut and byId.juggernaut.accent) or Color3.fromRGB(190, 120, 255)

local function core(): Instance
	local found = ReplicatedStorage:FindFirstChild("CrashCore")
	if not found and not RunService:IsServer() then
		found = ReplicatedStorage:WaitForChild("CrashCore", 20)
	end
	assert(found, "GameModes: CrashCore missing")
	return found
end

GameModes.root = core

-- ==========================================================================
-- which mode
-- ==========================================================================
function GameModes.all()
	return CFG.LIST
end

function GameModes.byId(id: string?)
	return type(id) == "string" and byId[id] or nil
end

function GameModes.currentId(): string
	local id = core():GetAttribute(ATTR.MODE_ID)
	if type(id) == "string" and byId[id] then
		return id
	end
	return DEFAULT.id
end

function GameModes.current()
	return byId[GameModes.currentId()] or DEFAULT
end

-- The replicated display name, falling back to the def so the UI is never blank.
function GameModes.displayName(): string
	local name = core():GetAttribute(ATTR.MODE_NAME)
	if type(name) == "string" and name ~= "" then
		return name
	end
	return GameModes.current().name or "Battle"
end

--[[ The next mode in the rotation. An unknown / nil id starts from the top, and an id
	sitting in ROTATION with no LIST entry is skipped rather than returned. ]]
function GameModes.nextId(afterId: string?): string
	local rotation = CFG.ROTATION
	local index = 0
	for i, id in ipairs(rotation) do
		if id == afterId then
			index = i
			break
		end
	end
	for step = 1, #rotation do
		local candidate = rotation[(index + step - 1) % #rotation + 1]
		if byId[candidate] then
			return candidate
		end
	end
	return DEFAULT.id
end

-- ==========================================================================
-- rules — every one takes an OPTIONAL def so a hot loop can resolve once
-- ==========================================================================
function GameModes.livesFor(def): number
	def = def or GameModes.current()
	return math.max(1, math.floor(tonumber(def.lives) or Config.MATCH.LIVES))
end

function GameModes.usesCrowns(def): boolean
	def = def or GameModes.current()
	return def.crowns == true
end

function GameModes.isTeams(def): boolean
	def = def or GameModes.current()
	return def.teams == true
end

function GameModes.hasJuggernaut(def): boolean
	def = def or GameModes.current()
	return def.juggernaut == true
end

function GameModes.hasBounty(def): boolean
	def = def or GameModes.current()
	return def.bounty == true
end

function GameModes.isLastStanding(def): boolean
	def = def or GameModes.current()
	return def.lastStanding == true
end

-- ==========================================================================
-- score
-- ==========================================================================
--[[ `entry` is a ScoreService round row: { crowns, kills, points }. WHICH of the three
	places is the mode's business, never the caller's — that is the whole reason this
	function exists rather than everyone reading .crowns. ]]
function GameModes.scoreOf(entry, def): number
	if type(entry) ~= "table" then
		return 0
	end
	def = def or GameModes.current()
	local value = entry[def.scoreKey or "crowns"]
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.floor(value)
end

function GameModes.scoreNoun(def): string
	def = def or GameModes.current()
	return def.scoreNoun or "points"
end

function GameModes.accent(def): Color3
	def = def or GameModes.current()
	return def.accent or Color3.fromRGB(255, 199, 64)
end

-- ==========================================================================
-- sides
-- ==========================================================================
function GameModes.teamCount(): number
	return #CFG.TEAM_NAMES
end

function GameModes.teamName(index: number?): string
	return CFG.TEAM_NAMES[index or 0] or ""
end

function GameModes.teamColor(index: number?): Color3
	return CFG.TEAM_COLORS[index or 0] or Color3.fromRGB(255, 255, 255)
end

-- 0 means "no team", which is the honest answer in four of the five modes.
function GameModes.teamOf(player): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 0
	end
	local team = player:GetAttribute(ATTR.TEAM)
	if type(team) ~= "number" or team ~= team then
		return 0
	end
	team = math.floor(team)
	if team < 1 or team > #CFG.TEAM_NAMES then
		return 0
	end
	return team
end

--[[ True ONLY when both are on the same REAL team. Everything that asks this is asking
	"must I hold fire?", so a teamless player is never a team-mate: in a mode with teams
	off every pair answers false and friendly fire simply never applies. ]]
function GameModes.sameTeam(a, b): boolean
	local teamA = GameModes.teamOf(a)
	return teamA ~= 0 and teamA == GameModes.teamOf(b)
end

function GameModes.isJuggernaut(player): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	return player:GetAttribute(ATTR.JUGGERNAUT) == true
end

-- ==========================================================================
-- bounty — the contract mode's two reads. BountyService is the only writer.
-- ==========================================================================
--[[ The userId this player has been sent after, or 0 for "nobody" -- which is the
	honest answer in every other mode, while a roller is still spinning, and for the
	last car left alive. Attributes, so a client needs no handshake and a mid-round
	joiner is correct on the frame it arrives. ]]
function GameModes.targetIdOf(player): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 0
	end
	local id = tonumber(player:GetAttribute(ATTR.BOUNTY_TARGET))
	if type(id) ~= "number" or id ~= id or id <= 0 then
		return 0
	end
	return math.floor(id)
end

-- The Player behind that id, or nil if they have left. Never assume this is alive.
function GameModes.targetOf(player): Player?
	local id = GameModes.targetIdOf(player)
	if id == 0 then
		return nil
	end
	return Players:GetPlayerByUserId(id)
end

-- True ONLY when `victim` is exactly the car `hunter` is contracted to wreck.
function GameModes.isTargetOf(hunter, victim): boolean
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then
		return false
	end
	local id = GameModes.targetIdOf(hunter)
	return id ~= 0 and id == victim.UserId
end

-- What this player is worth to whoever wrecks them, right now.
function GameModes.bountyOf(player): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 0
	end
	local value = tonumber(player:GetAttribute(ATTR.BOUNTY))
	if type(value) ~= "number" or value ~= value or value < 0 then
		return 0
	end
	return math.floor(value)
end

--[[ The one colour a car should wear, or nil when this mode says nothing about this
	player (so the caller keeps its own default). Juggernaut beats team on purpose:
	the instant both are true, "that is the monster" is the more useful read.

	`viewer` is WHOSE SCREEN this is being drawn on, and only Bounty needs it: a
	contract is a RELATIONSHIP, not a property of a car, so one car is red on its
	hunter's screen and white on everybody else's at the same instant. Clients pass
	their LocalPlayer. A caller with nobody to ask -- the server, or a list drawn
	before the local player resolves -- gets the neutral colour for everyone, which is
	a plain field rather than a wrong red. ]]
function GameModes.colorFor(player, viewer): Color3?
	if GameModes.isJuggernaut(player) then
		return GameModes.JUGG_COLOR
	end
	local team = GameModes.teamOf(player)
	if team ~= 0 then
		return GameModes.teamColor(team)
	end
	if GameModes.hasBounty() then
		local B = Config.BOUNTY
		if viewer and GameModes.isTargetOf(viewer, player) then
			return B.TARGET_COLOR
		end
		return B.OTHER_COLOR
	end
	return nil
end

--[[ Fires cb(def) on every mode change AND once immediately with the current mode, so a
	listener never misses the round it joined into. Mirrors MatchState.onPhaseChanged. ]]
function GameModes.onModeChanged(cb: (any) -> ()): RBXScriptConnection
	local conn = core():GetAttributeChangedSignal(ATTR.MODE_ID):Connect(function()
		cb(GameModes.current())
	end)
	task.spawn(cb, GameModes.current())
	return conn
end

return GameModes
