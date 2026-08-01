--[[ WeaponController — fire input -> server, plus feel-only local prediction.

	PURPOSE
		Owns the FireWeapon request path. Turns InputController's fire signal into
		at-most-one-per-cooldown FireWeapon calls, and kicks the muzzle flash /
		launch sound on the SAME frame as the press so shooting feels instant
		instead of waiting for a round trip.

	AUTHORITY SPLIT — read this before adding anything to this file
		SERVER OWNS   damage, hit detection, ammo, the powerup slot, every projectile,
		              and every broadcast fx (WeaponFx). Nothing here writes state:
		              the slot attributes are read-only to this controller.
		CLIENT OWNS   only the cosmetic muzzle flash + launch sound at the moment of
		              the press (FxController.predictFire). If the server rejects the
		              shot the player sees one harmless flash and their PowerupAmmo
		              attribute simply never changes — no fake damage, no fake ammo.
		FxController consumes that prediction so the authoritative WeaponFx that
		arrives a ping later does not double up the launch sound.

	RATE LIMITING
		The server enforces its own cooldown; ours exists so a held FIRE button on the
		machine gun sends at the real rate (PowerupDefs.cooldownFor) instead of 60x/sec.
		We deliberately send a hair SLOWER than the server cooldown (COOLDOWN_MARGIN)
		so the server never has to reject a shot for arriving early.

	DATA FLOW
		InputController.onFire (press)  -> tryFire(false)
		InputController.isFireHeld      -> Heartbeat continues fire for hold-kind weapons
			-> cooldown gate -> FireWeapon:FireServer(aimDir)      [C->S]
			-> FxController.predictFire(id, muzzle, aimDir)        [local, cosmetic]
		WeaponService then broadcasts the authoritative WeaponFx that FxController draws.

	REMOTES     FireWeapon (C->S, aimDir: Vector3, origin: Vector3)
	            aimDir is a full 3D direction now (it may pitch); origin is the barrel
	            of the weapon on this car's roof. Both are clamped server-side.
	ATTRIBUTES  reads Player: PowerupSlot, PowerupAmmo (via PowerupDefs.slotOf) — writes NOTHING
	SIBLINGS    InputController (onFire/isFireHeld), ChassisController (getCar/getLook),
	            CameraController (getAimDirection), FxController (predictFire),
	            TurretController (getMuzzleWorld/noteFired — the car-mounted weapon model).
	            All resolved LAZILY through ctx.ctrl inside functions, never at init time.
	INIT ORDER  after InputController / ChassisController / CameraController, before FxController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))

local player = Players.LocalPlayer

local WeaponController = {}

-- ==========================================================================
-- Tunables. No magic numbers below this block.
-- ==========================================================================
local FIRE = {
	COOLDOWN_MARGIN = 1.06, -- send this much slower than the server cooldown
	MIN_GAP = 0.05, -- absolute floor on wire traffic, whatever a def says
	HOLD_KINDS = { hitscan = true, cone = true }, -- PowerupDefs kinds that support hold-to-fire
	MUZZLE_FORWARD = 0.52, -- fraction of hull length ahead of hull center (FALLBACK only)
	MUZZLE_UP = 0.45, -- studs above hull center (FALLBACK only)
	CARS_FOLDER = "Cars",
	EMPTY_GAP = 0.5, -- min seconds between "you have nothing" clicks
}

-- Only sound this controller owns; everything else routes through FxController.
local SFX_EMPTY = {
	ASSET = "rbxasset://sounds/button.wav",
	VOLUME = 0.22,
	PITCH = 0.7,
	LIFE = 0.6,
}

-- ==========================================================================
-- State
-- ==========================================================================
local ctxRef = nil
local lastSentAt = 0
local lastEmptyAt = 0
local warned = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("WeaponController: " .. message)
end

