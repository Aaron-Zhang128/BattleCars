--[[ AimController — THE TARGETING RETICLE.

	PURPOSE
		Every weapon in this game fires STRAIGHT DOWN THE CAR'S NOSE
		(Config.WEAPONS.AIM_MAX_YAW_DEG = 0): steering is aiming. That rule is only fair
		if "ahead" is something you can SEE, and a roof turret that never swivels tells
		you nothing. So this controller draws a reticle on the ground in front of your
		own car — two rails shaped like the weapon you are holding, range marks down
		them, a dotted centre line where the shot goes — and BRACKETS whatever is
		standing between them. Line a car up, pull the trigger, hit it.

	THE SHAPE IS THE TUTORIAL
		Config.AIM.SHAPES gives every weapon its own footprint, so you learn a weapon by
		looking at the floor rather than by reading a stat: the railgun is a razor line,
		the flamethrower a stubby wedge you have to tailgate with, the missiles a wide
		flare that says "this one steers for you".

	=======================================================================
	WHY EVERY STRUCTURAL LINE IS DRAWN TWICE — do not "simplify" this away
		This was flat Neon slabs first and it read as raw. The cause was the FLOOR:
		ARENA.FLOOR_COLOR is very nearly white, so a GLOWING line blows out to white and
		vanishes on it. Five treatments were rendered against the real floor colour and
		grid texture; the only one that read cleanly was a dark, wider HALO ribbon with
		a flat saturated CORE on top. That pair also survives dark plateaus and the sand
		apron, because whichever way the background goes, one of the two layers
		contrasts with it. LightEmission is 0 on every Beam here and must stay 0.
	=======================================================================

	WHY IT IS A CONTROLLER AND NOT A SERVICE — it is one client's reticle
		Every instance here is created on THIS machine and hangs off one anchored,
		CanCollide/CanQuery/CanTouch = false host part in a workspace folder. The server
		never sees it, nobody else sees it, and it can never block a shot, join a physics
		assembly or fool the chassis ground probe. It is drawn for the LOCAL car only — a
		reticle over somebody else's roof would be telling them where they are pointing.

	COST
		ONE raycast per STATION (6 by default), shared by both rails and the centre line;
		tick and mark positions interpolate between stations for free. Beams and
		Attachments are pooled — built once, then only their properties are written, and
		surplus ones are Enabled = false rather than destroyed.

	MOTION is manual math on Heartbeat — no TweenService, per house rule. Fade, lock and
		the bracket's acquire are exp-damped scalars; the breath is one sine at two speeds.

	DATA FLOW
		Heartbeat -> local car + Player.PowerupSlot -> shape -> stations -> lock scan
		          -> rails / marks / centre / bracket                             (§9)

	PUBLIC   none. Nothing else in the game reads this controller.
	ATTRIBUTES reads Player.PowerupSlot / PowerupAmmo, and Car.Hp / OwnerUserId on the
	         cars it scans. Writes NOTHING.
	INIT ORDER after ChassisController (it reads getCar lazily). Order-independent
	         otherwise; it touches no other sibling.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))

local AIM = Config.AIM
local CAR = ChassisSpec.ATTR

local player = Players.LocalPlayer

local AimController = {}

-- ==========================================================================
-- § 1) names. Every NUMBER is Config.AIM; these are the things that are not numbers.
-- ==========================================================================
--[[ Excluded from the ground probe. The first three are the same list
	ChassisController's probe ignores (a pad top or a flying shell is not floor); Fx and
	our own folder are here because a muzzle flash must never lift the reticle off the road. ]]
local IGNORED_FOLDERS = { "Cars", "Pickups", "Projectiles", "Fx", AIM.FOLDER }

local WHITE = Color3.new(1, 1, 1)
local UP = Vector3.yAxis

-- ==========================================================================
-- § 2) state
-- ==========================================================================
local ctxRef = nil
local folder, host = nil, nil
local beams, beamUsed = {}, 0
local atts, attUsed = {}, 0
local rayParams = nil
local filterStale = true

