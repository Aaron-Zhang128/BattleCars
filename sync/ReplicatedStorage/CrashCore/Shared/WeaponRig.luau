--[[ WeaponRig
	The car-mounted weapon MODEL: how it is assembled, and every frame of how it moves.

	Six powerups are modelled weapons (Config.WEAPON_RIGS): GUN, CANNON, ROCKET, FLAME,
	MORTAR and DUALGUN.
	This module owns their art contract so the thing bolted to your roof and the thing
	the HUD says you are holding can never disagree.

	THE ASSET CONTRACT — ReplicatedStorage.CrashCore.Assets.Weapons.<model>
		Base    the pedestal. Its BOTTOM FACE is the rig origin, and the rig is centred
		        on it in X and Z. Never moves relative to the car.
		Turret  the swivelling body. Yaws about the rig's vertical axis to your aim.
		Muzzle  the barrel. Optional: CANNON and ROCKET have none, because their Turret
		        IS the barrel. `recoilPart` names whichever one kicks.
		Muzzle2 an optional SECOND barrel (DUALGUN). It poses off exactly the same base
		        as Muzzle, so twin barrels cost no new pose code — only the def's
		        `muzzleSpread`, which alternates which one a shot leaves from.
		Ammo    ROCKET only, and NOT part of the mounted rig — it is the missile mesh
		        the client skins the flying shell with (WeaponRig.ammoClone).
		Every model points along -Z, which is the direction a car drives AND the
		LookVector of Hull.WeaponMount, so mounting needs no correction per car or per
		weapon. See the Config.WEAPON_RIGS header for why that is baked in rather than
		fixed up here.

	ENTIRELY COSMETIC AND ENTIRELY LOCAL. Every part this module makes is created on
	ONE client, Anchored, CanCollide/CanQuery/CanTouch = false and Massless, and lives
	in a folder inside the car — so it dies with the car, it is invisible to the server,
	it can never enter a car's physics assembly, block a shot, or fool the chassis
	ground probe. Nothing here is authoritative: damage, ammo and hit detection are
	WeaponService's, and this module is never asked.

	MOTION is manual math on the caller's step — no TweenService anywhere, per house
	rule. `kick` and `spin` are scalars decayed with exp(); yaw slews at a fixed deg/s.

	USED BY  TurretController (mounts one rig per car, drives step/fire/aim)
	         FxController      (ammoClone, to skin the missile)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(script.Parent:WaitForChild("ChassisSpec"))

local WeaponRig = {}

-- ==========================================================================
-- § 1) names
-- ==========================================================================
WeaponRig.ASSET_FOLDER = "Weapons" -- Assets.Weapons
WeaponRig.LOCAL_FOLDER = "WeaponRigLocal" -- the client-only folder added inside a car
WeaponRig.BASE = "Base"
WeaponRig.TURRET = "Turret"
WeaponRig.MUZZLE = "Muzzle"
WeaponRig.MUZZLE2 = "Muzzle2" -- optional twin barrel; poses exactly like Muzzle
WeaponRig.AMMO = "Ammo"

local RIG = Config.WEAPON_RIG
local RIGS = Config.WEAPON_RIGS

-- Jitter frequencies for the two-sine judder while a weapon is firing. Coprime-ish
-- on purpose: the sum never repeats on a beat you can count.
local SHAKE_A = 37.0
local SHAKE_B = 61.0

-- ==========================================================================
-- § 2) asset lookup
-- ==========================================================================
local warned = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("WeaponRig: " .. message)
end

-- The rig definition for a powerup id, or nil when that powerup has no model
-- (SHIELD, and anything left out of Config.WEAPON_RIGS).
function WeaponRig.defFor(powerupId: any)
	if type(powerupId) ~= "string" or powerupId == "" then
		return nil
	end
	return RIGS[powerupId]
end

function WeaponRig.isModelled(powerupId: any): boolean
	return WeaponRig.defFor(powerupId) ~= nil
end

local assetsFolder = nil
local function weaponAssets(): Instance?
	if assetsFolder and assetsFolder.Parent then
		return assetsFolder
	end
	local assets = core:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild(WeaponRig.ASSET_FOLDER)
	assetsFolder = folder
	return folder
end

