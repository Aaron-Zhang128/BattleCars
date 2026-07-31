--[[ ChassisController
	The arcade velocity chassis. Every bit of how driving FEELS lives in this file.

	Cars are server-built Models with ONE collidable Hull. SpawnService calls
	hull:SetNetworkOwner(player), so THIS client simulates its own car with zero input
	latency: we write Hull.Drive (LinearVelocity) and Hull.Steer (AlignOrientation)
	locally every frame. Those property writes never replicate — the resulting MOTION
	does, automatically. The server never sets Drive/Steer on a player-owned car.

	Not a simulator: instant response, drifty, weighty on impact, forgiving in the air,
	always recoverable. Longitudinal + lateral speed are re-read from the hull every
	frame, so ram knockback and explosions really move you — grip and drag then bleed
	the hit off instead of erasing it.

	DATA FLOW
		CarLifecycle (S->C) "spawned"    -> attach(car, info.carId)
		CarLifecycle (S->C) "destroyed"  -> detach()
		CarState     (C->S)              -> (pos, vel, onGround) at CHASSIS.STATE_SEND_HZ
		InputController                  -> getThrottle / getSteer / isDrifting (resolved LAZILY)

	ATTRIBUTES — read only, all server-owned, we never write one:
		car.CarId, car.BoostUntil, car.FrozenUntil, car.StaggerUntil (via ChassisSpec helpers)
		StaggerUntil is a handshake: while it is live we hand horizontal drive authority
		back to physics so CombatService's knockback impulse survives (see setStaggerMode).

	MODEL CONTRACT: ChassisSpec — Hull, Hull.RootAtt, Hull.Drive, Hull.Steer, Wheels/

	PUBLIC SURFACE (pinned): getCar getSpeed getSpeedFraction isGrounded isDrifting getLook
		plus isBoosting() / getDriftCharge() / getDriftTier() as conveniences for HUD/FX
		(NOT part of the pinned contract — safe to read, never required).

	DRIFT REWARD (mini-turbo): sustaining a real slide banks charge; releasing it spends the
	charge on a short burst of the ordinary boost via state.padBoostUntil. There is
	deliberately no second speed system — see the payout site in step().

	LOOP: RunService.Heartbeat — the SIMULATION clock, not the render clock. See the
	connection at the bottom of init(); driving is frame-rate dependent on the wrong one.

	INIT ORDER: after InputController. There is deliberately NO match-phase gate here —
	MatchService decides whether a car exists at all, and a second gate could deadlock
	a live car.
]]

-- TUNING: the knobs that move the feel most. All in Config.CHASSIS unless noted.
--   TOP_SPEED (x per-car stats.topSpeed)  how fast it ever goes
--   ACCEL / BRAKE / COAST_DRAG           how eagerly it picks up and sheds speed
--   TURN_RATE / TURN_SPEED_FLOOR         turn sharpness, and how much a stopped car can pivot
--   GRIP vs DRIFT_GRIP                   THE drift — the gap between the two IS the slide
--   GROUND_SPRING / GROUND_DAMPER        hover stiffness: high spring = go-kart, low = boat
--   AIR_CONTROL                          steering left to you in mid-air off a ramp
--   UPRIGHT_TORQUE                       how crisply the nose follows the wheel + roof recovery
--                                        (CarFactory applies it to Steer.MaxTorque; we only read it)
--   BOOST_MULTIPLIER / BOOST_ACCEL_MULTIPLIER / BOOST_SECONDS   the pad kick, and
--                                        (x DRIFT_BOOST_FRACTION) the mini-turbo payout
--   MAX_SLOPE_COS                        how steep still counts as driveable ground
--   RAM.STAGGER_SECONDS                  how long a hit shoves you before you get control back
-- Drive.MaxForce (how much a ram shoves you) is CarFactory's, not ours — we read it, never write it.
-- Feel values with no Config.CHASSIS key yet live in LOCAL FEEL below.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))

local CFG = Config.CHASSIS
local ATTR = ChassisSpec.ATTR
local LocalPlayer = Players.LocalPlayer

-- ==========================================================================
-- LOCAL FEEL — tunables Config.CHASSIS has no key for (see HANDOFF), plus
-- structural plumbing that is not a feel value at all. Nothing below is a bare
-- literal inside the physics loop.
-- ==========================================================================
local AUTHORITY_FULL_FRACTION = 0.32 -- speed fraction where steering authority peaks at 1.0
local AUTHORITY_AT_TOP = 0.78 -- authority backed off at top speed so you cannot spin out
local AIR_GRIP_FRACTION = 0.15 -- fraction of grip kept with no wheels on the ground
local DRIFT_MIN_LATERAL = 6 -- studs/s of slide before isDrifting() reports a real drift
local DRIFT_KICK_THRESHOLD = 0.35 -- driftAmount at which the tail is kicked loose, once
local DRIFT_FX_THRESHOLD = 0.2 -- driftAmount at which skid marks / drift fx switch on
--[==[ MINI-TURBO — the reward that gives drifting a REASON. Charge accrues while a real
	slide is happening and is paid out as a short burst of the EXISTING boost, so there is
	exactly one speed system in this file (see the fire site for why that matters).
	Charge accrues at driftAmount per second, so it measures COMMITMENT x TIME rather than
	just time: a lazy 6-degree slide banks 0.45/s while a full-lock 21-degree slide banks
	~0.97/s. Simulated against the live Config (rustbucket, 90 top speed, 60fps):
		0.3s flick        charge 0.08  -> nothing, exactly as intended
		0.9s hard corner  charge 0.78  -> tier 1
		2.0s full lock    charge 1.84  -> tier 2
	TIER1 0.75 lands on a normal committed corner (~0.77s of slide, ~78 degrees of arc at a
	53-stud radius). TIER2 1.60 needs ~1.65s and ~168 degrees — a genuine sweeping corner or
	a deliberate donut, so tier 2 stays a flex rather than the default outcome. ]==]
local DRIFT_CHARGE_MIN_AMOUNT = 0.35 -- driftAmount below which no charge accrues (= tail-loose point)
local DRIFT_CHARGE_TIER1 = 0.75 -- charge units for the small mini-turbo
local DRIFT_CHARGE_TIER2 = 1.60 -- charge units for the big one
--[==[ Below the threshold for THIS long before the drift counts as over. Without it a
	mid-corner counter-steer to hold the line reads as a release and dumps the charge:
	simulated, a 0.12s correction inside a 1.4s corner scored 0 boosts at grace 0 and
	1 boost at grace 0.18. It cannot double-pay, because firing zeroes the charge. ]==]
local DRIFT_RELEASE_GRACE = 0.18
-- Boost length per tier, as a FRACTION of CFG.BOOST_SECONDS, so retuning the pad retunes
-- these with it. At BOOST_SECONDS 1.6 that is 0.48s and 0.96s against a pad's full 1.6s:
-- a mini-turbo is a partial pad you can earn anywhere, and pads stay the premium pickup.
local DRIFT_BOOST_FRACTION = { 0.30, 0.60 }
local DRIFT_BOOST_SHAKE = { 0.22, 0.38 } -- camera kick per tier, so the payout is felt
local DRIFT_BOOST_SHAKE_TIME = 0.18
--[==[ Launching off a ramp mid-drift must not silently bin the charge, so it is HELD while
	airborne (not accrued, not released) and pays out on landing. Bounded, or a car that
	takes off drifting and lands a lap later would still collect. ]==]