local alpha = 0 -- master fade, 0..1
local lock = 0 -- 0..1: a car is standing in the reticle
local acquire = 0 -- 0..1: how far the bracket has cinched in
local flash = 0 -- one-shot, set to 1 the frame a lock is first taken
local wasLocked = false
local held = nil -- the shape being drawn, KEPT through the fade-out
local heldColor = WHITE
local lockedHull = nil -- the hull the bracket is wrapped around

--[[ Rebuilt in place every frame rather than reallocated: one entry per station,
	each carrying the ground point, its normal and the in-surface lateral axis. ]]
local stations = {}

-- Per-frame colour sequences, built once and shared by every line of that layer.
local coreSeq, haloSeq = nil, nil

local warned = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("AimController: " .. message)
end

local function safeCall(controllerName: string, fnName: string, default: any, ...): any
	local ctrl = ctxRef and ctxRef.ctrl and ctxRef.ctrl[controllerName]
	local fn = ctrl and ctrl[fnName]
	if type(fn) ~= "function" then
		return default
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warnOnce("err:" .. controllerName .. "." .. fnName, controllerName .. "." .. fnName .. " errored -> " .. tostring(result))
		return default
	end
	if result == nil then
		return default
	end
	return result
end

-- ==========================================================================
-- § 3) host + pools
-- ==========================================================================
--[[ ONE part carries every Attachment, and it is parked at the world origin with an
	identity CFrame ON PURPOSE: an Attachment's CFrame is then literally its world
	CFrame, so nothing below has to transform into a moving parent's space every frame. ]]
local function ensureHost(): BasePart
	if host and host.Parent then
		return host
	end

	if not (folder and folder.Parent) then
		local existing = Workspace:FindFirstChild(AIM.FOLDER)
		if existing and existing:IsA("Folder") then
			folder = existing
		else
			local made = Instance.new("Folder")
			made.Name = AIM.FOLDER
			made.Parent = Workspace
			folder = made
		end
	end

	local part = Instance.new("Part")
	part.Name = AIM.HOST
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- so the ground probe below can never hit the reticle itself
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Locked = true
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.identity
	part.Parent = folder

	host = part
	return part
end

local function acquireAtt(cf: CFrame): Attachment?
	if attUsed >= AIM.MAX_BEAMS * 2 then
		return nil
	end
	attUsed += 1

	local existing = atts[attUsed]
	if not (existing and existing.Parent) then
		existing = Instance.new("Attachment")
		existing.Name = "AimAtt"
		existing.Parent = ensureHost()
		atts[attUsed] = existing
	end
	existing.CFrame = cf
	return existing
end

local function acquireBeam(): Beam?
	if beamUsed >= AIM.MAX_BEAMS then
		return nil
	end
	beamUsed += 1

	local existing = beams[beamUsed]
	if not (existing and existing.Parent) then
		existing = Instance.new("Beam")
		existing.Name = "AimLine"
		existing.FaceCamera = false
		existing.Segments = 1 -- straight ribbon: two vertices render the ramp exactly
		existing.LightEmission = 0 -- SEE THE HEADER. A glowing line vanishes on this floor.
		existing.LightInfluence = 0
		existing.Parent = ensureHost()
		beams[beamUsed] = existing
	end
	existing.Enabled = true
	return existing
end

local function hideUnused()
	for i = beamUsed + 1, #beams do
		local b = beams[i]
		if b and b.Parent then
			b.Enabled = false
		end
	end
end

local function hideAll()
	beamUsed, attUsed = 0, 0
	hideUnused()
end

-- ==========================================================================
-- § 4) the line primitive
-- ==========================================================================
--[[ A ribbon lying flat ON the surface. A Beam's WIDTH runs along its attachments'
	Y axis (measured, not assumed — three roll variants of the same run were rendered
	and only this one lay flat), so Y must be the in-surface axis ACROSS the line and X
	is the surface normal. Get that backwards and every line renders edge-on, which is
	to say invisible. ]]
local function planeCF(point: Vector3, normal: Vector3, along: Vector3, lift: number): CFrame
	local wide = along:Cross(normal)
	if wide.Magnitude < 1e-3 then
		return CFrame.new(point + normal * lift)
	end
	return CFrame.fromMatrix(point + normal * lift, normal, wide.Unit)
end

local function line(cfA: CFrame, cfB: CFrame, width: number, colorSeq: ColorSequence, tA: number, tB: number)
	if tA >= 1 and tB >= 1 then
		return -- fully dissolved; spend the beam on something visible
	end
	local beam = acquireBeam()
	if not beam then
		return
	end
	local a0 = acquireAtt(cfA)
	local a1 = acquireAtt(cfB)
	if not (a0 and a1) then
		beam.Enabled = false
		beamUsed -= 1
		return
	end
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = width
	beam.Width1 = width
	beam.Color = colorSeq
	beam.Transparency = NumberSequence.new(math.clamp(tA, 0, 1), math.clamp(tB, 0, 1))
end

-- A segment laid between two ground points: halo underneath, core a hair above it.
local function railSegment(pA: Vector3, nA: Vector3, pB: Vector3, nB: Vector3, tA: number, tB: number, haloA: number, haloB: number)
	local along = pB - pA
	if along.Magnitude < 1e-3 then
		return
	end
	line(
		planeCF(pA, nA, along, AIM.LIFT),
		planeCF(pB, nB, along, AIM.LIFT),
		AIM.RAIL_HALO_WIDTH, haloSeq, haloA, haloB
	)
	line(
		planeCF(pA, nA, along, AIM.LIFT + AIM.CORE_LIFT_BIAS),
		planeCF(pB, nB, along, AIM.LIFT + AIM.CORE_LIFT_BIAS),
		AIM.RAIL_WIDTH, coreSeq, tA, tB
	)
end

-- A secondary mark (tick / centre dot / corner turn). One layer, thin, no halo.
local function mark(pA: Vector3, pB: Vector3, normal: Vector3, transparency: number)
	local along = pB - pA
	if along.Magnitude < 1e-3 then
		return
	end
	line(
		planeCF(pA, normal, along, AIM.LIFT + AIM.CORE_LIFT_BIAS),
		planeCF(pB, normal, along, AIM.LIFT + AIM.CORE_LIFT_BIAS),
		AIM.THIN_WIDTH, coreSeq, transparency, transparency
	)
end

-- ==========================================================================
-- § 5) ground probe
-- ==========================================================================
local function rebuildRayFilter()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	--[[ Same rule as ChassisController's ground probe, for the same reason: only
		COLLIDABLE geometry is floor. Pads, chevrons, block caps and pit sensors are all
		queryable but not collidable, and a pad top would lift the reticle a stud off
		the road it is supposed to be painted on. ]]
	params.RespectCanCollide = true

	local filter = {}
	local missing = false
	for _, name in ipairs(IGNORED_FOLDERS) do
		local found = Workspace:FindFirstChild(name)
		if found then
			table.insert(filter, found)
		else
			missing = true
		end
	end
	params.FilterDescendantsInstances = filter

	rayParams = params
	-- ArenaService destroys and rebuilds its folders every Lobby, so the filter is only
	-- final once every folder exists. Until then, re-resolve next frame.
	filterStale = missing
