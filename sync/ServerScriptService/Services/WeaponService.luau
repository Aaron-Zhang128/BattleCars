--[[ WeaponService
	Server authority for every powerup in Config.POWERUPS. The client ASKS
	(FireWeapon), the server DECIDES: phase, live car, slot, ammo, per-powerup
	cooldown and aim are all re-validated here. Nothing about a shot is trusted
	from the client except one direction hint, and even that is flattened to the
	driving plane, clamped into a forward cone, and re-originated from the car's
	real server-side hull position.

	DATA FLOW
		PickupService.grantCrate -> WeaponService.givePowerup(player, id)
			-> writes ATTR.POWERUP / ATTR.POWERUP_AMMO (this service is their ONLY writer)
		client WeaponController -> FireWeapon(aimDir) -> validate -> kind handler
			-> CombatService.applyDamage / applyKnockback / applyFreeze / applyShield
			-> WeaponFx:FireAllClients(kind, payload) for FxController to draw

	REMOTES
		FireWeapon (C->S) (aimDir: Vector3, origin: Vector3?)
			origin = the barrel of the weapon on the firing car's roof. CLIENT-SUPPLIED
			because the turret model is drawn client-side, so only that machine knows
			where it points; clamped by sanitizeOrigin to near its own hull. aimDir may
			now PITCH (clamped by sanitizeAim) so a shot from the barrel can angle down
			onto a car instead of sailing over it.
		WeaponFx   (S->C) (kind, { origin, dir?, target?, color?, radius?, userId? })
			kind = powerup id on launch/fire, "IMPACT" on a blast.
			userId is on EVERY fire kind now, not just SHIELD: TurretController
			animates the turret of the car that actually fired, and FxController
			bubbles the right car in a scrum, rather than either guessing by
			proximity to origin.

	ATTRIBUTES WRITTEN (sole owner)
		Player: PowerupSlot, PowerupAmmo
		Car:    AimDir — the flat direction of the last accepted shot, so remote clients
		        can aim that car's turret. Cosmetic; nothing reads it for authority.
		(Shielded / Frozen / car Hp belong to CombatService — never written here.)

	RUNTIME INSTANCES OWNED
		Workspace.Projectiles — every rocket, freeze ball and mine part lives here.
		All are Anchored, CanCollide=false, CanQuery=false: they can never block,
		touch, or fool the ground probe of a car, and they are never in the Cars
		collision group. Every one carries the attribute PowerupId = <powerup id>
		(pinned in Net), so FxController decorates it by identity rather than by
		name-sniffing or proximity guessing.

	INIT ORDER
		Main inits this after PickupService and before CombatService. Every sibling
		service (CombatService, SpawnService, ArenaService) is resolved LAZILY at
		call time, so nothing here depends on a sibling existing at init.

	ONE Heartbeat loop steps every projectile and mine — never a coroutine per shot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")

local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))

local ATTR = Config.ATTR

-- ==========================================================================
-- Tunables. Firing discipline is Config.WEAPONS and every weapon NUMBER is
-- Config.POWERUPS; only folder names and cosmetic offsets are local to this service.
-- ==========================================================================
local PROJECTILE_FOLDER = "Projectiles" -- owned by this service
local PICKUP_FOLDER = "Pickups" -- owned by PickupService, excluded from casts
local CAR_FOLDER = "Cars" -- owned by SpawnService

-- Identity every projectile/mine carries for the client; pinned in Net's WeaponFx contract.
local PROJECTILE_ID_ATTR = "PowerupId"

-- Shared cap across rockets/freeze balls/mines, the cooldown tolerance and its
-- hard floor, the forward aim cone, and the blast edge damage fraction.
local CFG = Config.WEAPONS

local AIM_MIN_MAGNITUDE = 1e-3 -- shorter than this is not a direction at all
local AIM_MAX_MAGNITUDE = 1e4 -- longer than this is a malformed packet
-- FALLBACK muzzle only, for an untrusted/absent client origin. A real shot leaves the
-- turret barrel the client supplies; see sanitizeOrigin.
local MUZZLE_HEIGHT = 0.6 -- studs above hull center, so shots clear the deck
local MUZZLE_CLEARANCE = 1.5 -- extra studs so a projectile never spawns inside its own car
local GROUND_PROBE_UP = 12 -- mine placement: start the down-cast this far above
local GROUND_PROBE_DOWN = 48
local MINE_HEIGHT = 0.8
local MINE_DISC_SCALE = 1.0 -- disc diameter = triggerRadius, i.e. it reads as half the real trigger

-- ==========================================================================
-- State
-- ==========================================================================
local WeaponService = {}

local ctx = nil
local rng = Random.new()

local live = {} -- flat array of active projectiles + mines, swap-removed
local lastFireAt = {} -- [player] = os.clock() of the last ACCEPTED fire request
--[[ Railgun wind-ups in flight: [player] = { car, hull, def, localAim, localOrigin,
	firesAt }. The trigger and the bullet are separated in time for exactly one weapon in
	this game, and this table is that separation. ]]
local charging = {}
local connections = {} -- init-time connections, so a re-init cannot double up
local warnedMissing = {} -- one warn per missing sibling function, not per frame
local folder = nil -- Workspace.Projectiles

-- ==========================================================================
-- Workspace.Projectiles (ours alone)
-- ==========================================================================
local function ensureFolder(): Instance
	if folder and folder.Parent == workspace then
		return folder
	end
	local existing = workspace:FindFirstChild(PROJECTILE_FOLDER)
	if existing and not existing:IsA("Folder") then
		warn("WeaponService: replacing non-Folder Workspace." .. PROJECTILE_FOLDER)
		existing:Destroy()
		existing = nil
	end
	if not existing then
		existing = Instance.new("Folder")
		existing.Name = PROJECTILE_FOLDER
		existing.Parent = workspace
	end
	folder = existing
	return folder
end

-- ==========================================================================
-- Lazy sibling access. Services fill ctx.svc as Main walks its ORDER, so a
-- sibling is only ever resolved at CALL time, never captured at init.
-- ==========================================================================
local function svc(name: string)
	return ctx and ctx.svc and ctx.svc[name] or nil
