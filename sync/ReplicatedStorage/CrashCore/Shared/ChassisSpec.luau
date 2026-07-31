--[[ ChassisSpec
	The pinned car-model contract plus the pure math both sides must agree on.

	Client ChassisController drives the car; server CombatService scores the ram.
	They share this file so damage never disagrees.

	CAR MODEL CONTRACT (built by CarFactory, do not deviate):
		Model                          name = "Car_<userId>", tagged ChassisSpec.CAR_TAG
		  PrimaryPart = Hull           Part, the ONLY collidable body
		  Hull.RootAtt                 Attachment at hull center
		  Hull.WeaponMount             Attachment on the centreline, just clear of the
		                               highest bodywork, LookVector = the way the car
		                               drives. THE place to bolt a weapon or a cosmetic.
		  Hull.Drive                    LinearVelocity  (RelativeTo = Attachment0/World per spec)
		  Hull.Steer                    AlignOrientation (OneAttachment mode)
		  Wheels/                       Folder of non-collidable cosmetic wheels
		  Body/                         Folder of non-collidable cosmetic parts
		Model attributes:
			CarId        string   Config.CARS id
			OwnerUserId  number
			Hp           number   current
			MaxHp        number
			SpawnedAt    number   workspace:GetServerTimeNow()
			BoostUntil   number   server time the boost expires (0 = none)
			FrozenUntil  number   server time the freeze expires (0 = none)
			Invuln       number   server time spawn protection ends
			StaggerUntil number   server time until the OWNING CLIENT yields drive authority.
			                      Set by CombatService alongside any knockback impulse;
			                      ChassisController must stop commanding Drive while it is active.
]]

local Config = require(script.Parent.Parent.Config)

local ChassisSpec = {}

-- ---------- pinned names ----------
ChassisSpec.CAR_TAG = "CrashCar"
ChassisSpec.HULL = "Hull"
ChassisSpec.DRIVE = "Drive"
ChassisSpec.STEER = "Steer"
ChassisSpec.ROOT_ATT = "RootAtt"
ChassisSpec.MOUNT_ATT = "WeaponMount" -- roof mount point; see the contract above
--[[ Gap between the highest bodywork and the mount. Deliberately tiny: a mount that
	visibly floats reads as a bug, and anything bolting on can offset UP from a mount
	that hugs the roof but cannot recover one that started too high. ]]
ChassisSpec.MOUNT_CLEARANCE = 0.25
ChassisSpec.WHEELS = "Wheels"
ChassisSpec.BODY = "Body"
ChassisSpec.COLLISION_GROUP = "Cars"
ChassisSpec.PICKUP_TAG = "CrashPickup"
ChassisSpec.PAD_TAG = "CrashBoostPad"
ChassisSpec.PROJECTILE_TAG = "CrashProjectile"

-- Ride height fallback. resolve() runs on EVERY spawn, so it must never hard-error
-- on a missing tunable: a nil here would stop the game dead rather than drive slightly wrong.
local DEFAULT_GROUND_CLEARANCE = 0.5
ChassisSpec.LUCKY_TAG = "CrashLuckyBlock"