end

-- Surface height and normal under `point`. Falls back to the point itself over a pit,
-- where there is no floor to lie on and floating is the only honest answer.
local function groundAt(point: Vector3): (number, Vector3)
	local origin = point + Vector3.new(0, AIM.PROBE_UP, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(AIM.PROBE_UP + AIM.PROBE_DOWN), 0), rayParams)
	if hit then
		return hit.Position.Y, hit.Normal
	end
	return point.Y, UP
end

-- ==========================================================================
-- § 6) stations — the ONLY raycasts, and everything downstream reads them
-- ==========================================================================
local function sampleStations(root: Vector3, forward: Vector3, start: number, length: number, count: number)
	for i = 0, count do
		local t = i / count
		local at = root + forward * (start + t * length)
		local groundY, normal = groundAt(at)

		local lateral = forward:Cross(normal)
		lateral = lateral.Magnitude > 1e-3 and lateral.Unit or Vector3.xAxis

		local station = stations[i + 1]
		if not station then
			station = {}
			stations[i + 1] = station
		end
		station.t = t
		station.pos = Vector3.new(at.X, groundY, at.Z)
		station.normal = normal
		station.lateral = lateral
	end
end

-- Any point down the lane, interpolated between the two stations bracketing it — so a
-- tick costs no raycast of its own.
local function stationAt(t: number, count: number): (Vector3, Vector3, Vector3)
	local scaled = math.clamp(t, 0, 1) * count
	local i = math.clamp(math.floor(scaled), 0, count - 1)
	local f = scaled - i
	local a, b = stations[i + 1], stations[i + 2]
	if not (a and b) then
		local only = a or b or stations[1]
		return only.pos, only.normal, only.lateral
	end
	return a.pos:Lerp(b.pos, f), a.normal:Lerp(b.normal, f).Unit, a.lateral:Lerp(b.lateral, f).Unit
