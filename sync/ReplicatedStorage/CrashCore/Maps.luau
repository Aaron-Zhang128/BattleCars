--[[ Maps
	The four playable arenas, as pure data. ArenaService.build() reads exactly one of
	these per round; nothing in this module touches the world.

	SCALE — every number here is in REFERENCE studs (Config.ARENA.REFERENCE_SIZE, the
	original 420-stud layout) and is multiplied by Config.ARENA.SCALE on the way out
	through xz() / box() / n(). Retuning Config.ARENA.SIZE therefore moves every ramp,
	pit, prop and margin with it — which is exactly what the 420 -> 903 rebuild for the
	real car models had to do by hand. Author in reference studs, always.

	Every field is OPTIONAL — each map's metatable falls back to Config.ARENA, which
	holds what must stay identical on every map: ORIGIN, SIZE, FLOOR_THICKNESS,
	WALL_THICKNESS, the spawn ring and PAD_SIZE. SIZE and ORIGIN especially:
	CameraController reads them at module load for its lobby orbit and SpawnService
	caches ARENA_HALF for its out-of-bounds test, and neither re-reads on a map change.
	A map that resized the floor would silently desync both. Variety therefore comes
	from what is ON the floor, never from its footprint.

	SCHEMA (all lengths in reference studs)
		id / name / blurb             identity; `name` replicates as Config.ATTR.MAP_NAME
		FLOOR_COLOR / FLOOR_ACCENT    the checker pair
		FLOOR_TEXTURE                 baseplate grid laid over the tiles, TINTED by the
		                              checker colour. Inherited; "" = a plain floor.
		TILE_STUDS                    checker size. Cosmetic only: pits are cut to the
		                              exact rect, so tiles never quantise a hole.
		GROUND_COLOR                  the apron plane that fills the void outside the walls
		BANK_DEPTH / BANK_HEIGHT      sloped perimeter berm you can drive up (0 = none)
		BANK_COLOR / BANK_COLOR_ALT   ALT + BANK_SEGMENTS paints racing kerb stripes
		BANK_SEGMENTS                 wedges per side; 1 = one clean slope
		WALL_COLOR / WALL_HEIGHT / TRIM_COLOR
		BLOCK_COLOR / PAD_COLOR / PLATEAU_COLOR
		SKY = { clock, fog, outdoor, ambient, atmosphere, haze }
		RAMPS   { offset, size, rotY, tilt }  rotY aims AT the centre; takeoff faces in
		PADS    { offset, rotY }              the arrow is cosmetic — the boost runs
		                                      along the CAR's heading (ChassisController)
		PLATEAUS { offset, size }             exact XZ rect, raised into a solid mesa
		                                      with drivable wedge skirts on all four
		                                      sides. Nothing here is ever a hole
		BLOCKS  { offset, size }              solid, drivable on top, ram target
		MARKS   { kind, ... }                 flat floor paint: rect | disc | ring | checker
		DECOR   { kind, offset, ... }         scenery, ALWAYS outside the walls and never
		                                      collidable, so it cannot affect a round

	JUMP MATH — the one thing you cannot eyeball. A ramp launches at TOP_SPEED 193.5
	with gravity 196.2, so a 17 degree ramp of reference depth 34 (73 studs, 22 high)
	throws a car about 150 studs — roughly 70 reference studs. Gaps meant to be crossed
	are sized under that with margin; Rooftops' 28 (60 stud) streets are crossable at
	about half speed and fatal below it, which is the entire map. Re-check this before
	widening any gap or changing Config.CHASSIS.TOP_SPEED.

	ART DIRECTION (all four share it — this is the look, the theme is the variation)
		Near-white checker floor, flat SmoothPlastic, no textures. The boundary is a
		sloped berm rather than a flat wall, so the arena reads as a dish. One saturated
		accent per map (pads / kerbs / trim) against a desaturated pastel body.
		Everything you can hit is a solid block with a lighter cap; everything you
		cannot is decor, and decor never stands inside the walls.

	Consumers: ArenaService only. The DECOR `kind` strings are a contract with that
	service's prop builders — a new kind here needs a builder there.
]]

