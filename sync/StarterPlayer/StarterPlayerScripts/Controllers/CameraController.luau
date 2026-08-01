--[[ CameraController
	Owns the camera outright. Players ARE cars — CharacterAutoLoads = false — so there is
	no default camera subject and nothing moves the camera unless this module does.

	PURPOSE
		Chase camera on the local car, orbit camera when there is no car, plus the shake
		layer every impact in the game feeds into.

	PUBLIC SURFACE (pinned in StarterPlayerScripts.Main)
		shake(intensity, seconds)   getAimDirection() -> Vector3   setTarget(model)
		getAimPoint() -> Vector3?   the world point under the cursor on the car's ground
		                            plane; nil on touch/gamepad, which have no fine aim

	FEEL, all from named constants at the top
		- Position is a damped follow (MathUtil.damp), never locked to the hull CFrame, so a
		  hard turn swings the camera out instead of feeling rigid.
		- The look direction blends the car's facing with its VELOCITY, so a drift shows you
		  where you are actually going (VELOCITY_BLEND).
		- FOV widens with ChassisController.getSpeedFraction() (FOV_BASE -> FOV_MAX, damped).
		  That is most of the sensation of speed. Because that fraction is clamped at 1.0,
		  boosting past top speed adds a separate FOV_BOOST_EXTRA overlay, otherwise a boost
		  would be invisible to the camera.
		- Slight downward pitch; the camera lifts while airborne so a ramp jump reads.
		- A raycast from the car to the desired position pulls the camera in at walls and
		  blocks, so it never clips through the arena.

	MODES
		chase  a live target model exists and the phase is not Results.
		hub    a Lobby character exists and there is no car: the camera is handed BACK to
		       Roblox (CameraType Custom, subject = the humanoid), which also restores
		       the default walk controls. This module does nothing at all until a car
		       shows up again.
		orbit  no car (Lobby, dead, Results) — a slow sine orbit of the arena centre rather
		       than a frozen death spot. Chase and orbit are crossfaded (MODE_BLEND_RATE),
		       so spawning and dying are short blends, never cuts.
		Only Results forces orbit on purpose: if MatchService never published a phase,
		MatchState reports "Lobby", and a phase check there would strand a live driver
		staring at the sky. A car that exists is proof enough that the match is live.

	SHAKE
		shake() appends to a LIST; overlapping shakes accumulate and decay independently
		with a quadratic falloff (punchy, short). The sum is clamped to MAX_SHAKE_STUDS /
		MAX_SHAKE_DEGREES so a pileup of explosions can never black out a kid's screen.
		Manual sine math per the house rule — no TweenService loops.

	DATA FLOW
		ChassisController.getCar/getLook/getSpeedFraction/isGrounded (resolved LAZILY through
		ctx.ctrl, all optional — the hull is the fallback for every one of them)
		WeaponController + FxController call shake() on hits, rams and explosions.
		WeaponController calls getAimDirection() for the FireWeapon aimDir payload.

	REMOTES     CarLifecycle (S->C, read only) — "spawned" snaps the chase pose so the
	            blend out of orbit starts from the right place.
	ATTRIBUTES  reads the match Phase through MatchState, and the car's CarId (via
	            ChassisSpec) to resolve a top speed for the FOV fallback. Writes none.
	INSTANCES   none authored. Drives workspace.CurrentCamera only.

	INIT ORDER  after ChassisController, before WeaponController/FxController (they shake it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local shared = core:WaitForChild("Shared")
local ChassisSpec = require(shared:WaitForChild("ChassisSpec"))
local MatchState = require(shared:WaitForChild("MatchState"))
local MathUtil = require(shared:WaitForChild("MathUtil"))

local localPlayer = Players.LocalPlayer

local CameraController = {}

-- ==========================================================================
-- tuning — Config has no CAMERA section, so these are the knobs. All named.
-- ==========================================================================
local FOV_BASE = 70 -- standing still
local FOV_MAX = 88 -- flat out
local FOV_DAMP_RATE = 3.5
--[==[ Boost has to be VISIBLE, and until now it was not. The speed-driven FOV reads
	ChassisController.getSpeedFraction(), which is clamp01'd against top speed — so at the
	144 studs/s a 1.6x boost reaches on a 90-top-speed car the fraction is still exactly
	1.0, and FOV, pull-back and everything else derived from it sit unchanged at their
	flat-out values. A boost therefore changed NOTHING about the camera.
	These add an explicit overlay on top of the speed curve instead of fighting the clamp.
	Blended faster than FOV_DAMP_RATE, and added AFTER the fov damp, so a short mini-turbo
	(0.48s at tier 1) actually lands rather than easing in after it has already expired:
	at rate 9 the kick is 84% present 0.2s in. ]==]
local FOV_BOOST_EXTRA = 6 -- degrees added on top of the speed-driven FOV while boosting
local BOOST_PULL_EXTRA = 3 -- studs of extra pull-back while boosting
local BOOST_BLEND_RATE = 9

local BACK_DISTANCE = 31 -- studs behind the hull at a standstill
--[[ How much of a modified body's scale the chase distance follows. NOT 1: a full 2x
	pull-back on the Juggernaut reads as watching somebody else's car from across the
	arena, while 0 leaves a 2x body filling the screen with no view of what you are about
	to ram. 0.6 keeps the monster feeling huge and still shows the road. ]]
local CAR_SCALE_PULL = 0.6
local BACK_SPEED_EXTRA = 9 -- extra pull-back at full speed
local CAMERA_HEIGHT = 16 -- studs above the hull
local LOOK_AHEAD = 18 -- studs in front of the hull the camera aims at
local LOOK_HEIGHT = 3.5 -- aim point height; lower than CAMERA_HEIGHT = downward pitch
local POS_DAMP_RATE = 9 -- lower = looser, swingier camera
local LOOK_DAMP_RATE = 13
-- 0.8, not 0.45: the camera follows where the car is GOING, so a drifting car visibly
-- points sideways on screen. At 0.45 the camera rotated with the car and swallowed
-- most of the slip angle, which is why a real 23 deg slide only read as about 10.
local VELOCITY_BLEND = 0.8 -- 0 = pure facing, 1 = pure velocity
local VELOCITY_BLEND_MIN_SPEED = 12 -- below this the velocity is noise, use facing
-- How forward-going the car must be before the camera leans toward its velocity.
-- Compared against dot(velocity, facing), so 0.35 means the velocity has to be within
-- ~70 degrees of where the nose points. Reversing scores negative and gets no blend.
local REVERSE_BLEND_DOT = 0.35
local AIR_LIFT = 7 -- extra height while airborne
local AIR_LIFT_RATE = 4
local MODE_BLEND_RATE = 4.5 -- chase <-> orbit crossfade
local MAX_STEP = 0.1 -- a frame hitch must not fling the camera

local ORBIT_RADIUS_FRACTION = 0.56 -- of Config.ARENA.SIZE, so it sits outside the walls
local ORBIT_HEIGHT_FRACTION = 0.26
local ORBIT_LOOK_HEIGHT_FRACTION = 0.02
local ORBIT_DEG_PER_SEC = 6
local ORBIT_DRIFT_FREQ = 0.35 -- lazy vertical breathing, house two-sine drift
local ORBIT_DRIFT_AMP = 6

local OCCLUSION_ORIGIN_UP = 2.5 -- ray starts this far above the hull centre
local OCCLUSION_PULL = 1.8 -- sit this far off whatever we hit
local MIN_CHASE_DISTANCE = 6.5 -- never end up inside the car
--[==[ The occlusion pull-in used to be recomputed from scratch every frame, so the moment
	a wall stopped occluding, the camera JUMPED from the pulled-in position straight back
	out to the full chase distance — a visible snap every time you scraped along a wall.
	The distance is now a state that eases: it pulls in IMMEDIATELY (a camera must never be
	caught inside geometry for even one frame) and only eases back OUT at this rate. ]==]
local OCCLUSION_RETURN_RATE = 4

local SHAKE_DEFAULT_INTENSITY = 0.5
local SHAKE_DEFAULT_SECONDS = 0.22
local SHAKE_MAX_INTENSITY = 2 -- per layer
local SHAKE_MAX_SECONDS = 1.5
local SHAKE_MAX_LAYERS = 8
local SHAKE_FREQ = 26 -- rad/s of the noise sines
local SHAKE_STUDS = 2.2 -- studs of kick at intensity 1
local SHAKE_DEGREES = 2.6 -- degrees of roll at intensity 1
local MAX_SHAKE_STUDS = 3.2 -- hard clamp on the summed shake
local MAX_SHAKE_DEGREES = 4.5

local AIM_RAY_MIN_Y = 0.05 -- flatter than this and the mouse ray never meets the ground
local RENDER_BIND = "CrashCarsCamera"

-- ==========================================================================
-- state
-- ==========================================================================
local ctxRef = nil
local bound = false
local connections = {}

local followPos = Vector3.zero -- chase-side camera position (damped)
local followLook = Vector3.zero -- chase-side aim point (damped)
local modeWeight = 0 -- 0 = orbit, 1 = chase
local airLift = 0
local fov = FOV_BASE
local boostBlend = 0 -- 0..1 overlay while a boost / mini-turbo is live
local occlusionRatio = 1 -- fraction of the full chase distance currently allowed
local orbitTime = 0
local snapChase = true -- snap the chase pose on the next chase frame

local targetOverride: Model? = nil
local currentPhase = MatchState.PHASES.LOBBY
local shakes = {}

local arenaFolder: Instance? = nil
local rayParams: RaycastParams? = nil

-- ==========================================================================
-- helpers
-- ==========================================================================
local function track(conn: RBXScriptConnection): RBXScriptConnection
	table.insert(connections, conn)
	return conn
end

local function dampVector(current: Vector3, target: Vector3, rate: number, dt: number): Vector3
	return Vector3.new(
		MathUtil.damp(current.X, target.X, rate, dt),
		MathUtil.damp(current.Y, target.Y, rate, dt),
		MathUtil.damp(current.Z, target.Z, rate, dt)
	)
end

-- ChassisController is optional in every path: the hull is always the fallback.
local function chassis()
	local ctrl = ctxRef and ctxRef.ctrl
	local module = ctrl and ctrl.ChassisController
	if type(module) == "table" then
		return module
	end
	return nil
end

local function askChassis(name: string)
	local module = chassis()
	if not module or type(module[name]) ~= "function" then
		return nil
	end
	local ok, value = pcall(module[name])
	if not ok then
		return nil
	end
	return value
end

local function localCar(): Model?
	local car = askChassis("getCar")
	if typeof(car) == "Instance" and car:IsA("Model") and car.Parent then
		return car
	end
	return nil
end

--[[ setTarget wins; otherwise the local car. Dead models are dropped, never used.
	Also reports whether the target is the player's OWN car, which decides if the
	ChassisController getters apply to it. ]]
local function resolveTarget(): (Model?, boolean)
	local own = localCar()
	if targetOverride then
		if targetOverride.Parent then
			return targetOverride, targetOverride == own
		end
		targetOverride = nil
	end
	return own, own ~= nil
end

local function ensureCamera(): Camera?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		-- self-heal: with no character there is no subject, so a non-scriptable camera is dead
		camera.CameraType = Enum.CameraType.Scriptable
	end
	return camera
end

--[[ Include-filter on Workspace.Arena: the ray can then never hit a car, a pickup or a
	projectile, and RespectCanCollide drops decoration like boost pads and pit sensors.
	Re-resolved whenever ArenaService rebuilds the folder. ]]
local function arenaRayParams(): RaycastParams?
	if arenaFolder and arenaFolder.Parent and rayParams then
		return rayParams
	end
	local folder = Workspace:FindFirstChild("Arena")
	if not folder then
		arenaFolder, rayParams = nil, nil
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	params.IgnoreWater = true
	params.RespectCanCollide = true
	arenaFolder, rayParams = folder, params
	return params
end

local function flatFacing(hull: BasePart, isLocal: boolean): Vector3
	if isLocal then
		local look = askChassis("getLook")
		if typeof(look) == "Vector3" then
			local flat = MathUtil.flatUnit(look)
			if flat.Magnitude > 0 then
				return flat
			end
		end
	end
	local flat = MathUtil.flatUnit(hull.CFrame.LookVector)
	if flat.Magnitude > 0 then
		return flat
	end
	return Vector3.new(0, 0, -1)
end

local function speedFractionOf(target: Model, speed: number, isLocal: boolean): number
	if isLocal then
		local fraction = askChassis("getSpeedFraction")
		if type(fraction) == "number" and fraction == fraction then
			return MathUtil.clamp01(fraction)
		end
	end
	local topSpeed = Config.CHASSIS.TOP_SPEED
	local carId = target:GetAttribute(ChassisSpec.ATTR.CAR_ID)
	if type(carId) == "string" then
		local ok, resolved = pcall(ChassisSpec.resolve, carId)
		if ok and resolved and type(resolved.topSpeed) == "number" then
			topSpeed = resolved.topSpeed
		end
	end
	return MathUtil.clamp01(speed / math.max(topSpeed, 1))
end

local function groundedOf(isLocal: boolean): boolean
	if isLocal then
		local grounded = askChassis("isGrounded")
		if type(grounded) == "boolean" then
			return grounded
		end
	end
	return true -- unknown: never lift the camera on a guess
end

-- ==========================================================================
-- orbit — manual sine math (house rule: no TweenService for looped motion)
-- ==========================================================================
local function orbitPose(): (Vector3, Vector3)
	local center = Config.ARENA.ORIGIN
	local size = Config.ARENA.SIZE
	local angle = math.rad((orbitTime * ORBIT_DEG_PER_SEC) % 360)
	local height = size * ORBIT_HEIGHT_FRACTION + MathUtil.drift(orbitTime, ORBIT_DRIFT_FREQ, 0, ORBIT_DRIFT_AMP)
	local radius = size * ORBIT_RADIUS_FRACTION
	local pos = center + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
	local lookAt = center + Vector3.new(0, size * ORBIT_LOOK_HEIGHT_FRACTION, 0)
	return pos, lookAt
end

-- ==========================================================================
-- shake — a list, so overlapping hits accumulate and decay independently
-- ==========================================================================
local function stepShakes(dt: number): (Vector3, Vector3)
	local offset, rotation = Vector3.zero, Vector3.zero

	for index = #shakes, 1, -1 do
		local layer = shakes[index]
		layer.elapsed += dt
		if layer.elapsed >= layer.duration then
			table.remove(shakes, index)
		else
			local decay = 1 - layer.elapsed / layer.duration
			local amp = layer.amount * decay * decay -- quadratic falloff: punchy, then gone
			local t = layer.elapsed * SHAKE_FREQ + layer.seed
			offset += Vector3.new(math.sin(t), math.sin(t * 1.37 + 1.7), math.sin(t * 0.83 + 3.1)) * (amp * SHAKE_STUDS)
			rotation += Vector3.new(math.sin(t * 1.11 + 0.5), math.sin(t * 0.91 + 2.2), math.sin(t * 1.53 + 4.4))
				* (amp * math.rad(SHAKE_DEGREES))
		end
	end

	if offset.Magnitude > MAX_SHAKE_STUDS then
		offset = offset.Unit * MAX_SHAKE_STUDS
	end
	local maxRotation = math.rad(MAX_SHAKE_DEGREES)
	rotation = Vector3.new(
		math.clamp(rotation.X, -maxRotation, maxRotation),
		math.clamp(rotation.Y, -maxRotation, maxRotation),
		math.clamp(rotation.Z, -maxRotation, maxRotation)
	)
	return offset, rotation
end

-- ==========================================================================
-- per-frame
-- ==========================================================================
--[[ THE LOBBY HUB IS WALKED, NOT DRIVEN.
	LobbyService loads a real Roblox character up there — the only humanoids in this
	game. A humanoid means Roblox's own camera and control scripts do a better job than
	anything in here, so while one is alive and there is no car, hand the camera back and
	stay out of the way. That handover IS the hub's camera and its walk/jump controls.

	This has to run BEFORE ensureCamera(), which force-sets Scriptable every frame to
	self-heal a camera that has no subject. ]]
local function hubHumanoid(): Humanoid?
	local character = localPlayer and localPlayer.Character
	if not character or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function releaseCameraTo(humanoid: Humanoid)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
	end
	if camera.CameraType ~= Enum.CameraType.Custom then
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = FOV_BASE
	end
	-- Roblox can leave the camera anywhere, so the next car spawn must snap, not blend.
	snapChase = true
	occlusionRatio = 1
end

local function step(dt: number)
	local humanoid = hubHumanoid()
	if humanoid and not resolveTarget() then
		releaseCameraTo(humanoid)
		return
	end

	local camera = ensureCamera()
	if not camera then
		return
	end

	dt = math.min(dt, MAX_STEP)
	orbitTime += dt

	local target, isLocal = resolveTarget()
	local hull = target and ChassisSpec.getHull(target) or nil
	if hull and not hull.Parent then
		hull = nil -- destroyed mid-frame
	end
	local chasing = hull ~= nil and currentPhase ~= MatchState.PHASES.RESULTS

	local fovTarget = FOV_BASE
	local hullPos = nil

	if chasing and hull and target then
		hullPos = hull.Position

		local facing = flatFacing(hull, isLocal)
		local velocity = hull.AssemblyLinearVelocity
		local speed = velocity.Magnitude
		local heading = facing
		if speed > VELOCITY_BLEND_MIN_SPEED then
			--[[ Lean toward the velocity so a drift shows where the car is actually going —
				but ONLY while going forward. `heading` drives the camera's POSITION as well as
				its look, so blending toward a reversing velocity swings the camera a full 180
				degrees around the car: nauseating, and it hides the direction you are steering.
				Ramped through REVERSE_BLEND_DOT rather than switched, so crossing zero speed
				or snapping into reverse eases instead of cutting. A 23 degree drift still scores
				dot 0.92 and keeps the full blend. ]]
			local flatVelocity = MathUtil.flatUnit(velocity)
			if flatVelocity.Magnitude > 0 then
				local forwardness = MathUtil.clamp01(flatVelocity:Dot(facing) / REVERSE_BLEND_DOT)
				local blend = VELOCITY_BLEND * forwardness
				if blend > 0 then
					local blended = MathUtil.flatUnit(facing * (1 - blend) + flatVelocity * blend)
					if blended.Magnitude > 0 then
						heading = blended
					end
				end
			end
		end

		local fraction = speedFractionOf(target, speed, isLocal)
		fovTarget = MathUtil.map(fraction, 0, 1, FOV_BASE, FOV_MAX)

		local liftTarget = groundedOf(isLocal) and 0 or AIR_LIFT
		airLift = MathUtil.damp(airLift, liftTarget, AIR_LIFT_RATE, dt)

		-- isBoosting() covers a boost pad, a server-granted boost AND a drift mini-turbo,
		-- so every source of "you are going faster than normal" reads the same on screen.
		local boosting = isLocal and askChassis("isBoosting") == true
		boostBlend = MathUtil.damp(boostBlend, boosting and 1 or 0, BOOST_BLEND_RATE, dt)

		--[[ A modified body gets a modified rig: outward only, and never below 1, so an
			ordinary car is bit-identical to what it was before modes existed. ]]
		local bodyScale = tonumber(target:GetAttribute(ChassisSpec.ATTR.SCALE)) or 1
		local rig = 1 + math.max(bodyScale - 1, 0) * CAR_SCALE_PULL

		local desiredPos = hullPos
			- heading * ((BACK_DISTANCE + fraction * BACK_SPEED_EXTRA + boostBlend * BOOST_PULL_EXTRA) * rig)
			+ Vector3.new(0, CAMERA_HEIGHT * rig + airLift, 0)
		local desiredLook = hullPos + heading * (LOOK_AHEAD * rig) + Vector3.new(0, LOOK_HEIGHT, 0)

		if snapChase then
			snapChase = false
			followPos, followLook = desiredPos, desiredLook
		else
			followPos = dampVector(followPos, desiredPos, POS_DAMP_RATE, dt)
			followLook = dampVector(followLook, desiredLook, LOOK_DAMP_RATE, dt)
		end
	else
		snapChase = true -- next chase frame starts from the right pose, not a stale one
		airLift = MathUtil.damp(airLift, 0, AIR_LIFT_RATE, dt)
		boostBlend = MathUtil.damp(boostBlend, 0, BOOST_BLEND_RATE, dt)
	end

	modeWeight = MathUtil.damp(modeWeight, chasing and 1 or 0, MODE_BLEND_RATE, dt)

	local orbitPos, orbitLook = orbitPose()
	local finalPos = orbitPos:Lerp(followPos, modeWeight)
	local finalLook = orbitLook:Lerp(followLook, modeWeight)

	--[[ Never clip through a wall or a block while chasing. The allowed distance is kept
		along the chase ray rather than snapped to the hit point, which keeps the camera on
		its own line instead of sliding sideways along a wall face, and lets the pull-in and
		the ease-out share one scalar. Asymmetric on purpose: in is instant, out is eased. ]]
	if hullPos and modeWeight > 0.5 then
		local origin = hullPos + Vector3.new(0, OCCLUSION_ORIGIN_UP, 0)
		local delta = finalPos - origin
		local distance = delta.Magnitude
		local params = arenaRayParams()
		if params and distance > 1e-3 then
			local allowed = distance
			local hit = Workspace:Raycast(origin, delta, params)
			if hit then
				allowed = math.max((hit.Position - origin).Magnitude - OCCLUSION_PULL,
					math.min(MIN_CHASE_DISTANCE, distance))
			end
			local wanted = MathUtil.clamp01(allowed / distance)
			if wanted < occlusionRatio then
				occlusionRatio = wanted -- pull in this frame; never sit inside geometry
			else
				occlusionRatio = MathUtil.damp(occlusionRatio, wanted, OCCLUSION_RETURN_RATE, dt)
			end
			finalPos = origin + delta.Unit * (distance * occlusionRatio)
		end
	else
		occlusionRatio = 1 -- orbit / no car: nothing to be occluded by
	end

	-- The boost overlay is added AFTER the damp so a 0.48s mini-turbo still reads; damping
	-- it through fovTarget would spread a 6-degree kick over most of a second.
	fov = MathUtil.damp(fov, fovTarget, FOV_DAMP_RATE, dt)
	camera.FieldOfView = fov + boostBlend * FOV_BOOST_EXTRA

	if (finalLook - finalPos).Magnitude < 1e-3 then
		finalLook = finalPos + Vector3.new(0, 0, -1) -- CFrame.lookAt needs a direction
	end

	local shakeOffset, shakeRotation = stepShakes(dt)
	local base = CFrame.lookAt(finalPos, finalLook)
	-- shake is applied in camera space so it always reads as a kick to the lens
	camera.CFrame = base * CFrame.new(shakeOffset) * CFrame.Angles(shakeRotation.X, shakeRotation.Y, shakeRotation.Z)
end

-- ==========================================================================
-- public surface
-- ==========================================================================
--[[ Additive kick. intensity ~0.3 small hit, ~1 explosion. Layers stack and decay
	independently; the sum is clamped, so a pileup cannot disorient the player. ]]
function CameraController.shake(intensity: number?, seconds: number?)
	local amount = math.clamp(tonumber(intensity) or SHAKE_DEFAULT_INTENSITY, 0, SHAKE_MAX_INTENSITY)
	if amount <= 0 then
		return
	end
	local duration = math.clamp(tonumber(seconds) or SHAKE_DEFAULT_SECONDS, 0.05, SHAKE_MAX_SECONDS)

	if #shakes >= SHAKE_MAX_LAYERS then
		table.remove(shakes, 1) -- drop the oldest layer rather than growing forever
	end
	table.insert(shakes, {
		amount = amount,
		duration = duration,
		elapsed = 0,
		seed = math.random() * 100,
	})
end

--[[ The world POINT under the cursor, dropped onto the car's own ground plane — so it
	is already at another car's HULL-CENTRE height. Returns nil when this input method
	has no fine aim (touch, gamepad), which is the caller's cue to fall back.

	WeaponController needs a POINT and no longer just a direction, because shots now
	leave the turret barrel: a barrel sits about 8 studs above hull centre, so a FLAT
	shot fired from one passes clean over every other car's roof. Aiming at a point on
	the hull plane is exactly what pitches the shot back down onto the cars. ]]
function CameraController.getAimPoint(): Vector3?
	local target = resolveTarget()
	local hull = target and ChassisSpec.getHull(target) or nil
	if not hull then
		return nil
	end

	local lastInput = UserInputService:GetLastInputType()
	local usesMouse = lastInput == Enum.UserInputType.MouseMovement
		or lastInput == Enum.UserInputType.MouseButton1
		or lastInput == Enum.UserInputType.MouseButton2
		or lastInput == Enum.UserInputType.MouseWheel
		or lastInput == Enum.UserInputType.Keyboard
	if not usesMouse then
		return nil
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local location = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(location.X, location.Y)
	if math.abs(ray.Direction.Y) < AIM_RAY_MIN_Y then
		return nil -- ray parallel to the plane: no intersection to speak of
	end
	local distance = (hull.Position.Y - ray.Origin.Y) / ray.Direction.Y
	if distance <= 0 then
		return nil -- plane is behind the camera
	end
	return ray.Origin + ray.Direction * distance
end

--[[ The flat aim direction. Unchanged contract: always a unit Vector3 on the driving
	plane, never nil. Now derived from getAimPoint so the point and the direction can
	never disagree about where the player is pointing. ]]
function CameraController.getAimDirection(): Vector3
	local target, isLocal = resolveTarget()
	local hull = target and ChassisSpec.getHull(target) or nil
	local fallback = hull and flatFacing(hull, isLocal) or Vector3.new(0, 0, -1)
	if not hull then
		return fallback
	end

	local point = CameraController.getAimPoint()
	if not point then
		return fallback
	end
	local aim = MathUtil.flatUnit(point - hull.Position)
	if aim.Magnitude == 0 then
		return fallback
	end
	return aim
end

--[[ Override the followed model. nil falls back to the local car.
	Used for spectating and the results camera. ]]
function CameraController.setTarget(model: Model?)
	if model == nil then
		targetOverride = nil
		return
	end
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("CameraController.setTarget: expected a Model or nil")
		return
	end
	targetOverride = model
end

-- ==========================================================================
-- init / teardown
-- ==========================================================================
local function teardown()
	if bound then
		pcall(function()
			RunService:UnbindFromRenderStep(RENDER_BIND)
		end)
		bound = false
	end
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)
	table.clear(shakes)
	targetOverride = nil
	modeWeight = 0
	airLift = 0
	fov = FOV_BASE
	boostBlend = 0
	occlusionRatio = 1
	snapChase = true
end

function CameraController.init(ctx)
	teardown() -- safe to re-init: never two render bindings
	ctxRef = ctx

	local camera = ensureCamera()
	if camera then
		camera.FieldOfView = FOV_BASE
	else
		warn("CameraController: no CurrentCamera at init — resolving per frame instead")
	end

	-- start parked on the orbit so the very first frame is never a black void
	followPos, followLook = orbitPose()

	track(MatchState.onPhaseChanged(function(phase)
		currentPhase = phase
	end))

	local lifecycle = ctx and ctx.net and ctx.net.CarLifecycle
	if lifecycle and lifecycle:IsA("RemoteEvent") then
		track(lifecycle.OnClientEvent:Connect(function(action)
			if action == "spawned" then
				snapChase = true -- chase pose is correct immediately; the crossfade does the blend
			end
		end))
	end

	RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value, step)
	bound = true
end

return CameraController