end

-- ==========================================================================
-- § 7) shading
-- ==========================================================================
--[[ Opacity down the lane. Solid to FADE_START, then a clean ramp to nothing — the
	reticle ENDS BY RUNNING OUT rather than by hitting a bar across the mouth, which was
	the single most "floor decal" thing about the first version. ]]
local function profile(t: number): number
	if t <= AIM.FADE_START then
		return 1
	end
	return 1 - (t - AIM.FADE_START) / math.max(1 - AIM.FADE_START, 1e-3)
end

--[[ Base transparency -> the number a Beam wants, after the master fade, the breath
	and the distance dissolve. The fade multiplies OPACITY, not the transparency number:
	easing 0.46 -> 1 linearly makes a line look gone a third of the way out. ]]
local function shade(base: number, t: number, breath: number): number
	local opacity = (1 - base) * profile(t) * alpha * (1 + breath)
	return 1 - math.clamp(opacity, 0, 1)
end

-- ==========================================================================
-- § 8) the lock
-- ==========================================================================
--[[ Nobody you cannot shoot lights the reticle up. Teams mode is the only thing that
	makes another car friendly today (GameModes.sameTeam is 0-team-safe, so it is false
	in every other mode), and an unowned or half-replicated car is treated as a target
	rather than a friend — a reticle that locks a car you cannot hurt is a lie, but one
	that stays dark on a car you can is worse. ]]
local function isFriendly(car: Model): boolean
	local owner = car:GetAttribute(CAR.OWNER)
	if type(owner) ~= "number" then
		return false
	end
	local other = Players:GetPlayerByUserId(owner)
	if not other then
		return false
	end
	if other == player then
		return true
	end
	return GameModes.sameTeam(player, other)
end

-- `frame` looks along the reticle's own axis from the hull centre, so -Z is "ahead".
local function insideShape(shape, frame: CFrame, start: number, point: Vector3): boolean
	local rel = frame:PointToObjectSpace(point)
	if shape.ring then
		return Vector3.new(rel.X, 0, rel.Z).Magnitude <= shape.ring + AIM.LOCK_PAD
	end

	local ahead = -rel.Z
	local length = math.max(shape.length, 1e-3)
	if ahead < start - AIM.LOCK_PAD or ahead > start + length + AIM.LOCK_PAD then
		return false
	end
	local t = MathUtil.clamp01((ahead - start) / length)
	local half = MathUtil.lerp(shape.near, shape.far, t) * 0.5
	return math.abs(rel.X) <= half + AIM.LOCK_PAD
end

--[[ The NEAREST valid car inside the shape, so the bracket wraps the one that is
	actually about to be hit rather than whichever the child order happened to reach
	first. Returns its hull, or nil. ]]
local function findTarget(shape, frame: CFrame, start: number, myCar: Model): BasePart?
	local cars = Workspace:FindFirstChild(AIM.CARS_FOLDER)
	if not cars then
		return nil
	end

	local best, bestDist = nil, math.huge
	local scanned = 0
	for _, car in ipairs(cars:GetChildren()) do
		if car ~= myCar and car:IsA("Model") then
			scanned += 1
			if scanned > AIM.MAX_CARS_SCANNED then
				break
			end
			local hp = car:GetAttribute(CAR.HP)
			if (type(hp) ~= "number" or hp > 0) and not isFriendly(car) then
				local hull = ChassisSpec.getHull(car)
				if hull and hull.Parent and insideShape(shape, frame, start, hull.Position) then
					local dist = (hull.Position - frame.Position).Magnitude
					if dist < bestDist then
						best, bestDist = hull, dist
					end
				end
			end
		end
	end
	return best
