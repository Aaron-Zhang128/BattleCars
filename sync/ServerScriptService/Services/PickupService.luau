--[[ PickupService
	Spawns and awards the three collectibles that give the arena its reason to exist:
	crowns (the score), money (persistent currency) and crates (powerups).

	DATA FLOW
		init(ctx)             builds Workspace.Pickups/{Crowns,Money,Crates} and starts ONE
		                      Heartbeat loop running both spawn cadence and idle animation.
		startRound()          MatchService, at the start of Match: seeds the field, enables spawning.
		stopRound()           MatchService, when Match ends: disables spawning, clears the field.
		clearAll()            destroys every pickup and resets counters.
		dropCrowns(pos, n)    CombatService, on a kill: scatters the victim's crowns as pickups.
		grantCrate(player)    crate collection -> PowerupDefs.roll -> WeaponService.givePowerup.

	REMOTES (send only, never listens — nothing here is client-driven)
		WeaponFx  S->C  ("IMPACT", { origin, color, radius, vfx }) pop on collection; vfx
		                names which particle pack it throws (Config.PICKUPS[kind].vfx)
		Notify    S->C  (text, "gold")                         powerup name from a crate

	ATTRIBUTES
		Writes NOTHING on the Player. Crowns go through ScoreService.addCrowns (it owns the
		Crowns attribute and the client "+1" popup), money through ProfileService.addMoney,
		the powerup slot through WeaponService.givePowerup.
		Writes PickupKind / PickupValue on each pickup Model — this service owns those.

	INIT ORDER
		Siblings (ArenaService, SpawnService, ScoreService, ProfileService, WeaponService) are
		resolved LAZILY at call time, never captured at init, so init order does not matter.
		Nothing spawns until startRound().

	OWNS AT RUNTIME
		Workspace.Pickups and every descendant. Nothing else writes there.
		Reads Workspace.Cars (SpawnService owns it) to cull idle animation.

	PERF
		Idle bob/spin is server-driven, so every moved part replicates. Two bounds keep that
		off a mobile frame budget: the animation ticks at Config.PICKUPS.ANIM_HZ rather than
		per frame, and a pickup with no car within Config.PICKUPS.ANIM_RADIUS is skipped
		entirely. Motion is derived from an absolute clock, never integrated per frame, so a
		pickup that comes back into range resumes exactly where continuous motion would have
		put it — no pop.

		Pickup parts are CanQuery = false on purpose: a chassis hover ray or a bullet must
		never hit a collectible. Collection rides on one invisible Trigger ball per pickup,
		sized from Config.PICKUPS.<KIND>.radius, so a car at top speed cannot tunnel through.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))
local CarRegistry = require(sharedFolder:WaitForChild("CarRegistry"))

local CFG = Config.PICKUPS
local ARENA = Config.ARENA
local UI = Config.UI

-- ==========================================================================
-- CONSTANTS — everything tunable that Config.PICKUPS does not already pin.
-- ==========================================================================

local ROOT_FOLDER = "Pickups"
local CARS_FOLDER = "Cars" -- read-only; SpawnService owns this folder
local KIND_ORDER = { "CROWN", "MONEY", "CRATE" }
local KIND_FOLDER = { CROWN = "Crowns", MONEY = "Money", CRATE = "Crates" }

-- Pickup-model attributes. Deliberately NOT in Config.ATTR: that section is player state.
local ATTR_KIND = "PickupKind"
local ATTR_VALUE = "PickupValue"

-- Placement
local SPAWN_TRIES = 6 -- separation retries per kind per tick, then skip the tick
local SPAWN_MISS_WARN = 30 -- consecutive failed ticks before we suspect the arena
local RAY_MARGIN = 4 -- extra ray length below the floor slab
local SEED_FRACTION = 0.5 -- fraction of maxActive placed instantly on startRound
local ANIM_MIN_HZ = 1 -- floor under Config.PICKUPS.ANIM_HZ, so a bad value cannot divide by zero