--[[ Calls a sibling controller function lazily and safely.
	Siblings are written by other passes; a missing or throwing sibling must never
	take the fire path down, so we warn once and fall back to `default`. ]]
local function safeCall(controllerName: string, fnName: string, default: any, ...): any
	local ctrl = ctxRef and ctxRef.ctrl and ctxRef.ctrl[controllerName]
	local fn = ctrl and ctrl[fnName]
	if type(fn) ~= "function" then
		warnOnce(controllerName .. "." .. fnName, controllerName .. "." .. fnName .. " unavailable")
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
-- Car / aim resolution
-- ==========================================================================
local function liveHull(): BasePart?
	local car = safeCall("ChassisController", "getCar", nil)
	if typeof(car) ~= "Instance" or not car:IsA("Model") or not car.Parent then
		return nil
	end
	local hull = ChassisSpec.getHull(car)
	if not hull or not hull.Parent then
		return nil
	end
	return hull
end

--[[ Cosmetic muzzle point. Prefers the REAL barrel of the weapon bolted to your
	roof — TurretController owns that model and its live yaw, so the flash leaves the
	gun rather than the bonnet, even mid-swing. Falls back to the hull nose for the
	powerups with no model, and for the frame or two before a rig finishes mounting. ]]
local function muzzleOrigin(hull: BasePart): Vector3
	local barrel = safeCall("TurretController", "getMuzzleWorld", nil)
	if typeof(barrel) == "Vector3" then
		return barrel
	end
	return hull.CFrame:PointToWorldSpace(Vector3.new(0, FIRE.MUZZLE_UP, -hull.Size.Z * FIRE.MUZZLE_FORWARD))
end

--[[ The firing axis: the way the windshield is facing, flattened onto the driving
	plane. EVERY weapon fires along it and nothing the player points at can move it —
	steering is aiming, and that is the whole rule.

	Flattened because a hover chassis pitches over every bump, and that wobble is
	suspension rather than intent. The cursor is consulted only for yaw the weapon can
	actually spend, so at Config.WEAPONS.AIM_MAX_YAW_DEG = 0 it is not read at all;
	raise that key and the swivel comes back here first.

	WeaponService.sanitizeAim derives this same axis from the same hull and does not
	trust ours. Ours exists so the turret pose, the local prediction and the real shot
	are one line rather than three. ]]
local function firingAxis(hull: BasePart): Vector3
	local forward = MathUtil.flatUnit(hull.CFrame.LookVector)
	if forward == Vector3.zero then
		forward = Vector3.new(0, 0, -1)
	end
	local limit = Config.WEAPONS.AIM_MAX_YAW_DEG
	if limit <= 0 then
		return forward -- forward-only: there is no yaw to spend
	end
	local cursor = safeCall("CameraController", "getAimPoint", nil)
	if typeof(cursor) ~= "Vector3" then
		return forward
	end
	local flat = MathUtil.flatUnit(cursor - hull.Position)
	if flat == Vector3.zero then
		return forward
	end
	local yaw = math.clamp(MathUtil.signedYawTo(forward, flat), -limit, limit)
	return CFrame.fromAxisAngle(Vector3.yAxis, math.rad(yaw)) * forward
end

--[[ The direction the shot travels. Deliberately not a choice: it is the car's own
	heading, the same vector the server will derive for itself.

	This used to converge on an aim POINT — the nearest car on the axis, or a fixed
	distance ahead — because the barrel sits eight studs above hull centre and a flat
	shot from up there flies over every roof. That is now solved on the server, and
	solved better: the shot LEAVES from hull-centre height (WeaponService.shotOrigin)
	while the flash still draws at the barrel. So there is nothing left to converge on,
	and a shot goes exactly where the car is pointing at every range. ]]
local function shotDirection(hull: BasePart): Vector3
	return firingAxis(hull)
end