end

-- ==========================================================================
-- § 9) drawing
-- ==========================================================================
local function drawLane(shape, root: Vector3, forward: Vector3, start: number, breath: number)
	local count = math.max(1, AIM.STATIONS)
	local length = shape.length
	sampleStations(root, forward, start, length, count)

	local function halfAt(t: number): number
		return MathUtil.lerp(shape.near, shape.far, t) * 0.5
	end

	local coreBase = MathUtil.lerp(AIM.CORE_TRANSPARENCY, AIM.LOCK_CORE_TRANSPARENCY, lock)
	local haloBase = MathUtil.lerp(AIM.HALO_TRANSPARENCY, AIM.LOCK_HALO_TRANSPARENCY, lock)
	local thinBase = MathUtil.lerp(AIM.THIN_TRANSPARENCY, AIM.LOCK_THIN_TRANSPARENCY, lock)
	-- The one-shot flash the frame a lock is taken lands on the SECONDARY marks: the
	-- rails are already going solid, so flashing them too would read as a stutter.
	local markBase = math.max(thinBase - flash * AIM.FLASH_BOOST, 0)

	-- ---- the two rails ----
	for side = -1, 1, 2 do
		for i = 1, count do
			local a, b = stations[i], stations[i + 1]
			local pA = a.pos + a.lateral * (side * halfAt(a.t))
			local pB = b.pos + b.lateral * (side * halfAt(b.t))
			railSegment(
				pA, a.normal, pB, b.normal,
				shade(coreBase, a.t, breath), shade(coreBase, b.t, breath),
				shade(haloBase, a.t, breath), shade(haloBase, b.t, breath)
			)
		end
	end

	-- ---- range ticks: short inward stubs off each rail ----
	for _, t in ipairs(AIM.TICKS) do
		local pos, normal, lateral = stationAt(t, count)
		local half = halfAt(t)
		local transparency = shade(markBase, t, breath)
		for side = -1, 1, 2 do
			mark(
				pos + lateral * (side * half),
				pos + lateral * (side * half * (1 - AIM.TICK_LENGTH)),
				normal, transparency
			)
		end
	end

	--[[ The effective-range mark, at FADE_START — the last solid thing down the lane.
		It is what tells you how far the weapon reaches WITHOUT a bar across the mouth,
		which is the whole point of dissolving the far end instead of capping it. ]]
	do
		local t = AIM.FADE_START
		local pos, normal, lateral = stationAt(t, count)
		local half = halfAt(t)
		local transparency = shade(markBase, t, breath)
		for side = -1, 1, 2 do
			mark(
				pos + lateral * (side * half),
				pos + lateral * (side * half * (1 - AIM.RANGE_MARK_LENGTH)),
				normal, transparency
			)
		end
	end

	-- ---- the near corner turns, which close the frame back toward the car ----
	do
		local a = stations[1]
		local half = halfAt(0)
		local transparency = shade(markBase, 0, breath)
		for side = -1, 1, 2 do
			mark(
				a.pos + a.lateral * (side * half),
				a.pos + a.lateral * (side * half * (1 - AIM.CORNER_LENGTH)),
				a.normal, transparency
			)
		end
	end

	-- ---- the dotted centre line: where the shot itself goes ----
	local dots = math.max(0, AIM.CENTRE_DOTS)
	for i = 0, dots - 1 do
		local slot = AIM.FADE_START / dots
		local t0 = i * slot
		local t1 = t0 + slot * AIM.CENTRE_DOT_FRACTION
		local pA, nA = stationAt(t0, count)
		local pB = stationAt(t1, count)
		mark(pA, pB, nA, shade(thinBase, (t0 + t1) * 0.5, breath))
	end
end