end

local function svcCall(name: string, fnName: string, ...)
	local service = svc(name)
	local fn = service and service[fnName]
	if type(fn) ~= "function" then
		local key = name .. "." .. fnName
		if not warnedMissing[key] then
			warnedMissing[key] = true
			warn("WeaponService: " .. key .. " unavailable — weapon effect skipped")
		end
		return nil
	end
	return fn(...)
end

--[[ Arena containment. Flattened to the arena's own floor plane so this never
	depends on how ArenaService treats height. Fails OPEN: with no arena
	authority yet we must not delete projectiles for the wrong reason.

	isInBounds, NOT isInside: the two are the same test today, but they are kept apart
	on purpose — isInside means "could a player be here" and would go back to excluding
	ground if a map ever reintroduces some. A projectile only cares whether there is
	world here, so it must stay on isInBounds. ]]
local function insideArena(position: Vector3): boolean
	local arena = svc("ArenaService")
	if not arena or type(arena.isInBounds) ~= "function" then
		return true
	end
	local flat = Vector3.new(position.X, Config.ARENA.ORIGIN.Y, position.Z)
	return arena.isInBounds(flat) ~= false
end

-- ==========================================================================
-- Validation / aim
-- ==========================================================================
local function isPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function isFiniteNumber(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

--[[ Turns the client's aim hint into a server-approved unit direction.

	NaN / zero / absurd vectors are REPLACED by the car's own forward (a bad packet
	costs you accuracy, never a crash). Yaw is clamped into CFG.AIM_MAX_YAW_DEG on the
	driving plane exactly as before, so nobody shoots sideways or backwards out of a
	forward-facing weapon.

	The PITCH is now KEPT (clamped to CFG.AIM_MAX_PITCH_DEG). It has to be: shots leave
	the turret barrel, which sits about 8 studs above hull centre, and a flat shot from
	up there passes clean over every other car's roof. The client aims barrel -> target
	point, and that downward angle is the whole reason the shot connects. ]]
local function sanitizeAim(aimDir: any, hull: BasePart): Vector3
	local forward = MathUtil.flatUnit(hull.CFrame.LookVector)
	if forward == Vector3.zero then
		forward = Vector3.new(0, 0, -1) -- hull pointing straight up: pick something sane
	end

	if typeof(aimDir) ~= "Vector3" then
		return forward
	end
	if not (isFiniteNumber(aimDir.X) and isFiniteNumber(aimDir.Y) and isFiniteNumber(aimDir.Z)) then
		return forward
	end
	local magnitude = aimDir.Magnitude
	if magnitude < AIM_MIN_MAGNITUDE or magnitude > AIM_MAX_MAGNITUDE then
		return forward
	end

	local unit = aimDir / magnitude
	local flat = MathUtil.flatUnit(unit)
	if flat == Vector3.zero then
		return forward -- straight up or straight down is not an aim
	end

	local yaw = MathUtil.signedYawTo(forward, flat)
	if math.abs(yaw) > CFG.AIM_MAX_YAW_DEG then
		local clamped = math.clamp(yaw, -CFG.AIM_MAX_YAW_DEG, CFG.AIM_MAX_YAW_DEG)
		flat = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(clamped)) * forward
	end

	local limit = math.rad(CFG.AIM_MAX_PITCH_DEG)
	local pitch = math.clamp(math.asin(math.clamp(unit.Y, -1, 1)), -limit, limit)
	local rebuilt = flat * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
	return rebuilt.Magnitude > AIM_MIN_MAGNITUDE and rebuilt.Unit or flat
end

--[[ The muzzle the client CLAIMS it fired from.

	It has to come from the client: the turret model is drawn locally, so only the
	firing machine knows where its barrel is this frame. That makes it a claim, and this
	is the clamp — finite, and within CFG.MAX_MUZZLE_OFFSET of that player's OWN hull.
	The worst a forged packet can therefore do is fire from somewhere on its own car,
	which it could always do anyway; it cannot shoot from across the arena or from
	inside somebody else.

	Returns the point and whether it was trusted. An untrusted origin falls back to the
	old hull-centre muzzle, and the projectile handler still nudges that one forward so
	a shell does not spawn inside its own bodywork. ]]
local function sanitizeOrigin(originHint: any, hull: BasePart): (Vector3, boolean)
	local fallback = hull.Position + Vector3.new(0, MUZZLE_HEIGHT, 0)
	if typeof(originHint) ~= "Vector3" then
		return fallback, false
	end
	if not (isFiniteNumber(originHint.X) and isFiniteNumber(originHint.Y) and isFiniteNumber(originHint.Z)) then
		return fallback, false
	end
	if (originHint - hull.Position).Magnitude > CFG.MAX_MUZZLE_OFFSET then
		return fallback, false
	end
	return originHint, true
end

local function applySpread(direction: Vector3, spreadDegrees: number): Vector3
	if spreadDegrees <= 0 then
		return direction
	end
	local yaw = math.rad(rng:NextNumber(-spreadDegrees, spreadDegrees))
	local pitch = math.rad(rng:NextNumber(-spreadDegrees, spreadDegrees))
	return (CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles(pitch, yaw, 0)).LookVector
end

-- ==========================================================================
-- Cars
-- ==========================================================================
local function carModelFrom(instance: Instance?): Model?
	local node = instance
	while node and node ~= workspace do
		if node:IsA("Model") then
			local parent = node.Parent
			if node:HasTag(ChassisSpec.CAR_TAG) or (parent and parent.Name == CAR_FOLDER) then
				return node
			end
		end
		node = node.Parent
	end
	return nil
end

-- The player's car and hull, or nil,nil if they are not driving right now.
local function liveCarOf(player: Instance)
	local car = svcCall("SpawnService", "getCar", player)
	if typeof(car) ~= "Instance" or not car:IsA("Model") or car.Parent == nil then
		return nil, nil
	end
	local hull = ChassisSpec.getHull(car)
	if not hull or hull.Parent == nil then
		return nil, nil
	end
	return car, hull