local DRIFT_AIR_HOLD_SECONDS = 1.2
local REVERSE_STEER_SPEED = 3 -- backing up faster than this mirrors the steering
local FROZEN_TURN_BLEND = 0.6 -- how much of FROZEN_SPEED_MULTIPLIER also hits steering
local GROUNDED_HEIGHT_FACTOR = 1.8 -- grounded while within hoverHeight * this of the ground
local UP_BLEND_RATE = 8 -- how fast the chassis up-vector chases the ground normal
local WHEEL_STEER_DEG = 26 -- cosmetic front-wheel turn at full steer
-- Front wheels ease to their angle instead of snapping with the raw axis. Deliberately
-- slower than InputController's own smoothing (22) so the wheels visibly trail the input.
local WHEEL_STEER_RATE = 12
local WHEEL_SLIP_RATE = 9 -- how fast the cosmetic spin blends between spin-up and lock-up
local WHEEL_SPINUP_EXTRA = 0.6 -- up to +60% overspin while the throttle is still winning
local WHEEL_LOCK_SLIP = 0.15 -- wheels nearly stop under heavy braking (locked tyre)
--[==[ FLIP UNSTICK gate. Steer commands upright EVERY frame (ground normal when grounded,
	world up when not) and CarFactory scales MaxTorque by inertia, so no car is torque-
	limited and none of this is needed to right a car with room to rotate. It exists only
	for GEOMETRY — a hull wedged on its side against a wall or a pit lip. Hence: really
	inverted, really stopped, for over a second. Ramp air always carries speed, so a
	barrel roll can never trip this, which is the whole point of the speed gate. ]==]
local FLIP_UP_DOT = 0.35 -- hull up-vector Y below this counts as on-its-side or worse
local FLIP_STUCK_SPEED = 8 -- studs/s of planar motion under which we count as pinned
local FLIP_STUCK_SECONDS = 1.2
local FLIP_HOP_SPEED = 30 -- ~2.3 studs of lift, enough to clear a lip and let torque work
local FLIP_HOP_COOLDOWN = 1.5
--[[ Sign bridge between two opposite conventions, applied in exactly one place.
	InputController.getSteer() is RIGHT-POSITIVE (+1 = D / Right / stick right), matching
	VehicleSeat.Steer. But yawLook()/yawFromLook() use a LEFT-POSITIVE yaw: yawLook(90)
	is (-1,0,0), which is -X, i.e. LEFT. Adding a right-positive input straight into a
	left-positive yaw steers backwards. Both the body yaw AND the cosmetic front wheels
	multiply by this, so they can never disagree with each other. ]]
local STEER_TO_YAW = -1
local WHEEL_RADIUS_FALLBACK = 1.6 -- matches the fallback inside ChassisSpec.resolve