-- A ring centred on the car (ZAP): the same two-layer rail, closed into a circle.
local function drawRing(shape, root: Vector3, breath: number)
	local count = math.max(3, AIM.RING_STATIONS)
	local radius = shape.ring
	local coreBase = MathUtil.lerp(AIM.CORE_TRANSPARENCY, AIM.LOCK_CORE_TRANSPARENCY, lock)
	local haloBase = MathUtil.lerp(AIM.HALO_TRANSPARENCY, AIM.LOCK_HALO_TRANSPARENCY, lock)
	local coreT, haloT = shade(coreBase, 0, breath), shade(haloBase, 0, breath)

	local prevPos, prevNormal = nil, nil
	local firstPos, firstNormal = nil, nil
	for i = 0, count do
		local a = (i % count) * (math.pi * 2 / count)
		local at = root + Vector3.new(math.sin(a) * radius, 0, math.cos(a) * radius)
		local groundY, normal = groundAt(at)
		local pos = Vector3.new(at.X, groundY, at.Z)
		if prevPos then
			railSegment(prevPos, prevNormal, pos, normal, coreT, coreT, haloT, haloT)
		else
			firstPos, firstNormal = pos, normal
		end
		prevPos, prevNormal = pos, normal
	end
	if firstPos and prevPos then
		railSegment(prevPos, prevNormal, firstPos, firstNormal, coreT, coreT, haloT, haloT)
	end
end

--[[ THE TARGET BRACKET — four L-corners on the ground around the locked car, in ITS
	own heading so they wrap the body rather than sitting askew to it. They start
	BRACKET_POP further out and cinch in as `acquire` lands, which is the whole
	difference between a bracket that appears and one that ACQUIRES. ]]
local function drawBracket(hull: BasePart)
	if not (hull and hull.Parent) or lock <= 0.01 then
		return
	end

	local pos = hull.Position
	local groundY, normal = groundAt(pos)
	local centre = Vector3.new(pos.X, groundY, pos.Z)

	local forward = MathUtil.flatUnit(hull.CFrame.LookVector)
	if forward == Vector3.zero then
		forward = Vector3.new(0, 0, -1)
	end
	local lateral = forward:Cross(normal)
	lateral = lateral.Magnitude > 1e-3 and lateral.Unit or Vector3.xAxis
	forward = normal:Cross(lateral).Unit -- re-square against the surface

	local pad = AIM.BRACKET_PAD * MathUtil.lerp(AIM.BRACKET_POP, 1, acquire)
	local halfW = hull.Size.X * 0.5 + pad
	local halfL = hull.Size.Z * 0.5 + pad

	local coreT = 1 - (1 - AIM.LOCK_CORE_TRANSPARENCY) * lock * alpha
	local haloT = 1 - (1 - AIM.LOCK_HALO_TRANSPARENCY) * lock * alpha

	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			local corner = centre + lateral * (sx * halfW) + forward * (sz * halfL)
			-- one arm back along the body, one across it: an L, not a full box
			local alongBody = corner - forward * (sz * halfL * 2 * AIM.BRACKET_ARM)
			local acrossBody = corner - lateral * (sx * halfW * 2 * AIM.BRACKET_ARM)
			for _, tip in ipairs({ alongBody, acrossBody }) do
				local along = tip - corner
				line(
					planeCF(corner, normal, along, AIM.LIFT),
					planeCF(tip, normal, along, AIM.LIFT),
					AIM.BRACKET_HALO_WIDTH, haloSeq, haloT, haloT
				)
				line(
					planeCF(corner, normal, along, AIM.LIFT + AIM.CORE_LIFT_BIAS),
					planeCF(tip, normal, along, AIM.LIFT + AIM.CORE_LIFT_BIAS),
					AIM.BRACKET_WIDTH, coreSeq, coreT, coreT
				)
			end
		end
	end
end

-- ==========================================================================
-- § 10) step
-- ==========================================================================
local function shapeFor(id: string?)
	local shape = id and AIM.SHAPES[id]
	return shape or AIM.DEFAULT
end

local function localCar(): Model?
	local car = safeCall("ChassisController", "getCar", nil)
	if typeof(car) == "Instance" and car:IsA("Model") and car.Parent then
		return car
	end
	return nil
end