ChassisSpec.ATTR = {
	CAR_ID = "CarId",
	OWNER = "OwnerUserId",
	HP = "Hp",
	MAX_HP = "MaxHp",
	SPAWNED_AT = "SpawnedAt",
	BOOST_UNTIL = "BoostUntil",
	FROZEN_UNTIL = "FrozenUntil",
	INVULN = "Invuln",
	STAGGER_UNTIL = "StaggerUntil",
	--[[ The flat direction this car last FIRED in, published by WeaponService on every
		accepted shot. It exists purely so OTHER clients can aim this car's turret: the
		driver's camera never leaves their own machine, so without it everyone else
		sees a turret locked forward while its owner shoots sideways. Absent until the
		car's first shot, which is exactly when the turret should still be centred. ]]
	AIM_DIR = "AimDir",
	--[[ BODY MODIFIERS — stamped by CarFactory when a mode asks for a car that is not
		the ordinary one (today: the Juggernaut). Absent means 1, so every existing car
		and every consumer that never heard of them is unaffected. They live on the MODEL
		rather than in a table here because the client has to read them off a car it did
		not build: the owning client re-derives ride height from Scale, and getting that
		wrong is the difference between driving a monster and grinding it along the floor. ]]
	SCALE = "Scale", -- geometry: body and hull, 1 = stock
	MASS_SCALE = "MassScale", -- ram weight (ChassisSpec.ramResult's massRatio)
	HP_SCALE = "HpScale",
	SPEED_SCALE = "SpeedScale", -- top speed AND acceleration
}

-- ---------- car-model geometry ----------
--[[ World-axis-aligned bounds over every part's OWN oriented box, NOT model:GetExtents
	or GetBoundingBox: the shipped models carry a 90-deg-yawed, off-centre pivot that
	both of those honour, which is exactly what CarFactory spends its header warning
	about. Lives here because CarFactory (server, at build time) and the /weaponview
	authoring tool (client, on the raw asset) must land on the same number. ]]
function ChassisSpec.measureExtents(model: Model): (Vector3?, Vector3?)
	local low, high = nil, nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf, half = d.CFrame, d.Size * 0.5
			-- world-axis-aligned extent of an oriented box
			local extent = Vector3.new(
				math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z,
				math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z,
				math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
			)
			low = low and low:Min(cf.Position - extent) or (cf.Position - extent)
			high = high and high:Max(cf.Position + extent) or (cf.Position + extent)
		end
	end
	return low, high
end

--[[ Where Hull.WeaponMount sits, in hull space, for a RAW source model.

	CarFactory re-centres the bodywork's measured bounds on the hull's centre, so the
	top of the bodywork is exactly half the MODEL's height above that centre. That is
	NOT hullSize.Y * 0.5 — car.hull is deliberately 2 x GROUND_CLEARANCE shorter than
	the body, so measuring off the hull would bury the mount inside the roof.

	X and Z are zero on purpose: dead centre of the roofline is the one spot that reads
	as deliberate on all ten silhouettes, and it stays put when the car rolls. ]]
function ChassisSpec.mountOffset(model: Model): Vector3
	local low, high = ChassisSpec.measureExtents(model)
	if not low or not high then
		return Vector3.new(0, ChassisSpec.MOUNT_CLEARANCE, 0)
	end
	return Vector3.new(0, (high.Y - low.Y) * 0.5 + ChassisSpec.MOUNT_CLEARANCE, 0)
end

-- ---------- body modifiers ----------
--[[ A modifier table with every field guaranteed positive. nil, a bad number and a
	missing key all resolve to 1, so `resolve(carId)` with no mods is bit-identical to
	what it returned before modifiers existed. ]]
function ChassisSpec.normaliseMods(mods)
	local function positive(value: any, fallback: number): number
		local n = tonumber(value)
		if type(n) ~= "number" or n ~= n or n <= 0 or n == math.huge then
			return fallback
		end
		return n
	end
	if type(mods) ~= "table" then
		return { scale = 1, mass = 1, hp = 1, speed = 1 }
	end
	return {
		scale = positive(mods.scale, 1),
		mass = positive(mods.mass, 1),
		hp = positive(mods.hp, 1),
		speed = positive(mods.speed, 1),
	}
end

--[==[ Grows a hull to fit a body scaled by `scale`, and it is NOT hullSize * scale.

	Config.CARS[i].hull is authored 2 x GROUND_CLEARANCE SHORTER than its model, which is
	what keeps the collidable box clear of the ground while the bodywork sits on it (see
	the CarFactory header — a hull that reaches the floor fights the hover spring every
	frame and reads as vibration). Clearance is an ABSOLUTE gap, not a proportion, so the
	body scales and the clearance does not:

		bodyY  = hullY + 2c          (the relationship CarFactory authored)
		bodyY' = bodyY * scale
		hullY' = bodyY' - 2c

	which leaves hoverHeight = hullY'/2 + c = bodyY'/2 — the body's own bottom exactly on
	the road, at any scale. Scaling the hull naively instead floats a 2x car a whole
	clearance off the ground, and buries the same maths at 0.5x. ]==]
function ChassisSpec.scaleHull(hullSize: Vector3, scale: number?): Vector3
	local s = tonumber(scale) or 1
	if s == 1 or s <= 0 or s ~= s then
		return hullSize
	end
	local clearance = Config.CHASSIS.GROUND_CLEARANCE or DEFAULT_GROUND_CLEARANCE
	local bodyY = (hullSize.Y + clearance * 2) * s
	return Vector3.new(hullSize.X * s, math.max(bodyY - clearance * 2, 0.4), hullSize.Z * s)
end

-- The modifiers stamped on a live car, or nil when it is an ordinary one.
function ChassisSpec.modifiersOf(car: Instance?)
	if typeof(car) ~= "Instance" then
		return nil
	end
	local scale = tonumber(car:GetAttribute(ChassisSpec.ATTR.SCALE))
	local mass = tonumber(car:GetAttribute(ChassisSpec.ATTR.MASS_SCALE))
	local hp = tonumber(car:GetAttribute(ChassisSpec.ATTR.HP_SCALE))
	local speed = tonumber(car:GetAttribute(ChassisSpec.ATTR.SPEED_SCALE))
	if not (scale or mass or hp or speed) then
		return nil
	end
	return { scale = scale, mass = mass, hp = hp, speed = speed }
end

-- ---------- stat resolution ----------
--[[ Turns a Config.CARS entry into concrete handling numbers.
	Every consumer resolves through here so per-car stats apply identically. ]]
function ChassisSpec.resolve(carId: string, mods)
	local CH = Config.CHASSIS
	local car = Config.CARS_BY_ID[carId] or Config.CARS_BY_ID[Config.STARTER_CAR]
	local s = car.stats

	--[[ Cars are REAL MODELS now, not procedural primitives, so there is no `build`
		recipe to read. `car.hull` was MEASURED from each normalised model (92% of its
		width and length, full height) and is the one collider. Ride height therefore
		follows from the hull itself rather than from a wheel radius that no longer
		exists. Falls back to CH.HULL_SIZE so a malformed entry still spawns. ]]
	local m = ChassisSpec.normaliseMods(mods)
	local hullSize = ChassisSpec.scaleHull(car.hull or CH.HULL_SIZE, m.scale)

	return {
		carId = car.id,
		name = car.name,
		rarity = car.rarity,
		special = car.special,

		hullSize = hullSize,
		hoverHeight = hullSize.Y * 0.5 + (CH.GROUND_CLEARANCE or DEFAULT_GROUND_CLEARANCE),
		rayLength = CH.RAY_LENGTH,

		topSpeed = CH.TOP_SPEED * s.topSpeed * m.speed,
		reverseSpeed = CH.TOP_SPEED * s.topSpeed * CH.REVERSE_FRACTION * m.speed,
		accel = CH.ACCEL * s.accel * m.speed,
		brake = CH.BRAKE,
		coastDrag = CH.COAST_DRAG,
		turnRate = CH.TURN_RATE * s.turn,
		grip = CH.GRIP,
		driftGrip = CH.DRIFT_GRIP,
		driftTurnBoost = CH.DRIFT_TURN_BOOST,

		mass = s.mass * m.mass,
		--[[ Rounded to whole HP_PER_CHUNK chunks: health is authored in chunks and both
			health bars draw one cell per chunk, so a scaled car with a ragged remainder
			would grow a stub cell nobody can read. ]]
		maxHp = math.max(1, math.floor(s.hp * m.hp / (Config.HP_PER_CHUNK or 100) + 0.5) * (Config.HP_PER_CHUNK or 100)),
		scale = m.scale,
		-- No hover/saucer car in the model roster; kept so consumers need no change.
		hover = car.hover == true,
	}
end

--[[ resolve() for a car that already exists: the same numbers, read off the model
	instead of passed in. This is what every LIVE-car consumer should call —
	ChassisController, FxController, CombatService — because resolve(carId) alone
	silently returns the STOCK body for a modified car. ]]
function ChassisSpec.resolveCar(car: Instance?)
	if typeof(car) ~= "Instance" then
		return ChassisSpec.resolve(Config.STARTER_CAR)
	end
	local carId = car:GetAttribute(ChassisSpec.ATTR.CAR_ID)
	return ChassisSpec.resolve(type(carId) == "string" and carId or Config.STARTER_CAR, ChassisSpec.modifiersOf(car))
end

--[[ Memo key for a resolved spec. Two cars sharing an id AND a body resolve identically,
	so a per-frame client can cache on this rather than on carId alone — caching on carId
	is exactly how a juggernaut would inherit a stock car's hull size. ]]
function ChassisSpec.specKey(car: Instance?): string
	local carId = typeof(car) == "Instance" and car:GetAttribute(ChassisSpec.ATTR.CAR_ID) or nil
	local id = type(carId) == "string" and carId or Config.STARTER_CAR
	local mods = ChassisSpec.modifiersOf(car)
	if not mods then
		return id
	end
	return string.format("%s|%s|%s|%s|%s", id, tostring(mods.scale), tostring(mods.mass), tostring(mods.hp), tostring(mods.speed))
end

-- ---------- ram combat ----------
--[[ Body-slam resolution. Pure: same inputs -> same outputs on both sides.

	closingSpeed  studs/s the two hulls approached at along the contact normal
	attackerMass  resolved .mass
	victimMass    resolved .mass
	rearHit       true when the contact landed in the victim's rear arc

	returns damage, knockbackSpeed  (0,0 when the hit is too soft to count) ]]
function ChassisSpec.ramResult(closingSpeed: number, attackerMass: number, victimMass: number, rearHit: boolean)
	local R = Config.RAM
	if closingSpeed < R.MIN_CLOSING_SPEED then
		return 0, 0
	end

	local massRatio = math.clamp(attackerMass / math.max(victimMass, 0.01), 1 / R.MASS_RATIO_CLAMP, R.MASS_RATIO_CLAMP)
	local damage = closingSpeed * R.DAMAGE_PER_SPEED * massRatio
	if rearHit then
		damage = damage * R.FRONT_BONUS
	end

	local knockback = R.KNOCKBACK * massRatio * math.min(closingSpeed / R.MIN_CLOSING_SPEED, 3)
	return damage, knockback
end

-- Damage the rammer takes for its own trouble.
function ChassisSpec.ramSelfDamage(damage: number): number
	return damage * Config.RAM.SELF_DAMAGE_FRACTION
end

--[[ True when `hitDirection` (attacker -> victim, unit) lands in the victim's rear arc.
	Rear arc = the hit came from behind, so it travels the same way the victim faces. ]]
function ChassisSpec.isRearHit(hitDirection: Vector3, victimLook: Vector3): boolean
	return hitDirection.Unit:Dot(victimLook.Unit) > Config.RAM.FRONT_ARC_COS
end

-- ---------- shared state reads ----------
function ChassisSpec.isFrozen(car: Instance, now: number): boolean
	return (car:GetAttribute(ChassisSpec.ATTR.FROZEN_UNTIL) or 0) > now
end

function ChassisSpec.isBoosting(car: Instance, now: number): boolean
	return (car:GetAttribute(ChassisSpec.ATTR.BOOST_UNTIL) or 0) > now
end

function ChassisSpec.isInvulnerable(car: Instance, now: number): boolean
	return (car:GetAttribute(ChassisSpec.ATTR.INVULN) or 0) > now
end

--[[ True while the car is absorbing a knockback impulse.
	The owning client MUST NOT command Drive during this window — its LinearVelocity
	has enough MaxForce to cancel the impulse in about a tenth of a second, which would
	make every ram and explosion feel weightless. Server sets it, client obeys it. ]]
function ChassisSpec.isStaggered(car: Instance, now: number): boolean
	return (car:GetAttribute(ChassisSpec.ATTR.STAGGER_UNTIL) or 0) > now
end

-- Speed multiplier from transient states, applied to topSpeed.
function ChassisSpec.speedMultiplier(car: Instance, now: number): number
	local CH = Config.CHASSIS
	local mult = 1
	if ChassisSpec.isBoosting(car, now) then
		mult = mult * CH.BOOST_MULTIPLIER
	end
	if ChassisSpec.isFrozen(car, now) then
		mult = mult * CH.FROZEN_SPEED_MULTIPLIER
	end
	return mult
end

-- ---------- helpers ----------
function ChassisSpec.getHull(car: Instance): BasePart?
	if not car or not car:IsA("Model") then
		return nil
	end
	return car.PrimaryPart or car:FindFirstChild(ChassisSpec.HULL)
end

return ChassisSpec