-- Crown: cylinder band + 3 spikes + trigger = 5 parts, the budget.
local CROWN_BAND_HEIGHT = 1.1
local CROWN_BAND_DIAMETER = 2.4
local CROWN_SPIKES = 3
local CROWN_SPIKE_SIZE = Vector3.new(0.55, 0.55, 1.3) -- long axis on Z, aimed with lookAt
local CROWN_SPIKE_TILT = 15 -- degrees leaning outward from centre
local CROWN_SPIKE_INSET = 0.62 -- fraction of the band radius the spikes ring sits at
local CROWN_VALUE_SCALE_STEP = 0.09 -- fat death-drop crowns read chunkier
local CROWN_VALUE_SCALE_CAP = 6

--[[ Crowns read off the Neon material alone. 22 simultaneous PointLights sat at the edge of
	Roblox's practical nearby-light budget on mobile and bought no extra readability, so the
	lights are off. Flip this one constant to put them back. ]]
local CROWN_POINT_LIGHT = false
local CROWN_LIGHT_RANGE = 11
local CROWN_LIGHT_BRIGHTNESS = 2.2

-- Money: one decalled note plate + trigger = 2 parts. Sized to the art's own 1:1 crop.
local MONEY_THICKNESS = 0.3
local MONEY_HEIGHT = 2.8
local MONEY_WIDTH = 2.8

-- Crate: box + two crossed stripes + trigger = 4 parts.
local CRATE_SIZE = 2.6
local CRATE_STRIPE_THICKNESS = 0.55
local CRATE_STRIPE_OVERHANG = 0.1

-- Collection
local WALK_UP_LIMIT = 6 -- ancestor hops looking for the car model
local FX_RADIUS = 4 -- sparkle size handed to FxController
local CRATE_GRANT_GAP = 0.2 -- one car straddling two crates must not waste one
local NOTIFY_MOOD = "gold"

--[[ Death drops. Unlike normal spawns (ArenaService.randomGroundPoint already dodges
	obstacles for us) a drop picks arbitrary XZ around a wreck, so it validates its own ground:
	only the open floor plane counts, and a ring of probes keeps crowns off an edge. The arena
	no longer has holes, but this still earns its keep — a wreck on top of a plateau would
	otherwise scatter crowns onto a 16-stud deck, or half off it. ]]
local DROP_BURST_MAX = 12 -- crowns per death; a bigger hoard becomes fatter crowns
local DROP_RING_RADIUS = 9
local DROP_RING_JITTER = 3.5
local DROP_PLACE_TRIES = 4
local DROP_FLOOR_EPSILON = 1.0 -- accept only surfaces this close to the floor plane
local DROP_EDGE_MARGIN = 7 -- cardinal probe distance; wide enough to catch a plateau lip
local EDGE_PROBES = {
	Vector2.new(DROP_EDGE_MARGIN, 0),
	Vector2.new(-DROP_EDGE_MARGIN, 0),
	Vector2.new(0, DROP_EDGE_MARGIN),
	Vector2.new(0, -DROP_EDGE_MARGIN),
}

-- ==========================================================================
-- STATE
-- ==========================================================================

local PickupService = {}

-- Exposed so a sibling that wants to label a crown can read the same attribute names.
PickupService.ATTR = { KIND = ATTR_KIND, VALUE = ATTR_VALUE }

local ctxRef = nil
local rng = Random.new()

local rootFolder = nil
local folders = {} -- kind -> Folder
local active = {} -- array of pickup records
local counts = { CROWN = 0, MONEY = 0, CRATE = 0 }
local nextSpawnAt = { CROWN = 0, MONEY = 0, CRATE = 0 }
local lastGrantAt = {} -- player -> os.clock() of last crate grant

local spawning = false
local elapsed = 0 -- absolute animation clock; motion is derived from it, never integrated
local animAccum = 0
local spawnMissStreak = 0
local fieldEpoch = 0 -- bumped by clearAll so pending crate releases from a dead field no-op

local heartbeatConn, phaseConn, playerConn = nil, nil, nil
local warned = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("PickupService: " .. message)
end

-- Lazy sibling lookup. Never called during init.
local function svc(name: string)
	local bag = ctxRef and ctxRef.svc
	local found = bag and bag[name]
	if not found then
		warnOnce("svc_" .. name, name .. " unavailable")
	end
	return found