local function step(dt: number)
	if filterStale or not rayParams then
		rebuildRayFilter()
	end

	local car = localCar()
	local hull = car and ChassisSpec.getHull(car)
	if not (hull and hull.Parent) then
		-- No car. There is no fade to play out — the thing it was drawn in front of is
		-- gone, and a reticle hanging over an empty wreck reads as a bug.
		alpha, lock, acquire, flash, held, lockedHull, wasLocked = 0, 0, 0, 0, nil, nil, false
		hideAll()
		return
	end

	--[[ The reticle exists only while there is something to fire. An empty slot, a spent
		one, or a SHIELD (a bubble, not a gun) fades it out — and `held` survives that
		fade, so running a weapon dry reads as the reticle leaving rather than blinking. ]]
	local def, ammo = PowerupDefs.slotOf(player)
	local wanted = (def and ammo > 0 and def.kind ~= "self") and def or nil
	if wanted then
		held = shapeFor(wanted.id)
		heldColor = typeof(wanted.color) == "Color3" and wanted.color or WHITE
	end

	alpha = MathUtil.damp(alpha, wanted and 1 or 0, AIM.FADE_RATE, dt)
	if not held or alpha < 0.01 then
		if not wanted then
			held, lockedHull, wasLocked = nil, nil, false
			lock, acquire, flash = 0, 0, 0
		end
		hideAll()
		return
	end

	local forward = MathUtil.flatUnit(hull.CFrame.LookVector)
	if forward == Vector3.zero then
		forward = Vector3.new(0, 0, -1)
	end
	--[[ ONE axis for the drawing and for the lock test, so the reticle can never light
		up for a car it is not covering. `start` comes off the hull's own length, so a
		Juggernaut's 2x body pushes its reticle out past the bigger bumper for free. ]]
	local dir = held.behind and -forward or forward
	local root = hull.Position
	local start = hull.Size.Z * AIM.NOSE_FRACTION
	local frame = CFrame.lookAt(root, root + dir)

	-- ---- lock ----
	local target = wanted and findTarget(held, frame, start, car) or nil
	local locked = target ~= nil
	if locked and not wasLocked then
		flash = 1 -- fires ONCE, on the acquiring frame
		acquire = 0
	end
	wasLocked = locked
	lockedHull = target or lockedHull

	lock = MathUtil.damp(lock, locked and 1 or 0, AIM.LOCK_RATE, dt)
	acquire = MathUtil.damp(acquire, locked and 1 or 0, AIM.ACQUIRE_RATE, dt)
	flash = MathUtil.damp(flash, 0, AIM.FLASH_DECAY, dt)
	if lock < 0.01 then
		lockedHull = nil
	end

	-- One sine at two speeds: a slow breath while idle, a fast one the moment a car is
	-- in the reticle. The change of RATE is what you read, not the amplitude.
	local now = os.clock()
	local hz = MathUtil.lerp(AIM.IDLE_PULSE_HZ, AIM.LOCK_PULSE_HZ, lock)
	local breath = math.sin(now * math.pi * 2 * hz) * MathUtil.lerp(AIM.IDLE_PULSE, AIM.LOCK_PULSE, lock)

	-- Built once per frame and shared by every line of that layer, rather than one
	-- ColorSequence allocation per Beam per frame.
	local coreColor = heldColor:Lerp(WHITE, AIM.LOCK_BRIGHTEN * lock)
	coreSeq = ColorSequence.new(coreColor)
	haloSeq = ColorSequence.new(heldColor:Lerp(Color3.new(0, 0, 0), 1 - AIM.HALO_DARKEN))

	beamUsed, attUsed = 0, 0
	if held.ring then
		drawRing(held, root, breath)
	else
		drawLane(held, root, dir, start, breath)
	end
	drawBracket(lockedHull)
	hideUnused()
end

-- ==========================================================================
-- § 11) init
-- ==========================================================================
function AimController.init(ctx)
	ctxRef = ctx

	if not AIM.ENABLED then
		return
	end

	--[[ ArenaService rebuilds its folders every Lobby, which leaves the probe filter
		holding destroyed instances. Both signals simply mark it stale; §5 re-resolves
		on the next frame that needs a ray. ]]
	Workspace.ChildAdded:Connect(function()
		filterStale = true
	end)
	Workspace.ChildRemoved:Connect(function()
		filterStale = true
	end)

	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warnOnce("step", "step errored -> " .. tostring(err))
		end
	end)
end

return AimController
