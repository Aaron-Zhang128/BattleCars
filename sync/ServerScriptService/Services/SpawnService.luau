--[[ SpawnService
	Car lifecycle authority. Players have no humanoid character — spawning a player
	means building their car, handing its physics to them, and spending their lives.

	DATA FLOW
		MatchService  -> spawnAll() / despawnAll(cause) / resetLives(player) at phase edges
		CombatService -> killCar(player, cause, killer) lands back here as despawnCar()
		here          -> CombatService.onCarSpawned(player, car) immediately after a spawn
		client        -> CarState heartbeat (validation seam) + RequestRespawn (death card)
		MatchService  -> reads isAlive()/getCar() here; it owns the AliveCount attribute.

	REMOTES
		RequestRespawn (C->S) ()                      respawn button; phase + timer + lives gated
		CarState       (C->S) (pos, vel, onGround)    unreliable heartbeat, anti-cheat seam
		CarLifecycle   (S->C) ("spawned", car, { carId })
		                      ("destroyed", nil, { cause, killerName, livesLeft, canRespawnAt })

	ATTRIBUTES (sole writer, per Main's ownership table)
		Player     Config.ATTR.ALIVE (boolean)  Config.ATTR.LIVES (number)
		Car model  ChassisSpec.ATTR.INVULN — spawn protection stamp, written once at spawn.
		Reads only: Config.ATTR.EQUIPPED (ProfileService), car Boost/Frozen (CombatService).
		Never writes Config.ATTR.ALIVE_COUNT — MatchService owns it.

	RUNTIME FOLDER
		Workspace.Cars — created and owned here; every live car parents into it.

	INIT ORDER
		After ProfileService / ArenaService / CarFactory (spawnCar calls all three),
		before PickupService..MatchService. Siblings are resolved LAZILY at call time
		through ctx.svc, so init order only has to hold by the first spawn — and a
		missing sibling degrades with one warn instead of erroring every frame.

	NETWORK OWNERSHIP
		The owning client simulates its own car (zero input latency). The server never
		writes Hull.Drive/Hull.Steer on a player-owned car; it only reads position and
		velocity to judge pit deaths and absurd state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")

local Config = require(core:WaitForChild("Config"))
local Net = require(core:WaitForChild("Net"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local CarRegistry = require(sharedFolder:WaitForChild("CarRegistry"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))

local ATTR = Config.ATTR
local CFG = Config.MATCH
local CHASSIS = Config.CHASSIS

-- ==========================================================================
-- Local tunables. Config is the pinned contract this wave and is not ours to edit,
-- so the handful of numbers only SpawnService cares about live here (see HANDOFF:
-- they can migrate into a Config.SPAWN section later with no behaviour change).
-- ==========================================================================
local CARS_FOLDER = "Cars"
local WATCHDOG_INTERVAL = 1 / 10 -- server-authoritative sweep: pit deaths + orphan reaping
local STATE_RATE_SLACK = 2 -- inbound CarState allowance over Config.CHASSIS.STATE_SEND_HZ
local STATE_STALE_SECONDS = 3 -- a heartbeat older than this is not reported to callers
local SPEED_TOLERANCE = 2.5 -- multiple of resolved topSpeed still considered plausible
local BOUNDS_MARGIN = 250 -- studs past the arena edge before a position is absurd
local SUSPICION_STRIKES = 8 -- consecutive absurd samples before we correct anything
local CORRECT_LIFT = 4 -- studs above the last trusted pivot when correcting

local ARENA_HALF = Config.ARENA.SIZE * 0.5

-- Despawn causes. Only KILLED and FELL cost a life.
local CAUSE = {
	KILLED = "killed",
	FELL = "fell",
	ROUND_END = "roundEnd",
	LEFT = "left",
	RESET = "reset",
}

local COSTS_A_LIFE = {
	[CAUSE.KILLED] = true,
	[CAUSE.FELL] = true,
}

local SpawnService = {}

-- ==========================================================================
-- state
-- ==========================================================================
local ctxRef -- set in init; siblings resolved lazily off ctxRef.svc
local carsFolder -- Workspace.Cars
local carLifecycle -- RemoteEvent, S->C
local respawnGate -- Net.throttle for RequestRespawn
local stateGate -- Net.throttle for the CarState firehose
local initialized = false

local carsByPlayer = {} -- [Player] = Model
local playerByCar = {} -- [Model] = Player
local respawnAtByPlayer = {} -- [Player] = server time the respawn button unlocks
local stateByPlayer = {} -- [Player] = { pos, vel, onGround, at }  (client-reported)
local trustedCFrameByPlayer = {} -- [Player] = last pivot the server saw inside the arena
local topSpeedByPlayer = {} -- [Player] = resolved topSpeed of the live car
local strikesByPlayer = {} -- [Player] = consecutive absurd samples
local warnedByPlayer = {} -- [Player] = true once we have complained about them
local pendingDeath = {} -- [Model] = true while a pit death is in flight
local missingWarned = {} -- [string] = true, one warn per absent sibling api

-- ==========================================================================
-- helpers
-- ==========================================================================
--[[ Resolves a sibling service function at CALL time (Main fills ctx.svc as it goes).
	A sibling that is still a stub must degrade quietly, never spam a Heartbeat. ]]
local function api(serviceName: string, fnName: string)
	local svc = ctxRef and ctxRef.svc and ctxRef.svc[serviceName]
	local fn = svc and svc[fnName]
	if type(fn) ~= "function" then
		local key = serviceName .. "." .. fnName
		if not missingWarned[key] then
			missingWarned[key] = true
			warn("SpawnService: " .. key .. " unavailable")
		end
		return nil
	end
	return fn
end

local function isPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function isFinite(v: Vector3): boolean
	local m = v.Magnitude
	return m == m and m < math.huge
end

-- ensureRemote-style folder guard. Never clears children: that would nuke live cars.
local function ensureCarsFolder(): Instance
	local existing = workspace:FindFirstChild(CARS_FOLDER)
	if existing and not existing:IsA("Folder") then
		warn("SpawnService: replacing Workspace." .. CARS_FOLDER .. " (was " .. existing.ClassName .. ")")
		existing:Destroy()
		existing = nil
	end
	if not existing then
		existing = Instance.new("Folder")
		existing.Name = CARS_FOLDER
		existing.Parent = workspace
	end
	return existing
end

local function livingFolder(): Instance
	if not carsFolder or not carsFolder.Parent then
		carsFolder = ensureCarsFolder()
	end
	return carsFolder
end

-- The tracked car if it is still in the world. Read-only: reaping is the watchdog's job.
local function liveCar(player: Instance): Model?
	local car = carsByPlayer[player]
	if car and car.Parent then
		return car
	end
	return nil
end

local function setLives(player: Instance, lives: number)
	player:SetAttribute(ATTR.LIVES, math.max(0, math.floor(lives)))
end

local function fireLifecycle(player: Instance, action: string, model: Model?, info: { [string]: any })
	if not carLifecycle or not player.Parent then
		return
	end
	carLifecycle:FireClient(player, action, model, info)
end

-- ==========================================================================
-- where a fresh car goes
-- ==========================================================================
--[[ Cars only ever exist during a Match. The Lobby hub is on foot — LobbyService owns
	those characters and there is no car up there to place — and Results despawns
	everything, so this is always the arena's spawn ring. The wrapper exists to keep the
	"no arena, no spawn" failure in one place. ]]
local function resolveSpawnCFrame(player: Instance): CFrame?
	local randomSpawn = api("ArenaService", "randomSpawn")
	if not randomSpawn then
		return nil
	end

	local okSpawn, spawnCFrame = pcall(randomSpawn)
	if not okSpawn or typeof(spawnCFrame) ~= "CFrame" then
		warn("SpawnService: no spawn CFrame for " .. player.Name)
		return nil
	end
	return spawnCFrame
end

--[[ Absurd = far outside the arena HORIZONTALLY. Height is deliberately ignored:
	a car thrown clean out of the arena is legitimately below the floor and the death
	watchdog already owns that case. ArenaService is the authority on "inside";
	the margin exists so a ramp launch or a wall graze never reads as cheating. ]]
local function isAbsurdPosition(pos: Vector3): boolean
	if not isFinite(pos) then
		return true
	end

	local isInside = api("ArenaService", "isInside")
	if isInside then
		local ok, inside = pcall(isInside, pos)
		if ok and inside then
			return false
		end
	end

	local origin = Config.ARENA.ORIGIN
	local flat = Vector3.new(pos.X - origin.X, 0, pos.Z - origin.Z)
	return flat.Magnitude > ARENA_HALF + BOUNDS_MARGIN
end

--[[ Counts one absurd sample. Only after SUSPICION_STRIKES in a row do we touch the car.

	TODO(anticheat): this is a nudge, not a lockdown — the client owns the car's physics,
	so it can fight the correction back. Tolerances are intentionally loose because
	yanking an honest player mid-launch is far worse than a slow cheater. Tighten (and
	escalate to revoking network ownership or a kick) only with real telemetry. ]]
local function noteSuspicion(player: Instance, car: Model, why: string)
	local strikes = (strikesByPlayer[player] or 0) + 1
	strikesByPlayer[player] = strikes
	if strikes < SUSPICION_STRIKES then
		return
	end
	strikesByPlayer[player] = 0

	if not warnedByPlayer[player] then
		warnedByPlayer[player] = true
		warn("SpawnService: correcting " .. player.Name .. " — " .. why)
	end

	local target = trustedCFrameByPlayer[player]
	local hull = ChassisSpec.getHull(car)
	if not target or not hull or not car.Parent then
		return
	end

	car:PivotTo(target + Vector3.new(0, CORRECT_LIFT, 0))
	hull.AssemblyLinearVelocity = Vector3.zero
	hull.AssemblyAngularVelocity = Vector3.zero
end

-- ==========================================================================
-- public: reads
-- ==========================================================================
function SpawnService.getLives(player: Instance): number
	if not isPlayer(player) then
		return 0
	end
	local lives = player:GetAttribute(ATTR.LIVES)
	if type(lives) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(lives))
end

function SpawnService.isAlive(player: Instance): boolean
	if not isPlayer(player) then
		return false
	end
	return liveCar(player) ~= nil
end

function SpawnService.getCar(player: Instance): Model?
	if not isPlayer(player) then
		return nil
	end
	return liveCar(player)
end

function SpawnService.playerFromCar(model: Instance?): Instance?
	if typeof(model) ~= "Instance" then
		return nil
	end

	local player = playerByCar[model]
	if player and player.Parent then
		return player
	end

	-- Fallback for a model mid-despawn: the owner stamp CarFactory wrote.
	local userId = model:GetAttribute(ChassisSpec.ATTR.OWNER)
	if type(userId) == "number" then
		return Players:GetPlayerByUserId(userId)
	end
	return nil
end

--[[ Newest CarState sample: { pos: Vector3, vel: Vector3, onGround: boolean, at: number }.
	CLIENT-REPORTED — fine for fx and hints, never for authority; read the hull for that.
	Returns nil when there is no live car or the sample is stale. Treat as read-only. ]]
function SpawnService.lastKnownState(player: Instance)
	if not isPlayer(player) then
		return nil
	end
	local sample = stateByPlayer[player]
	if not sample then
		return nil
	end
	if workspace:GetServerTimeNow() - sample.at > STATE_STALE_SECONDS then
		return nil
	end
	return sample
end

-- ==========================================================================
-- public: lifecycle
-- ==========================================================================
function SpawnService.spawnCar(player: Instance, opts: { lift: number? }?): Model?
	if not isPlayer(player) or not player.Parent then
		return nil
	end
	if liveCar(player) then
		return nil -- already driving; an ordinary no-op, not an error
	end
	if SpawnService.getLives(player) <= 0 then
		return nil -- out for the rest of the round
	end

	-- Profile still loading is expected on a fresh join, so it is a silent refusal.
	local isLoaded = api("ProfileService", "isLoaded")
	if isLoaded then
		local okLoaded, loaded = pcall(isLoaded, player)
		if not okLoaded or not loaded then
			return nil
		end
	end

	local buildCar = api("CarFactory", "build")
	if not buildCar then
		return nil
	end

	local spawnCFrame = resolveSpawnCFrame(player)
	if not spawnCFrame then
		return nil
	end

	--[[ opts.lift is the round-start drop: spawn this far above the spawn slot and let
		the car fall into the map, so a round opens with everyone arriving from the sky
		instead of blinking into existence. Ordinary spawns pass nothing. ]]
	local lift = (type(opts) == "table" and tonumber(opts.lift)) or 0
	if lift > 0 then
		spawnCFrame = spawnCFrame + Vector3.new(0, lift, 0)
	end

	local carId = CarRegistry.equippedId(player)

	--[[ The MODE gets to change the BODY before it is built. The Juggernaut's car is 2x,
		heavier, tougher and a little slower, and every one of those is decided at BUILD
		time — hull size, density, hover height, MaxForce, MaxHp — so it is a CarFactory
		option rather than something bolted onto a car that is already driving. nil is the
		ordinary car, which is what four of the five modes return for everybody. ]]
	local mods = nil
	local modifiersFor = api("ModeService", "carModifiersFor")
	if modifiersFor then
		local okMods, value = pcall(modifiersFor, player)
		if okMods and type(value) == "table" then
			mods = value
		end
	end

	local okBuild, car = pcall(buildCar, carId, player.UserId, mods)
	if not okBuild or typeof(car) ~= "Instance" or not car:IsA("Model") then
		warn("SpawnService: CarFactory.build failed for " .. player.Name .. " / " .. tostring(carId) .. " -> " .. tostring(car))
		return nil
	end

	-- CarFactory is allowed to yield: bail if the world moved on while it built.
	if not player.Parent or carsByPlayer[player] then
		car:Destroy()
		return nil
	end

	local hull = ChassisSpec.getHull(car)
	if not hull then
		warn("SpawnService: car for " .. player.Name .. " has no " .. ChassisSpec.HULL)
		car:Destroy()
		return nil
	end

	car:PivotTo(spawnCFrame)
	--[[ CarFactory ships Steer.CFrame as identity, which commands "face world -Z" from
		the moment the car is live until ChassisController attaches and starts writing it.
		Aim the constraint down the spawn CFrame first (and zero any stale drive command)
		so a fresh car never yaws the wrong way for a few frames. Both are FindFirstChild
		guarded: a malformed car should still spawn, not error. ]]
	local steer = hull:FindFirstChild(ChassisSpec.STEER)
	if steer then
		steer.CFrame = CFrame.lookAlong(Vector3.zero, spawnCFrame.LookVector)
	end
	local drive = hull:FindFirstChild(ChassisSpec.DRIVE)
	if drive then
		drive.VectorVelocity = Vector3.zero
	end
	car:SetAttribute(ChassisSpec.ATTR.INVULN, workspace:GetServerTimeNow() + CFG.SPAWN_PROTECT)
	car.Parent = livingFolder()

	--[[ The whole feel of the game: the owner simulates its own car, so throttle and
		steering have zero latency. Must happen after parenting into Workspace. ]]
	local okOwner, ownerErr = pcall(hull.SetNetworkOwner, hull, player)
	if not okOwner then
		warn("SpawnService: SetNetworkOwner failed for " .. player.Name .. " -> " .. tostring(ownerErr))
		car:Destroy()
		return nil
	end

	--[[ Replication focus. There is no character here (CharacterAutoLoads = false), so
		the player has no default streaming anchor. With StreamingEnabled the client would
		never stream in its OWN car's Hull: the Model replicates as an empty container and
		ChassisController correctly refuses to drive a body-less car. Streaming is off in
		this place, so this is belt-and-braces — it makes re-enabling streaming safe
		instead of silently unplayable. ]]
	pcall(function()
		player.ReplicationFocus = hull
	end)

	carsByPlayer[player] = car
	playerByCar[car] = player
	trustedCFrameByPlayer[player] = car:GetPivot()
	-- resolveCar, not resolve(carId): a modified body has its own top speed, and the
	-- anti-cheat ceiling below is measured against it.
	topSpeedByPlayer[player] = ChassisSpec.resolveCar(car).topSpeed
	strikesByPlayer[player] = 0
	player:SetAttribute(ATTR.ALIVE, true)

	fireLifecycle(player, "spawned", car, { carId = carId })

	local onCarSpawned = api("CombatService", "onCarSpawned")
	if onCarSpawned then
		local okHook, hookErr = pcall(onCarSpawned, player, car)
		if not okHook then
			warn("SpawnService: CombatService.onCarSpawned errored -> " .. tostring(hookErr))
		end
	end

	return car
end

--[[ Idempotent: the maps are cleared FIRST, so a second call (a Destroying listener,
	a doubled killCar) finds nothing and cannot charge a second life. ]]
function SpawnService.despawnCar(player: Instance, cause: string?, killerPlayer: Instance?)
	if not isPlayer(player) then
		return
	end

	local car = carsByPlayer[player]
	if not car then
		return
	end

	local reason = type(cause) == "string" and cause or CAUSE.RESET

	carsByPlayer[player] = nil
	playerByCar[car] = nil
	pendingDeath[car] = nil
	stateByPlayer[player] = nil
	trustedCFrameByPlayer[player] = nil
	topSpeedByPlayer[player] = nil
	strikesByPlayer[player] = nil

	local lives = SpawnService.getLives(player)
	if COSTS_A_LIFE[reason] then
		lives = math.max(0, lives - 1)
		setLives(player, lives)
	end

	player:SetAttribute(ATTR.ALIVE, false)
	car:Destroy()

	local canRespawnAt = workspace:GetServerTimeNow() + CFG.RESPAWN_DELAY
	respawnAtByPlayer[player] = canRespawnAt

	if reason == CAUSE.LEFT then
		return -- nobody home to tell
	end

	local killerName = nil
	if isPlayer(killerPlayer) then
		killerName = killerPlayer.DisplayName
	end

	--[[ livesLeft == 0 means out for the round: the death card becomes a spectate
		state and nothing here ever auto-respawns them. ]]
	fireLifecycle(player, "destroyed", nil, {
		cause = reason,
		killerName = killerName,
		livesLeft = lives,
		canRespawnAt = canRespawnAt,
	})
end

-- Match start: everyone with lives and no car gets one.
function SpawnService.spawnAll()
	for _, player in ipairs(Players:GetPlayers()) do
		if not liveCar(player) and SpawnService.getLives(player) > 0 then
			SpawnService.spawnCar(player)
		end
	end
end

--[[ Round start: everyone leaves the hub and drops into the arena.

	The mountaintop is 1500 studs from the arena and the map underneath has just been
	rebuilt, so there is no driving down there — the hub car is taken away and a fresh
	one is dropped in from Config.MATCH.DROP_IN_HEIGHT above the spawn ring.

	The despawn uses ROUND_END, which costs no life and raises no death card (DeathUI
	only reacts to killed/fell), so the handover is silent on the client.

	MUST be called AFTER the phase is already Match: resolveSpawnCFrame reads the phase,
	and calling this during Lobby would hand everybody hub slots again. ]]
function SpawnService.dropInAll()
	SpawnService.despawnAll(CAUSE.ROUND_END)

	for _, player in ipairs(Players:GetPlayers()) do
		if SpawnService.getLives(player) > 0 then
			SpawnService.spawnCar(player, { lift = CFG.DROP_IN_HEIGHT })
		end
	end
end

-- Match end: clear the field. Never costs a life.
function SpawnService.despawnAll(cause: string?)
	local reason = type(cause) == "string" and cause or CAUSE.ROUND_END
	for player in pairs(carsByPlayer) do
		SpawnService.despawnCar(player, reason)
	end

	-- Strays with no owner (a player who left mid-build) leave nothing behind.
	for _, child in ipairs(livingFolder():GetChildren()) do
		child:Destroy()
	end
end

--[[ Round start: full lives, respawn timer cleared, fresh benefit of the doubt.

	HOW MANY lives is the MODE's call — Elimination hands out exactly one, Deathmatch
	five — so ModeService is asked at call time. Config.MATCH.LIVES is the fallback,
	which means a missing or broken ModeService degrades to the original game rather
	than to a round where nobody can spawn. ]]
function SpawnService.resetLives(player: Instance)
	if not isPlayer(player) then
		return
	end

	local count = CFG.LIVES
	local livesFor = api("ModeService", "livesFor")
	if livesFor then
		local okLives, value = pcall(livesFor, player)
		if okLives and type(value) == "number" and value == value and value > 0 then
			count = value
		end
	end
	setLives(player, count)
	respawnAtByPlayer[player] = nil
	strikesByPlayer[player] = 0
	warnedByPlayer[player] = nil
end

-- ==========================================================================
-- remote handlers
-- ==========================================================================
--[[ Ordinary refusals are silent: the client runs its own countdown and the death
	card already knows the phase, so a warn here would only be log noise. ]]
local function onRequestRespawn(player: Instance)
	if not isPlayer(player) then
		return
	end
	if not respawnGate(player) then
		return
	end
	if liveCar(player) then
		return
	end
	if SpawnService.getLives(player) <= 0 then
		return
	end

	local readyAt = respawnAtByPlayer[player]
	if readyAt and workspace:GetServerTimeNow() < readyAt then
		return
	end

	local canRespawn = api("MatchService", "canRespawn")
	if canRespawn then
		local okPhase, allowed = pcall(canRespawn, player)
		if not okPhase or not allowed then
			return
		end
	elseif not MatchState.isMatch() then
		-- MatchService is the authority; the shared phase attribute is the fallback.
		return
	end

	SpawnService.spawnCar(player)
end

--[[ Client heartbeat at Config.CHASSIS.STATE_SEND_HZ. Every argument is type-checked and
	the stream is rate-gated, so a hostile client can neither poison the sample nor flood us. ]]
local function onCarState(player: Instance, pos: any, vel: any, onGround: any)
	if not isPlayer(player) then
		return
	end
	if typeof(pos) ~= "Vector3" or typeof(vel) ~= "Vector3" or typeof(onGround) ~= "boolean" then
		return
	end
	if not isFinite(pos) or not isFinite(vel) then
		return
	end
	if not stateGate(player) then
		return -- faster than the contract allows; drop the extra samples
	end

	local car = liveCar(player)
	if not car then
		return
	end

	local now = workspace:GetServerTimeNow()
	stateByPlayer[player] = { pos = pos, vel = vel, onGround = onGround, at = now }

	local hull = ChassisSpec.getHull(car)
	if not hull then
		return
	end

	--[[ Anti-cheat seam. Generous on purpose: ram knockback, rocket blasts and pit
		falls all push an honest car well past its own top speed.
		TODO(anticheat): also compare `pos` against hull.Position once the unreliable
		stream's jitter has been measured — a raw mismatch is far too noisy today. ]]
	local ceiling = (topSpeedByPlayer[player] or CHASSIS.TOP_SPEED)
		* math.max(1, ChassisSpec.speedMultiplier(car, now))
		* SPEED_TOLERANCE
	local fastest = math.max(vel.Magnitude, hull.AssemblyLinearVelocity.Magnitude)

	if isAbsurdPosition(pos) or isAbsurdPosition(hull.Position) then
		noteSuspicion(player, car, "position outside the arena")
	elseif fastest > ceiling then
		noteSuspicion(player, car, string.format("speed %d over ceiling %d", math.floor(fastest), math.floor(ceiling)))
	else
		strikesByPlayer[player] = 0
	end
end

-- ==========================================================================
-- watchdog — server-authoritative, never asks the client
-- ==========================================================================
--[[ An environmental death is our verdict, but its consequences are not ours:
	CombatService owns crown scattering and the kill feed. We only report it, then make
	sure the wreck is actually gone even if CombatService did nothing.

	FALL_KILL_Y is now the ONLY environmental death in the game: the arena floor has no
	hole and no hazard in it (plateaus replaced the lava, which replaced the pits), so
	the sole way to leave the world is to be knocked clean over the perimeter wall. That
	still costs a life and still pays kill credit to whoever launched you
	(Config.RAM.KILL_CREDIT_SECONDS), which is what keeps shoving people worth doing. ]]
local function killFallen(player: Instance, car: Model)
	local killCar = api("CombatService", "killCar")
	if killCar then
		local okKill, killErr = pcall(killCar, player, CAUSE.FELL)
		if okKill then
			if carsByPlayer[player] == car then
				SpawnService.despawnCar(player, CAUSE.FELL)
			end
			return
		end
		warn("SpawnService: CombatService.killCar errored -> " .. tostring(killErr))
	end
	SpawnService.despawnCar(player, CAUSE.FELL)
end

local watchdogAccum = 0

--[[ Bounded work: one hull read per live car, WATCHDOG_INTERVAL apart. Removing keys
	while iterating pairs() is safe; nothing in here ever adds one. ]]
local function onHeartbeat(dt: number)
	watchdogAccum += dt
	if watchdogAccum < WATCHDOG_INTERVAL then
		return
	end
	watchdogAccum = 0

	for player, car in pairs(carsByPlayer) do
		if not player.Parent then
			SpawnService.despawnCar(player, CAUSE.LEFT)
		elseif not car.Parent then
			-- Something outside this service destroyed the model: resync, charge no life.
			SpawnService.despawnCar(player, CAUSE.RESET)
		elseif not pendingDeath[car] then
			local hull = ChassisSpec.getHull(car)
			if not hull then
				SpawnService.despawnCar(player, CAUSE.RESET)
			elseif hull.Position.Y < CHASSIS.FALL_KILL_Y then
				pendingDeath[car] = true
				-- Spawned so a yielding CombatService cannot stall the sweep.
				task.spawn(killFallen, player, car)
			elseif isAbsurdPosition(hull.Position) then
				noteSuspicion(player, car, "hull outside the arena")
			else
				trustedCFrameByPlayer[player] = car:GetPivot()
			end
		end
	end
end

-- ==========================================================================
-- players
-- ==========================================================================
-- Defaults the moment they join so the HUD has numbers before the first spawn.
local function onPlayerAdded(player: Instance)
	setLives(player, CFG.LIVES)
	player:SetAttribute(ATTR.ALIVE, false)
end

local function onPlayerRemoving(player: Instance)
	SpawnService.despawnCar(player, CAUSE.LEFT)

	respawnAtByPlayer[player] = nil
	stateByPlayer[player] = nil
	trustedCFrameByPlayer[player] = nil
	topSpeedByPlayer[player] = nil
	strikesByPlayer[player] = nil
	warnedByPlayer[player] = nil
end

-- ==========================================================================
-- init
-- ==========================================================================
function SpawnService.init(ctx)
	if initialized then
		warn("SpawnService: init called twice")
		return
	end
	initialized = true
	ctxRef = ctx

	carsFolder = ensureCarsFolder()
	-- No car outlives the session that built it, so anything already in there is junk.
	for _, child in ipairs(carsFolder:GetChildren()) do
		child:Destroy()
	end

	local net = ctx and ctx.net or {}
	carLifecycle = net.CarLifecycle or Net.server("CarLifecycle")
	local requestRespawn = net.RequestRespawn or Net.server("RequestRespawn")
	local carState = net.CarState or Net.server("CarState")

	respawnGate = Net.throttle()
	stateGate = Net.throttle(1 / (CHASSIS.STATE_SEND_HZ * STATE_RATE_SLACK))

	requestRespawn.OnServerEvent:Connect(onRequestRespawn)
	carState.OnServerEvent:Connect(onCarState)

	-- Studio: players can already be in the game when services init.
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Server-lifetime connections: nothing to disconnect, no per-round bookkeeping.
	RunService.Heartbeat:Connect(onHeartbeat)
end

return SpawnService