end

local function remote(name: string)
	local found = ctxRef and ctxRef.net and ctxRef.net[name]
	if not found then
		warnOnce("net_" .. name, name .. " remote missing")
	end
	return found
end

-- ==========================================================================
-- ARENA QUERIES — ArenaService owns the geometry, so we only ask it questions.
-- ==========================================================================

local function arenaFolder(): Instance?
	local arena = svc("ArenaService")
	if not arena or type(arena.getFolder) ~= "function" then
		return nil
	end
	local ok, folder = pcall(arena.getFolder)
	if not ok or typeof(folder) ~= "Instance" then
		return nil
	end
	return folder
end

--[[ ArenaService.randomGroundPoint already keeps its margin from the walls, the pit holes and
	every block/ramp footprint, and returns Y at the floor surface — we just add our hover. ]]
local function randomGround(): Vector3?
	local arena = svc("ArenaService")
	if not arena or type(arena.randomGroundPoint) ~= "function" then
		return nil
	end
	local ok, point = pcall(arena.randomGroundPoint, CFG.SPAWN_INSET)
	if not ok or typeof(point) ~= "Vector3" then
		warnOnce("randomGround", "ArenaService.randomGroundPoint gave no point")
		return nil
	end
	return point
end

-- Permissive when ArenaService cannot answer: a death drop must not be blocked.
local function insideArena(pos: Vector3): boolean
	local arena = svc("ArenaService")
	if not arena or type(arena.isInside) ~= "function" then
		return true
	end
	local ok, inside = pcall(arena.isInside, pos)
	if not ok then
		return true
	end
	return inside == true
end

--[[ Height of the SOLID surface under an XZ column, or nil over a hole.
	RespectCanCollide is essential: ArenaService documents that its pads, chevrons, block caps,
	pit shafts and pit sensors are non-collidable decoration, and a pit shaft's top edge sits
	level with the floor — without this flag a ray would read the inside of a pit as ground.
	Rays start from a fixed plane above the arena, not from the caller's Y, so a car that died
	mid-air still drops its crowns onto the floor below. ]]
local function surfaceYAt(x: number, z: number): number?
	local params = RaycastParams.new()
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local arena = arenaFolder()
	if arena then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { arena }
	else
		local skip = {}
		if rootFolder then
			table.insert(skip, rootFolder)
		end
		for _, name in ipairs({ CARS_FOLDER, "Projectiles" }) do
			local folder = Workspace:FindFirstChild(name)
			if folder then
				table.insert(skip, folder)
			end
		end
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = skip
	end

	local top = ARENA.ORIGIN.Y + ARENA.WALL_HEIGHT
	local length = ARENA.WALL_HEIGHT + ARENA.FLOOR_THICKNESS + RAY_MARGIN
	local hit = Workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -length, 0), params)
	if not hit then
		return nil
	end
	return hit.Position.Y
end

-- Open floor only: rejects a block top (unreachable) and a ramp face (crowns would embed).
local function floorYAt(x: number, z: number): number?
	local y = surfaceYAt(x, z)
	if not y or math.abs(y - ARENA.ORIGIN.Y) > DROP_FLOOR_EPSILON then
		return nil
	end
	return y
end

-- The candidate AND a ring around it must be open floor, so nothing lands on a pit lip.
local function openFloorYAt(x: number, z: number): number?
	local y = floorYAt(x, z)
	if not y then
		return nil
	end
	for _, probe in ipairs(EDGE_PROBES) do
		if not floorYAt(x + probe.X, z + probe.Y) then
			return nil
		end
	end
	return y
end

-- Hull positions of every live car. Built at most once per animation tick, never per pickup.
local function liveCarPositions(): { Vector3 }
	local out = {}
	local carsFolder = Workspace:FindFirstChild(CARS_FOLDER)
	if not carsFolder then
		return out -- SpawnService has not made its folder yet; nobody is out there
	end
	for _, child in ipairs(carsFolder:GetChildren()) do
		if child:IsA("Model") then
			local hull = ChassisSpec.getHull(child)
			if hull then
				table.insert(out, hull.Position)
			end
		end
	end
	return out
end