end

-- Snapshot of everyone currently driving. Built at most once per Heartbeat.
local function collectLiveCars()
	local out = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local car, hull = liveCarOf(player)
		if car and hull then
			table.insert(out, { player = player, car = car, hull = hull, pos = hull.Position })
		end
	end
	return out
end

-- ==========================================================================
-- Raycasting
-- ==========================================================================
local function rayParams(ownerCar: Model?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	-- Only REAL collidable geometry stops a shot. ArenaService's pad chevrons, block
	-- caps, pit shaft walls and pit sensors are CanCollide=false decoration, and a
	-- raycast would otherwise stop dead on them. Car Hulls are collidable, and car
	-- cosmetics are CanQuery=false, so only Hulls are ever hittable.
	params.RespectCanCollide = true

	local ignore = { ensureFolder() }
	if ownerCar then
		table.insert(ignore, ownerCar)
	end
	local pickups = workspace:FindFirstChild(PICKUP_FOLDER)
	if pickups then
		table.insert(ignore, pickups)
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- Crowns / coins / crates never stop a shot, whichever folder they live in.
local function castIgnoringPickups(origin: Vector3, delta: Vector3, params: RaycastParams): RaycastResult?
	local result = workspace:Raycast(origin, delta, params)
	if result and result.Instance and result.Instance:HasTag(ChassisSpec.PICKUP_TAG) then
		return nil
	end
	return result
end

-- ==========================================================================
-- Parts. Anchored + manually stepped: deterministic, cheap, no network ownership.
-- ==========================================================================
--[[ The single path that parents anything into Workspace.Projectiles, so the
	identity attribute can never be forgotten on a new weapon kind. ]]
local function styleProjectilePart(part: BasePart, def)
	part.Color = def.color or Config.UI.PAPER
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false -- must never block or push a car
	part.CanTouch = false
	part.CanQuery = false -- invisible to the chassis ground probe and to our own casts
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:AddTag(ChassisSpec.PROJECTILE_TAG)
	part:SetAttribute(PROJECTILE_ID_ATTR, def.id)
	part.Parent = ensureFolder() -- identity is set BEFORE parenting: never a blank frame
end

local function buildProjectilePart(def, position: Vector3, direction: Vector3): BasePart
	local size = def.size or Vector3.one
	local part = Instance.new("Part")
	part.Name = def.id
	part.Size = size
	part.Shape = (size.X == size.Y and size.Y == size.Z) and Enum.PartType.Ball or Enum.PartType.Block
	part.CFrame = CFrame.lookAt(position, position + direction)
	styleProjectilePart(part, def)
	return part
end

--[[ A PHYSICAL cannonball. Every line here contradicts styleProjectilePart on purpose,
	because this is the ONE projectile the engine simulates instead of one we step:
	    Anchored  = false  it has to fall, bounce and roll
	    CanCollide = true  the rolling IS the weapon
	    CanQuery  = false  a car's ground probe must never see it, or a ball rolling
	                       under somebody would make them hover on top of it
	Density is deliberately low so the collision itself barely shoves a car: the push
	that matters is the one applyBlast hands out, and physics adding a second, unbalanced
	one on top is exactly the sort of thing that makes a weapon feel random. Network
	ownership is pinned to the SERVER so every client sees the same roll — left alone,
	Roblox hands ownership of a loose part to whoever happens to be nearest. ]]
local function buildBallPart(def, position: Vector3): BasePart
	local size = def.ballSize or 3
	local part = Instance.new("Part")
	part.Name = def.id
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(size, size, size)
	part.CFrame = CFrame.new(position)
	part.Color = def.color or Config.UI.PAPER
	part.Material = Enum.Material.Metal
	part.Anchored = false
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CustomPhysicalProperties = PhysicalProperties.new(
		def.ballDensity or 0.7, def.ballFriction or 0.5, def.ballElasticity or 0.3, 1, 1)
	part:AddTag(ChassisSpec.PROJECTILE_TAG)
	part:SetAttribute(PROJECTILE_ID_ATTR, def.id)
	part.Parent = ensureFolder()
	pcall(function()
		part:SetNetworkOwner(nil)
	end)
	return part
end

--[[ A random direction inside a CONE of `degrees` around `direction`. Unlike
	applySpread's independent yaw/pitch jitter, the magnitude here is uniform in
	0..degrees and the roll around the axis is uniform in 0..360 — which is what
	"0 to 10 degrees of variation" actually describes. ]]
local function coneSpread(direction: Vector3, degrees: number): Vector3
	if degrees <= 0 then
		return direction
	end
	local angle = math.rad(rng:NextNumber(0, degrees))
	local roll = rng:NextNumber(0, math.pi * 2)
	local basis = CFrame.lookAt(Vector3.zero, direction)
	return (basis * CFrame.Angles(0, 0, roll) * CFrame.Angles(angle, 0, 0)).LookVector
end

local function buildMinePart(def, position: Vector3): BasePart
	local diameter = math.max((def.triggerRadius or MINE_HEIGHT) * MINE_DISC_SCALE, MINE_HEIGHT)
	local part = Instance.new("Part")
	part.Name = def.id
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(MINE_HEIGHT, diameter, diameter) -- cylinder axis is X...
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90)) -- ...so stand it up flat
	styleProjectilePart(part, def)
	return part
end

-- ==========================================================================
-- Fx broadcast
-- ==========================================================================
local function fx(kind: string, payload: { [string]: any })
	local remote = ctx and ctx.net and ctx.net.WeaponFx
	if not remote then
		return
	end
	remote:FireAllClients(kind, payload)
end

-- ==========================================================================
-- Damage
-- ==========================================================================
local function pushDirection(from: Vector3, to: Vector3): Vector3
	local flat = MathUtil.flatUnit(to - from)
	if flat == Vector3.zero then
		return Vector3.yAxis -- dead center: pop them straight up
	end
	return flat
end