local MAX_STEP = 1 / 20 -- dt clamp: a frame hitch must never launch the car
local ATTACH_TIMEOUT = 3.0 -- seconds to wait for the car's parts to replicate in
local OWNERSHIP_TIMEOUT = 1.0 -- seconds to wait for SetNetworkOwner to land
local OWNERSHIP_FALLBACK_WAIT = 0.15 -- used when GetNetworkOwner is not client-readable
local FORCE_HEADROOM_FALLBACK = 1.2 -- only if a car arrives with no MaxForce set (mirrors CarFactory)
local PAD_CHECK_INTERVAL = 0.08 -- seconds between boost-pad overlap scans
local INPUT_DEADZONE = 0.06
local WALLDBG = false -- wall instrumentation, kept but OFF; flip to true to re-arm
--[[ ONE collision signal for everything — walls, corners, ramps, blocks and other cars.
	The drive constraint can only change our planar velocity by MaxForce/mass * dt per frame
	(about 7.5 studs/s). So ANY larger planar change was not us: it is an external impulse,
	i.e. a collision, and its direction is the engine's own contact response — the true
	normal, for free, with no raycast and no per-surface special cases. Our own throttle and
	braking can never trip it, which is exactly what the old shortfall test got wrong.
	Small impulse -> stop commanding into it, so we stop dumping force into a wall.
	Large impulse -> also yield force briefly so the engine's bounce survives. ]]
local EXTERNAL_DV_SLACK = 1.8 -- multiple of our own max per-frame dv that counts as external
local HARD_IMPACT_DV = 30 -- studs/s of external change that also yields drive authority
local CONTACT_YIELD_SECONDS = 0.16 -- how long physics owns horizontal motion
local CONTACT_BLOCK_HOLD = 0.15 -- keep cancelling into that direction this long
local YAW_RESYNC_DEG = 25 -- max degrees the commanded heading may lead the real hull
local EPSILON = 1e-4
local WELD_NAME = "Weld" -- CarFactory parents each cosmetic part's WeldConstraint here
local FRONT_PREFIX = "F" -- Wheels/ naming: FL, FR steer; RL, RR do not
local REAR_PREFIX = "R"
-- Runtime folders owned by PickupService / WeaponService. Excluded from the ground
-- probe; other CARS are deliberately NOT excluded, so you can drive over a rival.
local IGNORED_FOLDERS = { "Pickups", "Projectiles" }

local ChassisController = {}

local ctxRef = nil

local state = {
	car = nil,
	hull = nil,
	drive = nil,
	steer = nil,
	spec = nil,
	attachToken = 0,
	ready = false,

	yaw = 0, -- integrated heading, degrees
	forwardSpeed = 0,
	lateralSpeed = 0,
	speed = 0,
	grounded = false,
	groundNormal = Vector3.yAxis,
	groundDistance = 0,
	upVector = Vector3.yAxis,
	drifting = false,
	padBoostUntil = 0,
	yielding = false, -- knockback stagger OR a fresh wall impact
	maxForce = 0,

	rayParams = nil,
	filterStale = true,
	sendAccum = 0,
	padAccum = 0,
	wheelSpin = 0,
	wheelRadius = WHEEL_RADIUS_FALLBACK,
	wheelRoll = true,
	wheels = {},
	wheelSteer = 0, -- smoothed cosmetic steer angle input
	wheelSlip = 1, -- cosmetic spin multiplier: >1 spinning up, <1 locking up

	driftAmount = 0,
	driftWasLoose = false, -- rising-edge latch for the entry kick
	driftCharge = 0, -- mini-turbo charge, in driftAmount-seconds
	driftTier = 0, -- tier the current charge would pay out (0 = nothing yet)
	driftBelowFor = 0, -- seconds spent under DRIFT_CHARGE_MIN_AMOUNT (release grace)
	driftAirFor = 0, -- seconds airborne while holding a charge
	flipStuckFor = 0,
	flipHopUntil = 0,
}

local warned = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("ChassisController: " .. message)
end

-- ==========================================================================
-- small pure helpers
-- ==========================================================================
local function yawLook(yawDegrees: number): Vector3
	local radians = math.rad(yawDegrees)
	return Vector3.new(-math.sin(radians), 0, -math.cos(radians))
end

-- Shortest signed difference between two headings, in degrees, wrapped to [-180, 180].
local function angleDelta(fromDeg: number, toDeg: number): number
	return (toDeg - fromDeg + 180) % 360 - 180
end

local function yawFromLook(lookVector: Vector3): number
	local flat = MathUtil.flatUnit(lookVector)
	if flat == Vector3.zero then
		return 0
	end
	return math.deg(math.atan2(-flat.X, -flat.Z))
end

-- Sibling controllers are resolved lazily, every call, and never trusted to exist.
local function readAxis(methodName: string): number
	local input = ctxRef and ctxRef.ctrl and ctxRef.ctrl.InputController
	if not input then
		return 0
	end
	local method = input[methodName]
	if type(method) ~= "function" then
		return 0
	end
	local value = method()
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(value, -1, 1)
end

-- Fire-and-forget camera kick. Same lazy, never-trusted resolution as readAxis: the
-- camera is a sibling controller, so a missing or broken one must never break driving.
local function pokeCamera(intensity: number, seconds: number)
	local camera = ctxRef and ctxRef.ctrl and ctxRef.ctrl.CameraController
	if not camera or type(camera.shake) ~= "function" then
		return
	end
	pcall(camera.shake, intensity, seconds)
end

local function readDriftHeld(): boolean
	local input = ctxRef and ctxRef.ctrl and ctxRef.ctrl.InputController
	if not input or type(input.isDrifting) ~= "function" then
		return false
	end
	return input.isDrifting() == true
end

-- ==========================================================================
-- ground probe filter
-- ==========================================================================
local function rebuildRayFilter()
	local car = state.car
	if not car then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	-- ArenaService's pads, chevrons, block caps and pit sensors are all CanCollide=false
	-- but still queryable, and a pad top would read as ground and make the car hop.
	-- Only floor / walls / ramps / blocks are collidable, so this is the real filter.
	params.RespectCanCollide = true

	local filter = { car }
	local missing = false
	for _, name in ipairs(IGNORED_FOLDERS) do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(filter, folder)
		else
			missing = true
		end
	end
	params.FilterDescendantsInstances = filter

	state.rayParams = params
	state.filterStale = missing -- retry until those services have built their folders
end

-- ==========================================================================
-- boost pads — client-side detection, locally predicted kick
-- ==========================================================================
--[[ Pads are anchored, non-collidable, CanTouch parts tagged ChassisSpec.PAD_TAG
	(ArenaService builds them). We box-test against our own hull instead of relying on
	Touched, so it works the same on every client.

	The authoritative BoostUntil attribute is SERVER-owned (pickups/weapons may set it);
	we never write it. Whichever boost is active wins, and they never stack. ]]
local function checkBoostPads(now: number)
	local hull, spec = state.hull, state.spec
	if not (hull and spec) then
		return
	end

	local marginXZ = math.max(spec.hullSize.X, spec.hullSize.Z) * 0.5
	local marginY = spec.hoverHeight + spec.hullSize.Y
	local position = hull.Position

	for _, pad in ipairs(CollectionService:GetTagged(ChassisSpec.PAD_TAG)) do
		if pad:IsA("BasePart") then
			local rel = pad.CFrame:PointToObjectSpace(position)
			local half = pad.Size * 0.5
			if
				math.abs(rel.X) <= half.X + marginXZ
				and math.abs(rel.Z) <= half.Z + marginXZ
				and math.abs(rel.Y) <= half.Y + marginY
			then
				state.padBoostUntil = now + CFG.BOOST_SECONDS
				return
			end
		end
	end
end

-- ==========================================================================
-- wheels (cosmetic)
-- ==========================================================================
--[[ Spin/steer the wheels with manual per-frame math. CarFactory welds every cosmetic
	part rigidly to the hull with a WeldConstraint parented to the part and named "Weld",
	so a wheel has to be FREED before it can be animated. Resolved once at attach so the
	loop stays cheap:
		WeldConstraint  -> disable it LOCALLY (our own client-owned car, never replicates)
		                   and drive the wheel CFrame relative to the hull
		Weld / Motor6D  -> animate C0/C1 around the recorded base transform (no freeing needed)
		no joint        -> drive the wheel CFrame relative to the hull
	The cylinder axis is local X (the car's right), so roll is CFrame.Angles(theta, 0, 0).
	Hover cars (the UFO's glowing pods live under the same FL/FR/RL/RR names) still steer
	but never roll, and a car with no Wheels folder skips all of this. ]]
local function buildWheelRecords(car: Model, hull: BasePart)
	local records = {}
	local folder = car:FindFirstChild(ChassisSpec.WHEELS)
	if not folder then
		return records
	end

	local jointByPart, weldsByPart = {}, {}
	for _, descendant in ipairs(car:GetDescendants()) do
		if descendant:IsA("Weld") or descendant:IsA("Motor6D") then
			if descendant.Part0 and not jointByPart[descendant.Part0] then
				jointByPart[descendant.Part0] = descendant
			end
			if descendant.Part1 and not jointByPart[descendant.Part1] then
				jointByPart[descendant.Part1] = descendant
			end
		elseif descendant:IsA("WeldConstraint") then
			for _, part in ipairs({ descendant.Part0, descendant.Part1 }) do
				if part then
					local list = weldsByPart[part]
					if not list then
						list = {}
						weldsByPart[part] = list
					end
					table.insert(list, descendant)
				end
			end
		end
	end

	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			local record = { part = part }
			local joint = jointByPart[part]

			if joint then
				record.joint = joint
				record.wheelIsPart1 = joint.Part1 == part
				record.baseTransform = record.wheelIsPart1 and joint.C1 or joint.C0
			else
				record.baseOffset = hull.CFrame:ToObjectSpace(part.CFrame)
				local welds = weldsByPart[part]
				local pinned = part:FindFirstChild(WELD_NAME)
				if pinned and pinned:IsA("WeldConstraint") then
					pinned.Enabled = false
				end
				if welds then
					for _, weld in ipairs(welds) do
						weld.Enabled = false
					end
				end
				-- Freed from the hull: keep it out of the physics and out of every query.
				part.Massless = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
			end

			local initial = part.Name:upper():sub(1, 1)
			if initial == FRONT_PREFIX then
				record.front = true
			elseif initial == REAR_PREFIX then
				record.front = false
			else
				-- Unnamed build: forward of hull center (-Z is forward) steers.
				record.front = hull.CFrame:PointToObjectSpace(part.Position).Z < 0
			end

			table.insert(records, record)
		end
	end

	return records
end

local function stepWheels(hull: BasePart, forwardSpeed: number, steerInput: number, slipTarget: number, dt: number)
	local records = state.wheels
	if #records == 0 then
		return
	end

	--[[ Cosmetic slip. A tyre pinned exactly to ground speed looks inert, so the spin is
		allowed to disagree with the ground the way a real one does: faster than the road
		while the throttle is still winning, nearly stopped under heavy braking. Blended
		rather than switched, so it reads as the tyre finding grip instead of a state flip.
		forwardSpeed is the LONGITUDINAL component, which is what actually rolls a wheel —
		so a big slip angle correctly rolls the wheels slower, not faster. ]]
	state.wheelSlip = MathUtil.damp(state.wheelSlip, slipTarget, WHEEL_SLIP_RATE, dt)

	-- Rolling forward (-Z) means a negative rotation about the local +X axle. Signed, so
	-- reverse counter-rotates for free. Hover pods never roll: their spin stays at identity.
	if state.wheelRoll then
		local rollRate = (forwardSpeed * state.wheelSlip) / math.max(state.wheelRadius, EPSILON)
		state.wheelSpin = (state.wheelSpin - rollRate * dt) % (math.pi * 2)
	end

	-- Ease the cosmetic steer so the wheels return to centre instead of snapping back.
	state.wheelSteer = MathUtil.damp(state.wheelSteer, steerInput, WHEEL_STEER_RATE, dt)

	local spinCF = CFrame.Angles(state.wheelSpin, 0, 0)
	local frontCF = CFrame.Angles(0, math.rad(WHEEL_STEER_DEG) * state.wheelSteer * STEER_TO_YAW, 0) * spinCF

	for _, record in ipairs(records) do
		local part = record.part
		if part.Parent then
			local rotation = record.front and frontCF or spinCF
			local joint = record.joint
			if joint then
				if joint.Parent then
					if record.wheelIsPart1 then
						joint.C1 = rotation:Inverse() * record.baseTransform
					else
						joint.C0 = rotation:Inverse() * record.baseTransform
					end
				end
			elseif record.baseOffset then
				part.CFrame = hull.CFrame * record.baseOffset * rotation
			end
		end
	end
end

-- ==========================================================================
-- knockback stagger
-- ==========================================================================
--[[ CombatService sets StaggerUntil on the victim car at the same instant it applies the
	knockback impulse. Drive has only ~1.2x headroom over gravity + accel, but that is
	still enough to erase an impulse in about a tenth of a second, which would make every
	ram and rocket feel like a tap. For the window we clamp the constraint to the VERTICAL
	axis only (PerAxis force limit): the hover spring keeps holding the car up, so it gets
	shoved rather than sinking, while not one stud of horizontal force can fight the hit.
	Called only on the transition, so there is no per-frame property churn. ]]
local function setStaggerMode(drive: LinearVelocity, on: boolean)
	local ok = pcall(function()
		if on then
			drive.ForceLimitMode = Enum.ForceLimitMode.PerAxis
			drive.MaxAxesForce = Vector3.new(0, state.maxForce, 0)
		else
			drive.ForceLimitMode = Enum.ForceLimitMode.Magnitude
			drive.MaxForce = state.maxForce
		end
	end)
	if not ok then
		-- No PerAxis limit in this engine: yield drive authority outright for the window.
		-- The car briefly falls at gravity instead of hovering, which still reads as a hit.
		warnOnce("peraxis", "PerAxis force limit unavailable — disabling Drive during stagger instead")
		drive.Enabled = not on
	end
end

-- ==========================================================================
-- attach / detach
-- ==========================================================================
local function detach()
	-- Bumping the token also cancels any attach still waiting on replication.
	state.attachToken += 1
	if state.contactConn then
		state.contactConn:Disconnect()
		state.contactConn = nil
	end
	state.contactYieldUntil = 0
	state.contactCooldownUntil = 0
	state.prevPlanar = nil
	state.blockedDir = nil
	state.blockedUntil = 0

	state.car = nil
	state.hull = nil
	state.drive = nil
	state.steer = nil
	state.spec = nil
	state.ready = false

	state.forwardSpeed = 0
	state.lateralSpeed = 0
	state.speed = 0
	state.grounded = false
	state.drifting = false
	state.groundNormal = Vector3.yAxis
	state.groundDistance = 0
	state.upVector = Vector3.yAxis
	state.padBoostUntil = 0
	state.yielding = false
	state.maxForce = 0

	state.rayParams = nil
	state.filterStale = true
	state.sendAccum = 0
	state.padAccum = 0
	state.wheels = {}
	state.wheelRadius = WHEEL_RADIUS_FALLBACK
	state.wheelRoll = true
	state.wheelSteer = 0
	state.wheelSlip = 1

	state.driftAmount = 0
	-- Stale `true` here would swallow the entry kick on the first frame of the NEXT car.
	state.driftWasLoose = false
	state.driftCharge = 0
	state.driftTier = 0
	state.driftBelowFor = 0
	state.driftAirFor = 0
	state.flipStuckFor = 0
	state.flipHopUntil = 0
end

--[[ SetNetworkOwner can land a frame or two after the model replicates; driving before
	it does just gets overwritten by the server. Poll briefly, then start anyway.
	GetNetworkOwner is not readable from the client in every engine version, so the
	call is pcall'd and we fall back to a short fixed wait. ]]
local function waitForOwnership(hull: BasePart, token: number): boolean
	local deadline = os.clock() + OWNERSHIP_TIMEOUT
	local function query()
		return hull:GetNetworkOwner()
	end
	while true do
		local ok, owner = pcall(query)
		if not ok then
			task.wait(OWNERSHIP_FALLBACK_WAIT)
			return true -- cannot be queried here; assume the server did its job
		end
		if owner == LocalPlayer then
			return true
		end
		if os.clock() >= deadline then
			return false
		end
		task.wait()
		if state.attachToken ~= token or not hull.Parent then
			return false
		end
	end
end

local function attach(car: Model, carId: string?)
	detach()
	local token = state.attachToken

	local hull = car:FindFirstChild(ChassisSpec.HULL) or car:WaitForChild(ChassisSpec.HULL, ATTACH_TIMEOUT)
	if state.attachToken ~= token or not car.Parent then
		return
	end
	if not (hull and hull:IsA("BasePart")) then
		warnOnce("hull", "spawned car has no " .. ChassisSpec.HULL .. " part — not driving")
		return
	end

	local rootAtt = hull:FindFirstChild(ChassisSpec.ROOT_ATT) or hull:WaitForChild(ChassisSpec.ROOT_ATT, ATTACH_TIMEOUT)
	local drive = hull:FindFirstChild(ChassisSpec.DRIVE) or hull:WaitForChild(ChassisSpec.DRIVE, ATTACH_TIMEOUT)
	local steer = hull:FindFirstChild(ChassisSpec.STEER) or hull:WaitForChild(ChassisSpec.STEER, ATTACH_TIMEOUT)
	if state.attachToken ~= token or not car.Parent or not hull.Parent then
		return
	end

	if not (drive and drive:IsA("LinearVelocity")) then
		warnOnce("drive", "hull has no " .. ChassisSpec.DRIVE .. " LinearVelocity — not driving")
		return
	end
	if not (steer and steer:IsA("AlignOrientation")) then
		-- Drivable but with no orientation authority: warn and carry on rather than brick.
		warnOnce("steer", "hull has no " .. ChassisSpec.STEER .. " AlignOrientation — no upright control")
		steer = nil
	end

	--[[ Resolved WITH the car's body modifiers, not from the id alone. A mode can hand
		you a modified body — the Juggernaut's is 2x, heavier and a little slower — and
		every number below has to describe the car that actually spawned. hoverHeight
		above all: resolving the stock body for a 2x car commands a ride height half a
		body too low, so the hull sits IN the road and the hover spring fights the floor
		for the whole life of the car (see the CarFactory header on exactly that failure).
		The id still comes from the lifecycle payload first — it arrives with the spawn,
		while the attribute has to replicate. ]]
	local spec = ChassisSpec.resolve(
		carId or car:GetAttribute(ATTR.CAR_ID) or Config.STARTER_CAR,
		ChassisSpec.modifiersOf(car)
	)
	local carDef = Config.CARS_BY_ID[spec.carId]

	state.car = car
	state.hull = hull
	state.drive = drive
	state.steer = steer
	state.spec = spec
	-- Measured per model and stored in Config.CARS[i].wheels.radius. The old build.wheelRadius
		-- is gone with the procedural cars; the fallback would roll every wheel at the wrong rate.
		-- x spec.scale, because CarFactory scaled the cylinders with the body: rolling a
		-- 2x tyre at the stock radius spins it at twice the speed it is travelling.
		state.wheelRadius = ((carDef and carDef.wheels and carDef.wheels.radius)
			or (carDef and carDef.build and carDef.build.wheelRadius) or WHEEL_RADIUS_FALLBACK)
			* (spec.scale or 1)
	state.wheelRoll = not (spec.hover or (carDef and carDef.build and carDef.build.saucer == true))

	--[[ Constraint check, once. CarFactory already tuned BOTH constraints — MaxForce with
		deliberately small headroom so rams still shove you, MaxTorque from the pinned
		Config value, Responsiveness so the nose lags a little. We do NOT overwrite any of
		that; we only fill in what a malformed car left empty, and we cache MaxForce so the
		stagger window can hand it back. Wrapped because a read-only or missing property
		must not take the whole chassis down. ]]
	local hasRootAtt = rootAtt ~= nil and rootAtt:IsA("Attachment")
	local okSetup, err = pcall(function()
		if hasRootAtt and not drive.Attachment0 then
			drive.Attachment0 = rootAtt
		end
		drive.RelativeTo = Enum.ActuatorRelativeTo.World
		drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		drive.ForceLimitMode = Enum.ForceLimitMode.Magnitude
		if drive.MaxForce <= 0 or drive.MaxForce == math.huge then
			local peakAccel = spec.accel * CFG.BOOST_ACCEL_MULTIPLIER
			drive.MaxForce = hull.AssemblyMass
				* (Workspace.Gravity + peakAccel + spec.coastDrag)
				* FORCE_HEADROOM_FALLBACK
		end
		state.maxForce = drive.MaxForce
		drive.VectorVelocity = Vector3.zero
		drive.Enabled = true

		if steer then
			if hasRootAtt and not steer.Attachment0 then
				steer.Attachment0 = rootAtt
			end
			steer.Mode = Enum.OrientationAlignmentMode.OneAttachment
			steer.PrimaryAxisOnly = false
			steer.ReactionTorqueEnabled = false
			steer.RigidityEnabled = false
			if steer.MaxTorque <= 0 then
				steer.MaxTorque = CFG.UPRIGHT_TORQUE
			end
			steer.Enabled = true
		end
	end)
	if not okSetup then
		warnOnce("setup", "constraint check failed -> " .. tostring(err))
	end
	if not drive.Attachment0 then
		warnOnce("rootatt", ChassisSpec.ROOT_ATT .. " missing: Drive has no Attachment0, the car cannot move")
	end

	-- Seed the integrators from where the car actually is, so nothing snaps on spawn.
	-- SpawnService has already pointed Steer.CFrame down the spawn direction.
	state.yaw = yawFromLook(hull.CFrame.LookVector)
	state.upVector = Vector3.yAxis
	local velocity = hull.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local look = MathUtil.flatUnit(hull.CFrame.LookVector)
	if look == Vector3.zero then
		look = yawLook(state.yaw)
	end
	state.forwardSpeed = flatVelocity:Dot(look)
	state.lateralSpeed = flatVelocity:Dot(look:Cross(Vector3.yAxis))
	rebuildRayFilter()

	local owned = waitForOwnership(hull, token)
	if state.attachToken ~= token or not car.Parent or not hull.Parent then
		return
	end
	if not owned then
		warnOnce("ownership", "network ownership of the hull never arrived — driving anyway")
	end

	-- Freeing the wheels is the LAST thing we do: an unwelded wheel that nothing is
	-- teleporting yet would visibly drop off the car, so the step loop has to be live
	-- the moment they come loose.
	state.wheels = buildWheelRecords(car, hull)
	state.ready = true

	--[[ One frame later the disabled welds have settled, so AssemblyRootPart is honest and
		we can anchor every wheel that really did come free. An anchored, non-collidable part
		that we teleport each frame costs no physics and cannot accumulate fall velocity.
		A wheel still attached to the hull assembly is left alone — anchoring that would
		anchor the entire car. ]]
	task.wait()
	if state.attachToken ~= token or not car.Parent then
		return
	end
	for _, record in ipairs(state.wheels) do
		local part = record.part
		if record.baseOffset and part.Parent and part.AssemblyRootPart == part then
			part.Anchored = true
		end
	end
end

-- ==========================================================================
-- per-frame step
-- ==========================================================================
local function step(dt: number)
	if not state.ready then
		return
	end

	local car, hull, drive, spec = state.car, state.hull, state.drive, state.spec
	if not (car and hull and drive and spec) then
		return
	end
	if not car.Parent or not hull.Parent then
		detach()
		return
	end

	dt = math.min(dt, MAX_STEP)
	local now = Workspace:GetServerTimeNow()

	-- 1) ground probe --------------------------------------------------------
	local result = Workspace:Raycast(hull.Position, Vector3.new(0, -spec.rayLength, 0), state.rayParams)
	local grounded = false
	local groundNormal = Vector3.yAxis
	local groundDistance = spec.rayLength
	if result then
		groundNormal = result.Normal
		groundDistance = result.Distance
		grounded = groundNormal.Y >= CFG.MAX_SLOPE_COS
			and groundDistance <= spec.hoverHeight * GROUNDED_HEIGHT_FACTOR
	end
	state.grounded = grounded
	state.groundNormal = groundNormal
	state.groundDistance = groundDistance

	-- velocity decomposed against where the car actually points ---------------
	local velocity = hull.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local look = MathUtil.flatUnit(hull.CFrame.LookVector)
	if look == Vector3.zero then
		look = yawLook(state.yaw) -- nose straight up/down: fall back to our heading
	end
	local right = look:Cross(Vector3.yAxis)
	local forwardSpeed = flatVelocity:Dot(look)
	local lateralSpeed = flatVelocity:Dot(right)

	-- transient states -------------------------------------------------------
	local serverBoost = ChassisSpec.isBoosting(car, now)
	local padBoost = state.padBoostUntil > now
	local boosting = serverBoost or padBoost
	local frozen = ChassisSpec.isFrozen(car, now)
	local speedMultiplier = ChassisSpec.speedMultiplier(car, now)
	if padBoost and not serverBoost then
		-- Server has not (yet) set BoostUntil, so apply the pad's kick locally. Never stacks.
		speedMultiplier = speedMultiplier * CFG.BOOST_MULTIPLIER
	end

	--[[ 8) knockback stagger. The server owns this window: we hand back horizontal drive
		authority so the impulse can actually move us, and skip our own throttle and grip
		integration so neither eats the hit. Nothing has to be restored afterwards —
		forwardSpeed/lateralSpeed are re-read from the hull every frame, so integration
		resumes from the ACTUAL post-impulse velocity with no jerk. Steering and uprighting
		keep running the whole time, so the player can fight for control as it decays. ]]
	-- Collision detection, before anything else consumes the velocity.
	local planarNow = Vector3.new(velocity.X, 0, velocity.Z)
	local ownDvLimit = (state.maxForce / math.max(hull.AssemblyMass, 1)) * dt * EXTERNAL_DV_SLACK
	if state.prevPlanar then
		local dv = planarNow - state.prevPlanar
		local dvMag = dv.Magnitude
		if dvMag > ownDvLimit and dvMag > EPSILON then
			-- dv points AWAY from whatever we hit, so the blocked direction is its opposite.
			state.blockedDir = -dv.Unit
			state.blockedUntil = now + CONTACT_BLOCK_HOLD
			if dvMag > HARD_IMPACT_DV then
				state.contactYieldUntil = now + CONTACT_YIELD_SECONDS
				if WALLDBG then
					warn(string.format("[WALL] impact dv=%.1f (own limit %.1f) normal=(%.2f,%.2f) spd=%.1f",
						dvMag, ownDvLimit, -state.blockedDir.X, -state.blockedDir.Z, velocity.Magnitude))
				end
			end
		end
	end
	state.prevPlanar = planarNow

	local staggered = ChassisSpec.isStaggered(car, now)
	--[[ A wall impact yields exactly like a knockback: horizontal force off, hover spring
		still on. The engine then resolves the collision with the wall's own elasticity, and
		because forwardSpeed/lateralSpeed are re-read from the hull every frame we resume
		from the true post-impact velocity with no jerk. This replaced a raycast that tried
		to reimplement collision response by hand and only ever made walls feel sticky. ]]
	local contactYield = (state.contactYieldUntil or 0) > now
	local yielding = staggered or contactYield
	if yielding ~= state.yielding then
		state.yielding = yielding
		setStaggerMode(drive, yielding)
		if WALLDBG then
			warn(string.format("[WALL] yield %s | vel=(%.0f,%.0f,%.0f) spd=%.1f fwd=%.1f lat=%.1f grounded=%s mode=%s",
				yielding and "ON " or "OFF", velocity.X, velocity.Y, velocity.Z, velocity.Magnitude,
				forwardSpeed, lateralSpeed, tostring(grounded), drive.ForceLimitMode.Name))
			state.dbgTraceUntil = now + 0.9
		end
	end
	if WALLDBG and (state.dbgTraceUntil or 0) > now and (state.dbgTraceAt or 0) <= now then
		state.dbgTraceAt = now + 0.1
		warn(string.format("[WALL]  trace y=%s spd=%.1f fwd=%.1f lat=%.1f blocked=%s lead=%.0f",
			tostring(yielding), velocity.Magnitude, forwardSpeed, lateralSpeed,
			tostring((state.blockedUntil or 0) > now),
			angleDelta(yawFromLook(hull.CFrame.LookVector), state.yaw)))
	end

	-- 3) throttle ------------------------------------------------------------
	local throttle = readAxis("getThrottle")
	local targetSpeed = 0
	if throttle > INPUT_DEADZONE then
		targetSpeed = spec.topSpeed * speedMultiplier * throttle
	elseif throttle < -INPUT_DEADZONE then
		targetSpeed = spec.reverseSpeed * speedMultiplier * throttle
	end

	if grounded and not yielding then
		local rate
		if math.abs(throttle) <= INPUT_DEADZONE then
			rate = spec.coastDrag
		elseif forwardSpeed * targetSpeed < 0 then
			rate = spec.brake -- input opposes the way we are actually moving
		else
			rate = spec.accel * (boosting and CFG.BOOST_ACCEL_MULTIPLIER or 1)
		end
		forwardSpeed = MathUtil.approach(forwardSpeed, targetSpeed, rate * dt)
	end
	-- Airborne: no throttle authority at all, existing momentum is kept.

	-- 6) grip / drift --------------------------------------------------------
	--[[ How committed is this corner? Two ramps multiplied: you must be going fast AND
		turning hard. This single value drives grip, extra yaw and the skid fx together,
		so they can never disagree about whether the car is drifting.
		The DRIFT button is now only a handbrake — it forces the value to 1 so you can
		break traction below the automatic thresholds. It is NOT required to drift. ]]
	local steerNow = readAxis("getSteer")
	local driftSpeedFraction = MathUtil.clamp01(math.abs(forwardSpeed) / math.max(spec.topSpeed, EPSILON))
	local speedTerm = MathUtil.clamp01((driftSpeedFraction - CFG.DRIFT_AUTO_SPEED_MIN)
		/ math.max(1 - CFG.DRIFT_AUTO_SPEED_MIN, EPSILON))
	local steerTerm = MathUtil.clamp01((math.abs(steerNow) - CFG.DRIFT_AUTO_STEER_MIN)
		/ math.max(1 - CFG.DRIFT_AUTO_STEER_MIN, EPSILON))
	local driftAmount = speedTerm * steerTerm
	if readDriftHeld() then
		driftAmount = 1 -- handbrake override
	end
	if not grounded or yielding then
		driftAmount = 0
	end
	state.driftAmount = driftAmount
	local breakingLoose = driftAmount >= DRIFT_KICK_THRESHOLD

	--[[ Drift ENTRY kick. Lowering grip alone means the slide has to accumulate through
		the grip time constant, which measured ~583ms to establish — the button feels
		disconnected from the car. Injecting the slip angle directly on the rising edge
		makes the tail step out on the same frame you press, and the yaw boost then
		sustains it. Sign: turning right rotates the nose right while momentum carries on,
		so velocity ends up LEFT of the nose -> lateral goes negative for a right turn.
		Only ever ADDS to an existing slide, so re-pressing mid-drift cannot damp it. ]]
	if breakingLoose and not state.driftWasLoose and grounded and not yielding then
		if math.abs(steerNow) > INPUT_DEADZONE then
			local kick = -math.sign(steerNow) * math.abs(forwardSpeed)
				* math.tan(math.rad(CFG.DRIFT_ENTRY_KICK_DEG)) * driftAmount
			if math.abs(kick) > math.abs(lateralSpeed) then
				lateralSpeed = kick
			end
		end
	end
	state.driftWasLoose = breakingLoose

	if not yielding then
		local gripRate = MathUtil.lerp(spec.grip, spec.driftGrip, driftAmount)
		if not grounded then
			gripRate = gripRate * AIR_GRIP_FRACTION
		end
		lateralSpeed = MathUtil.damp(lateralSpeed, 0, gripRate, dt)
	end
	state.drifting = grounded and not yielding and driftAmount >= DRIFT_FX_THRESHOLD
		and math.abs(lateralSpeed) >= DRIFT_MIN_LATERAL

	--[[ 7) planar speed ceiling. Without this the car accelerates sideways without bound:
		every frame the yaw converts forward velocity into lateral, the throttle restores
		forward to target, and grip only bleeds lateral slowly — so total speed ratchets up
		past anything the car should reach. Bleeding the excess at brake rate (rather than
		hard-clamping) keeps it smooth, and scaling BOTH components leaves the slip angle
		untouched, so the drift still looks like a drift, it just costs you speed.
		Skipped while yielding or airborne on purpose: knockback and ramp launches are
		SUPPOSED to exceed top speed. ]]
	if grounded and not yielding then
		local maxPlanar = spec.topSpeed * speedMultiplier * CFG.MAX_PLANAR_OVERSPEED
		local planarSpeed = math.sqrt(forwardSpeed * forwardSpeed + lateralSpeed * lateralSpeed)
		if planarSpeed > maxPlanar and planarSpeed > EPSILON then
			local allowed = MathUtil.approach(planarSpeed, maxPlanar, spec.brake * dt)
			local scale = allowed / planarSpeed
			forwardSpeed = forwardSpeed * scale
			lateralSpeed = lateralSpeed * scale
		end
	end

	--[[ 6b) MINI-TURBO charge and payout. Placed here on purpose: lateralSpeed is final
		only after the planar cap, and the charge gate reads the REAL slide, not the intent.

		Gated on actual lateral motion (DRIFT_MIN_LATERAL, the same test isDrifting uses) as
		well as driftAmount, which closes the obvious exploit: the handbrake forces
		driftAmount to 1, so charging on driftAmount alone would pay a player for holding
		the drift button in a straight line. No slide, no lateral, no charge.

		A crash CANCELS the charge rather than paying it. This matters more than it looks:
		`yielding` forces driftAmount to 0, so without an explicit cancel every wall impact
		mid-drift would read as a release and reward the player for crashing. ]]
	if yielding then
		state.driftCharge = 0
		state.driftBelowFor = 0
		state.driftAirFor = 0
	elseif not grounded then
		-- Airborne: hold the charge, pay out on landing, but not forever.
		state.driftAirFor += dt
		if state.driftAirFor > DRIFT_AIR_HOLD_SECONDS then
			state.driftCharge = 0
		end
	else
		state.driftAirFor = 0
		local sliding = driftAmount >= DRIFT_CHARGE_MIN_AMOUNT
			and math.abs(lateralSpeed) >= DRIFT_MIN_LATERAL
		if sliding then
			state.driftCharge += driftAmount * dt
			state.driftBelowFor = 0
		elseif state.driftCharge > 0 then
			state.driftBelowFor += dt
			if state.driftBelowFor >= DRIFT_RELEASE_GRACE then
				--[[ Payout through state.padBoostUntil — the EXISTING boost path — so the
					mini-turbo inherits everything already tuned and observed: the 1.6x
					speedMultiplier, BOOST_ACCEL_MULTIPLIER's eager pull, the raised planar
					ceiling, isBoosting() for the HUD, and never stacking with a pad or a
					server boost. Tiers differ in DURATION only, so there is no second
					magnitude to keep in sync with the first. ]]
				if state.driftCharge >= DRIFT_CHARGE_TIER1 then
					local tier = state.driftCharge >= DRIFT_CHARGE_TIER2 and 2 or 1
					state.padBoostUntil = now + CFG.BOOST_SECONDS * DRIFT_BOOST_FRACTION[tier]
					pokeCamera(DRIFT_BOOST_SHAKE[tier], DRIFT_BOOST_SHAKE_TIME)
				end
				state.driftCharge = 0
				state.driftBelowFor = 0
			end
		end
	end
	-- What a release would pay RIGHT NOW: 0, 1 or 2. Drives the charge readout.
	if state.driftCharge >= DRIFT_CHARGE_TIER2 then
		state.driftTier = 2
	elseif state.driftCharge >= DRIFT_CHARGE_TIER1 then
		state.driftTier = 1
	else
		state.driftTier = 0
	end

	-- 2) hover spring / gravity ---------------------------------------------
	local verticalSpeed = velocity.Y
	if grounded then
		local err = math.clamp(spec.hoverHeight - groundDistance, -spec.hoverHeight, spec.hoverHeight)
		verticalSpeed += (err * CFG.GROUND_SPRING - verticalSpeed * CFG.GROUND_DAMPER) * dt
	else
		-- Airborne we hand Y back to physics. A velocity constraint asked to hold the
		-- current Y would cancel gravity and give moon jumps, so we ask for exactly
		-- where gravity is about to take us instead. Ramp jumps arc properly.
		verticalSpeed -= Workspace.Gravity * dt
	end

	--[[ 2b) FLIP UNSTICK. Read the math before changing this: Steer already commands
		ground-normal-up while grounded and WORLD up while airborne, every frame, and
		CarFactory scales MaxTorque by inertia (~7.6 rad/s^2 for every car, with 4x angular
		headroom on MaxAngularVelocity specifically for uprighting). A car with room to
		rotate therefore always self-rights, heavy or not, and needs nothing from here.
		What torque cannot solve is a hull WEDGED against geometry. So this only lifts the
		car a couple of studs to give that torque somewhere to rotate into — it never
		rotates anything itself. The actual hull up-vector is the test, not state.upVector,
		which is our commanded up and is always already upright. ]]
	local planarSpeedNow = math.sqrt(forwardSpeed * forwardSpeed + lateralSpeed * lateralSpeed)
	if hull.CFrame.UpVector.Y < FLIP_UP_DOT and planarSpeedNow < FLIP_STUCK_SPEED and not yielding then
		state.flipStuckFor += dt
	else
		state.flipStuckFor = 0
	end
	if state.flipStuckFor >= FLIP_STUCK_SECONDS and now >= state.flipHopUntil then
		state.flipStuckFor = 0
		state.flipHopUntil = now + FLIP_HOP_COOLDOWN
		verticalSpeed = FLIP_HOP_SPEED
	end

	local planar = look * forwardSpeed + right * lateralSpeed

	--[[ 11) contact projection, from MEASURED disagreement rather than a raycast.
		If the velocity we commanded last frame did not materialise, something solid is in the
		way, and the shortfall points the way we tried and failed to go. That covers walls,
		corners, ramps and blocks with no probe and no false positives from decoration.
		Cancelling only the blocked component stops the throttle dumping ~50k of force into a
		wall — measured: the car reached full speed pressed against one — while along-wall
		motion survives, so you keep sliding and can steer out. The direction is HELD briefly:
		without that the cancel removes the shortfall, which clears the detection, which
		re-commands into the wall, oscillating at frame rate. ]]
	if not yielding and state.blockedDir and (state.blockedUntil or 0) > now then
		local into = planar:Dot(state.blockedDir)
		if into > 0 then
			planar = planar - state.blockedDir * into
		end
	end

	drive.VectorVelocity = Vector3.new(planar.X, verticalSpeed, planar.Z)

	state.forwardSpeed = forwardSpeed
	state.lateralSpeed = lateralSpeed
	state.speed = math.sqrt(forwardSpeed * forwardSpeed + lateralSpeed * lateralSpeed)

	-- 4) steering ------------------------------------------------------------
	local steerInput = readAxis("getSteer")
	local speedFraction = MathUtil.clamp01(math.abs(forwardSpeed) / math.max(spec.topSpeed, EPSILON))
	local authority
	if speedFraction <= AUTHORITY_FULL_FRACTION then
		-- A stopped car still pivots a little; authority climbs to 1 at cruising speed.
		authority = MathUtil.map(speedFraction, 0, AUTHORITY_FULL_FRACTION, CFG.TURN_SPEED_FLOOR, 1)
	else
		authority = MathUtil.map(speedFraction, AUTHORITY_FULL_FRACTION, 1, 1, AUTHORITY_AT_TOP)
	end
	if not grounded then
		authority = authority * CFG.AIR_CONTROL
	end
	if frozen then
		authority = authority * MathUtil.lerp(1, CFG.FROZEN_SPEED_MULTIPLIER, FROZEN_TURN_BLEND)
	end

	local steerSign = forwardSpeed < -REVERSE_STEER_SPEED and -1 or 1
	-- Drifting rotates the car FASTER than it travels. That slip angle between heading and
	-- velocity is what reads as a drift; without it, low grip only gives soggy understeer.
	--[[ Re-sync the commanded heading against reality BEFORE integrating this frame.
		state.yaw is dead-reckoned from attach, but a wall or a ram physically ROTATES the
		hull. Once the two diverge, AlignOrientation spends its whole torque budget dragging
		the car back to a heading that no longer relates to where it points — the car snaps,
		fights itself and reads as broken physics after every bounce.
		Capping the LEAD (rather than hard-snapping to actual) means a collision is genuinely
		accepted — you really do get spun and have to steer out of it — while a small lead is
		preserved so steering still feels like it is ahead of the car rather than chasing it. ]]
	local actualYaw = yawFromLook(hull.CFrame.LookVector)
	local lead = angleDelta(actualYaw, state.yaw)
	if math.abs(lead) > YAW_RESYNC_DEG then
		state.yaw = (actualYaw + math.sign(lead) * YAW_RESYNC_DEG) % 360
	end

	local driftYaw = MathUtil.lerp(1, spec.driftTurnBoost, state.driftAmount or 0)
	state.yaw = (state.yaw + spec.turnRate * steerInput * STEER_TO_YAW * authority * driftYaw * steerSign * dt) % 360

	-- 5) upright + slope hug -------------------------------------------------
	local targetUp = grounded and groundNormal or Vector3.yAxis
	local blended = state.upVector:Lerp(targetUp, 1 - math.exp(-UP_BLEND_RATE * dt))
	if blended.Magnitude < EPSILON then
		blended = Vector3.yAxis
	end
	state.upVector = blended.Unit

	local steerConstraint = state.steer
	if steerConstraint and steerConstraint.Parent then
		local up = state.upVector
		local back = -yawLook(state.yaw)
		local rightAxis = up:Cross(back)
		if rightAxis.Magnitude < EPSILON then
			rightAxis = Vector3.xAxis -- heading parallel to up: any basis will do for one frame
		end
		rightAxis = rightAxis.Unit
		back = rightAxis:Cross(up).Unit
		steerConstraint.CFrame = CFrame.fromMatrix(Vector3.zero, rightAxis, up, back)
	end

	-- 9) cosmetic wheels -----------------------------------------------------
	--[[ Spin-up while the throttle still has a big gap to close, lock-up while braking
		against our own motion. Same two cases the throttle block already distinguishes,
		read back off it rather than re-derived, so the wheels can never disagree with
		what the engine is doing. Airborne wheels just keep rolling: nothing to grip. ]]
	local slipTarget = 1
	if grounded and not yielding then
		if math.abs(throttle) > INPUT_DEADZONE and forwardSpeed * targetSpeed < 0 then
			slipTarget = WHEEL_LOCK_SLIP
		elseif math.abs(throttle) > INPUT_DEADZONE then
			local gap = MathUtil.clamp01((math.abs(targetSpeed) - math.abs(forwardSpeed))
				/ math.max(spec.topSpeed, EPSILON))
			slipTarget = 1 + gap * WHEEL_SPINUP_EXTRA
		end
	end
	stepWheels(hull, forwardSpeed, steerInput, slipTarget, dt)

	-- 7) boost pads (low rate) ----------------------------------------------
	state.padAccum += dt
	if state.padAccum >= PAD_CHECK_INTERVAL then
		state.padAccum = 0
		if state.filterStale then
			rebuildRayFilter()
		end
		if state.padBoostUntil <= now then
			checkBoostPads(now)
		end
	end

	-- 10) heartbeat to server ------------------------------------------------
	state.sendAccum += dt
	if state.sendAccum >= 1 / math.max(CFG.STATE_SEND_HZ, 1) then
		state.sendAccum = 0
		local remote = ctxRef and ctxRef.net and ctxRef.net.CarState
		if remote then
			remote:FireServer(hull.Position, velocity, grounded)
		end
	end