local Config = require(script.Parent:WaitForChild("Config"))

local SCALE = Config.ARENA.SCALE

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Reference studs -> live studs. Every length in this file goes through one of these.
local function n(value: number): number
	return value * SCALE
end

local function xz(x: number, z: number): Vector2
	return Vector2.new(x * SCALE, z * SCALE)
end

local function box(x: number, y: number, z: number): Vector3
	return Vector3.new(x * SCALE, y * SCALE, z * SCALE)
end

-- Pads evenly around a ring, each yawed along the racing line. rotY = -deg because a
-- part's local +Z maps to (sin yaw, cos yaw), and the CCW tangent at `deg` is
-- (-sin deg, cos deg).
local function ringPads(radius: number, count: number, startDeg: number)
	local out = {}
	for index = 0, count - 1 do
		local deg = startDeg + (360 / count) * index
		local rad = math.rad(deg)
		out[index + 1] = {
			offset = xz(math.cos(rad) * radius, math.sin(rad) * radius),
			rotY = -deg,
		}
	end
	return out
end

-- Bearing from the arena to the mountaintop hub. The valley wall opens up along it so
-- the plaza can see the map — derived, not typed, so moving Config.LOBBY moves the gap.
local LOBBY_BEARING_DEG = math.deg(
	math.atan2(Config.LOBBY.ORIGIN.Z - Config.ARENA.ORIGIN.Z, Config.LOBBY.ORIGIN.X - Config.ARENA.ORIGIN.X)
)

--[[ Scenery evenly around a ring outside the walls. `vary` cycles a size multiplier so a
	skyline or a tree line never reads as a stamped pattern — deterministic on purpose,
	because this module is required on both sides and random data would differ per peer.
	`skipHalfDeg` opens an arc facing the hub, so a ridge line never walls off the view
	from the lobby down into the valley. ]]