--[[ The mode's friendly-fire rule, resolved lazily and failing OPEN: a ModeService
	that is missing or throwing must never be able to switch every weapon in the game
	off. Modes without teams answer true for every pair. ]]
local function canHit(attacker: Instance?, victim: Instance?): boolean
	local mode = svc("ModeService")
	if type(mode) ~= "table" or type(mode.canDamage) ~= "function" then
		return true
	end
	local ok, allowed = pcall(mode.canDamage, attacker, victim)
	if not ok then
		return true
	end
	return allowed ~= false
end

--[[ Returns false when the victim's car is GONE — that hit killed it — which is how
	every call site below knows to skip the knockback it would otherwise pair with.

	A TEAM-MATE answers false too, and that is the whole reason the check lives here
	rather than only inside CombatService.applyDamage: returning false skips the paired
	knock() and freeze as well, so in Team Battle a rocket landing on your own side does
	nothing whatsoever instead of shoving them off a ramp for free. CombatService vetoes
	the damage independently — this is the half that also stops everything around it. ]]
local function hurt(victim: Instance, victimCar: Model, amount: number, attacker: Instance?, causeId: string): boolean
	if not canHit(attacker, victim) then
		return false
	end
	svcCall("CombatService", "applyDamage", victim, amount, attacker, causeId)
	return victimCar.Parent ~= nil -- false once that hit killed and despawned the car
end

local function knock(victim: Instance, direction: Vector3, speed: number)
	if speed <= 0 then
		return
	end
	svcCall("CombatService", "applyKnockback", victim, direction, speed)
end

--[[ Explosion. Full damage at the center tapering to CFG.BLAST_EDGE_FRACTION at
	exactly def.blastRadius, so a near-miss reads as a near-miss. The owner is
	always spared — a kids' game should not punish you for your own rocket. ]]
local function applyBlast(center: Vector3, def, owner: Instance?)
	local radius = def.blastRadius or 0
	if radius <= 0 then
		return
	end
	local attacker = (isPlayer(owner) and owner.Parent ~= nil) and owner or nil

	for _, entry in ipairs(collectLiveCars()) do
		if entry.player ~= owner and entry.car.Parent ~= nil then
			local offset = entry.pos - center
			local distance = offset.Magnitude
			if distance <= radius then
				local falloff = MathUtil.map(distance, 0, radius, 1, CFG.BLAST_EDGE_FRACTION)
				if hurt(entry.player, entry.car, (def.damage or 0) * falloff, attacker, def.id) then
					knock(entry.player, pushDirection(center, entry.pos), (def.knockback or 0) * falloff)
					if def.freezeSeconds then
						svcCall("CombatService", "applyFreeze", entry.player, def.freezeSeconds)
					end
				end
			end
		end
	end
end

local function detonate(entry, center: Vector3)
	applyBlast(center, entry.def, entry.owner)
	fx("IMPACT", { origin = center, color = entry.def.color, radius = entry.def.blastRadius })
end

-- ==========================================================================
-- Weapon behaviours, dispatched by def.kind (Config.POWERUPS.<id>.kind).
-- A handler returns false ONLY when the shot could not happen at all, which
-- leaves the ammo in the slot.
-- ==========================================================================
local HANDLERS = {}

HANDLERS.hitscan = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	local direction = applySpread(aim, def.spread or 0)
	local range = def.range or 0

	local result = castIgnoringPickups(origin, direction * range, rayParams(car))
	local target = origin + direction * range
	--[[ Whether the bolt landed on a CAR rides along in the fx payload: the client
		draws a full plasma splash on a car and a scuff on the ground, which is the one
		question a shooter is actually asking at eleven shots a second. Purely
		cosmetic — the damage was decided right here — so no client may act on it. ]]
	local hitCar = false
	if result then
		target = result.Position
		local victimCar = carModelFrom(result.Instance)
		hitCar = victimCar ~= nil
		local victim = victimCar and svcCall("SpawnService", "playerFromCar", victimCar) or nil
		if isPlayer(victim) and victim ~= player and victimCar.Parent ~= nil then
			if hurt(victim, victimCar, def.damage or 0, player, def.id) then
				knock(victim, pushDirection(origin, target), def.knockback or 0)
			end
		end
	end

	fx(def.id, { origin = origin, dir = direction, target = target, color = def.color, userId = player.UserId, hitCar = hitCar })
	return true
end

HANDLERS.projectile = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	if #live >= CFG.MAX_LIVE_PROJECTILES then
		return false
	end

	--[[ A trusted origin IS the barrel tip, already clear of the bodywork. The fallback
		origin is the hull CENTRE and still has to be pushed out in front of the car, or
		a shell spawns inside its own bonnet. ]]
	if not trusted then
		local reach = math.max(hull.Size.X, hull.Size.Z) * 0.5 + MUZZLE_CLEARANCE
		origin = origin + aim * reach
	end

	table.insert(live, {
		kind = "projectile",
		def = def,
		owner = player,
		part = buildProjectilePart(def, origin, aim),
		pos = origin,
		dir = aim,
		speed = def.speed or 0,
		expiresAt = os.clock() + (def.life or 0),
		params = rayParams(car), -- built once per shot, never per frame
	})

	fx(def.id, { origin = origin, dir = aim, color = def.color, radius = def.blastRadius, userId = player.UserId })
	return true
end

--[=[ LOB — the mortar, and the only shot in the game that is aimed at a PLACE rather
	than along a line. The server casts your aim to find the spot you are pointing at,
	then solves the launch velocity that puts the shell on that spot in exactly
	def.arcTime seconds. Two things fall out of that: the shell ARCS, so it clears
	walls and plateaus nothing else can reach, and the landing point is what you aimed
	at rather than a function of range — the only thing to learn is how far ahead of a
	moving car to place it. The client draws a ring on the landing spot for the whole
	flight (see FxController), because a weapon that lands from above has to be
	dodgeable to be fair. ]=]
HANDLERS.lob = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	if #live >= CFG.MAX_LIVE_PROJECTILES then
		return false
	end
	if not trusted then
		local reach = math.max(hull.Size.X, hull.Size.Z) * 0.5 + MUZZLE_CLEARANCE
		origin = origin + aim * reach
	end

	-- Where you are pointing: the first thing the aim ray meets, or the end of its range.
	local range = def.range or 200
	local hit = castIgnoringPickups(origin, aim * range, rayParams(car))
	local target = hit and hit.Position or (origin + aim * range)

	-- Never closer than minRange, or a panicked point-blank shot lands on your own roof.
	local flat = target - origin
	flat = Vector3.new(flat.X, 0, flat.Z)
	local minRange = def.minRange or 0
	if flat.Magnitude < minRange then
		local push = MathUtil.flatUnit(aim)
		if push == Vector3.zero then
			push = MathUtil.flatUnit(-hull.CFrame.LookVector)
		end
		target = origin + push * minRange
	end

	--[=[ The arc, exactly: with the flight time fixed, v = d/t + (g*t)/2 upward puts the
		shell through the target at t, and gravity alone decides how high it climbs. ]=]
	local t = math.max(def.arcTime or 1.2, 0.2)
	local gravity = def.gravity or 200
	local velocity = (target - origin) / t + Vector3.new(0, 0.5 * gravity * t, 0)
	local launchDir = velocity.Magnitude > 1e-3 and velocity.Unit or aim

	table.insert(live, {
		kind = "projectile",
		def = def,
		owner = player,
		part = buildProjectilePart(def, origin, launchDir),
		pos = origin,
		dir = launchDir,
		speed = velocity.Magnitude,
		vel = velocity, -- the gravity path integrates THIS; see stepProjectile
		gravity = gravity,
		expiresAt = os.clock() + (def.life or 0),
		params = rayParams(car),
	})

	fx(def.id, {
		origin = origin,
		dir = launchDir,
		target = target, -- the client rings this spot for the whole flight
		color = def.color,
		radius = def.blastRadius,
		flight = t,
		userId = player.UserId,
	})
	return true
end

--[[ SCATTER — the cannon. Fires def.pellets physical balls at once, each thrown 0..spreadDeg
	off the aim in a random direction and given an upward `lift` so it arcs out of the
	barrel rather than skimming. After that the engine owns them: they land, bounce and
	roll, and the FIRST car any one of them touches sets it off.

	Contact is a Touched connection rather than the raycast every other projectile uses,
	because a rolling ball has no travel line to cast along. `entry.hit` latches so one
	ball can never detonate twice while the step loop is getting round to destroying it,
	and the owner is skipped so your own shot cannot bounce back and punish you. ]]
HANDLERS.scatter = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	local pellets = math.max(def.pellets or 1, 1)
	if #live + pellets > CFG.MAX_LIVE_PROJECTILES then
		return false
	end

	local start = origin
	if not trusted then
		local reach = math.max(hull.Size.X, hull.Size.Z) * 0.5 + MUZZLE_CLEARANCE
		start = origin + aim * reach
	end

	for _ = 1, pellets do
		local direction = coneSpread(aim, def.spreadDeg or 0)
		local part = buildBallPart(def, start)
		part.AssemblyLinearVelocity = direction * (def.speed or 0) + Vector3.new(0, def.lift or 0, 0)
		-- A little tumble, so three identical spheres do not read as one object.
		part.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))

		local entry = {
			kind = "ball",
			def = def,
			owner = player,
			part = part,
			expiresAt = os.clock() + (def.life or 0),
			hit = false,
		}
		entry.touch = part.Touched:Connect(function(other: BasePart)
			if entry.hit then
				return
			end
			local victimCar = carModelFrom(other)
			if not victimCar or victimCar == car then
				return
			end
			local victim = svcCall("SpawnService", "playerFromCar", victimCar)
			if not isPlayer(victim) or victim == player then
				return
			end
			entry.hit = true
			detonate(entry, part.Position)
			entry.expiresAt = 0 -- the step loop reaps it on the next frame
		end)
		table.insert(live, entry)
	end

	fx(def.id, { origin = start, dir = aim, color = def.color, radius = def.blastRadius, userId = player.UserId })
	return true