-- ==========================================================================
-- Feedback
-- ==========================================================================
--[[ Local prediction hand-off. FxController draws the flash and plays the launch
	sound, and records it so the server's echo does not double the audio.
	NEVER pass damage/hit information through here — there is none to pass. ]]
local function predictFire(powerupId: string, origin: Vector3, dir: Vector3)
	local fx = ctxRef and ctxRef.ctrl and ctxRef.ctrl.FxController
	local fn = fx and fx.predictFire
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, powerupId, origin, dir)
	if not ok then
		warnOnce("err:FxController.predictFire", "FxController.predictFire errored -> " .. tostring(err))
	end
end

-- Soft dry click when you press fire with an empty slot. Rate limited, never a notification.
local function emptyClick()
	local now = os.clock()
	if now - lastEmptyAt < FIRE.EMPTY_GAP then
		return
	end
	lastEmptyAt = now

	local sound = Instance.new("Sound")
	sound.Name = "FireEmpty"
	sound.SoundId = SFX_EMPTY.ASSET
	sound.Volume = SFX_EMPTY.VOLUME
	sound.PlaybackSpeed = SFX_EMPTY.PITCH
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	-- Guaranteed destroy path even if Ended never fires.
	task.delay(SFX_EMPTY.LIFE, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

-- ==========================================================================
-- Fire path
-- ==========================================================================
--[[ fromHold = true when this came from the held-button loop rather than a press.
	Held fire never plays the empty click (that would machine-gun the click). ]]
local function tryFire(fromHold: boolean)
	local hull = liveHull()
	if not hull then
		return
	end

	local def, ammo = PowerupDefs.slotOf(player)
	if not def or ammo <= 0 then
		if not fromHold then
			emptyClick()
		end
		return
	end

	local now = os.clock()
	local gap = math.max(PowerupDefs.cooldownFor(def.id) * FIRE.COOLDOWN_MARGIN, FIRE.MIN_GAP)
	if now - lastSentAt < gap then
		return
	end

	local remote = ctxRef and ctxRef.net and ctxRef.net.FireWeapon
	if not remote then
		warnOnce("net.FireWeapon", "FireWeapon remote missing — cannot fire")
		return
	end

	lastSentAt = now
	--[[ ONE direction for all three consumers: the turret's pose, the wire, and the
		local prediction. Anything else and your own flash points somewhere your shot
		does not go. ]]
	local dir = shotDirection(hull)
	--[[ Aim the turret FIRST, then read the barrel off it: muzzleOrigin returns the rig's
		live pose, so aiming before measuring puts the shot on the barrel's new heading
		this frame instead of one frame behind it. ]]
	safeCall("TurretController", "noteFired", nil, def.id, dir)

	--[[ The client contributes ONE thing to a shot now, and it is COSMETIC: the barrel
		it fired from, so every machine's muzzle flash blooms on the gun instead of the
		bonnet. The direction and the point the shot actually leaves from are both the
		server's (sanitizeAim / shotOrigin). We contribute a flash position — never
		geometry, and never an outcome. ]]
	local origin = muzzleOrigin(hull)
	remote:FireServer(dir, origin)
	predictFire(def.id, origin, dir)
end

-- ==========================================================================
-- init
-- ==========================================================================
function WeaponController.init(ctx)
	ctxRef = ctx

	-- Press: every weapon fires once per press.
	safeCall("InputController", "onFire", nil, function()
		tryFire(false)
	end)

	--[[ Hold: only kinds in FIRE.HOLD_KINDS (the machine gun) keep firing while the
		button is down. One Heartbeat, gated on the cooldown above, so a held button
		costs one isFireHeld() read per frame and sends at the powerup's real rate. ]]
	RunService.Heartbeat:Connect(function()
		if not safeCall("InputController", "isFireHeld", false) then
			return
		end
		local def = PowerupDefs.slotOf(player)
		if not def or not FIRE.HOLD_KINDS[def.kind] then
			return
		end
		tryFire(true)
	end)
end

return WeaponController