local function ringDecor(kind: string, radius: number, count: number, startDeg: number, opts)
	local vary = opts.vary or { 1 }
	local out = {}
	for index = 0, count - 1 do
		local deg = startDeg + (360 / count) * index
		local skip = false
		if opts.skipHalfDeg then
			local delta = math.abs(((deg - LOBBY_BEARING_DEG + 180) % 360) - 180)
			skip = delta <= opts.skipHalfDeg
		end

		if not skip then
			local rad = math.rad(deg)
			local scale = vary[(index % #vary) + 1]
			table.insert(out, {
				kind = kind,
				offset = xz(math.cos(rad) * radius, math.sin(rad) * radius),
				-- Face the arena so flat-fronted props (stands, banners, towers) present
				-- their good side. Same tangent identity as ringPads, turned 180.
				rotY = -deg + 180,
				height = opts.height and n(opts.height * scale) or nil,
				width = opts.width and n(opts.width * scale) or nil,
				color = opts.color,
				accent = opts.accent,
			})
		end
	end
	return out
end

local function append(into, from)
	for _, entry in ipairs(from) do
		table.insert(into, entry)
	end
	return into
end

local Maps = {}

-- ==========================================================================
-- 1 — SAND BOWL. The reference look: a wide open banked dish with nothing in the
-- middle to hide behind, and two sinkholes to shove people into. This is the
-- shipped layout plus the berm, the paint and a skyline.
-- ==========================================================================
local SANDBOWL = {
	id = "sandbowl",
	name = "Sand Bowl",
	blurb = "Wide open desert dish. Two sinkholes, nowhere to hide.",

	FLOOR_COLOR = rgb(240, 241, 244),
	FLOOR_ACCENT = rgb(216, 222, 231),
	TILE_STUDS = n(42),
	GROUND_COLOR = rgb(214, 182, 132),

	BANK_DEPTH = n(36),
	BANK_HEIGHT = n(13),
	BANK_COLOR = rgb(222, 192, 142),
	WALL_HEIGHT = n(34),
	WALL_COLOR = rgb(192, 160, 112),
	TRIM_COLOR = rgb(240, 220, 178),

	BLOCK_COLOR = rgb(198, 168, 122),
	PAD_COLOR = rgb(255, 214, 64),
	SKY = {
		clock = 14,
		fog = rgb(236, 226, 204),
		outdoor = rgb(150, 146, 138),
		ambient = rgb(96, 94, 90),
		atmosphere = rgb(226, 214, 192),
		haze = 1.0,
	},

	-- Four inward launches at the cardinals; the centre pad is the crown fight.
	RAMPS = {
		{ offset = xz(0, 96), size = box(52, 3, 36), rotY = 0, tilt = 15 },
		{ offset = xz(0, -96), size = box(52, 3, 36), rotY = 180, tilt = 15 },
		{ offset = xz(96, 0), size = box(52, 3, 36), rotY = 90, tilt = 15 },
		{ offset = xz(-96, 0), size = box(52, 3, 36), rotY = -90, tilt = 15 },
	},
	PADS = {
		{ offset = xz(0, 0), rotY = 0 },
		{ offset = xz(76, 76), rotY = 45 },
		{ offset = xz(-76, 76), rotY = -45 },
		{ offset = xz(76, -76), rotY = 135 },
		{ offset = xz(-76, -76), rotY = -135 },
	},
	PLATEAUS = {
		{ offset = xz(126, 126), size = xz(54, 54) },
		{ offset = xz(-126, -126), size = xz(54, 54) },
	},
	BLOCKS = {
		{ offset = xz(150, -50), size = box(18, 13, 46) },
		{ offset = xz(-150, 50), size = box(18, 13, 46) },
		{ offset = xz(50, 150), size = box(46, 13, 18) },
		{ offset = xz(-50, -150), size = box(46, 13, 18) },
		{ offset = xz(88, -88), size = box(26, 11, 26) },
		{ offset = xz(-88, 88), size = box(26, 11, 26) },
	},
	MARKS = {
		{ kind = "ring", offset = xz(0, 0), radius = n(130), width = n(3), color = rgb(226, 214, 190) },
		{ kind = "disc", offset = xz(0, 0), radius = n(30), color = rgb(232, 220, 196) },
	},
}
SANDBOWL.DECOR = append(
	append(
		append(
			-- The valley wall. Everything closer than this is dressing; this is the horizon.
			ringDecor("ridge", 560, 12, 15, { height = 150, width = 210, color = rgb(172, 142, 104), accent = rgb(206, 180, 142), skipHalfDeg = 42, vary = { 1, 1.35, 0.78, 1.15 } }),
			ringDecor("dune", 320, 14, 0, { height = 44, width = 210, color = rgb(214, 182, 132), vary = { 1, 1.4, 0.75, 1.15 } })
		),
		ringDecor("rock", 258, 10, 18, { height = 26, color = rgb(176, 146, 104), vary = { 1, 0.7, 1.3 } })
	),
	ringDecor("cactus", 250, 8, 22.5, { height = 30, color = rgb(120, 168, 108), vary = { 1, 0.75, 1.25 } })
)

-- ==========================================================================
-- 2 — FROSTBITE. One enormous hole in the middle with a boost ring around it, so
-- the whole map is a game of chicken on the rim.
-- ==========================================================================
local FROSTBITE = {
	id = "frostbite",
	name = "Frostbite",
	blurb = "A frozen crater with a speed ring around the rim. Don't get nudged.",

	FLOOR_COLOR = rgb(238, 246, 252),
	FLOOR_ACCENT = rgb(212, 230, 246),
	TILE_STUDS = n(30),
	GROUND_COLOR = rgb(232, 241, 248),

	BANK_DEPTH = n(30),
	BANK_HEIGHT = n(11),
	BANK_COLOR = rgb(220, 235, 246), -- a hair deeper than the ice, or the rim vanishes
	WALL_HEIGHT = n(32),
	WALL_COLOR = rgb(158, 196, 222),
	TRIM_COLOR = rgb(226, 242, 250),

	BLOCK_COLOR = rgb(186, 220, 240),
	PAD_COLOR = rgb(120, 235, 255),
	SKY = {
		clock = 16.5,
		fog = rgb(222, 236, 248),
		outdoor = rgb(146, 158, 176),
		ambient = rgb(92, 100, 116),
		atmosphere = rgb(216, 232, 246),
		haze = 1.6,
	},

	-- Launches sit at the outer edge and land well short of the rim, so a ramp is a
	-- fast reposition and never a suicide.
	RAMPS = {
		{ offset = xz(0, 150), size = box(52, 3, 36), rotY = 0, tilt = 15 },
		{ offset = xz(0, -150), size = box(52, 3, 36), rotY = 180, tilt = 15 },
		{ offset = xz(150, 0), size = box(52, 3, 36), rotY = 90, tilt = 15 },
		{ offset = xz(-150, 0), size = box(52, 3, 36), rotY = -90, tilt = 15 },
	},
	PADS = ringPads(98, 8, 0),
	PLATEAUS = {
		{ offset = xz(0, 0), size = xz(96, 96) },
		{ offset = xz(150, -150), size = xz(56, 56) },
		{ offset = xz(-150, 150), size = xz(56, 56) },
	},
	BLOCKS = {
		{ offset = xz(150, 150), size = box(34, 12, 34) },
		{ offset = xz(-150, -150), size = box(34, 12, 34) },
		{ offset = xz(112, -112), size = box(26, 11, 26) },
		{ offset = xz(-112, 112), size = box(26, 11, 26) },
	},
	MARKS = {
		{ kind = "ring", offset = xz(0, 0), radius = n(70), width = n(2.5), color = rgb(126, 178, 214) },
		{ kind = "ring", offset = xz(0, 0), radius = n(122), width = n(2), color = rgb(196, 220, 238) },
		{ kind = "ring", offset = xz(112, 112), radius = n(34), width = n(2), color = rgb(196, 220, 238) },
		{ kind = "ring", offset = xz(-112, -112), radius = n(34), width = n(2), color = rgb(196, 220, 238) },
	},
}
FROSTBITE.DECOR = append(
	append(
		append(
			ringDecor("ridge", 560, 12, 15, { height = 180, width = 205, color = rgb(146, 168, 190), accent = rgb(240, 247, 252), skipHalfDeg = 42, vary = { 1, 1.4, 0.75, 1.2 } }),
			ringDecor("mound", 300, 12, 15, { height = 34, width = 180, color = rgb(240, 247, 252), vary = { 1, 1.3, 0.8 } })
		),
		ringDecor("pine", 252, 14, 0, { height = 46, color = rgb(58, 96, 84), accent = rgb(238, 246, 252), vary = { 1, 0.72, 1.28, 0.9 } })
	),
	ringDecor("spike", 236, 8, 22.5, { height = 54, color = rgb(178, 216, 240), vary = { 1, 1.35, 0.7 } })
)

-- ==========================================================================
-- 3 — ROOFTOPS. The floor itself is the hazard: a cross of open street splits it
-- into four roofs, joined by a perimeter loop and four ramp jumps. See the jump
-- math in the header before touching the street width.
-- ==========================================================================
local ROOFTOPS = {
	id = "rooftops",
	name = "Rooftops",
	blurb = "Four roofs, one long way round, and four jumps for everyone else.",

	FLOOR_COLOR = rgb(228, 230, 234),
	FLOOR_ACCENT = rgb(206, 210, 218),
	TILE_STUDS = n(42),
	GROUND_COLOR = rgb(96, 100, 112),

	-- No berm: a roof ends in a parapet, and the drop past it is the point.
	BANK_DEPTH = 0,
	BANK_HEIGHT = 0,
	WALL_HEIGHT = n(22),
	WALL_COLOR = rgb(168, 172, 182),
	TRIM_COLOR = rgb(250, 196, 72),

	BLOCK_COLOR = rgb(196, 200, 208),
	PAD_COLOR = rgb(255, 214, 64),
	SKY = {
		clock = 17.2,
		fog = rgb(250, 224, 196),
		outdoor = rgb(168, 152, 140),
		ambient = rgb(98, 92, 96),
		atmosphere = rgb(246, 222, 200),
		haze = 1.2,
	},

	RAMPS = {
		{ offset = xz(-35, 78), size = box(48, 3, 34), rotY = -90, tilt = 17 },
		{ offset = xz(35, -78), size = box(48, 3, 34), rotY = 90, tilt = 17 },
		{ offset = xz(78, 35), size = box(48, 3, 34), rotY = 0, tilt = 17 },
		{ offset = xz(-78, -35), size = box(48, 3, 34), rotY = 180, tilt = 17 },
	},
	PADS = append({
		-- One feeder behind each ramp: you need the speed to make the jump.
		{ offset = xz(-100, 78), rotY = -90 },
		{ offset = xz(100, -78), rotY = 90 },
		{ offset = xz(78, 100), rotY = 0 },
		{ offset = xz(-78, -100), rotY = 180 },
	}, ringPads(172, 4, 45)),
	PLATEAUS = {
		{ offset = xz(0, 0), size = xz(300, 28) },
		{ offset = xz(0, 0), size = xz(28, 300) },
	},
	BLOCKS = {
		{ offset = xz(95, 95), size = box(30, 14, 30) },
		{ offset = xz(-95, -95), size = box(30, 14, 30) },
		{ offset = xz(95, -95), size = box(30, 14, 30) },
		{ offset = xz(-95, 95), size = box(30, 14, 30) },
		{ offset = xz(0, 178), size = box(84, 10, 16) },
		{ offset = xz(0, -178), size = box(84, 10, 16) },
	},
	MARKS = {
		-- Hazard paint along every roof edge, so the drop reads before you are on it.
		{ kind = "rect", offset = xz(0, 17), size = xz(300, 4), color = rgb(250, 196, 72) },
		{ kind = "rect", offset = xz(0, -17), size = xz(300, 4), color = rgb(250, 196, 72) },
		{ kind = "rect", offset = xz(17, 0), size = xz(4, 300), color = rgb(250, 196, 72) },
		{ kind = "rect", offset = xz(-17, 0), size = xz(4, 300), color = rgb(250, 196, 72) },
		-- Helipad on the quiet roof.
		{ kind = "ring", offset = xz(-60, 60), radius = n(26), width = n(2.5), color = rgb(244, 246, 250) },
		{ kind = "rect", offset = xz(-66, 60), size = xz(4, 22), color = rgb(244, 246, 250) },
		{ kind = "rect", offset = xz(-54, 60), size = xz(4, 22), color = rgb(244, 246, 250) },
		{ kind = "rect", offset = xz(-60, 60), size = xz(12, 4), color = rgb(244, 246, 250) },
	},
}
--[[ The near ring sits well back: at 300 the towers crowded the parapet and read as a
	fence around the roof instead of a skyline behind it.
	This map needs no `ridge` — the skyline IS its valley wall. Both rings open an
	avenue along the hub bearing, or a 560-stud tower would stand exactly in the sight
	line from the plaza down to the roofs. ]]
ROOFTOPS.DECOR = append(
	append(
		ringDecor("tower", 345, 12, 0, { height = 175, width = 62, color = rgb(150, 156, 172), accent = rgb(252, 226, 168), skipHalfDeg = 30, vary = { 1, 1.45, 0.7, 1.2, 0.85 } }),
		ringDecor("tower", 470, 12, 15, { height = 260, width = 74, color = rgb(126, 132, 150), accent = rgb(252, 226, 168), skipHalfDeg = 30, vary = { 1, 0.72, 1.3, 0.9 } })
	),
	ringDecor("watertower", 252, 6, 30, { height = 34, color = rgb(184, 130, 96), accent = rgb(150, 100, 72), vary = { 1, 0.85, 1.15 } })
)

-- ==========================================================================
-- 4 — SPEEDWAY. A stadium oval: kerbed banking, a boost line, and a raised infield
-- you ramp onto — the only map where the high ground is a place, not a wall.
-- ==========================================================================
local SPEEDWAY = {
	id = "speedway",
	name = "Speedway",
	blurb = "Kerbed banking, a boost line, and an infield you have to jump onto.",

	FLOOR_COLOR = rgb(234, 236, 241),
	FLOOR_ACCENT = rgb(212, 218, 228),
	TILE_STUDS = n(42),
	GROUND_COLOR = rgb(170, 208, 152), -- pastel infield green; full saturation fought the floor

	BANK_DEPTH = n(40),
	BANK_HEIGHT = n(15),
	BANK_COLOR = rgb(232, 84, 78),
	BANK_COLOR_ALT = rgb(246, 248, 250),
	BANK_SEGMENTS = 14,
	WALL_HEIGHT = n(30),
	WALL_COLOR = rgb(245, 246, 248),
	TRIM_COLOR = rgb(46, 52, 64),

	BLOCK_COLOR = rgb(126, 196, 110),
	PAD_COLOR = rgb(255, 214, 64),
	SKY = {
		clock = 12.5,
		fog = rgb(226, 236, 248),
		outdoor = rgb(156, 162, 172),
		ambient = rgb(100, 104, 112),
		atmosphere = rgb(220, 232, 246),
		haze = 0.8,
	},

	-- The four ramps clear the shoulder and drop you onto the infield deck.
	RAMPS = {
		{ offset = xz(0, 92), size = box(52, 3, 36), rotY = 0, tilt = 17 },
		{ offset = xz(0, -92), size = box(52, 3, 36), rotY = 180, tilt = 17 },
		{ offset = xz(92, 0), size = box(52, 3, 36), rotY = 90, tilt = 17 },
		{ offset = xz(-92, 0), size = box(52, 3, 36), rotY = -90, tilt = 17 },
	},
	PADS = ringPads(140, 8, 22.5),
	PLATEAUS = {
		{ offset = xz(150, 150), size = xz(48, 48) },
		{ offset = xz(-150, -150), size = xz(48, 48) },
	},
	BLOCKS = {
		{ offset = xz(0, 0), size = box(130, 8, 130) },
		{ offset = xz(120, -120), size = box(26, 10, 26) },
		{ offset = xz(-120, 120), size = box(26, 10, 26) },
	},
	MARKS = {
		{ kind = "checker", offset = xz(0, -150), size = xz(180, 12), squares = 15 },
		{ kind = "ring", offset = xz(0, 0), radius = n(104), width = n(3), color = rgb(246, 248, 250) },
		{ kind = "ring", offset = xz(0, 0), radius = n(168), width = n(3), color = rgb(246, 248, 250) },
	},
}
SPEEDWAY.DECOR = append(
	append(
		append(
			ringDecor("ridge", 590, 12, 15, { height = 118, width = 240, color = rgb(126, 158, 116), accent = rgb(164, 194, 148), skipHalfDeg = 42, vary = { 1, 1.3, 0.8, 1.1 } }),
			ringDecor("stand", 292, 12, 0, { height = 44, width = 130, color = rgb(238, 240, 244), accent = rgb(232, 84, 78), vary = { 1, 1, 1 } })
		),
		ringDecor("mast", 268, 8, 22.5, { height = 96, color = rgb(210, 214, 222), accent = rgb(255, 246, 200), vary = { 1 } })
	),
	ringDecor("banner", 234, 10, 18, { height = 12, width = 44, color = rgb(46, 52, 64), accent = rgb(255, 214, 64), vary = { 1 } })
)

-- ==========================================================================
-- registry
-- ==========================================================================
Maps.LIST = { SANDBOWL, FROSTBITE, ROOFTOPS, SPEEDWAY }
Maps.BY_ID = {}

for _, map in ipairs(Maps.LIST) do
	-- Anything a map leaves out comes from Config.ARENA, so a map def only has to
	-- state what makes it different.
	setmetatable(map, { __index = Config.ARENA })
	Maps.BY_ID[map.id] = map
end

function Maps.count(): number
	return #Maps.LIST
end

-- Nil for an unknown id: callers fall back to the rotation rather than to a blank world.
function Maps.get(id: string?)
	return id and Maps.BY_ID[id] or nil
end

function Maps.indexOf(id: string?): number?
	for index, map in ipairs(Maps.LIST) do
		if map.id == id then
			return index
		end
	end
	return nil
end

return Maps