end

-- Ignores `origin`: a mine is dropped BEHIND the car, never out of a barrel.
HANDLERS.place = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	if #live >= CFG.MAX_LIVE_PROJECTILES then
		return false
	end

	local back = MathUtil.flatUnit(-hull.CFrame.LookVector)
	if back == Vector3.zero then
		back = -aim
	end
	local drop = hull.Position + back * (def.dropBehind or 0)

	-- Sit it on the ground, ignoring the dropper's own car so it never lands on the roof.
	local down = Vector3.new(0, -(GROUND_PROBE_UP + GROUND_PROBE_DOWN), 0)
	local ground = castIgnoringPickups(drop + Vector3.new(0, GROUND_PROBE_UP, 0), down, rayParams(car))
	local y = ground and (ground.Position.Y + MINE_HEIGHT * 0.5) or drop.Y
	local position = Vector3.new(drop.X, y, drop.Z)

	local now = os.clock()
	table.insert(live, {
		kind = "mine",
		def = def,
		owner = player,
		part = buildMinePart(def, position),
		pos = position,
		armAt = now + (def.armTime or 0), -- so it cannot blow up on your own bumper
		expiresAt = now + (def.life or 0),
	})

	fx(def.id, { origin = position, color = def.color, radius = def.triggerRadius, userId = player.UserId })
	return true
end

