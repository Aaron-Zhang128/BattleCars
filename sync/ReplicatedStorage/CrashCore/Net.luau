--[[ Net
	Central remote registry. ONE Remotes folder, ensureRemote idiom everywhere.

	Server calls Net.server(name) during init to create/fetch a remote.
	Client calls Net.client(name) to fetch one (waits for replication).

	PINNED REMOTE CONTRACT — do not rename or invent entries.

	FireWeapon      RemoteEvent            C->S  (aimDir: Vector3, origin: Vector3?)
	                                             Request to fire the held powerup. Server is authority
	                                             over damage, ammo, cooldown and every hit; the CLIENT
	                                             supplies the shot GEOMETRY, because the turret model is
	                                             drawn client-side and only that machine knows where its
	                                             barrel points this frame.
	                                               origin — that barrel. Clamped to within
	                                                        Config.WEAPONS.MAX_MUZZLE_OFFSET of the
	                                                        firer's own hull, else replaced by the
	                                                        hull-centre muzzle.
	                                               aimDir — full 3D and may PITCH (clamped to
	                                                        AIM_MAX_PITCH_DEG, yaw cone still applies):
	                                                        a barrel sits ~8 studs above hull centre, so
	                                                        a flat shot from one misses every car.
	CarState        UnreliableRemoteEvent  C->S  (pos: Vector3, vel: Vector3, onGround: boolean)
	                                             Heartbeat for server-side sanity/anti-cheat + pickup checks.
	RequestRespawn  RemoteEvent            C->S  ()
	                                             Player pressed RESPAWN on the death card.
	GarageAction    RemoteEvent            C->S  (action: "buy"|"equip", carId: string)
	                                       S->C  (ok: boolean, message: string, carId: string)
	CarLifecycle    RemoteEvent            S->C  (action: "spawned"|"destroyed", model: Model?, info: table?)
	                                             info.cause / info.killer on destroy.
	WeaponFx        RemoteEvent            S->C  (kind: string, payload: table)
	                                             kind = powerup id or "IMPACT" | "RAM" | "SHIELD_POP".
	                                             payload = { origin: Vector3, dir: Vector3?, target: Vector3?,
	                                                         color: Color3?, radius: number?,
	                                                         userId: number?, userIds: {number}? }
	                                             IDENTITY (added after FxController had to guess by proximity):
	                                               userId  — on EVERY fire kind, plus SHIELD / SHIELD_POP: whose
	                                                         car fired / owns the bubble. TurretController animates
	                                                         that car's turret from it, so a shot can never kick the
	                                                         wrong roof in a scrum.
	                                               userIds — RAM: {attackerUserId, victimUserId}, so a client can
	                                                         tell whether IT was involved instead of measuring
	                                                         distance to the contact point.
	                                             Server-spawned projectiles in Workspace.Projectiles must also carry
	                                             an attribute PowerupId = <powerup id> so the client can decorate
	                                             them correctly rather than name-sniffing.
	BountyEvent     RemoteEvent            S->C  (kind: string, payload: table)
	                                             Bounty mode only. Client DRAWS ONLY; the server
	                                             owns every contract and every payout.
	                                               "roll"   { targetId, targetName, targetBounty,
	                                                          reel = { {userId, name, bounty}, ... },
	                                                          landIndex, startedAt, duration }
	                                                        The target roller. reel[landIndex] IS the
	                                                        winner and tiles exist after it so the
	                                                        settle never scrolls off the strip. The
	                                                        Player's BountyTarget attribute is NOT
	                                                        written until startedAt + duration, so the
	                                                        reel landing IS the reveal.
	                                               "claim"  { victimName, amount, wasTarget }
	                                                        You banked a bounty.
	                                               "lost"   { }  your mark was wrecked by somebody
	                                                        else; a new roll follows.
	MatchEvent      RemoteEvent            S->C  (kind: string, payload: table)
	                                             kind = "phase" | "kill" | "crown" | "results" | "board".
	Notify          RemoteEvent            S->C  (text: string, mood: "gold"|"green"|"red")
	Monetization    RemoteEvent            C->S  (action: "product"|"pass"|"claimGroup"|"claimFavourite", key: string?)
	                                       S->C  (kind: string, payload: table)
	                                             kind = "granted" {what, amount} | "owned" {passKey}
	                                                  | "failed" {reason} | "limited" {key, endsAt}
	                                             The client NEVER grants anything: it prompts, then reads
	                                             the resulting attributes. Prices come from Config only,
	                                             never from the client.
	DailyAction     RemoteEvent            C->S  (action: "claim"|"sync")
	                                       S->C  (state: { day: number, ready: boolean, nextAt: number,
	                                                       claimed: {boolean}, rewards: {table} })
	MapVote         RemoteEvent            C->S  ("vote", mapId: string) | ("sync")
	                                       S->C  ("state", {
	                                               open    = boolean,
	                                               endsAt  = number,   -- server time the ballot closes
	                                               roundId = number,   -- so a stale payload is discardable
	                                               winner  = string?,  -- set once it has closed
	                                               choices = { { id, name, blurb, votes }, ... },
	                                               voters  = { [userId] = mapId } })
	                                             ONE broadcast for everybody: `voters` is how a client
	                                             finds its OWN pick inside it, and how the UI can show
	                                             who is backing what. The client draws only — the
	                                             server owns the tally, the clock and the winner.
	LuckySpin       RemoteEvent            S->C  (payload: table)
	                                             Lucky-block reel. payload = {
	                                               reel      = { powerupId, ... } tiles to scroll,
	                                               winner    = powerup id that was won,
	                                               landIndex = index in `reel` the reel stops on.
	                                                           reel[landIndex] == winner, and tiles
	                                                           exist AFTER it so the settle never
	                                                           scrolls past the end of the strip,
	                                               startedAt = workspace:GetServerTimeNow() at the roll,
	                                               duration  = seconds the reel should take }
	                                             The powerup is NOT in the slot when this arrives —
	                                             the server grants it at startedAt + duration, so the
	                                             HUD fills as the reel stops. Client draws only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.NAMES = {
	FireWeapon = "RemoteEvent",
	CarState = "UnreliableRemoteEvent",
	RequestRespawn = "RemoteEvent",
	GarageAction = "RemoteEvent",
	CarLifecycle = "RemoteEvent",
	WeaponFx = "RemoteEvent",
	MatchEvent = "RemoteEvent",
	BountyEvent = "RemoteEvent",
	Notify = "RemoteEvent",
	Monetization = "RemoteEvent",
	DailyAction = "RemoteEvent",
	LuckySpin = "RemoteEvent",
	MapVote = "RemoteEvent",
}

-- Per-player request throttle shared by every server handler.
Net.REQUEST_GAP = 0.5

local function remotesFolder(): Instance
	local core = ReplicatedStorage:FindFirstChild("CrashCore")
	if not core then
		if RunService:IsServer() then
			core = Instance.new("Folder")
			core.Name = "CrashCore"
			core.Parent = ReplicatedStorage
		else
			core = ReplicatedStorage:WaitForChild("CrashCore", 20)
		end
	end
	assert(core, "Net: CrashCore folder missing")

	local folder = core:FindFirstChild("Remotes")
	if not folder then
		if RunService:IsServer() then
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = core
		else
			folder = core:WaitForChild("Remotes", 20)
		end
	end
	assert(folder, "Net: Remotes folder missing")
	return folder
end

-- Server: fetch or create. Validates class, replaces a wrong-class impostor.
function Net.server(name: string): Instance
	local className = Net.NAMES[name]
	assert(className, "Net.server: unknown remote '" .. tostring(name) .. "'")

	local folder = remotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		if existing.ClassName == className then
			return existing
		end
		warn("Net: replacing " .. name .. " (was " .. existing.ClassName .. ", want " .. className .. ")")
		existing:Destroy()
	end

	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = folder
	return remote
end

-- Client: fetch, waiting for replication.
function Net.client(name: string, timeout: number?): Instance
	local className = Net.NAMES[name]
	assert(className, "Net.client: unknown remote '" .. tostring(name) .. "'")

	local folder = remotesFolder()
	local remote = folder:WaitForChild(name, timeout or 20)
	if not remote then
		error("Net.client: '" .. name .. "' never replicated", 2)
	end
	if remote.ClassName ~= className then
		error("Net.client: '" .. name .. "' is a " .. remote.ClassName .. ", expected " .. className, 2)
	end
	return remote
end

-- Creates every pinned remote. Server bootstrap calls this before services init.
function Net.buildAll(): { [string]: Instance }
	local built = {}
	for name in pairs(Net.NAMES) do
		built[name] = Net.server(name)
	end
	return built
end

--[[ Server-side spam guard.
	local gate = Net.throttle()
	if not gate(player) then return end
]]
function Net.throttle(gapSeconds: number?)
	local gap = gapSeconds or Net.REQUEST_GAP
	local last = {}

	local Players = game:GetService("Players")
	Players.PlayerRemoving:Connect(function(player)
		last[player] = nil
	end)

	return function(player: Instance): boolean
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return false
		end
		local now = os.clock()
		local prev = last[player]
		if prev and now - prev < gap then
			return false
		end
		last[player] = now
		return true
	end
end

return Net