end

-- ==========================================================================
-- public surface
-- ==========================================================================
function ChassisController.getCar(): Model?
	return state.car
end

-- Horizontal speed in studs/s.
function ChassisController.getSpeed(): number
	return state.speed
end

-- 0..1 against this car's top speed. HUD speedo + camera FOV read this.
function ChassisController.getSpeedFraction(): number
	local spec = state.spec
	if not spec then
		return 0
	end
	return MathUtil.clamp01(state.speed / math.max(spec.topSpeed, EPSILON))
end

function ChassisController.isGrounded(): boolean
	return state.grounded
end

-- True only for a real slide: drift held, actually sideways, wheels on the ground.
function ChassisController.isDrifting(): boolean
	return state.drifting
end

--[[ Mini-turbo charge as 0..1 of the way to the BIG tier, for a charge meter.
	Not part of the pinned contract (same status as isBoosting). ]]
function ChassisController.getDriftCharge(): number
	return MathUtil.clamp01(state.driftCharge / math.max(DRIFT_CHARGE_TIER2, EPSILON))
end

-- What releasing the drift right now would pay: 0 (nothing), 1 (small) or 2 (big).
function ChassisController.getDriftTier(): number
	return state.driftTier
end

-- Unit forward vector on the XZ plane. Never nil, even with no car.
function ChassisController.getLook(): Vector3
	local hull = state.hull
	if hull and hull.Parent then
		local look = MathUtil.flatUnit(hull.CFrame.LookVector)
		if look ~= Vector3.zero then
			return look
		end
	end
	return yawLook(state.yaw)