-- ==========================================================================
-- BUILD — every pickup is primitives, no art assets.
-- ==========================================================================

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false -- the Trigger owns collection so a touch can only fire once
	part.CanQuery = false -- keep chassis hover rays and bullets off collectibles
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function newTrigger(radius: number, parent: Instance): BasePart
	local diameter = radius * 2
	local trigger = Instance.new("Part")
	trigger.Name = "Trigger"
	trigger.Shape = Enum.PartType.Ball
	trigger.Size = Vector3.new(diameter, diameter, diameter)
	trigger.Transparency = 1
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.CanTouch = true
	trigger.CanQuery = false
	trigger.CastShadow = false
	trigger.Parent = parent
	return trigger
end

local function buildCrown(value: number): (Model, BasePart)
	local extra = math.clamp(value - 1, 0, CROWN_VALUE_SCALE_CAP)
	local scale = 1 + extra * CROWN_VALUE_SCALE_STEP

	local model = Instance.new("Model")
	model.Name = "Pickup_CROWN"
	local trigger = newTrigger(CFG.CROWN.radius, model)

	local band = newPart(
		"Band",
		Vector3.new(CROWN_BAND_HEIGHT * scale, CROWN_BAND_DIAMETER * scale, CROWN_BAND_DIAMETER * scale),
		CFG.CROWN.color,
		Enum.Material.Neon,
		model
	)
	band.Shape = Enum.PartType.Cylinder
	-- Cylinder parts run along X, so roll it 90 degrees to lay the disc flat.
	band.CFrame = CFrame.Angles(0, 0, math.rad(90))

	if CROWN_POINT_LIGHT then
		local light = Instance.new("PointLight")
		light.Color = CFG.CROWN.color
		light.Range = CROWN_LIGHT_RANGE
		light.Brightness = CROWN_LIGHT_BRIGHTNESS
		light.Shadows = false
		light.Parent = band
	end

	local tilt = math.rad(CROWN_SPIKE_TILT)
	local ringRadius = CROWN_BAND_DIAMETER * 0.5 * CROWN_SPIKE_INSET * scale
	local spikeSize = CROWN_SPIKE_SIZE * scale
	local spikeReach = (CROWN_BAND_HEIGHT * 0.5 + CROWN_SPIKE_SIZE.Z * 0.5) * scale

	for i = 1, CROWN_SPIKES do
		local angle = (i - 1) / CROWN_SPIKES * math.pi * 2
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local up = (Vector3.yAxis * math.cos(tilt) + outward * math.sin(tilt)).Unit
		local centre = outward * ringRadius + up * spikeReach

		local spike = newPart("Spike", spikeSize, UI.GOLD_LIGHT, Enum.Material.Neon, model)
		-- `outward` as the up-hint keeps lookAt out of its degenerate near-vertical case.
		spike.CFrame = CFrame.lookAt(centre, centre + up, outward)
	end

	model.PrimaryPart = trigger
	return model, trigger
end

--[[ A floating BANKNOTE, not a coin: a thin slab wearing the shop's own cash art on both
	broad faces, so the thing on the floor, the counter on the rail and the packs in the
	store are recognisably one currency.

	The art is a Decal, which means the slab underneath must NOT be Neon — neon blows the
	image out to a flat white card. It is SmoothPlastic in cash green instead, and the green
	is only ever seen as the note's edge as it turns. The plate faces are the X faces for
	the same reason the coin's disc did: the pickup spins about Y, so the note presents
	fully, thins to a line, and presents again — the flash that made the coin findable at
	speed, kept. ]]
local function buildMoney(): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Pickup_MONEY"
	local trigger = newTrigger(CFG.MONEY.radius, model)

	local note = newPart(
		"Note",
		Vector3.new(MONEY_THICKNESS, MONEY_HEIGHT, MONEY_WIDTH),
		CFG.MONEY.color,
		Enum.Material.SmoothPlastic,
		model
	)
	note.CFrame = CFrame.new()

	for _, face in ipairs({ Enum.NormalId.Right, Enum.NormalId.Left }) do
		local decal = Instance.new("Decal")
		decal.Name = "Face"
		decal.Texture = Config.ART.MONEY
		decal.Face = face
		decal.Parent = note
	end

	model.PrimaryPart = trigger
	return model, trigger
