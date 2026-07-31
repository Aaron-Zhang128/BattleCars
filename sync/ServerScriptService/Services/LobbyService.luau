--[[ LobbyService
	The hub: a raked terrace cut into the summit of the biggest rock in the rim that
	rings the arena, built once and never rebuilt. For the whole Lobby phase players are
	ON FOOT up here as their ordinary
	Roblox character, watching the valley; when the round starts the character is
	destroyed and SpawnService drops them a car into the arena below (dropInAll).

	THIS SERVICE OWNS THE ONLY HUMANOIDS IN THE GAME.
		Everywhere else the car IS the avatar and Players.CharacterAutoLoads is false —
		that stays false, because nothing may load a character except this service, and
		nothing may respawn one after death except its sweep. SpawnService owns cars,
		LobbyService owns characters, and the two never overlap: exitAll() runs before
		dropInAll(), so no player has both.
		On the client, CameraController hands the camera back to Roblox whenever a live
		character exists and there is no car, which is what gives the hub the default
		camera and the default walk/jump controls for free.

	WHY IT IS SEPARATE FROM ArenaService
		The arena is destroyed and rebuilt every Lobby as the map rotates. The hub must
		NOT be — people are standing on it. So this service owns Workspace.Lobby, builds
		it once at init, and never touches it again. Nothing here reads the active map.
		The rock RIM around the arena is here for the same reason: it never changes with
		the map, and re-cloning ~50 unions every rotation would be real cost for nothing.

	THE DECK IS FLAT, AND EVERYTHING ON IT IS BUILT IN `deckFrame`
		Config.LOBBY.DECK_TILT_DEG is 0 as of 2026-07-30 — the terrace was raked until
		then, and Config records exactly what flattening it trades away. deckFrame
		survives the change and is still how every piece up here is placed: local +Z
		points at the arena, local +Y is the deck normal, and every builder below works
		in that frame. So putting the rake back is one Config number and nothing else.
		World-axis geometry is only the rock — the rim around the arena and the crags
		around the terrace — plus the plinth that joins it to the deck.

	DATA FLOW
		Main.server  -> LobbyService.init(ctx) -> build()
		MatchService -> enterAll() at the top of Lobby, exitAll() at the top of Match
		anyone       : isOnDeck(pos) / getFolder() / randomSpawn() / getSpawnPoints()

	OWNS AT RUNTIME
		Workspace.Lobby — this service is the ONLY writer, including the SpawnLocations
		under it. They live inside that folder on purpose: ArenaService deletes stray
		SpawnLocations, but only ones parented directly to Workspace.
		Every player's Character while the hub is active.

		The deck, plinth, rim, kickers and pillars are the only collidable parts.
		Everything else up here — the emblem, the caps, and every rock in the rim and in
		the peak — is CanCollide = false, so nothing you can fall onto can strand you.

	NO COMBAT HAPPENS HERE. CombatService gates ram damage on MatchState.isMatch(), and
	there are no cars up here anyway.

	Init order: after ArenaService and before SpawnService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(core:WaitForChild("Shared"):WaitForChild("ChassisSpec"))

local CFG = Config.LOBBY

-- ==========================================================================
-- names
-- ==========================================================================
local LOBBY_FOLDER = "Lobby"
local PEAK_FOLDER = "Peak"
local RING_FOLDER = "Ring"
local DECK_FOLDER = "Deck"
local RIM_FOLDER = "Rim"
local PROPS_FOLDER = "Props"
local SPAWNS_FOLDER = "Spawns"
local PRACTICE_FOLDER = "Practice"
local CARS_FOLDER = "Cars" -- read-only; SpawnService owns it

-- ==========================================================================
-- tuning (studs; the hub is authored at live scale like the rest of the world)
-- ==========================================================================
local DECK_FRICTION = 0.35
local DECK_ELASTICITY = 0.10
local RIM_FRICTION = 0.10
local RIM_ELASTICITY = 0.45
local RIM_ELASTICITY_WEIGHT = 3
local PART_DENSITY = 1

--[[ Rock is cloned, not built, so these are knobs about CLONING A UNION rather than
	about how the rim looks — the look lives in Config.RING and Config.LOBBY's PEAK_*. ]]
local ROCKS_ASSET_FOLDER = "Rocks" -- inside CrashCore.Assets
local ROCK_YAW_STEP = 47 -- degrees turned per clone, so no two neighbours face the same way
local ROCK_TINT_SPAN = 320 -- summit height over which ROCK_LOW lerps up to ROCK_HIGH
local CRAG_DECK_MARGIN = 18 -- a crag keeps this much clear of the deck's outer rail
local PEAK_PHASE_DEG = 11 -- turns the crag ellipse so none of them sits dead centre
local VIEW_EYE_HEIGHT = 10 -- a 2.15x rig's eye above the deck, for the buttress clamp

local RIM_CAP_THICKNESS = 4
local RIM_CAP_OVERHANG = 3

local RAMP_YAW_FLIP = 180 -- same convention as ArenaService: rotY aims at the centre
local RAMP_MAX_TILT = 25 -- a hub kicker is for fun; it must never clear the rail
local RAMP_LIP_THICKNESS = 0.45
local RAMP_LIP_WIDTH = 4.8

local MARK_THICKNESS = 0.6
local MARK_LIFT = 0.2
local MARK_RING_SEGMENTS = 32
local MARK_RING_OVERLAP = 1.12

local PILLAR_INSET = 52 -- from the deck corner
local PILLAR_WIDTH = 26
local PILLAR_HEIGHT = 78
local PILLAR_CAP = 8

local EDGE_STRIPE_DEPTH = 7 -- bright line along the rail, so the drop reads at speed
local EDGE_STRIPE_INSET = 11

local OBSTACLE_MARGIN = 26 -- a spawn slot keeps this clear of ramps/pads/pillars
local SPAWN_TIE_EPSILON = 12
local SPAWN_NUDGE_DEG = 9
local SPAWN_NUDGE_TRIES = 8

-- ==========================================================================
-- state
-- ==========================================================================
local LobbyService = {}

local ctxRef = nil
local lobbyFolder: Folder? = nil
local spawnPoints: { CFrame } = {}
local obstacleRects = {} -- deck-LOCAL rects; spawn slots are resolved in the same frame
local rng = Random.new()

--[[ TWO ways to belong in the hub, and everything that used to test `hubActive`
	tests inHub() instead.

	`hubActive` is the PHASE gate: everybody belongs up there between enterAll() and
	exitAll(). `hubGuests` is per-player, and it is what lets somebody be in the hub
	while a ROUND is running -- a player who is out of lives is admitted individually
	(MatchService.sweepEliminated -> LobbyService.admit) instead of sitting bodyless in
	an empty camera until the round ends, which in Elimination is most of three minutes.

	A guest that only passed the door check would not survive: enterHub re-tests after
	LoadCharacter yields, and the sweep decides who gets looked after. Miss either and a
	guest is destroyed the moment they finish loading, or is never picked up after a
	fall. ]]
local hubActive = false -- true between enterAll() and exitAll()
local hubGuests = {} -- [Player] = true: individually admitted while a round runs
local charactersByPlayer = {} -- [Player] = Model
local loadingByPlayer = {} -- [Player] = true while LoadCharacter is in flight
local nextEnterAt = {} -- [Player] = earliest os.clock() we may respawn them
local sweepAccum = 0

--[[ The deck's own frame: origin at the centre of its top surface, +Y the deck normal,
	+Z downhill toward the arena. Tilting about X sends local +Z down, and Config puts
	the arena on the world +Z side of the hub, so the rake points the right way. ]]
local deckFrame = CFrame.new(CFG.ORIGIN) * CFrame.Angles(math.rad(CFG.DECK_TILT_DEG), 0, 0)

-- ==========================================================================
-- helpers
-- ==========================================================================
local function deckCFrame(x: number, y: number, z: number, yawDeg: number?): CFrame
	local cf = deckFrame * CFrame.new(x, y, z)
	if yawDeg then
		cf = cf * CFrame.Angles(0, math.rad(yawDeg), 0)
	end
	return cf
end

local function rectFrom(centerX: number, centerZ: number, sizeX: number, sizeZ: number)
	return {
		minX = centerX - sizeX * 0.5,
		maxX = centerX + sizeX * 0.5,
		minZ = centerZ - sizeZ * 0.5,
		maxZ = centerZ + sizeZ * 0.5,
	}
end

--[[ THE SUMMIT: everything the peak has to hold up. That is the terrace, plus the
	practice field behind it when Config.PRACTICE has any depth. Deck-local, +Z toward
	the arena, and it is the single source for three things that must agree — where the
	crags may stand, how far the keep-out reaches, and what counts as being up here at
	all (isOnDeck). Deriving all three from one rect is what lets the practice field be
	added or removed without re-tuning the peak or stranding anyone who walks onto it. ]]
local function summitRect()
	local front = CFG.DECK_DEPTH * 0.5
	local back = -CFG.DECK_DEPTH * 0.5
	local halfX = CFG.DECK_WIDTH * 0.5

	local practice = Config.PRACTICE
	if practice and practice.DEPTH > 0 then
		back -= practice.DEPTH
		halfX = math.max(halfX, practice.WIDTH * 0.5)
	end

	return {
		halfX = halfX,
		halfZ = (front - back) * 0.5,
		centerZ = (front + back) * 0.5,
	}
end

local function inAnyRect(x: number, z: number, rects, margin: number): boolean
	for _, rect in ipairs(rects) do
		if x >= rect.minX - margin and x <= rect.maxX + margin and z >= rect.minZ - margin and z <= rect.maxZ + margin then
			return true
		end
	end
	return false
end

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

local function setDecor(part: BasePart)
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
end

local function setPhysics(part: BasePart, friction: number, elasticity: number, weight: number)
	part.CustomPhysicalProperties = PhysicalProperties.new(PART_DENSITY, friction, elasticity, 1, weight)
end

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- ==========================================================================
-- the rim and the peak — real rock, not parts
-- ==========================================================================
--[[ Every rock in this world is a clone of one of the 65 slate unions in
	CrashCore.Assets.Rocks, and they are authored by SUMMIT HEIGHT and WIDTH — never by
	centre, never by scale factor. What you actually care about is how tall a crag
	stands next to the deck and how much horizon it covers; deriving the rest is what
	keeps a rock planted in the ground whatever size it ends up being.

	The plan factor is shared by X and Z, so a boulder keeps its own footprint shape and
	only the vertical stretch varies between rocks. That is what turns a pack of 2.4:1
	spires into squat crater rock without them reading as squashed copies of each other.

	NONE OF IT IS COLLIDABLE, and that is an improvement on the mountain it replaces:
	the old peak was a stack of collidable slabs, which is exactly how someone who went
	over the rail could strand on a ledge well above catchY with no way home. Rock is
	scenery now — fall past it and the sweep catches you.

	The unions ship with UsePartColor OFF and RenderFidelity PRECISE, so a raw clone
	would ignore Color entirely and ~66 of them would be real GPU cost for something
	nobody ever drives on. placeRock fixes both. ]]
local rockCursor = 0

local function rockTemplates(): { BasePart }
	local core = ReplicatedStorage:FindFirstChild("CrashCore")
	local assets = core and core:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild(ROCKS_ASSET_FOLDER)
	local out = {}
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(out, child)
			end
		end
	end
	if #out == 0 then
		warn("LobbyService: CrashCore.Assets." .. ROCKS_ASSET_FOLDER .. " is empty — no rim and no peak")
	end
	return out
end

-- Walk the pack in order instead of rolling for one: 65 templates covers every rock
-- these builders place, so nothing repeats until it has to.
local function nextTemplate(templates: { BasePart }): BasePart
	rockCursor += 1
	return templates[(rockCursor - 1) % #templates + 1]
end

--[[ The plan footprint of a clone. It depends on WIDTH alone and never on height, and
	splitting it out is what lets a buttress be positioned FIRST and then have its
	summit clamped against the view ray that its own final position decides. ]]
local function rockPlan(template: BasePart, width: number): Vector2
	local plan = width / template.Size.X
	return Vector2.new(template.Size.X * plan, template.Size.Z * plan)
end

-- Summit height and width in, real Size out. Y spans the buried foot to the summit.
local function rockSize(template: BasePart, width: number, topY: number): Vector3
	local plan = rockPlan(template, width)
	return Vector3.new(plan.X, topY - (CFG.FOOT_Y - CFG.BURIAL), plan.Y)
end

local function placeRock(folder: Instance, name: string, template: BasePart, size: Vector3, x: number, z: number, topY: number): BasePart
	local rock = template:Clone()
	rock.Name = name
	rock.Size = size
	rock.CFrame = CFrame.new(x, CFG.FOOT_Y - CFG.BURIAL + size.Y * 0.5, z)
		* CFrame.Angles(0, math.rad(rockCursor * ROCK_YAW_STEP), 0)
	rock.UsePartColor = true
	rock.Color = CFG.ROCK_LOW:Lerp(CFG.ROCK_HIGH, math.clamp(topY / ROCK_TINT_SPAN, 0, 1))
	rock.Material = Enum.Material.Slate
	rock.RenderFidelity = Enum.RenderFidelity.Automatic
	rock.Anchored = true
	setDecor(rock)
	rock.Parent = folder
	return rock
end

--[[ Slide (x, z) straight out from (cx, cz) until a footprint `half` wide clears the
	keep-out rect. It only ever pushes OUTWARD, so a rock that already clears is left
	exactly where the ring put it, and pushing along the radius keeps a ring a ring.
	Used twice per rock: once so nothing overhangs the terrace, once so nothing reaches
	the arena. ]]
local function pushClear(x: number, z: number, half: number, cx: number, cz: number, keepX: number, keepZ: number): (number, number)
	local dx, dz = x - cx, z - cz
	if math.abs(dx) >= keepX + half or math.abs(dz) >= keepZ + half then
		return x, z
	end
	local scale = math.huge
	if math.abs(dx) > 1e-3 then
		scale = math.min(scale, (keepX + half) / math.abs(dx))
	end
	if math.abs(dz) > 1e-3 then
		scale = math.min(scale, (keepZ + half) / math.abs(dz))
	end
	if scale == math.huge then
		return cx + keepX + half, cz -- dead centre: any direction out will do
	end
	return cx + dx * scale, cz + dz * scale
end

-- Radians between an angle and the bearing the hub stands on.
local function bearingDelta(angle: number, bearing: number): number
	return math.abs(((angle - bearing + math.pi) % (math.pi * 2)) - math.pi)
end

--[[ The rim: rows of rock around the arena so the horizon closes behind the walls and
	a map reads as a crater floor instead of a slab in an empty desert. The arc in front
	of the hub is left EMPTY — the peak fills it — and the rocks either side swell
	upward toward it, which is what makes the terrace read as part of the ridge rather
	than a building parked on one. ]]
local function buildRockRing(parent: Instance)
	local templates = rockTemplates()
	if #templates == 0 then
		return
	end

	local ring = Config.RING
	local folder = newFolder(RING_FOLDER, parent)
	local arena = Config.ARENA.ORIGIN
	local arenaKeep = Config.ARENA.SIZE * 0.5 + ring.ARENA_MARGIN
	local bearing = math.atan2(CFG.ORIGIN.Z - arena.Z, CFG.ORIGIN.X - arena.X)
	local gap = math.rad(ring.GAP_DEG) * 0.5
	local roll = Random.new(ring.SEED)

	for rowIndex, row in ipairs(ring.ROWS) do
		for index = 0, row.count - 1 do
			local angle = (index / row.count) * math.pi * 2 + math.rad(row.phase)
			local delta = bearingDelta(angle, bearing)
			if delta < gap then
				continue -- the peak stands here
			end

			-- Squared cosine: nearly full lift right beside the peak, none of it a
			-- quarter turn away, and no seam where the swell runs out.
			local lean = math.max(0, math.cos(delta))
			local topY = roll:NextNumber(row.topMin, row.topMax) + ring.SWELL * row.swell * lean * lean
			local width = roll:NextNumber(row.widthMin, row.widthMax)
			local radius = row.radius + roll:NextNumber(-row.jitter, row.jitter)

			local template = nextTemplate(templates)
			local size = rockSize(template, width, topY)
			local x, z = pushClear(
				arena.X + math.cos(angle) * radius,
				arena.Z + math.sin(angle) * radius,
				math.max(size.X, size.Z) * 0.5,
				arena.X,
				arena.Z,
				arenaKeep,
				arenaKeep
			)
			placeRock(folder, string.format("Rim_%d_%d", rowIndex, index + 1), template, size, x, z, topY)
		end
	end
end

--[[ The peak: the one rock in the ring big enough to stand on. Crags ring the terrace
	on an ellipse and get pushed outward until they clear the deck's rail, so the plaza
	ends up as the flat spot IN a summit however fat a crag turns out to be.

	The arena-facing arc gets BUTTRESSES instead — the same rock, summit held below the
	deck's front edge and set on a wider ellipse so they flank the balcony rather than
	hide under it. This is the rule the old mountain used to skip its skirt peaks there:
	anything tall in front of the terrace is the one thing standing between it and what
	it exists to look at. They double as the mask for the plinth's front face.

	THE PLINTH STAYS A PART on purpose. Its top face IS the deck underside, which is
	what guarantees there is never a seam or a sliver of sky between the raked plaza and
	the rock holding it up — a job no scattered union can be trusted with. It ends up
	almost entirely buried in crags. ]]
local function buildPeak(parent: Instance)
	local folder = newFolder(PEAK_FOLDER, parent)

	--[[ PEAK_MARGIN overhangs the plinth past the deck on the sides and the back, so the
		terrace reads as cut into rock rather than balanced on a box. It must NOT overhang
		at the FRONT: on a flat deck that 70-stud shelf sits only 26 studs below the floor
		and 70 studs out in front of it, which puts it squarely in the sight line and hid
		the arena centre from four of the ten spawn slots. Shifting the box back by half
		the margin lands its front face flush with the open edge. ]]
	local plinth = newPart(
		"Plinth",
		Vector3.new(CFG.DECK_WIDTH + CFG.PEAK_MARGIN, CFG.PLINTH_THICKNESS, CFG.DECK_DEPTH + CFG.PEAK_MARGIN),
		deckCFrame(0, -CFG.DECK_THICKNESS - CFG.PLINTH_THICKNESS * 0.5, -CFG.PEAK_MARGIN * 0.5),
		CFG.ROCK_HIGH,
		folder
	)
	plinth.Material = Enum.Material.Slate
	plinth.CastShadow = true
	setPhysics(plinth, DECK_FRICTION, DECK_ELASTICITY, 1)

	local templates = rockTemplates()
	if #templates == 0 then
		return
	end

	local arena = Config.ARENA.ORIGIN
	local arenaKeep = Config.ARENA.SIZE * 0.5 + Config.RING.ARENA_MARGIN
	--[[ Crags ring the SUMMIT, not the terrace — see summitRect. Buttresses are the one
		exception and stay keyed to ORIGIN, because they belong to the balcony. ]]
	local summit = summitRect()
	local summitAt = deckCFrame(0, 0, summit.centerZ).Position
	local keepX = summit.halfX + CFG.RIM_THICKNESS + CRAG_DECK_MARGIN
	local keepZ = summit.halfZ + CFG.RIM_THICKNESS + CRAG_DECK_MARGIN
	--[[ THE VIEW RAY, which is what a buttress summit is actually clamped to.
		The terrace's own front lip already decides how near to the arena you can see
		from up here, and a buttress must not raise that cutoff. "Keep it below the
		deck's front edge" is the obvious rule and it is WRONG: a rock 34 studs below
		the lip but 118 studs in front of it stands far higher in the field of view than
		the lip does, and it hid the arena out past its own centre. The ceiling is
		instead the ray from the deck's FRONT ROW out over the lip, evaluated at the
		buttress's own arena-side face. ]]
	local eyeW = deckCFrame(0, VIEW_EYE_HEIGHT, CFG.SPAWN_RING_Z + CFG.SPAWN_RING_Z_OFFSET).Position
	local lipW = deckCFrame(0, CFG.PARAPET_HEIGHT, CFG.DECK_DEPTH * 0.5 + CFG.RIM_THICKNESS * 0.5).Position
	local viewSlope = (lipW.Y - eyeW.Y) / math.max(1, lipW.Z - eyeW.Z)
	local function viewCeilingY(z: number): number
		return eyeW.Y + viewSlope * (z - eyeW.Z)
	end

	local toArena = Vector3.new(arena.X - CFG.ORIGIN.X, 0, arena.Z - CFG.ORIGIN.Z)
	toArena = toArena.Magnitude > 0 and toArena.Unit or Vector3.new(0, 0, 1)

	local roll = Random.new(Config.RING.SEED + 1)

	for index = 0, CFG.PEAK_COUNT - 1 do
		local angle = (index / CFG.PEAK_COUNT) * math.pi * 2 + math.rad(PEAK_PHASE_DEG)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local buttress = dir:Dot(toArena) > CFG.PEAK_CLEAR_DOT

		-- Footprint and position first; the summit is clamped against where it lands.
		local template = nextTemplate(templates)
		local width = roll:NextNumber(CFG.PEAK_WIDTH_MIN, CFG.PEAK_WIDTH_MAX)
		local plan = rockPlan(template, width)
		local half = math.max(plan.X, plan.Y) * 0.5
		local x, z
		if buttress then
			x = CFG.ORIGIN.X + dir.X * CFG.PEAK_BUTTRESS_RADIUS_X
			z = CFG.ORIGIN.Z + dir.Z * CFG.PEAK_BUTTRESS_RADIUS_Z
		else
			x = summitAt.X + dir.X * (summit.halfX + CFG.PEAK_STANDOFF)
			z = summitAt.Z + dir.Z * (summit.halfZ + CFG.PEAK_STANDOFF)
		end

		--[[ A crag has to clear the terrace, because it is tall enough to grow through
			it. A buttress must NOT be pushed off it: its summit ends up well below the
			deck, so it is free to stand under the overhang, and shoving it clear is
			exactly what would put it between the terrace and the arena. ]]
		if not buttress then
			x, z = pushClear(x, z, half, summitAt.X, summitAt.Z, keepX, keepZ)
		end
		x, z = pushClear(x, z, half, arena.X, arena.Z, arenaKeep, arenaKeep)

		local topY
		if buttress then
			-- Never above the balcony floor either: on a flat deck the view ray alone
			-- is a weak constraint, and a buttress poking past the deck underside would
			-- be visible from up there whatever the ray allows.
			local ceiling = math.min(viewCeilingY(z + half), CFG.ORIGIN.Y - CFG.DECK_THICKNESS)
			topY = ceiling - CFG.PEAK_BUTTRESS_DROP - roll:NextNumber(0, CFG.PEAK_BUTTRESS_SPREAD)
		else
			topY = CFG.ORIGIN.Y + roll:NextNumber(-CFG.PEAK_SINK, CFG.PEAK_RISE)
		end
		local size = rockSize(template, width, topY)

		placeRock(folder, string.format(buttress and "Buttress_%d" or "Crag_%d", index + 1), template, size, x, z, topY)
	end
end

-- ==========================================================================
-- the terrace
-- ==========================================================================
local function buildDeck(parent: Instance)
	local folder = newFolder(DECK_FOLDER, parent)
	local tilesX = math.max(2, math.floor(CFG.DECK_WIDTH / CFG.TILE_STUDS + 0.5))
	local tilesZ = math.max(2, math.floor(CFG.DECK_DEPTH / CFG.TILE_STUDS + 0.5))
	local sizeX = CFG.DECK_WIDTH / tilesX
	local sizeZ = CFG.DECK_DEPTH / tilesZ

	for ix = 0, tilesX - 1 do
		for iz = 0, tilesZ - 1 do
			local tile = newPart(
				string.format("Deck_%d_%d", ix, iz),
				Vector3.new(sizeX, CFG.DECK_THICKNESS, sizeZ),
				deckCFrame(
					-CFG.DECK_WIDTH * 0.5 + sizeX * (ix + 0.5),
					-CFG.DECK_THICKNESS * 0.5,
					-CFG.DECK_DEPTH * 0.5 + sizeZ * (iz + 0.5)
				),
				((ix + iz) % 2 == 0) and CFG.DECK_COLOR or CFG.DECK_ACCENT,
				folder
			)
			setPhysics(tile, DECK_FRICTION, DECK_ELASTICITY, 1)
		end
	end
end

--[[ Rim. Three tall sides keep cars on the mountain; the downhill side is a low rail
	you look straight over, because the rake already put the valley in frame. Cars
	cannot clear either — the kickers are capped at RAMP_MAX_TILT for exactly that. ]]
local function buildRim(parent: Instance)
	local folder = newFolder(RIM_FOLDER, parent)
	local halfX = CFG.DECK_WIDTH * 0.5
	local halfZ = CFG.DECK_DEPTH * 0.5
	local thickness = CFG.RIM_THICKNESS
	local spanX = CFG.DECK_WIDTH + thickness * 2
	local spanZ = CFG.DECK_DEPTH + thickness * 2

	local sides = {
		-- +Z is downhill, so this one is the parapet you watch the round from.
		{ name = "RimFront", height = CFG.PARAPET_HEIGHT, size = Vector2.new(spanX, thickness), offset = Vector2.new(0, halfZ + thickness * 0.5) },
		-- The way onto the practice field, when there is one.
		{ name = "RimBack", height = CFG.RIM_HEIGHT, size = Vector2.new(spanX, thickness), offset = Vector2.new(0, -halfZ - thickness * 0.5), gap = Config.PRACTICE and Config.PRACTICE.DEPTH > 0 and Config.PRACTICE.DOOR_WIDTH or 0 },
		{ name = "RimEast", height = CFG.RIM_HEIGHT, size = Vector2.new(thickness, spanZ), offset = Vector2.new(halfX + thickness * 0.5, 0) },
		{ name = "RimWest", height = CFG.RIM_HEIGHT, size = Vector2.new(thickness, spanZ), offset = Vector2.new(-halfX - thickness * 0.5, 0) },
	}

	for _, side in ipairs(sides) do
		--[[ A `gap` splits the side into two panels with a doorway between them, which
			is how you get from the terrace onto the practice field. Only meaningful on
			a side that runs along X; the two flanks never ask for one. ]]
		local panels = { { x = side.offset.X, width = side.size.X } }
		if side.gap and side.gap > 0 and side.size.X > side.gap then
			local width = (side.size.X - side.gap) * 0.5
			local reach = (side.gap + width) * 0.5
			panels = {
				{ x = side.offset.X - reach, width = width },
				{ x = side.offset.X + reach, width = width },
			}
		end

		for index, panel in ipairs(panels) do
			local suffix = #panels > 1 and ("_" .. index) or ""

			--[[ The invisible wall goes up EVERY side, the open one included — the front
				edge is open so you can SEE out of it, not so you can walk out of it, and
				this is what makes a railless balcony over a 330-stud drop safe. It
				follows the panels, so the doorway onto the practice field stays a
				doorway instead of being quietly sealed by something nobody can see. ]]
			if CFG.BARRIER_HEIGHT > 0 then
				local barrier = newBarrier(
					side.name .. "Barrier" .. suffix,
					Vector3.new(panel.width, CFG.BARRIER_HEIGHT, side.size.Y),
					deckCFrame(panel.x, CFG.BARRIER_HEIGHT * 0.5, side.offset.Y),
					folder
				)
				setPhysics(barrier, RIM_FRICTION, RIM_ELASTICITY, RIM_ELASTICITY_WEIGHT)
			end

			--[[ A zero height means no VISIBLE wall here, which is what the arena-facing
				side is: any rail tall enough to stop you is also tall enough to hide the
				valley from a flat deck. EdgeStripe marks the drop; the barrier holds it. ]]
			if side.height <= 0 then
				continue
			end

			local wall = newPart(
				side.name .. suffix,
				Vector3.new(panel.width, side.height, side.size.Y),
				deckCFrame(panel.x, side.height * 0.5, side.offset.Y),
				CFG.RIM_COLOR,
				folder
			)
			wall.CastShadow = true
			setPhysics(wall, RIM_FRICTION, RIM_ELASTICITY, RIM_ELASTICITY_WEIGHT)

			local cap = newPart(
				side.name .. "Cap" .. suffix,
				Vector3.new(panel.width + RIM_CAP_OVERHANG, RIM_CAP_THICKNESS, side.size.Y + RIM_CAP_OVERHANG),
				deckCFrame(panel.x, side.height, side.offset.Y),
				CFG.RIM_CAP_COLOR,
				folder
			)
			setDecor(cap)
		end
	end

	local stripe = newPart(
		"EdgeStripe",
		Vector3.new(CFG.DECK_WIDTH, MARK_THICKNESS, EDGE_STRIPE_DEPTH),
		deckCFrame(0, MARK_LIFT, halfZ - EDGE_STRIPE_INSET),
		CFG.TRIM_COLOR,
		folder
	)
	setDecor(stripe)
end

-- ==========================================================================
-- props
-- ==========================================================================
--[[ Walkable kickers. No boost pads up here: a pad's effect lives on the CAR chassis,
	so on foot one would be a promise the hub cannot keep. ]]
local function buildRamps(folder: Folder)
	for index, def in ipairs(CFG.RAMPS) do
		local tilt = math.clamp(def.tilt, 0, RAMP_MAX_TILT)
		local height = math.max(2, def.size.Z * math.tan(math.rad(tilt)))
		local yaw = def.rotY + RAMP_YAW_FLIP

		local ramp = Instance.new("WedgePart")
		ramp.Name = string.format("LobbyRamp_%d", index)
		ramp.Size = Vector3.new(def.size.X, height, def.size.Z)
		ramp.CFrame = deckCFrame(def.offset.X, height * 0.5, def.offset.Y, yaw)
		ramp.Color = CFG.DECK_ACCENT
		ramp.Material = Enum.Material.SmoothPlastic
		ramp.Anchored = true
		ramp.CanCollide = true
		ramp.CastShadow = true
		ramp.Parent = folder
		setPhysics(ramp, DECK_FRICTION, DECK_ELASTICITY, 1)

		local lip = newPart(
			string.format("LobbyRampLip_%d", index),
			Vector3.new(def.size.X, RAMP_LIP_THICKNESS, RAMP_LIP_WIDTH),
			ramp.CFrame * CFrame.new(0, height * 0.5, (def.size.Z - RAMP_LIP_WIDTH) * 0.5),
			CFG.TRIM_COLOR,
			folder
		)
		lip.Material = Enum.Material.Neon
		setDecor(lip)

		local span = math.max(def.size.X, def.size.Z)
		table.insert(obstacleRects, rectFrom(def.offset.X, def.offset.Y, span, span))
	end
end

local function buildProps(parent: Instance)
	local folder = newFolder(PROPS_FOLDER, parent)
	local halfX = CFG.DECK_WIDTH * 0.5
	local halfZ = CFG.DECK_DEPTH * 0.5

	buildRamps(folder)

	-- Corner pillars: the only tall things on the terrace, so the plaza has a shape.
	for corner = 0, 3 do
		local sx = (corner % 2 == 0) and 1 or -1
		local sz = (corner < 2) and 1 or -1
		local px = (halfX - PILLAR_INSET) * sx
		local pz = (halfZ - PILLAR_INSET) * sz

		local pillar = newPart(
			string.format("Pillar_%d", corner + 1),
			Vector3.new(PILLAR_WIDTH, PILLAR_HEIGHT, PILLAR_WIDTH),
			deckCFrame(px, PILLAR_HEIGHT * 0.5, pz),
			CFG.RIM_COLOR,
			folder
		)
		pillar.CastShadow = true
		setPhysics(pillar, RIM_FRICTION, RIM_ELASTICITY, RIM_ELASTICITY_WEIGHT)
		table.insert(obstacleRects, rectFrom(px, pz, PILLAR_WIDTH, PILLAR_WIDTH))

		local cap = newPart(
			string.format("PillarCap_%d", corner + 1),
			Vector3.new(PILLAR_WIDTH + 6, PILLAR_CAP, PILLAR_WIDTH + 6),
			deckCFrame(px, PILLAR_HEIGHT + PILLAR_CAP * 0.5, pz),
			CFG.TRIM_COLOR,
			folder
		)
		cap.Material = Enum.Material.Neon
		setDecor(cap)
	end

	-- Centre emblem: painted ring and disc, the same floor-paint language as the maps.
	local disc = newPart(
		"EmblemDisc",
		Vector3.new(MARK_THICKNESS, CFG.EMBLEM_RADIUS * 0.7, CFG.EMBLEM_RADIUS * 0.7),
		deckCFrame(0, MARK_LIFT, 0) * CFrame.Angles(0, 0, math.rad(90)),
		CFG.TRIM_COLOR,
		folder
	)
	disc.Shape = Enum.PartType.Cylinder
	setDecor(disc)

	local barLength = (2 * math.pi * CFG.EMBLEM_RADIUS / MARK_RING_SEGMENTS) * MARK_RING_OVERLAP
	for segment = 0, MARK_RING_SEGMENTS - 1 do
		local angle = (segment / MARK_RING_SEGMENTS) * math.pi * 2
		local bar = newPart(
			string.format("EmblemRing_%d", segment),
			Vector3.new(CFG.EMBLEM_WIDTH, MARK_THICKNESS, barLength),
			deckCFrame(0, MARK_LIFT, 0) * CFrame.Angles(0, -angle, 0) * CFrame.new(CFG.EMBLEM_RADIUS, 0, 0),
			CFG.TRIM_COLOR,
			folder
		)
		setDecor(bar)
	end
end

-- ==========================================================================
-- the practice field
-- ==========================================================================
--[[ Flat ground and two kickers on the same summit as the terrace, one doorway back
	through the rail. It is built in `deckFrame` like everything else up here, so it
	inherits the deck's height and its own numbers are only ever a size — there is no
	second origin to keep in sync.

	It is sized for CARS. Nothing puts a car up here yet (the Lobby is on foot and
	SpawnService gates on MatchService.canRespawn, which is Match-only), so for now this
	is a field you can run around; the ramps are the arena's own spec so that the day a
	practice car exists, what you learn here is what the arena does.

	Config.PRACTICE.DEPTH = 0 removes the whole thing: this returns early, buildRim stops
	cutting a doorway, and summitRect shrinks back to the terrace. ]]
local function buildPractice(parent: Instance)
	local practice = Config.PRACTICE
	if not practice or practice.DEPTH <= 0 then
		return
	end

	local folder = newFolder(PRACTICE_FOLDER, parent)
	local halfX = practice.WIDTH * 0.5
	local front = -CFG.DECK_DEPTH * 0.5 -- flush with the terrace's back edge: one surface
	local back = front - practice.DEPTH
	local centerZ = (front + back) * 0.5

	local tilesX = math.max(2, math.floor(practice.WIDTH / practice.TILE_STUDS + 0.5))
	local tilesZ = math.max(2, math.floor(practice.DEPTH / practice.TILE_STUDS + 0.5))
	local sizeX = practice.WIDTH / tilesX
	local sizeZ = practice.DEPTH / tilesZ

	for ix = 0, tilesX - 1 do
		for iz = 0, tilesZ - 1 do
			local tile = newPart(
				string.format("Field_%d_%d", ix, iz),
				Vector3.new(sizeX, practice.THICKNESS, sizeZ),
				deckCFrame(-halfX + sizeX * (ix + 0.5), -practice.THICKNESS * 0.5, back + sizeZ * (iz + 0.5)),
				((ix + iz) % 2 == 0) and practice.FLOOR_COLOR or practice.FLOOR_ACCENT,
				folder
			)
			setPhysics(tile, DECK_FRICTION, DECK_ELASTICITY, 1)
		end
	end

	-- Three walls. The terrace side is left open: that is the doorway you came through.
	local sides = {
		{
			name = "FieldBack",
			size = Vector2.new(practice.WIDTH + practice.WALL_THICKNESS * 2, practice.WALL_THICKNESS),
			offset = Vector2.new(0, back - practice.WALL_THICKNESS * 0.5),
		},
		{
			name = "FieldEast",
			size = Vector2.new(practice.WALL_THICKNESS, practice.DEPTH),
			offset = Vector2.new(halfX + practice.WALL_THICKNESS * 0.5, centerZ),
		},
		{
			name = "FieldWest",
			size = Vector2.new(practice.WALL_THICKNESS, practice.DEPTH),
			offset = Vector2.new(-halfX - practice.WALL_THICKNESS * 0.5, centerZ),
		},
	}

	--[[ The field is WIDER than the terrace, so the terrace's back rail — which spans the
		DECK — only closes part of its front edge. These two shoulders close the notch
		left on each flank; without them you walk straight off the corner where the wider
		floor ends and the narrower one has not started yet. They sit on the same line as
		RimBack, so the three of them plus the doorway make one continuous front. ]]
	local shoulder = halfX - (CFG.DECK_WIDTH * 0.5 + CFG.RIM_THICKNESS)
	if shoulder > 0 then
		for _, sign in ipairs({ -1, 1 }) do
			table.insert(sides, {
				name = sign < 0 and "FieldShoulderWest" or "FieldShoulderEast",
				size = Vector2.new(shoulder, practice.WALL_THICKNESS),
				offset = Vector2.new(
					sign * (CFG.DECK_WIDTH * 0.5 + CFG.RIM_THICKNESS + shoulder * 0.5),
					front - practice.WALL_THICKNESS * 0.5
				),
			})
		end
	end

	for _, side in ipairs(sides) do
		--[[ The invisible wall first, and it is not optional here: these kickers exist to
			launch a car, and a 34-stud rail is not what stops one that has just been
			launched. ]]
		if CFG.BARRIER_HEIGHT > 0 then
			local barrier = newBarrier(
				side.name .. "Barrier",
				Vector3.new(side.size.X, CFG.BARRIER_HEIGHT, side.size.Y),
				deckCFrame(side.offset.X, CFG.BARRIER_HEIGHT * 0.5, side.offset.Y),
				folder
			)
			setPhysics(barrier, RIM_FRICTION, RIM_ELASTICITY, RIM_ELASTICITY_WEIGHT)
		end

		local wall = newPart(
			side.name,
			Vector3.new(side.size.X, practice.WALL_HEIGHT, side.size.Y),
			deckCFrame(side.offset.X, practice.WALL_HEIGHT * 0.5, side.offset.Y),
			practice.WALL_COLOR,
			folder
		)
		wall.CastShadow = true
		setPhysics(wall, RIM_FRICTION, RIM_ELASTICITY, RIM_ELASTICITY_WEIGHT)

		local cap = newPart(
			side.name .. "Cap",
			Vector3.new(side.size.X + RIM_CAP_OVERHANG, RIM_CAP_THICKNESS, side.size.Y + RIM_CAP_OVERHANG),
			deckCFrame(side.offset.X, practice.WALL_HEIGHT, side.offset.Y),
			CFG.RIM_CAP_COLOR,
			folder
		)
		setDecor(cap)
	end

	--[[ Same convention as the terrace's kickers and ArenaService's: height comes from
		length and tilt, and RAMP_YAW_FLIP turns the wedge so its thin edge meets you on
		the way in. rotY 0 therefore means "launch away from the lobby". ]]
	for index, def in ipairs(practice.RAMPS) do
		local tilt = math.clamp(def.tilt, 0, RAMP_MAX_TILT)
		local height = math.max(2, def.size.Z * math.tan(math.rad(tilt)))

		local ramp = Instance.new("WedgePart")
		ramp.Name = string.format("FieldRamp_%d", index)
		ramp.Size = Vector3.new(def.size.X, height, def.size.Z)
		ramp.CFrame = deckCFrame(def.offset.X, height * 0.5, def.offset.Y, def.rotY + RAMP_YAW_FLIP)
		ramp.Color = practice.FLOOR_ACCENT
		ramp.Material = Enum.Material.SmoothPlastic
		ramp.Anchored = true
		ramp.CanCollide = true
		ramp.CastShadow = true
		ramp.Parent = folder
		setPhysics(ramp, DECK_FRICTION, DECK_ELASTICITY, 1)

		local lip = newPart(
			string.format("FieldRampLip_%d", index),
			Vector3.new(def.size.X, RAMP_LIP_THICKNESS, RAMP_LIP_WIDTH),
			ramp.CFrame * CFrame.new(0, height * 0.5, (def.size.Z - RAMP_LIP_WIDTH) * 0.5),
			CFG.TRIM_COLOR,
			folder
		)
		lip.Material = Enum.Material.Neon
		setDecor(lip)
	end

	-- The block it stands on. Its top face IS the floor's underside, exactly as the
	-- plinth is the deck's, so the two merge into one mesa with no seam between them.
	local pedestal = newPart(
		"Pedestal",
		Vector3.new(practice.WIDTH + CFG.PEAK_MARGIN, practice.PEDESTAL_THICKNESS, practice.DEPTH + CFG.PEAK_MARGIN),
		deckCFrame(0, -practice.THICKNESS - practice.PEDESTAL_THICKNESS * 0.5, centerZ),
		CFG.ROCK_HIGH,
		folder
	)
	pedestal.Material = Enum.Material.Slate
	pedestal.CastShadow = true
	setPhysics(pedestal, DECK_FRICTION, DECK_ELASTICITY, 1)
end

-- ==========================================================================
-- spawn slots
-- ==========================================================================
--[[ A wide, shallow arc pressed against the open front edge by SPAWN_RING_Z_OFFSET: on
	a flat deck only the band nearest that edge can see the arena, so that is where
	people have to arrive. Slots are resolved in DECK space and converted at the end. ]]
local function buildSpawnPoints()
	spawnPoints = {}
	local count = math.max(1, CFG.SPAWN_COUNT)
	local arena = Config.ARENA.ORIGIN

	for index = 0, count - 1 do
		local baseAngle = (index / count) * math.pi * 2
		local localX, localZ

		for attempt = 0, SPAWN_NUDGE_TRIES do
			local step = math.ceil(attempt * 0.5)
			local sign = (attempt % 2 == 0) and 1 or -1
			local angle = baseAngle + math.rad(SPAWN_NUDGE_DEG * step * sign)
			localX = math.cos(angle) * CFG.SPAWN_RING_X
			localZ = math.sin(angle) * CFG.SPAWN_RING_Z + CFG.SPAWN_RING_Z_OFFSET
			if not inAnyRect(localX, localZ, obstacleRects, OBSTACLE_MARGIN) then
				break
			end
		end

		local pos = deckCFrame(localX, CFG.SPAWN_HEIGHT, localZ).Position
		-- Face the arena, not the middle of the terrace: the first thing you see on
		-- arriving in the hub should be the map you are about to play.
		spawnPoints[index + 1] = CFrame.lookAt(pos, Vector3.new(arena.X, pos.Y, arena.Z))
	end
end

--[[ A SpawnLocation per slot, so player:LoadCharacter() places people on the terrace
	by itself instead of dropping them at the world origin (which is the middle of the
	arena) and needing a corrective teleport a frame later.
	Neutral, invisible, non-collidable, zero forcefield duration — they are placement
	hints, not part of the look. ]]
local function buildSpawnPads(parent: Instance)
	local folder = newFolder(SPAWNS_FOLDER, parent)

	for index, slot in ipairs(spawnPoints) do
		local pad = Instance.new("SpawnLocation")
		pad.Name = string.format("HubSpawn_%d", index)
		pad.Size = Vector3.new(14, 1, 14)
		-- Slots sit SPAWN_HEIGHT up so a car could drop into them; a pad wants the floor.
		pad.CFrame = slot * CFrame.new(0, -CFG.SPAWN_HEIGHT + 0.5, 0)
		pad.Anchored = true
		pad.CanCollide = false
		pad.CanTouch = false
		pad.Transparency = 1
		pad.Neutral = true
		pad.Duration = 0
		pad.Enabled = true
		pad.Parent = folder
	end
end

local function hubOccupantPositions(): { Vector3 }
	local out = {}
	for _, character in pairs(charactersByPlayer) do
		local root = character.Parent and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(out, root.Position)
		end
	end

	-- Cars never exist up here, but if one ever does it should still be avoided.
	local carsFolder = Workspace:FindFirstChild(CARS_FOLDER)
	if carsFolder then
		for _, child in ipairs(carsFolder:GetChildren()) do
			if child:IsA("Model") then
				local hull = ChassisSpec.getHull(child)
				if hull and LobbyService.isOnDeck(hull.Position) then
					table.insert(out, hull.Position)
				end
			end
		end
	end
	return out
end

-- ==========================================================================
-- characters — the only humanoids in the game
-- ==========================================================================
local function isPlayer(player): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent ~= nil
end

-- A character that is present AND alive. Anything else is a reason to respawn them.
local function liveCharacter(player): Model?
	local character = charactersByPlayer[player]
	if not character or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character
end

--[[ Size the rig to the world and scale its movement with it.

	Everything here is Config.ARENA.SCALE (2.15x) oversized because the cars are real
	models about 21 studs long, so a default 5-stud avatar reads as an insect on a
	500-stud terrace and would need 30 seconds to cross it.

	R15 rigs carry their scale as NumberValues under the Humanoid, and writing them
	rescales the character with no yield — unlike HumanoidDescription, which would make
	this whole path yield-and-retry. R6 rigs have no such values and are simply left at
	default size, which is why CHARACTER_SCALE is a knob and not an assumption. ]]
local function applyHubBody(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local scale = tonumber(CFG.CHARACTER_SCALE) or 1
	if scale > 1 then
		for _, name in ipairs({ "BodyHeightScale", "BodyWidthScale", "BodyDepthScale", "HeadScale" }) do
			local value = humanoid:FindFirstChild(name)
			if value and value:IsA("NumberValue") then
				value.Value = value.Value * scale
			end
		end
	end

	humanoid.WalkSpeed = CFG.WALK_SPEED
	humanoid.UseJumpPower = true
	humanoid.JumpPower = CFG.JUMP_POWER
end

--[[ Put `player` on the terrace on foot. Safe to call repeatedly — it no-ops when they
	already have a live character, while one is loading, or during the short respawn
	cooldown, which is what lets both MatchService's top-up and the sweep below call it
	without coordinating.
	LoadCharacter YIELDS, so every decision is re-checked after it returns: the match may
	have started, or the player may have left, while we were away. ]]
-- Phase-wide OR individually admitted. The one question every hub path asks.
local function inHub(player): boolean
	return hubActive or hubGuests[player] == true
end

function LobbyService.enterHub(player)
	if not isPlayer(player) or not inHub(player) then
		return
	end
	if loadingByPlayer[player] or liveCharacter(player) then
		return
	end
	local gate = nextEnterAt[player]
	if gate and os.clock() < gate then
		return
	end

	loadingByPlayer[player] = true
	nextEnterAt[player] = os.clock() + CFG.RESPAWN_SECONDS
	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	loadingByPlayer[player] = nil

	if not ok then
		warn("LobbyService: LoadCharacter failed for " .. player.Name .. " -> " .. tostring(err))
		return
	end

	local character = player.Character
	if not isPlayer(player) or not character then
		return
	end
	if not inHub(player) then
		-- The round started -- or this guest was pulled back into it -- while we were
		-- loading: this character must not exist.
		character:Destroy()
		return
	end

	charactersByPlayer[player] = character
	applyHubBody(character)

	-- The SpawnLocations already put them on the deck; this spreads them off each other.
	local okPivot = pcall(function()
		character:PivotTo(LobbyService.randomSpawn())
	end)
	if not okPivot then
		warn("LobbyService: could not place " .. player.Name .. " on the terrace")
	end
end

-- Take the hub character away. Called for everyone the moment a round starts.
function LobbyService.exitHub(player)
	local character = charactersByPlayer[player]
	charactersByPlayer[player] = nil
	nextEnterAt[player] = nil
	hubGuests[player] = nil -- taking the body away also revokes the invitation

	if character then
		character:Destroy()
	end
	if isPlayer(player) and player.Character == character then
		player.Character = nil
	end
end

function LobbyService.enterAll()
	hubActive = true
	for _, player in ipairs(Players:GetPlayers()) do
		-- Spawned: LoadCharacter yields, and one slow load must not stall the rest.
		task.spawn(LobbyService.enterHub, player)
	end
end

function LobbyService.exitAll()
	hubActive = false
	for _, player in ipairs(Players:GetPlayers()) do
		LobbyService.exitHub(player)
	end
	-- Anyone who left mid-load still has an entry; clear the maps outright.
	table.clear(charactersByPlayer)
	table.clear(nextEnterAt)
	table.clear(hubGuests)
end

--[[ Admit ONE player to the hub while a round is running -- the eliminated player's way
	home. Idempotent and safe to call repeatedly: enterHub no-ops when they already have
	a body, when one is loading, and during the respawn cooldown.

	They stay a guest until exitHub / exitAll takes them out, and that is what puts them
	under the 0.5s sweep: fall off the mountain as a guest and you are put back exactly
	like anyone else in Lobby. ]]
function LobbyService.admit(player)
	if not isPlayer(player) then
		return
	end
	hubGuests[player] = true
	task.spawn(LobbyService.enterHub, player)
end

function LobbyService.isActive(): boolean
	return hubActive
end

--[[ One sweep owns every way a hub character can go wrong:
	* walked off the mountain -> put back on the terrace, no death (a fall from 430 studs
	  would otherwise end at Workspace.FallenPartsDestroyHeight)
	* died, or the character went missing -> load a new one, after the cooldown
	* joined mid-Lobby -> they have no character at all, so the same path covers them
	CharacterAutoLoads is false, so if this does not respawn them, nothing will. ]]
local function sweep(dt: number)
	if not hubActive and next(hubGuests) == nil then
		return
	end
	sweepAccum += dt
	if sweepAccum < CFG.SWEEP_INTERVAL then
		return
	end
	sweepAccum = 0

	local floor = LobbyService.catchY()

	for _, player in ipairs(Players:GetPlayers()) do
		-- Guests are swept too; anyone still in the round is not our business.
		if inHub(player) then
			local character = liveCharacter(player)
			if character then
				local root = character:FindFirstChild("HumanoidRootPart")
				--[[ Off the deck matters as much as below it: the mountain's own slabs are
					collidable, so someone who goes over the rail can land on a rock ledge
					well above catchY with no way back up. The terrace is walled, so being
					outside it at all means they are somewhere they cannot walk home from. ]]
				if root and root:IsA("BasePart") and (root.Position.Y < floor or not LobbyService.isOnDeck(root.Position)) then
					local okPut = pcall(function()
						character:PivotTo(LobbyService.randomSpawn())
						root.AssemblyLinearVelocity = Vector3.zero
						root.AssemblyAngularVelocity = Vector3.zero
					end)
					if not okPut then
						warn("LobbyService: could not recover " .. player.Name .. " from a fall")
					end
				end
			else
				task.spawn(LobbyService.enterHub, player)
			end
		end
	end
end

-- ==========================================================================
-- public API
-- ==========================================================================
function LobbyService.build(): Folder
	local existing = Workspace:FindFirstChild(LOBBY_FOLDER)
	if existing then
		existing:Destroy()
	end

	obstacleRects = {}
	spawnPoints = {}
	rockCursor = 0

	local folder = newFolder(LOBBY_FOLDER, Workspace)
	lobbyFolder = folder

	buildRockRing(folder)
	buildPeak(folder)
	buildDeck(folder)
	buildRim(folder)
	buildProps(folder)
	buildPractice(folder) -- shares the summit with the deck; buildPeak already knows
	buildSpawnPoints() -- needs obstacleRects from the props
	buildSpawnPads(folder) -- needs spawnPoints

	return folder
end

function LobbyService.getFolder(): Folder?
	return lobbyFolder
end

function LobbyService.getSpawnPoints(): { CFrame }
	return table.clone(spawnPoints)
end

-- The slot furthest from every live car, random among ties — the same rule as the
-- arena, so nobody ever materialises on top of somebody already parked there.
function LobbyService.randomSpawn(): CFrame
	if #spawnPoints == 0 then
		warn("LobbyService: randomSpawn called before build — using the terrace centre")
		return deckCFrame(0, CFG.SPAWN_HEIGHT, 0)
	end

	local cars = hubOccupantPositions()
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

--[[ Below this height a hub character is no longer on the mountain. The sweep puts them
	back rather than letting the fall finish — a Lobby fall is not a death and must not
	cost anybody their place on the terrace for a respawn cycle. ]]
function LobbyService.catchY(): number
	return CFG.ORIGIN.Y - CFG.CATCH_DROP
end

-- On the terrace. Tested in deck space, so the rake does not matter.
function LobbyService.isOnDeck(pos: Vector3): boolean
	if typeof(pos) ~= "Vector3" then
		return false
	end
	--[[ The whole SUMMIT, not just the terrace. The sweep treats "not on deck" as
		"fell off the mountain" and teleports you back, so the moment a practice field
		existed this had to grow with it or walking through the doorway would have
		yanked you home twice a second. ]]
	local summit = summitRect()
	local local_ = deckFrame:PointToObjectSpace(pos)
	return math.abs(local_.X) <= summit.halfX + CFG.RIM_THICKNESS
		and math.abs(local_.Z - summit.centerZ) <= summit.halfZ + CFG.RIM_THICKNESS
end

function LobbyService.init(ctx)
	ctxRef = ctx
	LobbyService.build()

	Players.PlayerRemoving:Connect(function(player)
		charactersByPlayer[player] = nil
		loadingByPlayer[player] = nil
		nextEnterAt[player] = nil
		hubGuests[player] = nil
	end)

	-- Server-lifetime connection: the sweep no-ops entirely while the hub is inactive
	-- AND there is no guest up there.
	RunService.Heartbeat:Connect(sweep)
end

return LobbyService