end

-- Convenience for HUD/FX (not part of the pinned contract): pad OR server boost.
function ChassisController.isBoosting(): boolean
	local car = state.car
	if not car then
		return false
	end
	local now = Workspace:GetServerTimeNow()
	return state.padBoostUntil > now or ChassisSpec.isBoosting(car, now)
end

function ChassisController.init(ctx)
	ctxRef = ctx

	local lifecycle = ctx.net and ctx.net.CarLifecycle
	if not lifecycle then
		warnOnce("lifecycle", "CarLifecycle remote missing — no car will ever attach")
	else
		lifecycle.OnClientEvent:Connect(function(action, model, info)
			if action == "spawned" then
				if typeof(model) ~= "Instance" or not model:IsA("Model") then
					warnOnce("spawnpayload", "'spawned' arrived without a car model")
					return
				end
				local carId = nil
				if type(info) == "table" and type(info.carId) == "string" then
					carId = info.carId
				end
				task.spawn(attach, model, carId)
			elseif action == "destroyed" then
				detach()
			end
		end)
	end

	-- Late init (studio script reload, or a car that spawned before we connected):
	-- adopt whatever car already belongs to us.
	for _, car in ipairs(CollectionService:GetTagged(ChassisSpec.CAR_TAG)) do
		if car:IsA("Model") and car:GetAttribute(ATTR.OWNER) == LocalPlayer.UserId then
			task.spawn(attach, car, car:GetAttribute(ATTR.CAR_ID))
			break
		end
	end

	--[[ ONE persistent connection that early-returns when there is no car, so a respawn
		can never leave two loops fighting over the same hull.

		HEARTBEAT, NOT RENDERSTEPPED — this is a physics loop, not an animation loop, and
		the difference is not cosmetic. Everything here is either written to a constraint or
		re-seeded from the hull, so `dt` MUST be the simulation step. On RenderStepped it was
		the RENDER frame instead, and on any display faster than the simulation (a 120Hz Mac
		panel is two render frames per physics step) three things broke at once:
		  * throttle, grip and the hover spring all advance by rate * dt from a hull velocity
		    that has not changed yet, so the car accelerated and sprang about half as hard at
		    120Hz as at 60Hz — and slid between the two whenever the frame rate wobbled;
		  * ownDvLimit below is scaled by dt, so it halved while the ACTUAL per-step velocity
		    change did not. Ordinary acceleration then read as an external impulse, and the
		    blockedDir cancel chopped the throttle every other frame. That was the stutter.
		  * Steer's goal CFrame was rewritten several times per step, so the orientation
		    solver chased a target moving out of phase with it.
		Heartbeat fires once per simulation step, after physics: dt matches the step the
		velocities were produced over, prevPlanar brackets exactly one step, and the cosmetic
		wheels are placed from a post-physics hull CFrame rather than a stale one.
		Heartbeat passes deltaTime as its only argument, exactly like RenderStepped did. ]]
	RunService.Heartbeat:Connect(step)
end

return ChassisController
