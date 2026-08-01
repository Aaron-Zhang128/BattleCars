--[[ ArenaService
	Builds the play space procedurally from ONE of Maps.LIST — checkered floor, banked
	perimeter, boundary wall, launch ramps, boost pads, plateaus, obstacle blocks, floor
	paint and outside-the-wall scenery — plus the arcade lighting look for that map.
	No art assets, nothing hand-placed, all rebuildable.

	Data flow
		Main.server   -> ArenaService.init(ctx) -> ArenaService.build()
		MatchService  : nextMap()                 rotates the map at the start of Lobby
		SpawnService  : randomSpawn() / getSpawnPoints()   where to drop a fresh car
		PickupService : randomGroundPoint(inset)           where to place crowns/money/crates
		anyone        : isInside(pos) / getFolder() / getMap()

	MAPS
		Config.ARENA holds what never changes between maps (ORIGIN, SIZE, FLOOR_THICKNESS,
		WALL_THICKNESS, spawn ring, PAD_SIZE); a map def in CrashCore.Maps
		overrides the look and the layout and inherits the rest. build(mapId) is the only
		place `activeMap` is assigned. The current map replicates as two attributes on
		ReplicatedStorage.CrashCore: Config.ATTR.MAP_ID and Config.ATTR.MAP_NAME.

	Owns at runtime
		Workspace.Arena — this service is the ONLY writer. build() destroys and
		rebuilds it, and deletes the scratch-place Baseplate / SpawnLocation.
		Lighting properties (+ its Atmosphere / SunRays / Bloom children).

		Boost pads carry ChassisSpec.PAD_TAG; we only build and tag them — the boost
		EFFECT lives on the chassis/spawn side. Nothing this service builds can kill a
		player: the arena floor has no hole and no hazard anywhere in it.

		The ONLY collidable arena geometry is floor / banks / walls / ramps / blocks /
		plateaus. Pads, chevrons, block caps, plateau caps, floor paint, the apron and
		every decor prop are CanCollide=false (and CanTouch=false unless they are the pad). Raycasts fire through non-collidable parts by default, so a ground
		probe or hitscan that must not stop on decoration should set
		RaycastParams.RespectCanCollide = true.

		Decor is ALWAYS outside the walls, so no prop can ever change a round. The apron
		is non-collidable on purpose: a car launched out of the arena must fall past it to
		FALL_KILL_Y, not land on the scenery.

	Remotes: none.  Player attributes: none.  Reads Workspace.Cars (SpawnService owns it).

	Init order: second, after ProfileService and before CarFactory / SpawnService /
	PickupService, because everything that positions something in the world asks
	this service where the ground is. Calls no sibling service at any time.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local Maps = require(core:WaitForChild("Maps"))
local ChassisSpec = require(core:WaitForChild("Shared"):WaitForChild("ChassisSpec"))

local CFG = Config.ARENA
local ATTR = Config.ATTR
local UI = Config.UI

--[[ Reference studs -> live studs. Config.ARENA.SCALE is SIZE / REFERENCE_SIZE, and
	every stud-valued constant in this file is authored at the reference scale and
	stretched through it — same as the map data. Retuning Config.ARENA.SIZE therefore
	moves the trim, the margins and the pit dressing along with the layout instead of
	leaving hairline decoration on a arena twice the size. ]]
local SCALE = CFG.SCALE or 1

-- ==========================================================================
-- names
-- ==========================================================================
local ARENA_FOLDER = "Arena"
local FLOOR_FOLDER = "Floor"
local BANKS_FOLDER = "Banks"
local WALLS_FOLDER = "Walls"
local RAMPS_FOLDER = "Ramps"
local PADS_FOLDER = "Pads"
local PLATEAUS_FOLDER = "Plateaus"
local BLOCKS_FOLDER = "Blocks"
local MARKS_FOLDER = "Marks"
local DECOR_FOLDER = "Decor"
local CARS_FOLDER = "Cars" -- read-only; SpawnService owns this folder
local SCRATCH_BASEPLATE = "Baseplate" -- blank-place leftovers we delete on build

-- ==========================================================================
-- geometry tuning (all derived numbers live here, never inline)
-- ==========================================================================
local WALL_FRICTION = 0.10 -- walls should skate cars along, not grab them
local WALL_ELASTICITY = 0.45
local WALL_ELASTICITY_WEIGHT = 3 -- wall dominates the pair, so ricochet is reliable
local FLOOR_FRICTION = 0.35
local FLOOR_ELASTICITY = 0.10
local BLOCK_FRICTION = 0.20
local BLOCK_ELASTICITY = 0.50
local BLOCK_ELASTICITY_WEIGHT = 3 -- ramming a block bounces you off it
local PART_DENSITY = 1 -- everything is anchored, so density is cosmetic

local TILE_MIN_PIECE = 1.0 * SCALE -- a clipped floor sliver thinner than this is not worth a part

local RAMP_YAW_FLIP = 180 -- a WedgePart's TALL face is its +Z side, and Config rotY
-- aims the ramp at the arena centre, so flip it to put the
-- takeoff lip centre-side and the flush entry wall-side
local RAMP_MAX_TILT = 40 -- keeps tan() sane if Config is ever cranked up
local RAMP_MIN_HEIGHT = 2 * SCALE

local WALL_TRIM_THICKNESS = 1.6 * SCALE -- bright cap along the top of the wall
local WALL_TRIM_OVERHANG = 0.8 * SCALE

local BANK_MAX_HEIGHT_FRACTION = 0.7 -- a berm taller than this much of the wall is a ramp out
local BLOCK_CAP_THICKNESS = 1.2 * SCALE
local BLOCK_CAP_TINT = 0.45 -- lerp toward PAPER so blocks read as ram targets
local BLOCK_CAP_TRIM = 0.6 * SCALE -- cap overhangs the block by this much

local PAD_CORE_SCALE = Vector3.new(0.78, 1.2, 0.90) -- inner glow slab = fake gradient
local PAD_CORE_TINT = 0.50
local PAD_CHEVRONS = 3
local PAD_CHEVRON_ANGLE = 32 -- degrees each bar yaws to form the arrow
local PAD_CHEVRON_THICKNESS = 0.2 * SCALE
local PAD_CHEVRON_WIDTH = 2.2 * SCALE
local PAD_CHEVRON_SPAN = 0.52 -- bar length as a fraction of PAD_SIZE.X
local PAD_CHEVRON_OFFSET = 0.22 -- bar centre offset as a fraction of PAD_SIZE.X

-- A plateau's deck has to clear a car, not just a kerb, and the skirts are what make
-- it drivable — so height and skirt depth are one pair, both set in Config.ARENA.
local PLATEAU_MIN_HEIGHT = 4 * SCALE

local MARK_THICKNESS = 0.3 * SCALE -- floor paint: proud of the floor, never in the way
local MARK_LIFT = 0.1 * SCALE
local MARK_RING_SEGMENTS = 28 -- a ring is drawn as short bars; a disc is a cylinder
local MARK_RING_OVERLAP = 1.12 -- bar length fudge so segments meet cleanly

-- Wide enough that its far edge sits past FogEnd (SIZE * FOG_END_ARENAS) and hazes out.
-- At 4.4 you could see the world end as a hard line on the horizon.
local APRON_SIZE_ARENAS = 11
-- A BasePart is capped at 2048 studs per axis and oversize requests are SILENTLY
-- clamped, which tore holes in a one-part apron. SIZE * 2 = 1806 stays under it.
local APRON_TILE_ARENAS = 2
local APRON_THICKNESS = 4 * SCALE
local APRON_TOP_DROP = 2 * SCALE -- apron top sits inside the floor slab so it cannot z-fight

local OBSTACLE_MARGIN = 4 * SCALE -- pickups keep this far off blocks/ramps
local BANK_MARGIN = 6 * SCALE -- ...and this far off the foot of the berm
local SPAWN_CLEARANCE = 12 * SCALE -- a spawn slot must clear obstacles by this much
local SPAWN_BANK_MARGIN = 10 * SCALE -- ...and never sit on the berm itself
local SPAWN_NUDGE_DEG = 7 -- angular step when a ring slot lands in a pit/block
local SPAWN_NUDGE_TRIES = 6
local SPAWN_SHRINK = 0.72 -- last resort: pull that slot in toward the centre
local SPAWN_TIE_EPSILON = 6 -- spawn slots within this many studs count as tied
local GROUND_POINT_TRIES = 48

-- ==========================================================================
-- lighting tuning — bright, punchy, cheap. Per-map SKY overrides the mood keys.
-- ==========================================================================
-- NOTE: Lighting.Technology is NOT writable from a Script or a plugin in this
-- engine build (it needs the RobloxScript capability), so it is authored on the
-- place itself in Studio > Lighting > Technology. The soft-set below stays in
-- case that ever opens up. Future reads best on the neon pads; ShadowMap is the
-- cheap mobile fallback if frame time suffers.
local LIGHT_TECHNOLOGY = Enum.Technology.Future
local LIGHT_CLOCK_TIME = 14 -- early afternoon: readable shadows, no squint
local LIGHT_LATITUDE = 20
local LIGHT_BRIGHTNESS = 2.6
local LIGHT_EXPOSURE = 0.10
local LIGHT_SHADOW_SOFTNESS = 0.20
local LIGHT_AMBIENT = Color3.fromRGB(96, 100, 110)
local LIGHT_OUTDOOR_AMBIENT = Color3.fromRGB(150, 154, 164)
local LIGHT_ENV_DIFFUSE = 0.7
local LIGHT_ENV_SPECULAR = 0.4
local LIGHT_FOG_COLOR = Color3.fromRGB(226, 234, 244)
-- Haze must not touch the arena AS SEEN FROM THE HUB: the plaza is 1500 studs out and
-- looking at a fogged-over map is the one thing that view cannot afford.
local FOG_START_ARENAS = 2.0
local FOG_END_ARENAS = 4.2

local ATMOS_DENSITY = 0.12 -- 0.22 greyed the sky out and flattened every map's mood
local ATMOS_OFFSET = 0.10
local ATMOS_COLOR = Color3.fromRGB(222, 232, 244)
local ATMOS_DECAY = Color3.fromRGB(112, 122, 138)
local ATMOS_GLARE = 0.12
local ATMOS_HAZE = 1.0

local SUNRAYS_INTENSITY = 0.06 -- subtle; kids' arcade, not a cinematic
local SUNRAYS_SPREAD = 0.9
local BLOOM_INTENSITY = 0.5
local BLOOM_SIZE = 24
local BLOOM_THRESHOLD = 1.6

-- ==========================================================================
-- state
-- ==========================================================================
local ArenaService = {}

local ctxRef = nil
local arenaFolder: Folder? = nil
local activeMap = Maps.LIST[1]
local activeIndex = 1
local spawnPoints: { CFrame } = {}
local obstacleRects = {} -- blocks + ramps; only pickups/spawns avoid these
local rng = Random.new()

-- ==========================================================================
-- geometry helpers
-- ==========================================================================
local function rectFrom(centerX: number, centerZ: number, sizeX: number, sizeZ: number)
	return {
		minX = centerX - sizeX * 0.5,
		maxX = centerX + sizeX * 0.5,
		minZ = centerZ - sizeZ * 0.5,
		maxZ = centerZ + sizeZ * 0.5,
	}
end

-- Axis-aligned bound of a box footprint yawed by `yawDeg` (pads/ramps at 45s).
local function yawedRect(centerX: number, centerZ: number, sizeX: number, sizeZ: number, yawDeg: number)
	local c = math.abs(math.cos(math.rad(yawDeg)))
	local s = math.abs(math.sin(math.rad(yawDeg)))
	return rectFrom(centerX, centerZ, sizeX * c + sizeZ * s, sizeX * s + sizeZ * c)
end

local function inRect(x: number, z: number, rect, margin: number): boolean
	return x >= rect.minX - margin and x <= rect.maxX + margin and z >= rect.minZ - margin and z <= rect.maxZ + margin
end

local function inAnyRect(x: number, z: number, rects, margin: number): boolean
	for _, rect in ipairs(rects) do
		if inRect(x, z, rect, margin) then
			return true
		end
	end
	return false
end

--[[ Guillotine subtraction: `rect` minus `cut`, appending 0-4 survivors to `out`.
	This is what lets a pit be the EXACT rect a map asked for instead of "whichever
	checker tiles happened to have their centre inside it" — Rooftops depends on a
	28-stud street being 28 studs wide, because that is the jump distance. ]]
local function subtractRect(rect, cut, out)
	if cut.minX >= rect.maxX or cut.maxX <= rect.minX or cut.minZ >= rect.maxZ or cut.maxZ <= rect.minZ then
		table.insert(out, rect)
		return
	end

	local bandMinZ = math.max(rect.minZ, cut.minZ)
	local bandMaxZ = math.min(rect.maxZ, cut.maxZ)

	if bandMinZ - rect.minZ > TILE_MIN_PIECE then
		table.insert(out, { minX = rect.minX, maxX = rect.maxX, minZ = rect.minZ, maxZ = bandMinZ })
	end
	if rect.maxZ - bandMaxZ > TILE_MIN_PIECE then
		table.insert(out, { minX = rect.minX, maxX = rect.maxX, minZ = bandMaxZ, maxZ = rect.maxZ })
	end
	if cut.minX - rect.minX > TILE_MIN_PIECE then
		table.insert(out, { minX = rect.minX, maxX = cut.minX, minZ = bandMinZ, maxZ = bandMaxZ })
	end
	if rect.maxX - cut.maxX > TILE_MIN_PIECE then
		table.insert(out, { minX = cut.maxX, maxX = rect.maxX, minZ = bandMinZ, maxZ = bandMaxZ })
	end
end

local function worldXZ(offset: Vector2): (number, number)
	return CFG.ORIGIN.X + offset.X, CFG.ORIGIN.Z + offset.Y
end

-- The berm eats this much of the floor on every side; spawns and pickups stay off it.
local function bankInset(): number
	local depth = activeMap.BANK_DEPTH or 0
	local height = activeMap.BANK_HEIGHT or 0
	return (depth > 0 and height > 0) and depth or 0
end

-- ==========================================================================
-- part helpers
-- ==========================================================================
local function newPart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[ An invisible wall: Transparency 1 with CanCollide true.

	CanTouch = false keeps it out of every Touched handler in the game (CombatService
	reads hull touches, PickupService reads pickups) — an invisible part firing contact
	events would be a genuinely invisible bug.

	CanQuery = false IS SET AND DOES NOT WORK. Measured 2026-07-30: the engine ignores
	CanQuery while CanCollide is true. The property reads back false and a raycast hits
	the part anyway; only a non-collidable part is truly excluded. It is left set so the
	intent stays on the record, but DO NOT RELY ON IT — anything that raycasts will see
	these walls, Roblox's default camera occlusion included. The only lever that actually
	hides a solid part from a query is a collision group the querying side excludes. ]]
local function newBarrier(name: string, size: Vector3, cframe: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

-- Pure decoration: no collision, no touch bookkeeping, no shadow cost.
local function setDecor(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
end

local function setPhysics(part: BasePart, friction: number, elasticity: number, elasticityWeight: number)
	part.CustomPhysicalProperties = PhysicalProperties.new(PART_DENSITY, friction, elasticity, 1, elasticityWeight)
end

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- A cylinder's axis is its LOCAL X, so standing one up is a 90 degree roll.
local function newCylinder(name: string, height: number, diameter: number, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = newPart(name, Vector3.new(height, diameter, diameter), cframe * CFrame.Angles(0, 0, math.rad(90)), color, parent)
	part.Shape = Enum.PartType.Cylinder
	return part
end

local function newBall(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = newPart(name, size, cframe, color, parent)
	part.Shape = Enum.PartType.Ball
	return part
end

-- ==========================================================================
-- floor / perimeter
-- ==========================================================================
-- Checkered floor, unbroken: nothing is cut out of it any more, because plateaus sit ON
-- the ground rather than replacing it.
local function buildFloor(parent: Instance)
	local folder = newFolder(FLOOR_FOLDER, parent)
	local half = CFG.SIZE * 0.5
	local tileStuds = math.max(4, activeMap.TILE_STUDS)
	local tiles = math.max(1, math.floor(CFG.SIZE / tileStuds + 0.5))
	local tileSize = CFG.SIZE / tiles -- exact fit even if SIZE is not a multiple
	local centerY = CFG.ORIGIN.Y - CFG.FLOOR_THICKNESS * 0.5

	--[[ The baseplate grid every tile wears. The period is SNAPPED to an even number of
		repeats per tile: a Texture tiles outward from the face CENTRE, so an odd count
		puts the pattern half a period out at every seam and the grid breaks along all
		90 checker lines. Derived from tileSize, so if the guillotine above is ever
		switched back on, a clipped piece would need its own snap. ]]
	local gridImage = activeMap.FLOOR_TEXTURE
	local gridPeriod = 0
	if type(gridImage) == "string" and gridImage ~= "" then
		local target = math.max(1, activeMap.FLOOR_TEXTURE_STUDS or tileSize)
		gridPeriod = tileSize / math.max(2, math.floor(tileSize / target / 2 + 0.5) * 2)
	end

	for ix = 0, tiles - 1 do
		for iz = 0, tiles - 1 do
			local cx = CFG.ORIGIN.X - half + tileSize * (ix + 0.5)
			local cz = CFG.ORIGIN.Z - half + tileSize * (iz + 0.5)
			local color = ((ix + iz) % 2 == 0) and activeMap.FLOOR_COLOR or activeMap.FLOOR_ACCENT

			--[[ Still a loop over PIECES even though nothing cuts the floor any more: this
				arena has had holes cut in it twice (pits, then lava) and the guillotine
				machinery is three lines away should it ever need them again. ]]
			local pieces = { rectFrom(cx, cz, tileSize, tileSize) }

			for pieceIndex, piece in ipairs(pieces) do
				local sizeX = piece.maxX - piece.minX
				local sizeZ = piece.maxZ - piece.minZ
				if sizeX > TILE_MIN_PIECE and sizeZ > TILE_MIN_PIECE then
					local tile = newPart(
						string.format("Tile_%d_%d_%d", ix, iz, pieceIndex),
						Vector3.new(sizeX, CFG.FLOOR_THICKNESS, sizeZ),
						CFrame.new((piece.minX + piece.maxX) * 0.5, centerY, (piece.minZ + piece.maxZ) * 0.5),
						color,
						folder
					)
					setPhysics(tile, FLOOR_FRICTION, FLOOR_ELASTICITY, 1)

					if gridPeriod > 0 then
						local grid = Instance.new("Texture")
						grid.Name = "Grid"
						grid.Texture = gridImage
						grid.Face = Enum.NormalId.Top
						grid.StudsPerTileU = gridPeriod
						grid.StudsPerTileV = gridPeriod
						-- Color3 MULTIPLIES the image, so the tile keeps its own checker colour
						-- and the map's palette survives instead of being painted baseplate grey.
						grid.Color3 = color
						grid.Transparency = activeMap.FLOOR_TEXTURE_TRANSPARENCY or 0
						grid.Parent = tile
					end
				end
			end
		end
	end
end

--[[ The banked berm that makes the arena a dish instead of a box: one wedge per side,
	each spanning the FULL width so the four overlap in the corners. Overlapping wedges
	resolve to whichever is higher, which is exactly the corner mound we want — no
	corner pieces, no seams to line up.
	Height is clamped against the wall: a berm you can crest is a way out of the world. ]]
local function buildBanks(parent: Instance)
	local depth = activeMap.BANK_DEPTH or 0
	local height = activeMap.BANK_HEIGHT or 0
	if depth <= 0 or height <= 0 then
		return -- flat-walled map (Rooftops): the drop past the parapet is the point
	end

	local wallHeight = activeMap.WALL_HEIGHT
	if height > wallHeight * BANK_MAX_HEIGHT_FRACTION then
		height = wallHeight * BANK_MAX_HEIGHT_FRACTION
		warn("ArenaService: BANK_HEIGHT clamped on map " .. tostring(activeMap.id) .. " — berm was near wall height")
	end

	local folder = newFolder(BANKS_FOLDER, parent)
	local half = CFG.SIZE * 0.5
	local segments = math.max(1, activeMap.BANK_SEGMENTS or 1)
	local segLength = CFG.SIZE / segments
	local across = half - depth * 0.5

	-- yaw puts the wedge's tall face against the wall; axis says which world axis the
	-- side runs along.
	local sides = {
		{ name = "North", yaw = 0, alongX = true, sign = 1 },
		{ name = "South", yaw = 180, alongX = true, sign = -1 },
		{ name = "East", yaw = 90, alongX = false, sign = 1 },
		{ name = "West", yaw = -90, alongX = false, sign = -1 },
	}

	for _, side in ipairs(sides) do
		for index = 0, segments - 1 do
			local along = -half + segLength * (index + 0.5)
			local ox = side.alongX and along or across * side.sign
			local oz = side.alongX and across * side.sign or along
			local wx, wz = worldXZ(Vector2.new(ox, oz))

			local color = activeMap.BANK_COLOR
			if activeMap.BANK_COLOR_ALT and index % 2 == 1 then
				color = activeMap.BANK_COLOR_ALT
			end

			local bank = Instance.new("WedgePart")
			bank.Name = string.format("Bank%s_%d", side.name, index + 1)
			bank.Size = Vector3.new(segLength, height, depth)
			bank.CFrame = CFrame.new(wx, CFG.ORIGIN.Y + height * 0.5, wz) * CFrame.Angles(0, math.rad(side.yaw), 0)
			bank.Color = color
			bank.Material = Enum.Material.SmoothPlastic
			bank.Anchored = true
			bank.CanCollide = true
			bank.CastShadow = false
			bank.Parent = folder
			setPhysics(bank, FLOOR_FRICTION, FLOOR_ELASTICITY, 1)
		end
	end
end

-- Four boundary walls, overlapping at the corners so nothing squeezes out, each capped
-- with a bright trim bar so the boundary reads from across the arena.
local function buildWalls(parent: Instance)
	local folder = newFolder(WALLS_FOLDER, parent)
	local half = CFG.SIZE * 0.5
	local thickness = CFG.WALL_THICKNESS
	local height = activeMap.WALL_HEIGHT
	local outer = half + thickness * 0.5
	local span = CFG.SIZE + thickness * 2
	local y = CFG.ORIGIN.Y + height * 0.5

	local defs = {
		{ name = "WallNorth", size = Vector3.new(span, height, thickness), offset = Vector2.new(0, outer) },
		{ name = "WallSouth", size = Vector3.new(span, height, thickness), offset = Vector2.new(0, -outer) },
		{ name = "WallEast", size = Vector3.new(thickness, height, span), offset = Vector2.new(outer, 0) },
		{ name = "WallWest", size = Vector3.new(thickness, height, span), offset = Vector2.new(-outer, 0) },
	}

	for _, def in ipairs(defs) do
		local wx, wz = worldXZ(def.offset)
		local wall = newPart(def.name, def.size, CFrame.new(wx, y, wz), activeMap.WALL_COLOR, folder)
		wall.CastShadow = true
		setPhysics(wall, WALL_FRICTION, WALL_ELASTICITY, WALL_ELASTICITY_WEIGHT)

		local trim = newPart(
			def.name .. "Trim",
			Vector3.new(
				def.size.X + (def.size.X < def.size.Z and WALL_TRIM_OVERHANG or 0),
				WALL_TRIM_THICKNESS,
				def.size.Z + (def.size.Z < def.size.X and WALL_TRIM_OVERHANG or 0)
			),
			CFrame.new(wx, CFG.ORIGIN.Y + height, wz),
			activeMap.TRIM_COLOR,
			folder
		)
		setDecor(trim)

		--[[ The invisible wall above it: same footprint, same physics as the wall it
			stands on, so glancing off it at speed feels exactly like glancing off the
			visible part rather than hitting glue. ]]
		local barrierHeight = activeMap.BARRIER_HEIGHT or 0
		if barrierHeight > 0 then
			local barrier = newBarrier(
				def.name .. "Barrier",
				Vector3.new(def.size.X, barrierHeight, def.size.Z),
				CFrame.new(wx, CFG.ORIGIN.Y + height + barrierHeight * 0.5, wz),
				folder
			)
			setPhysics(barrier, WALL_FRICTION, WALL_ELASTICITY, WALL_ELASTICITY_WEIGHT)
		end
	end
end

-- ==========================================================================
-- features
-- ==========================================================================
--[[ Launch ramps. A WedgePart is solid down to the floor, so the low edge is flush
	(no lip to clip on) and the tall edge is a clean takeoff. `tilt` is the slope
	angle, so wedge height comes from tilt + footprint depth; Config's size.Y
	describes a flat deck and has no meaning for a solid wedge.
	The takeoff faces the arena centre on purpose — launching outward could clear
	WALL_HEIGHT and throw cars out of the world. ]]
local function buildRamps(parent: Instance)
	local folder = newFolder(RAMPS_FOLDER, parent)
	local color = activeMap.RAMP_COLOR or activeMap.FLOOR_ACCENT

	for index, def in ipairs(activeMap.RAMPS) do
		local tilt = math.clamp(def.tilt, 0, RAMP_MAX_TILT)
		local height = math.max(RAMP_MIN_HEIGHT, def.size.Z * math.tan(math.rad(tilt)))
		local rx, rz = worldXZ(def.offset)
		local yaw = def.rotY + RAMP_YAW_FLIP

		local ramp = Instance.new("WedgePart")
		ramp.Name = string.format("Ramp_%d", index)
		ramp.Size = Vector3.new(def.size.X, height, def.size.Z)
		ramp.CFrame = CFrame.new(rx, CFG.ORIGIN.Y + height * 0.5, rz) * CFrame.Angles(0, math.rad(yaw), 0)
		ramp.Color = color
		ramp.Material = Enum.Material.SmoothPlastic
		ramp.Anchored = true
		ramp.CanCollide = true
		ramp.CastShadow = true
		ramp.Parent = folder
		setPhysics(ramp, FLOOR_FRICTION, FLOOR_ELASTICITY, 1)

		-- Bright nose stripe on the takeoff edge so the ramp reads at speed.
		local lip = newPart(
			string.format("RampLip_%d", index),
			Vector3.new(def.size.X, PAD_CHEVRON_THICKNESS, PAD_CHEVRON_WIDTH),
			ramp.CFrame * CFrame.new(0, height * 0.5, (def.size.Z - PAD_CHEVRON_WIDTH) * 0.5),
			activeMap.PAD_COLOR,
			folder
		)
		lip.Material = Enum.Material.Neon
		setDecor(lip)

		table.insert(obstacleRects, yawedRect(rx, rz, def.size.X, def.size.Z, yaw))
	end
end

--[[ Boost pads. We only BUILD and TAG them — SpawnService/ChassisController own
	the boost itself. Non-collidable so cars drive straight over, CanTouch on so
	the consumer can hook Touched. ]]
local function buildPads(parent: Instance)
	local folder = newFolder(PADS_FOLDER, parent)
	local padSize = CFG.PAD_SIZE
	local padY = CFG.ORIGIN.Y + padSize.Y * 0.5
	local topY = padSize.Y * 0.5

	for index, def in ipairs(activeMap.PADS) do
		local px, pz = worldXZ(def.offset)
		local padCFrame = CFrame.new(px, padY, pz) * CFrame.Angles(0, math.rad(def.rotY), 0)

		local pad = newPart(string.format("BoostPad_%d", index), padSize, padCFrame, activeMap.PAD_COLOR, folder)
		pad.Material = Enum.Material.Neon
		pad.CanCollide = false
		pad.CanTouch = true
		CollectionService:AddTag(pad, ChassisSpec.PAD_TAG)

		-- Inner glow slab: a two-tone core reads as a gradient without a texture.
		local padCore = newPart(
			string.format("BoostPadCore_%d", index),
			Vector3.new(padSize.X * PAD_CORE_SCALE.X, padSize.Y * PAD_CORE_SCALE.Y, padSize.Z * PAD_CORE_SCALE.Z),
			padCFrame,
			activeMap.PAD_COLOR:Lerp(UI.PAPER, PAD_CORE_TINT),
			folder
		)
		padCore.Material = Enum.Material.Neon
		setDecor(padCore)

		-- Chevrons: two yawed bars per arrow, inner ends forward (pad LookVector).
		local barSize = Vector3.new(padSize.X * PAD_CHEVRON_SPAN, PAD_CHEVRON_THICKNESS, PAD_CHEVRON_WIDTH)
		for slot = 1, PAD_CHEVRONS do
			local slotZ = padSize.Z * ((slot - 0.5) / PAD_CHEVRONS - 0.5)
			for side = -1, 1, 2 do
				local bar = newPart(
					string.format("Chevron_%d_%d_%d", index, slot, side),
					barSize,
					padCFrame
						* CFrame.new(padSize.X * PAD_CHEVRON_OFFSET * side, topY, slotZ)
						* CFrame.Angles(0, math.rad(-PAD_CHEVRON_ANGLE * side), 0),
					UI.INK,
					folder
				)
				setDecor(bar)
			end
		end
	end
end

--[[ Plateaus. What a map authors as a footprint is raised into a solid mesa you drive
	AROUND — or, taking a run at any side, straight up and over. This replaced the lava
	pools, which replaced the open pits: the arena floor now holds no hole and no hazard
	at all, and a map shapes its lanes with geometry instead of by killing you.

	Each one is a core block on the EXACT authored rect, a lighter cap so it reads as a
	ram target like every other block, and four wedge skirts sitting OUTSIDE that rect.
	The skirts each span the full width and overlap in the corners, so the four resolve
	into one clean mound with no corner pieces and no seams to line up — the same trick
	buildBanks uses for the perimeter berm.

	Skirts go outside rather than inset so the deck stays exactly the size the map asked
	for. Rooftops' streets are 60 studs wide because that width IS the map; eating a
	skirt out of each side would erase it. ]]
local function buildPlateaus(parent: Instance)
	local defs = activeMap.PLATEAUS
	if not defs or #defs == 0 then
		return
	end

	local folder = newFolder(PLATEAUS_FOLDER, parent)
	local height = math.max(PLATEAU_MIN_HEIGHT, activeMap.PLATEAU_HEIGHT or 0)
	local skirt = math.max(0, activeMap.PLATEAU_SKIRT or 0)
	local color = activeMap.PLATEAU_COLOR or activeMap.BLOCK_COLOR

	--[[ A WedgePart's TALL face is its +Z side, so each yaw below aims that face at the
		plateau and lands the thin edge flush on the floor — no lip for a wheel to clip.
		`alongX` says which world axis the skirt runs along, `sign` which side it is on. ]]
	local sides = {
		{ name = "North", yaw = 180, alongX = true, sign = 1 },
		{ name = "South", yaw = 0, alongX = true, sign = -1 },
		{ name = "East", yaw = -90, alongX = false, sign = 1 },
		{ name = "West", yaw = 90, alongX = false, sign = -1 },
	}

	--[[ DISJOINT DECK PIECES. Rooftops' two streets both centre on the origin, so their
		decks and their caps would be coincident across the whole 60x60 crossing — two
		solid boxes with the same top face, which z-fights every frame. Cutting each rect
		against the ones already placed (the same guillotine the checker floor uses) means
		the crossing is covered exactly once. The pieces butt up against each other, so
		the cross still reads and drives as one continuous raised shape.

		Caps get NO outward trim, unlike a Block's: a trim would push neighbouring pieces
		back into overlapping each other. The cap straddles the deck's top face rather
		than sitting on it, so it never z-fights the core either. ]]
	local pieces = {}
	for _, def in ipairs(defs) do
		local cx, cz = worldXZ(def.offset)
		local kept = { rectFrom(cx, cz, def.size.X, def.size.Y) }
		for _, taken in ipairs(pieces) do
			local survivors = {}
			for _, piece in ipairs(kept) do
				subtractRect(piece, taken, survivors)
			end
			kept = survivors
			if #kept == 0 then
				break
			end
		end
		for _, piece in ipairs(kept) do
			table.insert(pieces, piece)
		end
	end

	for index, piece in ipairs(pieces) do
		local sizeX = piece.maxX - piece.minX
		local sizeZ = piece.maxZ - piece.minZ
		local cx = (piece.minX + piece.maxX) * 0.5
		local cz = (piece.minZ + piece.maxZ) * 0.5

		local core = newPart(
			string.format("Plateau_%d", index),
			Vector3.new(sizeX, height, sizeZ),
			CFrame.new(cx, CFG.ORIGIN.Y + height * 0.5, cz),
			color,
			folder
		)
		core.CastShadow = true
		setPhysics(core, FLOOR_FRICTION, FLOOR_ELASTICITY, 1)

		local cap = newPart(
			string.format("PlateauCap_%d", index),
			Vector3.new(sizeX, BLOCK_CAP_THICKNESS, sizeZ),
			CFrame.new(cx, CFG.ORIGIN.Y + height, cz),
			color:Lerp(UI.PAPER, BLOCK_CAP_TINT),
			folder
		)
		setDecor(cap)
	end

	--[[ Skirts and the keep-out rect come from the AUTHORED rects, not the cut pieces: a
		seam between two pieces is deck meeting deck and must not sprout a ramp down to
		the floor in the middle of the crossing. ]]
	for index, def in ipairs(defs) do
		local cx, cz = worldXZ(def.offset)
		local sizeX, sizeZ = def.size.X, def.size.Y

		if skirt > 0 then
			for _, side in ipairs(sides) do
				local span = (side.alongX and sizeX or sizeZ) + skirt * 2
				local out = ((side.alongX and sizeZ or sizeX) * 0.5 + skirt * 0.5) * side.sign
				local wx = side.alongX and cx or (cx + out)
				local wz = side.alongX and (cz + out) or cz

				local ramp = Instance.new("WedgePart")
				ramp.Name = string.format("PlateauRamp_%d_%s", index, side.name)
				ramp.Size = Vector3.new(span, height, skirt)
				ramp.CFrame = CFrame.new(wx, CFG.ORIGIN.Y + height * 0.5, wz)
					* CFrame.Angles(0, math.rad(side.yaw), 0)
				ramp.Color = color
				ramp.Material = Enum.Material.SmoothPlastic
				ramp.Anchored = true
				ramp.CanCollide = true
				ramp.CastShadow = false
				ramp.TopSurface = Enum.SurfaceType.Smooth
				ramp.BottomSurface = Enum.SurfaceType.Smooth
				ramp.Parent = folder
				setPhysics(ramp, FLOOR_FRICTION, FLOOR_ELASTICITY, 1)
			end
		end

		--[[ Spawns and pickups avoid the WHOLE mound, skirts included: a crate halfway up
			a slope is awkward to take at speed, and a spawn inside the core would bury a
			car in solid geometry. ]]
		table.insert(obstacleRects, rectFrom(cx, cz, sizeX + skirt * 2, sizeZ + skirt * 2))
	end
end

-- Solid obstacles that double as ram targets, and (when low and wide) drivable decks.
local function buildBlocks(parent: Instance)
	local folder = newFolder(BLOCKS_FOLDER, parent)

	for index, def in ipairs(activeMap.BLOCKS) do
		local bx, bz = worldXZ(def.offset)
		local block = newPart(
			string.format("Block_%d", index),
			def.size,
			CFrame.new(bx, CFG.ORIGIN.Y + def.size.Y * 0.5, bz),
			activeMap.BLOCK_COLOR,
			folder
		)
		block.CastShadow = true
		setPhysics(block, BLOCK_FRICTION, BLOCK_ELASTICITY, BLOCK_ELASTICITY_WEIGHT)

		local cap = newPart(
			string.format("BlockCap_%d", index),
			Vector3.new(def.size.X + BLOCK_CAP_TRIM, BLOCK_CAP_THICKNESS, def.size.Z + BLOCK_CAP_TRIM),
			CFrame.new(bx, CFG.ORIGIN.Y + def.size.Y, bz),
			activeMap.BLOCK_COLOR:Lerp(UI.PAPER, BLOCK_CAP_TINT),
			folder
		)
		setDecor(cap)

		table.insert(obstacleRects, rectFrom(bx, bz, def.size.X, def.size.Z))
	end
end

-- ==========================================================================
-- floor paint — flat, non-collidable, purely to give each map a read
-- ==========================================================================
local function markCFrame(offset: Vector2, rotY: number?): CFrame
	local mx, mz = worldXZ(offset)
	return CFrame.new(mx, CFG.ORIGIN.Y + MARK_LIFT, mz) * CFrame.Angles(0, math.rad(rotY or 0), 0)
end

local function buildMarks(parent: Instance)
	local marks = activeMap.MARKS
	if not marks or #marks == 0 then
		return
	end
	local folder = newFolder(MARKS_FOLDER, parent)

	for index, def in ipairs(marks) do
		local color = def.color or activeMap.FLOOR_COLOR

		if def.kind == "rect" then
			local rect = newPart(
				string.format("Mark_%d", index),
				Vector3.new(def.size.X, MARK_THICKNESS, def.size.Y),
				markCFrame(def.offset, def.rotY),
				color,
				folder
			)
			setDecor(rect)
		elseif def.kind == "disc" then
			local disc = newCylinder(
				string.format("MarkDisc_%d", index),
				MARK_THICKNESS,
				def.radius * 2,
				markCFrame(def.offset, def.rotY),
				color,
				folder
			)
			setDecor(disc)
		elseif def.kind == "ring" then
			-- Bars around a circle, not a disc-on-disc: the checker underneath changes
			-- colour, so a "hole" drawn in one floor tone would show its seams.
			local segments = MARK_RING_SEGMENTS
			local barLength = (2 * math.pi * def.radius / segments) * MARK_RING_OVERLAP
			local base = markCFrame(def.offset, def.rotY)
			for segment = 0, segments - 1 do
				local angle = (segment / segments) * math.pi * 2
				local bar = newPart(
					string.format("MarkRing_%d_%d", index, segment),
					Vector3.new(def.width, MARK_THICKNESS, barLength),
					base * CFrame.Angles(0, -angle, 0) * CFrame.new(def.radius, 0, 0),
					color,
					folder
				)
				setDecor(bar)
			end
		elseif def.kind == "checker" then
			local squares = math.max(2, def.squares or 12)
			local squareX = def.size.X / squares
			local base = markCFrame(def.offset, def.rotY)
			for square = 0, squares - 1 do
				for row = 0, 1 do
					local dark = ((square + row) % 2 == 0)
					local tile = newPart(
						string.format("MarkChecker_%d_%d_%d", index, square, row),
						Vector3.new(squareX, MARK_THICKNESS, def.size.Y * 0.5),
						base * CFrame.new(-def.size.X * 0.5 + squareX * (square + 0.5), 0, def.size.Y * 0.25 * (row == 0 and -1 or 1)),
						dark and UI.INK or UI.PAPER,
						folder
					)
					setDecor(tile)
				end
			end
		end
	end
end

-- ==========================================================================
-- scenery — everything here lives OUTSIDE the wall and never collides
-- ==========================================================================
--[[ One builder per DECOR `kind` in CrashCore.Maps. Each gets the prop's ground CFrame
	(already positioned and yawed) and fills in from there. Keep them cheap: this is a
	silhouette over a wall, not a set piece. ]]
local DECOR_BUILDERS = {}

DECOR_BUILDERS.dune = function(folder, def, base, index)
	local width = def.width or 180
	local height = def.height or 40
	local ball = newBall(
		string.format("Dune_%d", index),
		Vector3.new(width, height * 2, width * 0.62),
		base,
		def.color or activeMap.GROUND_COLOR,
		folder
	)
	setDecor(ball)
end

DECOR_BUILDERS.mound = DECOR_BUILDERS.dune

--[[ A valley wall segment: three tapering yawed slabs, same construction as the hub's
	peak in LobbyService so the two read as one landscape. This is what puts the arena
	in a basin — every map except Rooftops rings itself with these, and Rooftops uses
	its skyline for the same job. `accent` caps the top tier (snow, sunlit rock). ]]
DECOR_BUILDERS.ridge = function(folder, def, base, index)
	local height = def.height or 300
	local width = def.width or 420
	local color = def.color or activeMap.WALL_COLOR

	for tier = 1, 3 do
		local fraction = (tier - 1) / 2
		local tierWidth = width * (1 - fraction * 0.52)
		local tierHeight = height * (0.5 - fraction * 0.09)
		local part = newPart(
			string.format("Ridge_%d_%d", index, tier),
			Vector3.new(tierWidth, tierHeight, tierWidth * 0.8),
			base
				* CFrame.new(0, height * (0.22 + 0.29 * (tier - 1)), -width * 0.06 * (tier - 1))
				* CFrame.Angles(0, math.rad(13 * tier), 0),
			(tier == 3 and def.accent) and color:Lerp(def.accent, 0.55) or color:Lerp(UI.PAPER, 0.06 * (tier - 1)),
			folder
		)
		setDecor(part)
	end
end

DECOR_BUILDERS.rock = function(folder, def, base, index)
	local height = def.height or 26
	local color = def.color or activeMap.WALL_COLOR
	local chunks = {
		{ size = Vector3.new(height * 1.3, height, height * 1.1), cf = CFrame.Angles(0, 0.6, 0.12) },
		{ size = Vector3.new(height * 0.8, height * 0.7, height * 0.9), cf = CFrame.new(height * 0.7, -height * 0.2, height * 0.3) * CFrame.Angles(0.1, -0.5, 0) },
		{ size = Vector3.new(height * 0.6, height * 1.4, height * 0.6), cf = CFrame.new(-height * 0.6, height * 0.2, -height * 0.2) * CFrame.Angles(0, 0.9, -0.14) },
	}
	for chunkIndex, chunk in ipairs(chunks) do
		local part = newPart(
			string.format("Rock_%d_%d", index, chunkIndex),
			chunk.size,
			base * CFrame.new(0, chunk.size.Y * 0.4, 0) * chunk.cf,
			chunkIndex == 1 and color or color:Lerp(UI.PAPER, 0.16),
			folder
		)
		setDecor(part)
	end
end

DECOR_BUILDERS.cactus = function(folder, def, base, index)
	local height = def.height or 30
	local color = def.color or Color3.fromRGB(120, 168, 108)
	local thickness = height * 0.16

	local trunk = newPart(
		string.format("Cactus_%d", index),
		Vector3.new(thickness, height, thickness),
		base * CFrame.new(0, height * 0.5, 0),
		color,
		folder
	)
	setDecor(trunk)

	for side = -1, 1, 2 do
		local armY = height * (side < 0 and 0.52 or 0.66)
		local arm = newPart(
			string.format("CactusArm_%d_%d", index, side),
			Vector3.new(thickness * 2.2, thickness * 0.8, thickness * 0.8),
			base * CFrame.new(thickness * 1.3 * side, armY, 0),
			color,
			folder
		)
		setDecor(arm)
		local tip = newPart(
			string.format("CactusTip_%d_%d", index, side),
			Vector3.new(thickness * 0.8, height * 0.3, thickness * 0.8),
			base * CFrame.new(thickness * 2.1 * side, armY + height * 0.15, 0),
			color,
			folder
		)
		setDecor(tip)
	end
end

DECOR_BUILDERS.pine = function(folder, def, base, index)
	local height = def.height or 44
	local color = def.color or Color3.fromRGB(58, 96, 84)
	local snow = def.accent or UI.PAPER

	local trunk = newPart(
		string.format("PineTrunk_%d", index),
		Vector3.new(height * 0.1, height * 0.35, height * 0.1),
		base * CFrame.new(0, height * 0.175, 0),
		Color3.fromRGB(104, 76, 56),
		folder
	)
	setDecor(trunk)

	-- Three tapering skirts, each yawed 45 off the last so the silhouette is not a stack.
	for tier = 1, 3 do
		local fraction = 1 - (tier - 1) * 0.28
		local tierHeight = height * 0.30 * fraction
		local tierWidth = height * 0.52 * fraction
		local skirt = newPart(
			string.format("Pine_%d_%d", index, tier),
			Vector3.new(tierWidth, tierHeight, tierWidth),
			base * CFrame.new(0, height * (0.30 + 0.20 * (tier - 1)), 0) * CFrame.Angles(0, math.rad(45 * tier), 0),
			tier == 3 and color:Lerp(snow, 0.35) or color,
			folder
		)
		setDecor(skirt)
	end
end

DECOR_BUILDERS.spike = function(folder, def, base, index)
	local height = def.height or 50
	local color = def.color or Color3.fromRGB(178, 216, 240)
	for shard = 1, 3 do
		local scale = 1 - (shard - 1) * 0.3
		local part = newPart(
			string.format("Spike_%d_%d", index, shard),
			Vector3.new(height * 0.14 * scale, height * scale, height * 0.14 * scale),
			base
				* CFrame.new(height * 0.22 * (shard - 2), height * 0.5 * scale, height * 0.16 * (shard % 2 == 0 and 1 or -1))
				* CFrame.Angles(math.rad(6 * (shard - 2)), 0, math.rad(9 * (2 - shard))),
			color,
			folder
		)
		part.Transparency = 0.2
		part.Material = Enum.Material.Glass
		setDecor(part)
	end
end

DECOR_BUILDERS.tower = function(folder, def, base, index)
	local height = def.height or 180
	local width = def.width or 60
	local color = def.color or Color3.fromRGB(150, 156, 172)

	local shaft = newPart(
		string.format("Tower_%d", index),
		Vector3.new(width, height, width * 0.85),
		base * CFrame.new(0, height * 0.5, 0),
		color,
		folder
	)
	setDecor(shaft)

	local cap = newPart(
		string.format("TowerCap_%d", index),
		Vector3.new(width * 0.7, height * 0.06, width * 0.6),
		base * CFrame.new(0, height + height * 0.03, 0),
		color:Lerp(UI.INK, 0.25),
		folder
	)
	setDecor(cap)

	-- Window bands on the arena-facing face only: the back is never seen.
	for band = 1, 4 do
		local windows = newPart(
			string.format("TowerBand_%d_%d", index, band),
			Vector3.new(width * 0.74, height * 0.055, width * 0.02),
			base * CFrame.new(0, height * (0.16 + 0.2 * (band - 1)), width * 0.43),
			def.accent or Color3.fromRGB(252, 226, 168),
			folder
		)
		windows.Material = Enum.Material.Neon
		setDecor(windows)
	end
end

DECOR_BUILDERS.watertower = function(folder, def, base, index)
	local height = def.height or 34
	local color = def.color or Color3.fromRGB(184, 130, 96)
	local legHeight = height * 0.9
	local tankDiameter = height * 0.95

	for leg = 0, 3 do
		local angle = math.rad(45 + 90 * leg)
		local post = newPart(
			string.format("WaterLeg_%d_%d", index, leg),
			Vector3.new(height * 0.08, legHeight, height * 0.08),
			base * CFrame.new(math.cos(angle) * tankDiameter * 0.32, legHeight * 0.5, math.sin(angle) * tankDiameter * 0.32),
			def.accent or color:Lerp(UI.INK, 0.3),
			folder
		)
		setDecor(post)
	end

	local tank = newCylinder(
		string.format("WaterTank_%d", index),
		height * 0.8,
		tankDiameter,
		base * CFrame.new(0, legHeight + height * 0.4, 0),
		color,
		folder
	)
	setDecor(tank)

	local roof = newPart(
		string.format("WaterRoof_%d", index),
		Vector3.new(tankDiameter * 0.5, height * 0.16, tankDiameter * 0.5),
		base * CFrame.new(0, legHeight + height * 0.86, 0),
		color:Lerp(UI.INK, 0.25),
		folder
	)
	setDecor(roof)
end

DECOR_BUILDERS.stand = function(folder, def, base, index)
	local height = def.height or 44
	local width = def.width or 120
	local color = def.color or Color3.fromRGB(238, 240, 244)
	local accent = def.accent or Color3.fromRGB(232, 84, 78)

	-- Three tiers stepping up and away from the track.
	for tier = 1, 3 do
		local tierHeight = height * (0.34 + 0.22 * (tier - 1))
		local deck = newPart(
			string.format("Stand_%d_%d", index, tier),
			Vector3.new(width, tierHeight, height * 0.42),
			base * CFrame.new(0, tierHeight * 0.5, -height * 0.42 * (tier - 1)),
			tier % 2 == 0 and color:Lerp(UI.INK, 0.10) or color,
			folder
		)
		setDecor(deck)

		local crowd = newPart(
			string.format("StandCrowd_%d_%d", index, tier),
			Vector3.new(width * 0.96, height * 0.07, height * 0.06),
			base * CFrame.new(0, tierHeight, -height * 0.42 * (tier - 1) + height * 0.2),
			accent,
			folder
		)
		setDecor(crowd)
	end

	-- The roof sits ON the back tier and stands on two front posts. Floated free (it
	-- was at 0.94 height with nothing under it) it read as a slab hanging in the air.
	local roofY = height * 0.80
	local roof = newPart(
		string.format("StandRoof_%d", index),
		Vector3.new(width * 1.04, height * 0.08, height * 1.35),
		base * CFrame.new(0, roofY, -height * 0.42),
		color:Lerp(UI.INK, 0.2),
		folder
	)
	setDecor(roof)

	for post = -1, 1, 2 do
		local column = newPart(
			string.format("StandPost_%d_%d", index, post),
			Vector3.new(height * 0.07, roofY, height * 0.07),
			base * CFrame.new(width * 0.46 * post, roofY * 0.5, height * 0.2),
			color:Lerp(UI.INK, 0.3),
			folder
		)
		setDecor(column)
	end
end

DECOR_BUILDERS.mast = function(folder, def, base, index)
	local height = def.height or 90
	local color = def.color or Color3.fromRGB(210, 214, 222)

	local pole = newPart(
		string.format("Mast_%d", index),
		Vector3.new(height * 0.045, height, height * 0.045),
		base * CFrame.new(0, height * 0.5, 0),
		color,
		folder
	)
	setDecor(pole)

	local head = newPart(
		string.format("MastHead_%d", index),
		Vector3.new(height * 0.4, height * 0.06, height * 0.1),
		base * CFrame.new(0, height, 0),
		color:Lerp(UI.INK, 0.35),
		folder
	)
	setDecor(head)

	for lamp = -1, 1, 2 do
		local panel = newPart(
			string.format("MastLamp_%d_%d", index, lamp),
			Vector3.new(height * 0.15, height * 0.05, height * 0.05),
			base * CFrame.new(height * 0.11 * lamp, height * 0.97, height * 0.04),
			def.accent or Color3.fromRGB(255, 246, 200),
			folder
		)
		panel.Material = Enum.Material.Neon
		setDecor(panel)
	end
end

DECOR_BUILDERS.banner = function(folder, def, base, index)
	local height = def.height or 12
	local width = def.width or 44
	local color = def.color or Color3.fromRGB(46, 52, 64)

	local panel = newPart(
		string.format("Banner_%d", index),
		Vector3.new(width, height, height * 0.2),
		base * CFrame.new(0, height * 0.9, 0),
		color,
		folder
	)
	setDecor(panel)

	local stripe = newPart(
		string.format("BannerStripe_%d", index),
		Vector3.new(width * 0.9, height * 0.28, height * 0.24),
		base * CFrame.new(0, height * 0.9, 0),
		def.accent or Color3.fromRGB(255, 214, 64),
		folder
	)
	setDecor(stripe)

	for post = -1, 1, 2 do
		local leg = newPart(
			string.format("BannerPost_%d_%d", index, post),
			Vector3.new(height * 0.16, height * 0.9, height * 0.16),
			base * CFrame.new(width * 0.44 * post, height * 0.45, 0),
			color:Lerp(UI.PAPER, 0.2),
			folder
		)
		setDecor(leg)
	end
end

--[[ The apron is the ground the scenery stands on — without it the world outside the
	wall is void and every prop looks like it is floating.

	It is a grid of tiles with the arena footprint CUT OUT, not one big plate. Two
	reasons, both found the hard way: a plate that spans the footprint shows through
	every pit a few studs down, so a 258-stud shaft reads as a painted-on square; and a
	part wider than 2048 studs is silently clamped, which tears gaps in the ground.

	Non-collidable on purpose: a car thrown out of the arena has to keep falling to
	FALL_KILL_Y rather than landing on the scenery. ]]
local function buildApron(parent: Instance)
	local outer = CFG.SIZE * APRON_SIZE_ARENAS * 0.5
	local footprint = CFG.SIZE + CFG.WALL_THICKNESS * 2
	local hole = rectFrom(CFG.ORIGIN.X, CFG.ORIGIN.Z, footprint, footprint)
	local tiles = math.max(2, math.ceil((outer * 2) / (CFG.SIZE * APRON_TILE_ARENAS)))
	local tileSize = (outer * 2) / tiles
	local y = CFG.ORIGIN.Y - APRON_TOP_DROP - APRON_THICKNESS * 0.5

	for ix = 0, tiles - 1 do
		for iz = 0, tiles - 1 do
			local pieces = {}
			subtractRect(
				rectFrom(
					CFG.ORIGIN.X - outer + tileSize * (ix + 0.5),
					CFG.ORIGIN.Z - outer + tileSize * (iz + 0.5),
					tileSize,
					tileSize
				),
				hole,
				pieces
			)

			for pieceIndex, piece in ipairs(pieces) do
				local slab = newPart(
					string.format("Apron_%d_%d_%d", ix, iz, pieceIndex),
					Vector3.new(piece.maxX - piece.minX, APRON_THICKNESS, piece.maxZ - piece.minZ),
					CFrame.new((piece.minX + piece.maxX) * 0.5, y, (piece.minZ + piece.maxZ) * 0.5),
					activeMap.GROUND_COLOR,
					parent
				)
				setDecor(slab)
			end
		end
	end
end

local function buildDecor(parent: Instance)
	local decor = activeMap.DECOR
	if not decor or #decor == 0 then
		return
	end
	local folder = newFolder(DECOR_FOLDER, parent)
	local groundY = CFG.ORIGIN.Y - APRON_TOP_DROP
	local warnedKinds = {}

	for index, def in ipairs(decor) do
		local builder = DECOR_BUILDERS[def.kind]
		if not builder then
			if not warnedKinds[def.kind] then
				warnedKinds[def.kind] = true
				warn("ArenaService: no decor builder for kind " .. tostring(def.kind))
			end
			continue
		end

		local dx, dz = worldXZ(def.offset)
		builder(folder, def, CFrame.new(dx, groundY, dz) * CFrame.Angles(0, math.rad(def.rotY or 0), 0), index)
	end
end

-- ==========================================================================
-- spawn ring
-- ==========================================================================
local function ringPos(angle: number, radius: number): Vector3
	return Vector3.new(
		CFG.ORIGIN.X + math.cos(angle) * radius,
		CFG.ORIGIN.Y + CFG.SPAWN_HEIGHT,
		CFG.ORIGIN.Z + math.sin(angle) * radius
	)
end

-- A slot is usable only over real floor, off the berm, and clear of blocks/ramps.
local function isSpawnClear(pos: Vector3): boolean
	if not ArenaService.isInside(pos) then
		return false
	end
	local limit = CFG.SIZE * 0.5 - bankInset() - SPAWN_BANK_MARGIN
	if math.abs(pos.X - CFG.ORIGIN.X) > limit or math.abs(pos.Z - CFG.ORIGIN.Z) > limit then
		return false
	end
	return not inAnyRect(pos.X, pos.Z, obstacleRects, SPAWN_CLEARANCE)
end

--[[ Ring slots can land in a pit or inside a block (the config ring radius grazes
	both), so nudge the angle either way before falling back to a tighter radius.
	Never returns nil — a bad spawn beats no spawn. Runs AFTER pits/blocks. ]]
local function resolveSpawnPos(baseAngle: number): Vector3
	for attempt = 0, SPAWN_NUDGE_TRIES do
		local step = math.ceil(attempt * 0.5)
		local sign = (attempt % 2 == 0) and 1 or -1
		local pos = ringPos(baseAngle + math.rad(SPAWN_NUDGE_DEG * step * sign), CFG.SPAWN_RING_RADIUS)
		if isSpawnClear(pos) then
			return pos
		end
	end

	local fallback = ringPos(baseAngle, CFG.SPAWN_RING_RADIUS * SPAWN_SHRINK)
	if not isSpawnClear(fallback) then
		warn(string.format("ArenaService: no clear spawn slot near %.0f deg on %s", math.deg(baseAngle), tostring(activeMap.id)))
	end
	return fallback
end

local function buildSpawnPoints()
	spawnPoints = {}
	local count = math.max(1, CFG.SPAWN_COUNT)

	for index = 0, count - 1 do
		local pos = resolveSpawnPos((index / count) * math.pi * 2)
		-- Face the middle so a fresh car is already pointed at the action.
		spawnPoints[index + 1] = CFrame.lookAt(pos, Vector3.new(CFG.ORIGIN.X, pos.Y, CFG.ORIGIN.Z))
	end
end

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
-- lighting
-- ==========================================================================
local function applyLighting()
	local sky = activeMap.SKY or {}

	Lighting.Ambient = sky.ambient or LIGHT_AMBIENT
	Lighting.OutdoorAmbient = sky.outdoor or LIGHT_OUTDOOR_AMBIENT
	Lighting.Brightness = LIGHT_BRIGHTNESS
	Lighting.ClockTime = sky.clock or LIGHT_CLOCK_TIME
	Lighting.GeographicLatitude = LIGHT_LATITUDE
	Lighting.ExposureCompensation = LIGHT_EXPOSURE
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = LIGHT_SHADOW_SOFTNESS
	Lighting.EnvironmentDiffuseScale = LIGHT_ENV_DIFFUSE
	Lighting.EnvironmentSpecularScale = LIGHT_ENV_SPECULAR
	Lighting.FogColor = sky.fog or LIGHT_FOG_COLOR
	-- Haze starts past the far wall so it only ever softens the skyline.
	Lighting.FogStart = CFG.SIZE * FOG_START_ARENAS
	Lighting.FogEnd = CFG.SIZE * FOG_END_ARENAS

	-- Engine refuses scripted writes to Technology (RobloxScript capability), so
	-- this is a soft set and the place property is the real source of truth.
	local okTech = pcall(function()
		Lighting.Technology = LIGHT_TECHNOLOGY
	end)
	if not okTech then
		warn("ArenaService: Lighting.Technology is place-authored — set it in Studio > Lighting")
	end

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Density = ATMOS_DENSITY
	atmosphere.Offset = ATMOS_OFFSET
	atmosphere.Color = sky.atmosphere or ATMOS_COLOR
	atmosphere.Decay = ATMOS_DECAY
	atmosphere.Glare = ATMOS_GLARE
	atmosphere.Haze = sky.haze or ATMOS_HAZE
	atmosphere.Parent = Lighting

	local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect") or Instance.new("SunRaysEffect")
	sunRays.Intensity = SUNRAYS_INTENSITY
	sunRays.Spread = SUNRAYS_SPREAD
	sunRays.Enabled = true
	sunRays.Parent = Lighting

	local bloom = Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect")
	bloom.Intensity = BLOOM_INTENSITY
	bloom.Size = BLOOM_SIZE
	bloom.Threshold = BLOOM_THRESHOLD
	bloom.Enabled = true
	bloom.Parent = Lighting

	-- Blur costs frames and hides the traffic you are about to hit. Off.
	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if dof then
		dof.Enabled = false
	end
end

-- Blank-place leftovers. Removed in code, never by hand, so a rebuild is enough.
local function clearScratchInstances()
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("SpawnLocation") or (child.Name == SCRATCH_BASEPLATE and child:IsA("BasePart")) then
			child:Destroy()
		end
	end
end

-- ==========================================================================
-- map selection
-- ==========================================================================
--[[ Studio can pin one map so a layout can be iterated on without waiting for the
	rotation to come back round. Production always rotates. ]]
local function forcedIndex(): number?
	if not RunService:IsStudio() then
		return nil
	end
	return Maps.indexOf(Config.TEST.FORCE_MAP)
end

local function selectMap(index: number)
	local count = Maps.count()
	if count == 0 then
		warn("ArenaService: Maps.LIST is empty — nothing to build")
		return
	end
	activeIndex = ((index - 1) % count) + 1
	activeMap = Maps.LIST[activeIndex]
end

-- ==========================================================================
-- public API
-- ==========================================================================
--[[ Tears down any previous arena and rebuilds the whole thing from the active map
	(or `mapId`, when given). Safe to call more than once; do NOT call it mid-round,
	it deletes the ground. ]]
function ArenaService.build(mapId: string?): Folder
	local requested = mapId and Maps.indexOf(mapId) or nil
	if mapId and not requested then
		warn("ArenaService: unknown map id " .. tostring(mapId) .. " — keeping " .. tostring(activeMap.id))
	end
	selectMap(forcedIndex() or requested or activeIndex)

	local existing = Workspace:FindFirstChild(ARENA_FOLDER)
	if existing then
		existing:Destroy()
	end
	clearScratchInstances()

	obstacleRects = {}
	spawnPoints = {}

	local folder = newFolder(ARENA_FOLDER, Workspace)
	arenaFolder = folder

	buildApron(folder)
	buildFloor(folder)
	buildBanks(folder)
	buildWalls(folder)
	buildRamps(folder)
	buildPads(folder)
	buildPlateaus(folder) -- fills obstacleRects, so it must precede buildSpawnPoints
	buildBlocks(folder)
	buildMarks(folder)
	buildDecor(folder)
	buildSpawnPoints() -- needs obstacleRects from ramps + blocks

	applyLighting()

	-- Late joiners and the lobby UI read the map off these, not off a remote.
	core:SetAttribute(ATTR.MAP_ID, activeMap.id)
	core:SetAttribute(ATTR.MAP_NAME, activeMap.name)

	return folder
end

--[[ Rotates to the next map and rebuilds. MatchService calls this at the top of Lobby,
	the only window where destroying the ground is safe: cars are despawned, pickups
	stopped, and nobody is driving. ]]
function ArenaService.nextMap(): Folder
	selectMap(activeIndex + 1)
	return ArenaService.build()
end

function ArenaService.getMap()
	return activeMap
end

function ArenaService.getMapId(): string
	return activeMap.id
end

function ArenaService.getFolder(): Folder?
	return arenaFolder
end

function ArenaService.getSpawnPoints(): { CFrame }
	return table.clone(spawnPoints)
end

--[[ The spawn slot furthest from every live car, random among ties, so nobody
	ever lands on top of somebody. Falls back to the arena centre if the ring is
	somehow empty. ]]
function ArenaService.randomSpawn(): CFrame
	if #spawnPoints == 0 then
		warn("ArenaService: randomSpawn called before build — using arena centre")
		return CFrame.new(CFG.ORIGIN + Vector3.new(0, CFG.SPAWN_HEIGHT, 0))
	end

	local cars = liveCarPositions()
	local best: { CFrame } = {}
	local bestScore = -math.huge

	for _, slot in ipairs(spawnPoints) do
		local nearest = math.huge
		for _, carPos in ipairs(cars) do
			local dx = slot.Position.X - carPos.X
			local dz = slot.Position.Z - carPos.Z
			local dist = math.sqrt(dx * dx + dz * dz)
			if dist < nearest then
				nearest = dist
			end
		end

		if nearest > bestScore + SPAWN_TIE_EPSILON then
			best = { slot }
			bestScore = nearest
		elseif nearest >= bestScore - SPAWN_TIE_EPSILON then
			table.insert(best, slot)
			bestScore = math.max(bestScore, nearest)
		end
	end

	if #best == 0 then
		return spawnPoints[rng:NextInteger(1, #spawnPoints)]
	end
	return best[rng:NextInteger(1, #best)]
end

--[[ A point on the floor for PickupService: clear of the walls AND the berm, never
	over a pit, never buried inside a block or ramp. Y is the floor surface — the
	caller adds its own hover. ]]
function ArenaService.randomGroundPoint(inset: number?): Vector3
	local margin = (type(inset) == "number") and inset or Config.PICKUPS.SPAWN_INSET
	margin = math.max(margin, bankInset() + BANK_MARGIN)
	local limit = math.max(activeMap.TILE_STUDS * 0.5, CFG.SIZE * 0.5 - margin)

	for _ = 1, GROUND_POINT_TRIES do
		local x = CFG.ORIGIN.X + rng:NextNumber(-limit, limit)
		local z = CFG.ORIGIN.Z + rng:NextNumber(-limit, limit)
		if
			not inAnyRect(x, z, obstacleRects, OBSTACLE_MARGIN)
		then
			return Vector3.new(x, CFG.ORIGIN.Y, z)
		end
	end

	warn("ArenaService: randomGroundPoint exhausted its tries — using arena centre")
	return CFG.ORIGIN
end

--[[ Inside the arena footprint? XZ test only, so it works for cars mid-air too.

	isInside and isInBounds are the SAME test now and both are kept on purpose. They
	stopped differing the moment the floor lost its holes: there used to be somewhere
	inside the footprint you could not stand (a pit, later a lava slab), so callers had
	to say which they meant — "is there world here" (projectiles) or "could a player be
	here" (spawn slots, pickup placement, death drops). Plateaus are ordinary solid
	geometry that pickups and spawns dodge via obstacleRects instead, so the distinction
	has no content. Keep both names: if a future map ever reintroduces unstandable ground
	the callers are already sorted into the right two groups. ]]
function ArenaService.isInBounds(pos: Vector3): boolean
	local half = CFG.SIZE * 0.5
	return math.abs(pos.X - CFG.ORIGIN.X) <= half and math.abs(pos.Z - CFG.ORIGIN.Z) <= half
end

function ArenaService.isInside(pos: Vector3): boolean
	return ArenaService.isInBounds(pos)
end

function ArenaService.init(ctx)
	ctxRef = ctx
	-- Start somewhere different each server so the same map is not always first.
	selectMap(rng:NextInteger(1, math.max(1, Maps.count())))
	ArenaService.build()
end

return ArenaService