-- Ignores the barrel `origin` on purpose: an aoe discharge radiates from the CAR.
HANDLERS.aoe = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, _origin: Vector3, _trusted: boolean): boolean
	local origin = hull.Position
	local radius = def.radius or 0

	local candidates = {}
	for _, entry in ipairs(collectLiveCars()) do
		if entry.player ~= player then
			local distance = (entry.pos - origin).Magnitude
			if distance <= radius then
				table.insert(candidates, { entry = entry, distance = distance })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)

	local hits = math.min(#candidates, def.maxTargets or 0)
	for index = 1, hits do
		local entry = candidates[index].entry
		if entry.car.Parent ~= nil then
			-- One fx per target so the client can draw the chain.
			fx(def.id, { origin = origin, target = entry.pos, color = def.color, radius = radius, userId = player.UserId })
			if hurt(entry.player, entry.car, def.damage or 0, player, def.id) then
				knock(entry.player, pushDirection(origin, entry.pos), def.knockback or 0)
			end
		end
	end

	if hits == 0 then
		fx(def.id, { origin = origin, color = def.color, radius = radius, userId = player.UserId }) -- empty discharge still reads
	end
	return true
end

--[[ FLAMETHROWER. A short cone re-evaluated on EVERY tick rather than a projectile:
	the jet has no travel time, so a car that drives out of it stops burning on the
	next tick with nothing left in flight to chase it. Distance AND angle are measured
	on the driving plane (MathUtil.flatUnit), the same plane aim is clamped to, so a
	car on a plateau above you burns exactly like one beside you. ]]
HANDLERS.cone = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	local range = def.range or 0
	local minDot = math.cos(math.rad(def.coneDeg or 30))
	local maxTargets = def.maxTargets or 3
	-- The jet is measured on the driving plane, so the cone test uses the FLATTENED aim
	-- even though the shot now carries a pitch.
	local flatAim = MathUtil.flatUnit(aim)
	if flatAim == Vector3.zero then
		flatAim = MathUtil.flatUnit(hull.CFrame.LookVector)
	end

	local hits = 0
	for _, entry in ipairs(collectLiveCars()) do
		if entry.player ~= player and entry.car.Parent ~= nil then
			local offset = entry.pos - origin
			if offset.Magnitude <= range then
				local toward = MathUtil.flatUnit(offset)
				if toward ~= Vector3.zero and toward:Dot(flatAim) >= minDot then
					if hurt(entry.player, entry.car, def.damage or 0, player, def.id) then
						knock(entry.player, toward, def.knockback or 0)
					end
					hits += 1
					if hits >= maxTargets then
						break
					end
				end
			end
		end
	end

	-- Always broadcast: the jet has to be visible even when it is burning nothing.
	fx(def.id, { origin = origin, dir = aim, color = def.color, radius = range, userId = player.UserId })
	return true
end

-- Ignores the barrel `origin`: the bubble belongs to the CAR, not to a gun.
HANDLERS.self = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, _origin: Vector3, _trusted: boolean): boolean
	svcCall("CombatService", "applyShield", player, def.duration or 0)
	-- userId, not proximity: the bubble must land on THIS car even in a scrum.
	fx(def.id, {
		origin = hull.Position,
		color = def.color,
		radius = math.max(hull.Size.X, hull.Size.Z),
		userId = player.UserId,
	})
	return true
end

--[=[ CHARGED — the railgun, and the only weapon that does not fire when you pull the
	trigger. The press starts a wind-up and RETURNS TRUE, which is what spends the round:
	a charge that never gets to fire (you were killed, the round ended) still costs it,
	the same deal a rocket already in flight makes.

	THE SHOT IS RE-AIMED AT FIRE TIME, and that is the whole feel of the weapon.
	Config.WEAPONS.AIM_MAX_YAW_DEG is 0, so "aim" in this game IS the car's heading —
	storing the press-time direction in the HULL's object space and rebuilding it a second
	later means you STEER a charged shot onto its target. Store a world direction instead
	and the railgun fires wherever you happened to be pointing when you pressed, which
	reads as broken every single time the car turns. The origin rides the same transform,
	so a beam that started at a barrel 190 studs/s ago still leaves the barrel. ]=]
HANDLERS.charged = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, _trusted: boolean): boolean
	if charging[player] then
		return false -- already winding one up: the player keeps the ammo
	end

	local chargeTime = math.max(def.chargeTime or 0, 0)
	charging[player] = {
		player = player,
		car = car,
		hull = hull,
		def = def,
		localAim = hull.CFrame:VectorToObjectSpace(aim),
		localOrigin = hull.CFrame:PointToObjectSpace(origin),
		firesAt = os.clock() + chargeTime,
	}

	--[[ Broadcast to EVERYONE, not just the shooter. The wind-up is this weapon's only
		counterplay, so the tell has to be public the moment it starts. ]]
	fx("RAILCHARGE", {
		origin = origin,
		dir = aim,
		color = def.color,
		userId = player.UserId,
		duration = chargeTime,
	})
	return true
end

-- One cast, one car, one very large number.
local function fireCharged(entry)
	local player, car, hull, def = entry.player, entry.car, entry.hull, entry.def
	local cf = hull.CFrame
	local aim = cf:VectorToWorldSpace(entry.localAim)
	if aim.Magnitude < 1e-3 then
		return
	end
	aim = aim.Unit
	local origin = cf:PointToWorldSpace(entry.localOrigin)

	local range = def.range or 0
	local result = castIgnoringPickups(origin, aim * range, rayParams(car))
	local target = origin + aim * range
	local hitCar = false
	if result then
		target = result.Position
		local victimCar = carModelFrom(result.Instance)
		hitCar = victimCar ~= nil
		local victim = victimCar and svcCall("SpawnService", "playerFromCar", victimCar) or nil
		if isPlayer(victim) and victim ~= player and victimCar.Parent ~= nil then
			if hurt(victim, victimCar, def.damage or 0, player, def.id) then
				knock(victim, pushDirection(origin, target), def.knockback or 0)
			end
		end
	end

	--[[ Re-published here as well as at the press: a full second of steering has passed
		since onFireWeapon stamped it, and every other client points this turret off it. ]]
	local flatAim = MathUtil.flatUnit(aim)
	if flatAim ~= Vector3.zero then
		car:SetAttribute(ChassisSpec.ATTR.AIM_DIR, flatAim)
	end

	fx(def.id, {
		origin = origin,
		dir = aim,
		target = target,
		color = def.color,
		userId = player.UserId,
		hitCar = hitCar,
	})
end