-- The source Model for a powerup id, straight out of Assets.Weapons.
function WeaponRig.source(powerupId: string): Model?
	local def = WeaponRig.defFor(powerupId)
	if not def then
		return nil
	end
	local folder = weaponAssets()
	if not folder then
		warnOnce("assets", "Assets." .. WeaponRig.ASSET_FOLDER .. " missing — no weapon will appear on any car")
		return nil
	end
	local model = folder:FindFirstChild(def.model)
	if not (model and model:IsA("Model")) then
		warnOnce("model:" .. tostring(def.model), "Assets." .. WeaponRig.ASSET_FOLDER .. "." .. tostring(def.model) .. " missing")
		return nil
	end
	return model
end

--[[ A fresh copy of the missile mesh, centred on its own origin with the nose along
	-Z. FxController welds this onto the server's (invisible) shell so the thing you
	watch fly is the model rather than a neon box. Returns nil for every other id. ]]
function WeaponRig.ammoClone(powerupId: string): BasePart?
	local model = WeaponRig.source(powerupId)
	local ammo = model and model:FindFirstChild(WeaponRig.AMMO)
	if not (ammo and ammo:IsA("BasePart")) then
		return nil
	end
	return ammo:Clone()
end

-- ==========================================================================
-- § 3) build / destroy
-- ==========================================================================
local function prep(part: BasePart)
	-- Belt and braces: the asset is authored this way, but a re-export must never be
	-- able to drop a collidable, queryable part onto a moving car.
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
end

--[[ Mounts `powerupId` on `car`. Returns a rig table, or nil when the car is not
	ready, the powerup has no model, or the asset is missing — every caller treats
	nil as "no weapon to draw" and carries on. ]]
function WeaponRig.build(car: Model, powerupId: string)
	local def = WeaponRig.defFor(powerupId)
	if not def or typeof(car) ~= "Instance" or not car:IsA("Model") or not car.Parent then
		return nil
	end

	local hull = ChassisSpec.getHull(car)
	if not (hull and hull.Parent) then
		return nil
	end
	local mount = hull:FindFirstChild(ChassisSpec.MOUNT_ATT)
	if not (mount and mount:IsA("Attachment")) then
		warnOnce("mount", car.Name .. " has no Hull." .. ChassisSpec.MOUNT_ATT .. " — nothing can bolt on")
		return nil
	end

	local source = WeaponRig.source(powerupId)
	if not source then
		return nil
	end

	-- One folder per car, replaced rather than stacked, so a fast crate swap can never
	-- leave two guns on one roof.
	local existing = car:FindFirstChild(WeaponRig.LOCAL_FOLDER)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = WeaponRig.LOCAL_FOLDER

	local parts, rest = {}, {}
	for _, role in ipairs({ WeaponRig.BASE, WeaponRig.TURRET, WeaponRig.MUZZLE, WeaponRig.MUZZLE2 }) do
		local template = source:FindFirstChild(role)
		if template and template:IsA("BasePart") then
			local part = template:Clone()
			prep(part)
			part.Parent = folder
			parts[role] = part
			-- The asset's own CFrame IS its rig-local rest pose (see the asset contract).
			rest[role] = template.CFrame
		end
	end

	if not parts[WeaponRig.BASE] then
		warnOnce("base:" .. powerupId, powerupId .. " model has no " .. WeaponRig.BASE .. " part")
		folder:Destroy()
		return nil
	end

	folder.Parent = car

	--[[ Which part the recoil moves, and everything downstream of it. A Turret recoil
		drags the Muzzle with it (they are one barrel); a Muzzle recoil moves the
		muzzle alone while the turret body holds still. ]]
	local recoilsTurret = def.recoilPart == WeaponRig.TURRET

	-- Spin pivots on each barrel's OWN centreline, not the rig origin, or a barrel
	-- would orbit the car instead of rolling. Twin barrels get one pivot each.
	local spinPivots = {}
	for _, role in ipairs({ WeaponRig.MUZZLE, WeaponRig.MUZZLE2 }) do
		local restCF = rest[role]
		if restCF then
			spinPivots[role] = Vector3.new(restCF.Position.X, restCF.Position.Y, 0)
		end
	end

	return {
		id = powerupId,
		def = def,
		car = car,
		hull = hull,
		mount = mount,
		folder = folder,
		parts = parts,
		rest = rest,
		recoilsTurret = recoilsTurret,
		spinPivots = spinPivots,

		yaw = 0, -- current turret yaw, radians, relative to the car's nose
		aimYaw = 0, -- where it is slewing to
		kick = 0, -- 0..1 recoil amount, jumps to 1 on fire and decays
		shots = 0, -- fired count; twin barrels alternate off its parity
		spin = 0, -- accumulated barrel roll, radians
		spinRate = 0, -- radians/sec
		firingUntil = 0, -- os.clock() the "still firing" pose expires
	}