end

local function buildCrate(): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Pickup_CRATE"
	local trigger = newTrigger(CFG.CRATE.radius, model)

	local box = newPart("Box", Vector3.new(CRATE_SIZE, CRATE_SIZE, CRATE_SIZE), CFG.CRATE.color, Enum.Material.Neon, model)
	box.CFrame = CFrame.new()

	-- Two crossed bands read as a wrapped supply crate rather than a plain cube.
	local span = CRATE_SIZE + CRATE_STRIPE_OVERHANG
	local bandFlat = newPart("BandFlat", Vector3.new(span, CRATE_STRIPE_THICKNESS, span), UI.PAPER, Enum.Material.Neon, model)
	bandFlat.CFrame = CFrame.new()
	local bandUpright =
		newPart("BandUpright", Vector3.new(CRATE_STRIPE_THICKNESS, span, span), UI.PAPER, Enum.Material.Neon, model)
	bandUpright.CFrame = CFrame.new()

	model.PrimaryPart = trigger
	return model, trigger
end

-- ==========================================================================
-- FIELD BOOKKEEPING
-- ==========================================================================

local onTriggerTouched -- forward declaration; defined below createPickup's dependencies

local function removeRecord(record): boolean
	for i = #active, 1, -1 do
		if active[i] == record then
			active[i] = active[#active]
			active[#active] = nil
			return true
		end
	end
	return false
end

local function destroyRecord(record)
	if record.conn then
		record.conn:Disconnect()
		record.conn = nil
	end
	if record.model then
		record.model:Destroy()
		record.model = nil
	end
end

--[[ Frees the slot the collected pickup occupied. Kinds with a respawnDelay hold their
	slot for that long, so the field genuinely thins out after a crate rush. ]]
local function releaseSlot(kind: string)
	local delay = CFG[kind].respawnDelay or 0
	if delay <= 0 then
		counts[kind] = math.max(0, counts[kind] - 1)
		return
	end

	local epoch = fieldEpoch
	task.delay(delay, function()
		if epoch ~= fieldEpoch then
			return -- field was cleared under us; counters are already zeroed
		end
		counts[kind] = math.max(0, counts[kind] - 1)
	end)
end

local function createPickup(kind: string, groundPos: Vector3, value: number): boolean
	local folder = folders[kind]
	if not folder then
		warnOnce("folder_" .. kind, "folder for " .. kind .. " missing")
		return false
	end

	local model, trigger
	if kind == "CROWN" then
		model, trigger = buildCrown(value)
	elseif kind == "MONEY" then
		model, trigger = buildMoney()
	else
		model, trigger = buildCrate()
	end

	local basePos = Vector3.new(groundPos.X, groundPos.Y + CFG.FLOAT_HEIGHT, groundPos.Z)
	model:SetAttribute(ATTR_KIND, kind)
	model:SetAttribute(ATTR_VALUE, value)
	CollectionService:AddTag(model, ChassisSpec.PICKUP_TAG)
	model:PivotTo(CFrame.new(basePos))
	model.Parent = folder

	local record = {
		kind = kind,
		model = model,
		basePos = basePos,
		value = value,
		phase = rng:NextNumber(0, math.pi * 2), -- so the field never pulses in lockstep
		spinOffset = rng:NextNumber(0, 360),
		collected = false,
		conn = nil,
	}
	record.conn = trigger.Touched:Connect(function(hitPart)
		onTriggerTouched(record, hitPart)
	end)

	table.insert(active, record)
	counts[kind] = counts[kind] + 1
	return true
end

-- XZ-only separation so a crown near a ramp still counts against one on the floor beside it.
local function farEnough(pos: Vector3): boolean
	local minSq = CFG.MIN_SEPARATION * CFG.MIN_SEPARATION
	for _, record in ipairs(active) do
		local dx = record.basePos.X - pos.X
		local dz = record.basePos.Z - pos.Z
		if dx * dx + dz * dz < minSq then
			return false
		end
	end
	return true
end

local function valueFor(kind: string): number
	return CFG[kind].value or 0
end

--[[ Crowns are the SCORE of exactly one mode. Deathmatch, Team Battle, Juggernaut and
	Elimination all place on something else, so a crown lying in the road there is a
	pickup that pays nothing and reads as clutter — worse, it teaches the wrong habit in
	a mode where chasing one gets you rammed. Money and crates are unaffected: money and
	weapons matter in every mode.

	Gated inside trySpawn rather than at the two call sites, so the seed burst, the
	top-up cadence and anything added later all obey it from one place. Death drops
	(dropCrowns) never come through here, and in a modeless round nothing changes: an
	absent GameModes answer defaults to the crown mode. ]]
local function kindAllowed(kind: string): boolean
	if kind ~= "CROWN" then
		return true
	end
	local ok, allowed = pcall(GameModes.usesCrowns)
	return not ok or allowed ~= false
end

-- Bounded retries: a crowded field skips this tick rather than spinning.
local function trySpawn(kind: string): boolean
	if not kindAllowed(kind) then
		return false
	end
	for _ = 1, SPAWN_TRIES do
		local ground = randomGround()
		if not ground then
			return false
		end
		if farEnough(ground) then
			return createPickup(kind, ground, valueFor(kind))
		end
	end
	return false
end

--[[ The whistle must not blow on an empty arena, so half of each kind's cap lands at once.
	After this the normal spawnInterval cadence tops the field up. ]]
local function seedField()
	for _, kind in ipairs(KIND_ORDER) do
		local target = math.floor(CFG[kind].maxActive * SEED_FRACTION)
		while counts[kind] < target do
			if not trySpawn(kind) then
				break
			end
		end
	end
end

-- ==========================================================================
-- COLLECTION
-- ==========================================================================

local function carFromPart(part: BasePart): Model?
	local node: Instance? = part
	for _ = 1, WALK_UP_LIMIT do
		if not node then
			return nil
		end
		if node:IsA("Model") and CollectionService:HasTag(node, ChassisSpec.CAR_TAG) then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function popFx(kind: string, position: Vector3)
	local fx = remote("WeaponFx")
	if not fx then
		return
	end
	-- Reusing the pinned "IMPACT" kind: FxController already knows how to sparkle it.
	fx:FireAllClients("IMPACT", {
		origin = position,
		color = CFG[kind].color,
		radius = FX_RADIUS,
		vfx = CFG[kind].vfx,
	})
end

local function award(kind: string, player: Instance, value: number)
	if kind == "CROWN" then
		local score = svc("ScoreService")
		if score and type(score.addCrowns) == "function" then
			score.addCrowns(player, value)
		end
	elseif kind == "MONEY" then
		local profile = svc("ProfileService")
		if profile and type(profile.addMoney) == "function" then
			profile.addMoney(player, value)
		end
	else
		PickupService.grantCrate(player)
	end
end

onTriggerTouched = function(record, hitPart: BasePart)
	if record.collected then
		return
	end
	if not MatchState.isMatch() then
		return -- pickups are inert outside the Match phase
	end

	local car = carFromPart(hitPart)
	if not car then
		return
	end

	local spawnSvc = svc("SpawnService")
	if not spawnSvc or type(spawnSvc.playerFromCar) ~= "function" then
		return
	end

	local okOwner, player = pcall(spawnSvc.playerFromCar, car)
	if not okOwner or typeof(player) ~= "Instance" or not player:IsA("Player") or not player.Parent then
		return
	end
	if type(spawnSvc.isAlive) == "function" and not spawnSvc.isAlive(player) then
		return
	end

	if record.kind == "CRATE" then
		local now = os.clock()
		if now - (lastGrantAt[player] or 0) < CRATE_GRANT_GAP then
			return -- leave the crate standing rather than burning it on a double touch
		end
		lastGrantAt[player] = now
	end

	-- Latch BEFORE anything that can yield, so a pickup can only ever pay out once.
	record.collected = true
	removeRecord(record)
	releaseSlot(record.kind)

	local kind, value, position = record.kind, record.value, record.basePos
	destroyRecord(record)
	popFx(kind, position)

	-- Awarding last, and pcall'd: a sibling erroring must not leave a ghost pickup behind.
	local ok, err = pcall(award, kind, player, value)
	if not ok then
		warn("PickupService: award " .. kind .. " failed -> " .. tostring(err))
	end
end

-- ==========================================================================
-- PUBLIC API
-- ==========================================================================

--[[ The car they are actually driving decides the signature-powerup bonus. Equipped id is
	the fallback for the frame between equipping and respawning. ]]
local function drivingCarId(player: Instance): string
	local spawnSvc = svc("SpawnService")
	if spawnSvc and type(spawnSvc.getCar) == "function" then
		local ok, car = pcall(spawnSvc.getCar, player)
		if ok and typeof(car) == "Instance" then
			local id = car:GetAttribute(ChassisSpec.ATTR.CAR_ID)
			if type(id) == "string" and id ~= "" then
				return id
			end
		end
	end
	return CarRegistry.equippedId(player)
end

function PickupService.grantCrate(player: Instance)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		warnOnce("grantCrate_arg", "grantCrate called without a Player")
		return
	end

	local def = PowerupDefs.roll(drivingCarId(player), rng)
	if not def then
		warnOnce("grantCrate_roll", "PowerupDefs.roll returned nothing")
		return
	end

	local weapons = svc("WeaponService")
	if weapons and type(weapons.givePowerup) == "function" then
		weapons.givePowerup(player, def.id)
	end

	local notify = remote("Notify")
	if notify then
		notify:FireClient(player, "Got a " .. def.name .. "!", NOTIFY_MOOD)
	end
end

-- One crown's landing spot: on the ring, pulled inward on each retry, open floor only.
local function dropPoint(centre: Vector3, index: number, total: number): Vector3?
	local angle = (index - 1) / total * math.pi * 2 + rng:NextNumber(0, math.pi * 2 / total)
	for try = 1, DROP_PLACE_TRIES do
		local pull = 1 - (try - 1) / DROP_PLACE_TRIES
		local radius = math.max(0, DROP_RING_RADIUS + rng:NextNumber(-DROP_RING_JITTER, DROP_RING_JITTER)) * pull
		local x = centre.X + math.cos(angle) * radius
		local z = centre.Z + math.sin(angle) * radius
		local y = openFloorYAt(x, z)
		if y then
			local point = Vector3.new(x, y, z)
			if insideArena(point) then
				return point
			end
		end
	end
	-- Died over a pit, on a ramp or on a block: put the crowns somewhere reachable instead.
	return randomGround()
end

--[[ Scatters a dead player's crowns in a ring around the wreck.
	Ignores maxActive — a death drop must never silently vanish because the field is full —
	but caps the burst at DROP_BURST_MAX and folds the remainder into fatter crowns, so a
	40-crown leader drops 12 chunky crowns rather than 40 parts' worth of confetti. ]]
function PickupService.dropCrowns(position: Vector3, count: number)
	if typeof(position) ~= "Vector3" or type(count) ~= "number" or count ~= count then
		warnOnce("dropCrowns_arg", "dropCrowns called with bad arguments")
		return
	end

	local total = math.floor(count)
	if total <= 0 then
		return
	end

	local pieces = math.min(total, DROP_BURST_MAX)
	local base = total // pieces
	local extra = total % pieces

	for i = 1, pieces do
		local value = base + (i <= extra and 1 or 0)
		local ground = dropPoint(position, i, pieces)
		if ground then
			createPickup("CROWN", ground, value)
		end
	end
end

function PickupService.clearAll()
	fieldEpoch += 1

	for i = #active, 1, -1 do
		destroyRecord(active[i])
		active[i] = nil
	end

	for _, kind in ipairs(KIND_ORDER) do
		counts[kind] = 0
		nextSpawnAt[kind] = 0 -- next tick may spawn immediately
		local folder = folders[kind]
		if folder then
			-- Anything the folder holds outside `active` (a reload leftover) goes too.
			for _, child in ipairs(folder:GetChildren()) do
				child:Destroy()
			end
		end
	end
end

function PickupService.startRound()
	PickupService.clearAll()
	spawnMissStreak = 0
	spawning = true
	seedField()
end

function PickupService.stopRound()
	spawning = false
	PickupService.clearAll()
end

-- ==========================================================================
-- LOOP + INIT
-- ==========================================================================

local function stepSpawning(now: number)
	if not spawning then
		return
	end

	local placed, due = false, false
	for _, kind in ipairs(KIND_ORDER) do
		local cfg = CFG[kind]
		if now >= nextSpawnAt[kind] then
			nextSpawnAt[kind] = now + cfg.spawnInterval
			if counts[kind] < cfg.maxActive then
				due = true
				placed = trySpawn(kind) or placed
			end
		end
	end

	-- A field that is due for pickups but never places one means the arena is not answering.
	if not due then
		return
	end
	if placed then
		spawnMissStreak = 0
	else
		spawnMissStreak += 1
		if spawnMissStreak >= SPAWN_MISS_WARN then
			warnOnce("spawnStarved", "no pickup placed in " .. SPAWN_MISS_WARN .. " due ticks — check ArenaService")
		end
	end
end

--[[ Manual sine math per the house rule: no TweenService for looped motion.
	Throttled to Config.PICKUPS.ANIM_HZ and culled to Config.PICKUPS.ANIM_RADIUS, because every
	moved part replicates. `now` is an absolute clock, so a pickup that was skipped resumes at
	the exact CFrame continuous motion would have given it — coming back into range never pops. ]]
local function stepAnimation(now: number, dt: number)
	animAccum += dt
	local interval = 1 / math.max(ANIM_MIN_HZ, CFG.ANIM_HZ)
	if animAccum < interval then
		return
	end
	animAccum %= interval

	if #active == 0 then
		return
	end

	local cars = liveCarPositions() -- ONCE per animation tick, not per pickup
	if #cars == 0 then
		return -- nobody is out there to see it; every pickup holds its last CFrame
	end

	local radiusSq = CFG.ANIM_RADIUS * CFG.ANIM_RADIUS
	for _, record in ipairs(active) do
		local base = record.basePos
		local seen = false
		for _, carPos in ipairs(cars) do
			local dx, dy, dz = carPos.X - base.X, carPos.Y - base.Y, carPos.Z - base.Z
			if dx * dx + dy * dy + dz * dz <= radiusSq then
				seen = true
				break
			end
		end

		if seen then
			local cfg = CFG[record.kind]
			local bob = MathUtil.drift(now, cfg.bobSpeed, record.phase, cfg.bobHeight)
			local yaw = math.rad((now * cfg.spinSpeed + record.spinOffset) % 360)
			record.model:PivotTo(CFrame.new(base + Vector3.new(0, bob, 0)) * CFrame.Angles(0, yaw, 0))
		end
	end
end

function PickupService.init(ctx)
	ctxRef = ctx

	rootFolder = Workspace:FindFirstChild(ROOT_FOLDER)
	if not rootFolder then
		rootFolder = Instance.new("Folder")
		rootFolder.Name = ROOT_FOLDER
		rootFolder.Parent = Workspace
	end

	for _, kind in ipairs(KIND_ORDER) do
		local name = KIND_FOLDER[kind]
		local folder = rootFolder:FindFirstChild(name)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = name
			folder.Parent = rootFolder
		end
		folders[kind] = folder
	end

	spawning = false
	elapsed = 0
	animAccum = 0
	spawnMissStreak = 0
	PickupService.clearAll()

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	-- ONE loop for both jobs: cadence every frame, idle motion at ANIM_HZ.
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		stepSpawning(elapsed)
		stepAnimation(elapsed, dt)
	end)

	if playerConn then
		playerConn:Disconnect()
	end
	playerConn = Players.PlayerRemoving:Connect(function(player)
		lastGrantAt[player] = nil
	end)

	if phaseConn then
		phaseConn:Disconnect()
	end
	--[[ Defensive only. MatchService drives startRound/stopRound; this makes sure any other
		exit from Match (forceEndRound, an empty server) still leaves a clean field. ]]
	phaseConn = MatchState.onPhaseChanged(function(phase)
		if phase ~= MatchState.PHASES.MATCH and spawning then
			PickupService.stopRound()
		end
	end)
end

return PickupService