-- Resolves every wind-up that has come due. Stepped from the same Heartbeat as the
-- projectiles, but AHEAD of their early-out — a charge is not a projectile.
local function stepCharges()
	if next(charging) == nil then
		return
	end
	local now = os.clock()
	local inMatch = MatchState.isMatch()
	for player, entry in pairs(charging) do
		--[[ A wind-up dies with its car: no ghost railgun firing out of a wreck, and no
			shot arriving after the round has ended. The round is already spent, which is
			the price of being killed mid-charge. ]]
		if not inMatch or player.Parent == nil or entry.car.Parent == nil or entry.hull.Parent == nil then
			charging[player] = nil
		elseif now >= entry.firesAt then
			charging[player] = nil
			local ok, err = pcall(fireCharged, entry)
			if not ok then
				warn("WeaponService: charged shot errored -> " .. tostring(err))
			end
		end
	end
end

-- ==========================================================================
-- FireWeapon — the most abusable remote in the game. Everything is re-checked.
-- ==========================================================================
local function consumeAmmo(player: Instance, powerupId: string, ammoBefore: number)
	if player:GetAttribute(ATTR.POWERUP) ~= powerupId then
		return -- a crate swapped the slot underneath this shot
	end
	local left = math.max(0, ammoBefore - 1)
	if left <= 0 then
		WeaponService.clearPowerup(player)
	else
		player:SetAttribute(ATTR.POWERUP_AMMO, left)
	end
end

local function onFireWeapon(player: Instance, aimDir: any, originHint: any)
	if not isPlayer(player) then
		return
	end
	if not MatchState.isMatch() then
		return
	end

	local powerupId = player:GetAttribute(ATTR.POWERUP)
	if type(powerupId) ~= "string" or powerupId == "" then
		return
	end
	local def = PowerupDefs.get(powerupId)
	if not def then
		warn("WeaponService: slot held unknown powerup '" .. tostring(powerupId) .. "', scrubbing")
		WeaponService.clearPowerup(player)
		return
	end

	local ammo = player:GetAttribute(ATTR.POWERUP_AMMO)
	if type(ammo) ~= "number" or ammo <= 0 then
		WeaponService.clearPowerup(player)
		return
	end

	--[[ Server-side rate limit: the powerup's OWN cooldown (the machine gun is
		0.09s, far under Net.REQUEST_GAP), with a hard floor underneath so no
		scripted client can outrun the real fire rate. Stamped before the
		remaining checks so a spammer is throttled whatever their state. ]]
	local now = os.clock()
	local gap = math.max(PowerupDefs.cooldownFor(powerupId) * CFG.COOLDOWN_TOLERANCE, CFG.HARD_MIN_FIRE_GAP)
	local previous = lastFireAt[player]
	if previous and now - previous < gap then
		return
	end
	lastFireAt[player] = now

	local car, hull = liveCarOf(player)
	if not car or not hull then
		return
	end

	local handler = HANDLERS[def.kind]
	if not handler then
		warn("WeaponService: no handler for kind '" .. tostring(def.kind) .. "' (" .. powerupId .. ")")
		return
	end

	--[[ Both are HINTS and both are clamped. The client owns the GEOMETRY of a shot —
		it is the only side that knows where its turret is pointing — and the server owns
		everything that follows from it. ]]
	local origin, trusted = sanitizeOrigin(originHint, hull)
	local aim = sanitizeAim(aimDir, hull)
	if handler(player, car, hull, def, aim, origin, trusted) == false then
		return -- weapon declined (projectile cap): the player keeps the ammo
	end

	--[[ Publish the flat aim so every OTHER client can point this car's turret at what
		it is actually shooting. Written per ACCEPTED shot rather than streamed on its
		own channel: the hold weapons fire 11-12x a second, which is precisely when
		anyone is looking at a turret, and between shots it holds the last angle — a gun
		still trained where you last fired, instead of snapping back to centre. ]]
	local flatAim = MathUtil.flatUnit(aim)
	if flatAim ~= Vector3.zero then
		car:SetAttribute(ChassisSpec.ATTR.AIM_DIR, flatAim)
	end

	consumeAmmo(player, powerupId, ammo)
end

-- ==========================================================================
-- One Heartbeat steps everything. Swap-remove keeps the list flat and cheap.
-- ==========================================================================
local function destroyEntry(index: number)
	local entry = live[index]
	if not entry then
		return
	end
	if entry.touch then
		entry.touch:Disconnect()
	end
	if entry.part then
		entry.part:Destroy()
	end
	local last = #live
	live[index] = live[last]
	live[last] = nil
end

--[[ Guidance for def.homing shells. Locks the NEAREST live car already inside
	seekCone of the shell's own heading, then bends toward it by at most
	turnRate * dt — so a missile can correct a lead, but can never turn around and
	chase someone it has already flown past, and can never home onto its owner.
	It re-locks every step on purpose: no stored target to go stale when a car dies. ]]
local function homingSteer(entry, dt: number, cars)
	local def = entry.def
	local range = def.seekRange or 0
	if range <= 0 or not cars then
		return
	end

	local minDot = math.cos(math.rad(def.seekCone or 45))
	local best, bestDistance = nil, math.huge
	for _, carEntry in ipairs(cars) do
		if carEntry.player ~= entry.owner and carEntry.car.Parent ~= nil then
			local offset = carEntry.pos - entry.pos
			local distance = offset.Magnitude
			if distance <= range and distance > 1e-3 and distance < bestDistance then
				local toward = offset / distance
				if toward:Dot(entry.dir) >= minDot then
					best, bestDistance = toward, distance
				end
			end
		end
	end
	if not best then
		return
	end

	local angle = math.acos(math.clamp(entry.dir:Dot(best), -1, 1))
	if angle <= 1e-4 then
		return
	end
	local blend = math.min((math.rad(def.turnRate or 90) * dt) / angle, 1)
	local steered = entry.dir:Lerp(best, blend)
	if steered.Magnitude > 1e-3 then
		entry.dir = steered.Unit
	end
end