end

function WeaponRig.destroy(rig)
	if not rig then
		return
	end
	if rig.folder then
		pcall(function()
			rig.folder:Destroy()
		end)
	end
	rig.folder = nil
	rig.parts = {}
end

-- ==========================================================================
-- § 4) inputs
-- ==========================================================================
--[[ Point the turret at a WORLD direction. Flattened and expressed relative to the
	car's own heading, then clamped to the rig's yaw limit, so a turret can never
	spin past its housing however wild the aim is. ]]
function WeaponRig.setAim(rig, worldDir: Vector3?)
	if not rig or not rig.hull or not rig.hull.Parent then
		return
	end
	if typeof(worldDir) ~= "Vector3" or worldDir.Magnitude < 1e-3 then
		rig.aimYaw = 0 -- no aim: rest along the car's nose
		return
	end

	local hullCF = rig.hull.CFrame
	local localDir = hullCF:VectorToObjectSpace(worldDir)
	local flat = Vector3.new(localDir.X, 0, localDir.Z)
	if flat.Magnitude < 1e-3 then
		rig.aimYaw = 0
		return
	end

	-- Rig forward is -Z, so a heading of 0 is straight ahead.
	local yaw = math.atan2(-flat.Unit.X, -flat.Unit.Z)
	--[[ Capped by the WEAPON's firing cone as well as by the model's own swivel limit,
		and the firing cone always wins: a barrel that points somewhere the shot will
		not go is worse than one that does not move. With Config.WEAPONS.AIM_MAX_YAW_DEG
		at 0 this pins every turret to the car's heading. ]]
	local limit = math.rad(math.min(rig.def.yawLimit or 90, Config.WEAPONS.AIM_MAX_YAW_DEG))
	rig.aimYaw = math.clamp(yaw, -limit, limit)
end

-- One shot. Kicks the recoil to full and re-arms the "firing" pose.
function WeaponRig.fire(rig, now: number?)
	if not rig then
		return
	end
	local at = now or os.clock()
	rig.kick = 1
	rig.shots = (rig.shots or 0) + 1 -- twin barrels alternate off this
	rig.firingUntil = at + RIG.FIRE_HOLD
end

-- Where the shot leaves, in world space. Follows the live turret yaw, so the flash
-- comes out of the barrel even mid-swing.
function WeaponRig.muzzleWorld(rig): Vector3?
	if not rig or not rig.hull or not rig.hull.Parent then
		return nil
	end
	local mountCF = rig.hull.CFrame * rig.mount.CFrame * CFrame.new(0, RIG.MOUNT_LIFT, 0)
	local point = rig.def.muzzle or Vector3.zero
	--[=[ Twin barrels: shots leave alternate sides, so the muzzle flash, the tracer and
		the origin the server is handed all agree with the barrel that just kicked.
		fire() has already counted this shot, so the parity here is the one firing. ]=]
	local spread = rig.def.muzzleSpread
	if spread and spread > 0 then
		point += Vector3.new(((rig.shots or 0) % 2 == 0) and -spread or spread, 0, 0)
	end
	return (mountCF * CFrame.Angles(0, rig.yaw, 0)):PointToWorldSpace(point)
end

-- ==========================================================================
-- § 5) step — one frame of the whole rig
-- ==========================================================================
--[[ Called from the caller's Heartbeat, NOT RenderStepped. Heartbeat fires after
	physics, so the hull CFrame we read is the one the frame will actually render —
	the same reason ChassisController places the cosmetic wheels there. Driving this
	on RenderStepped would leave a turret a full step behind its own car at speed. ]]
function WeaponRig.step(rig, dt: number, now: number)
	if not rig or not rig.folder or not rig.folder.Parent then
		return false
	end
	local hull = rig.hull
	if not (hull and hull.Parent) then
		return false
	end

	local def = rig.def
	local firing = now < rig.firingUntil

	--[=[ yaw: slew toward the aim at a fixed deg/s and never snap. setAim already
		parks aimYaw at 0 when there is no aim to follow, so "return to centre" is
		this same slew and needs no separate idle path. ]=]
	local maxStep = math.rad(def.yawSpeed or 360) * dt
	rig.yaw += math.clamp(rig.aimYaw - rig.yaw, -maxStep, maxStep)

	-- ---- recoil: instant kick, exponential settle ----
	local ret = math.max(def.recoilReturn or 0.15, 1e-3)
	rig.kick = rig.kick * math.exp(-dt / ret)
	if rig.kick < 1e-3 then
		rig.kick = 0
	end

	-- ---- barrel roll: spins up while held, coasts down after ----
	local spinTarget = firing and math.rad(def.spinSpeed or 0) or 0
	if (def.spinSpeed or 0) > 0 then
		local decay = math.min(dt * (def.spinDecay or 3), 1)
		rig.spinRate = rig.spinRate + (spinTarget - rig.spinRate) * (firing and 1 or decay)
		rig.spin = (rig.spin + rig.spinRate * dt) % (math.pi * 2)
	end

	-- ---- poses ----
	local mountCF = hull.CFrame * rig.mount.CFrame * CFrame.new(0, RIG.MOUNT_LIFT, 0)
	local turretCF = mountCF * CFrame.Angles(0, rig.yaw, 0)

	-- +Z is backwards (forward is -Z), so the kick pushes the barrel INTO its housing;
	-- the pitch rotates about the rig origin, which is why it reads as the cannon
	-- elevating and the missile pod rearing back rather than as a part sliding.
	local recoilCF = CFrame.identity
	if rig.kick > 0 then
		recoilCF = CFrame.new(0, 0, rig.kick * (def.recoilStuds or 0))
			* CFrame.Angles(math.rad(rig.kick * (def.recoilPitch or 0)), 0, 0)
	end

	-- Judder while firing. Two sines rather than random, so it reads as a machine
	-- running instead of as noise, and so it is identical on every client.
	local shakeCF = CFrame.identity
	local amp = def.shake or 0
	if firing and amp > 0 then
		local jx = (math.sin(now * SHAKE_A) * 0.7 + math.sin(now * SHAKE_B + 1) * 0.3) * amp
		local jy = (math.sin(now * SHAKE_B * 0.83 + 2) * 0.7 + math.sin(now * SHAKE_A * 1.3) * 0.3) * amp
		shakeCF = CFrame.new(jx, jy, 0)
	end

	local parts, rest = rig.parts, rig.rest
	if parts[WeaponRig.BASE] then
		parts[WeaponRig.BASE].CFrame = mountCF * rest[WeaponRig.BASE]
	end

	local turretBase = rig.recoilsTurret and (turretCF * recoilCF * shakeCF) or turretCF
	if parts[WeaponRig.TURRET] then
		parts[WeaponRig.TURRET].CFrame = turretBase * rest[WeaponRig.TURRET]
	end

	--[=[ Every barrel poses off the SAME base. A Turret recoil has already moved that
		base (turret and barrel are one assembly); a Muzzle recoil moves the barrels
		alone while the housing holds still. ]=]
	local muzzleBase = turretBase
	if not rig.recoilsTurret then
		muzzleBase = turretCF * recoilCF * shakeCF
	end
	for _, role in ipairs({ WeaponRig.MUZZLE, WeaponRig.MUZZLE2 }) do
		local part = parts[role]
		if part then
			local poseCF = muzzleBase
			local pivot = rig.spinPivots and rig.spinPivots[role]
			if rig.spin ~= 0 and pivot then
				poseCF = poseCF * CFrame.new(pivot) * CFrame.Angles(0, 0, rig.spin) * CFrame.new(-pivot)
			end
			part.CFrame = poseCF * rest[role]
		end
	end

	return true
end

return WeaponRig