local function stepProjectile(entry, dt: number, now: number, cars): boolean
	if entry.def.homing then
		homingSteer(entry, dt, cars)
	end
	local from = entry.pos
	local to
	if entry.gravity then
		--[=[ A lobbed shell integrates a real velocity, which is what lets it arc over
			something. `dir` is kept in step with it because the part's CFrame, the blast
			push and every fx downstream read dir, not vel. ]=]
		entry.vel -= Vector3.new(0, entry.gravity * dt, 0)
		to = from + entry.vel * dt
		if entry.vel.Magnitude > 1e-3 then
			entry.dir = entry.vel.Unit
		end
	else
		to = from + entry.dir * entry.speed * dt
	end

	local result = castIgnoringPickups(from, to - from, entry.params)
	if result then
		detonate(entry, result.Position)
		return true
	end

	entry.pos = to
	entry.part.CFrame = CFrame.lookAt(to, to + entry.dir)

	if to.Y < Config.CHASSIS.FALL_KILL_Y or not insideArena(to) then
		return true -- out of the play area: no blast, just gone
	end
	if now >= entry.expiresAt then
		detonate(entry, to)
		return true
	end
	return false
end

local function stepMine(entry, now: number, cars): boolean
	if now >= entry.expiresAt then
		return true -- timed out quietly
	end
	if now < entry.armAt then
		return false
	end

	local triggerRadius = entry.def.triggerRadius or 0
	for _, carEntry in ipairs(cars) do
		if carEntry.player ~= entry.owner and (carEntry.pos - entry.pos).Magnitude <= triggerRadius then
			detonate(entry, entry.pos)
			return true
		end
	end
	return false
end

--[[ A ball needs no stepping — the engine moves it. This only reaps: the lifetime,
	a ball knocked over the wall, and one that has already detonated on contact. ]]
local function stepBall(entry, now: number): boolean
	if now >= entry.expiresAt then
		return true
	end
	local position = entry.part.Position
	return position.Y < Config.CHASSIS.FALL_KILL_Y or not insideArena(position)
end

local function step(dt: number)
	stepCharges() -- BEFORE the projectile early-out: a charge is not a projectile

	if #live == 0 then
		return
	end

	local now = os.clock()
	-- Built at most once per frame, and only if a mine or a homing shell needs it.
	local cars = nil
	local function liveCars()
		if cars == nil then
			cars = collectLiveCars()
		end
		return cars
	end

	for index = #live, 1, -1 do
		local entry = live[index]
		local dead

		if entry.part == nil or entry.part.Parent == nil then
			dead = true
		elseif entry.kind == "ball" then
			dead = stepBall(entry, now)
		elseif entry.kind == "mine" then
			dead = stepMine(entry, now, liveCars())
		else
			dead = stepProjectile(entry, dt, now, entry.def.homing and liveCars() or nil)
		end

		if dead then
			destroyEntry(index)
		end
	end
end

-- ==========================================================================
-- Public API (pinned in Main's SERVICE CONTRACT)
-- ==========================================================================
--[[ Fills the single powerup slot. A fresh crate is ALLOWED to overwrite what
	you were holding — that is the design, not a bug. ]]
function WeaponService.givePowerup(player: Instance, powerupId: string): boolean
	if not isPlayer(player) then
		return false
	end
	if not PowerupDefs.exists(powerupId) then
		warn("WeaponService.givePowerup: unknown powerup '" .. tostring(powerupId) .. "'")
		return false
	end

	player:SetAttribute(ATTR.POWERUP, powerupId)
	player:SetAttribute(ATTR.POWERUP_AMMO, PowerupDefs.ammoFor(powerupId))
	return true
end

function WeaponService.clearPowerup(player: Instance)
	if not isPlayer(player) then
		return
	end
	player:SetAttribute(ATTR.POWERUP, "")
	player:SetAttribute(ATTR.POWERUP_AMMO, 0)
end

function WeaponService.hasPowerup(player: Instance): boolean
	if not isPlayer(player) then
		return false
	end
	local powerupId = player:GetAttribute(ATTR.POWERUP)
	local ammo = player:GetAttribute(ATTR.POWERUP_AMMO)
	return type(powerupId) == "string"
		and powerupId ~= ""
		and PowerupDefs.exists(powerupId)
		and type(ammo) == "number"
		and ammo > 0
end

-- Wipes every rocket, freeze ball and mine in the world.
function WeaponService.clearProjectiles()
	for index = #live, 1, -1 do
		destroyEntry(index)
	end
end

-- Round teardown: nothing from last round may survive into the next one.
function WeaponService.clearRound()
	WeaponService.clearProjectiles()
	for _, player in ipairs(Players:GetPlayers()) do
		WeaponService.clearPowerup(player)
	end
	table.clear(lastFireAt)
	table.clear(charging)
end

-- ==========================================================================
-- init
-- ==========================================================================
function WeaponService.init(context)
	ctx = context
	ensureFolder()

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	local fireWeapon = ctx and ctx.net and ctx.net.FireWeapon
	if fireWeapon then
		table.insert(connections, fireWeapon.OnServerEvent:Connect(onFireWeapon))
	else
		warn("WeaponService: FireWeapon remote missing — powerups can never fire")
	end

	-- Slot attributes exist from the moment you join, so the HUD reads a real value.
	for _, player in ipairs(Players:GetPlayers()) do
		WeaponService.clearPowerup(player)
	end
	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		WeaponService.clearPowerup(player)
	end))

	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		lastFireAt[player] = nil
		charging[player] = nil -- no railgun may fire out of a car whose driver has left
		for index = #live, 1, -1 do
			if live[index].owner == player then
				destroyEntry(index)
			end
		end
	end))

	-- Leaving the Match phase clears the battlefield and every slot.
	table.insert(connections, MatchState.onPhaseChanged(function(phase: string)
		if phase ~= MatchState.PHASES.MATCH then
			WeaponService.clearRound()
		end
	end))

	table.insert(connections, RunService.Heartbeat:Connect(step))
end

return WeaponService
