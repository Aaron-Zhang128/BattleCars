--[[ ChassisSpec
	The pinned car-model contract plus the pure math both sides must agree on.

	Client ChassisController drives the car; server CombatService scores the ram.
	They share this file so damage never disagrees.

	CAR MODEL CONTRACT (built by CarFactory, do not deviate):
		Model                          name = "Car_<userId>", tagged ChassisSpec.CAR_TAG
		  PrimaryPart = Hull           Part, the ONLY collidable body
		  Hull.RootAtt                 Attachment at hull center
		  Hull.WeaponMount             Attachment sitting ON the patch of roof a weapon
		                               base covers (see mountOffset -- it is NOT always
		                               the centre, and NOT the tallest point), LookVector
		                               = the way the car drives. THE place to bolt a
		                               weapon or a cosmetic.
		  Hull.BodyTop                 Attachment on the centreline at the highest point
		                               of the bodywork. What a NAMETAG clears; never
		                               where anything stands.
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
ChassisSpec.TOP_ATT = "BodyTop" -- highest point of the bodywork; what a nametag clears
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

--[[ Half the widest weapon base in the game (RAILGUN, 6.80 studs across), so the disc
	mountOffset samples is exactly the patch of roof a rig physically stands on. Widen it
	and the pickup climbs back onto its cab. ]]
ChassisSpec.MOUNT_FOOTPRINT = 3.4

--[=[ SEATING THE MOUNT. These four dials are the whole "a weapon must not float"
	rule, and they exist because a car roof is not a table: it is domed, it carries
	rails and aerials, and on one of the ten cars there is no roof at all.

	COVERAGE  the fraction of the base's footprint that must be SOLID at the height
	          the mount picks. Reading the highest thing in the footprint instead --
	          which is what this used to do -- hands the whole rig to a roof rail:
	          the black SUV's rails stand 0.70 above its roof, so every weapon on it
	          hovered that far off the paint. At 0.60 the rails become the minority
	          they are, the base sits on the ROOF, and the rails poke harmlessly into
	          its skirt.
	SEAT_TOL  how far under the chosen height still counts as touching, i.e. how much
	          dome a base is allowed to bridge.
	POKE_TOL  how far a rail/aerial may stand PROUD of it before that spot counts as
	          spearing the rig rather than supporting it. Keep it under a base's own
	          thickness (~1.5 studs) or a windscreen can come through the turret.
	SEAT_OK   a footprint this solid is accepted where it stands, so nine of the ten
	          cars never enter the slide search below and land on exactly the height
	          they had before this rule existed. ]=]
ChassisSpec.MOUNT_COVERAGE = 0.60
ChassisSpec.MOUNT_SEAT_TOL = 0.60
ChassisSpec.MOUNT_POKE_TOL = 0.80
ChassisSpec.MOUNT_SEAT_OK = 0.85

--[[ How far, and in what steps, the mount may travel ALONG THE CAR to find something
	to stand on when dead centre is mostly air. It is the convertible that needs this:
	its centre is the open cockpit, so a centred mount leaves the gun hovering over the
	seats with only the windscreen holding it up. Sliding finds the bonnet 6.5 studs
	forward, where the base is 100% supported. Nine cars never slide at all. ]]
ChassisSpec.MOUNT_SLIDE_MAX = 7
ChassisSpec.MOUNT_SLIDE_STEP = 0.5

--[[ The yaw CarFactory turns a raw source model by on assembly (its models are authored
	nose-backwards). It lives here rather than in CarFactory because mountOffset now
	returns a point that is OFF the centreline, and that point has to be turned by the
	same angle as the bodywork or the mount lands on the wrong end of the car. ]]
ChassisSpec.MODEL_FACING_YAW_DEG = 180

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

--[=[ Where Hull.WeaponMount sits, in hull space, for a RAW source model.

	CarFactory re-centres the bodywork's measured bounds on the hull's centre, so a
	height here is measured from that AABB CENTRE. It is NOT hullSize.Y * 0.5 —
	car.hull is deliberately 2 x GROUND_CLEARANCE shorter than the body, so measuring
	off the hull would bury the mount inside the roof.

	IT SEATS THE RIG ON THE ROOF IT ACTUALLY STANDS ON. Not the tallest point anywhere
	on the car (that is the whole-model rule this started as, and it left every weapon
	on the pickup hanging over the tray), and not the tallest point in the footprint
	either (that is the rule after it, and it handed the black SUV's rig to a roof rail
	and hung it 1.00 stud off the paint). What it does instead is sample the disc the
	base physically covers and take the height at which MOUNT_COVERAGE of that disc is
	SOLID — the roof plane, with rails and aerials outvoted.

	AND IT MAY SLIDE ALONG THE CAR. A convertible has no roof at all: dead centre is
	the open cockpit, and the only thing up there to hold a gun is the windscreen. So
	when the footprint where it stands is mostly air, the mount walks the car's long
	axis in MOUNT_SLIDE_STEP steps and takes the most solid seat it can find — the
	bonnet, 6.5 studs forward, on the convertible. Nine of the ten cars pass the
	MOUNT_SEAT_OK test where they stand and never move a millimetre.

	The offset comes back YAWED BY MODEL_FACING_YAW, because it is no longer on the
	centre of the car: the slide is measured on the raw model and the bodywork is
	turned by that angle on assembly, so the mount has to turn with it or it lands on
	the wrong end. Height is unaffected either way.

	The whole-model top is kept as the FALLBACK for a model with nothing under it at
	all, and it is the value that can never clip.

	MEMOISED. Sampling a disc 113 ways costs ~2 ms on a car that stands where it is and
	~10 ms on one that has to go looking for a seat, and CarFactory calls this on EVERY
	spawn — twelve at once at the start of a round. The answer depends only on the model
	and the size it was scaled to, so it is worked out once per (model, size). ]=]
local mountMemo = {}

function ChassisSpec.mountOffset(model: Model): Vector3
	local low, high = ChassisSpec.measureExtents(model)
	if not low or not high then
		return Vector3.new(0, ChassisSpec.MOUNT_CLEARANCE, 0)
	end

	local size = high - low
	local memoKey = string.format("%s|%.3f|%.3f|%.3f", model.Name, size.X, size.Y, size.Z)
	local cached = mountMemo[memoKey]
	if cached then
		return cached
	end

	local centre = (low + high) * 0.5
	local reach = ChassisSpec.MOUNT_FOOTPRINT
	local slideMax = ChassisSpec.MOUNT_SLIDE_MAX

	--[[ Which horizontal axis is the car's LENGTH. A raw model may be authored across
		either one, so this is measured rather than assumed: sliding a mount sideways
		off a car would be a far worse bug than the float it is fixing. ]]
	local alongX = (high.X - low.X) >= (high.Z - low.Z)

	--[[ Every part flattened to a world-axis box, once, and only the ones that can
		reach the sampled disc anywhere along its travel. Everything below reads this
		list, so the slide search costs no extra geometry passes. ]]
	local boxes = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf, half = d.CFrame, d.Size * 0.5
			local extent = Vector3.new(
				math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z,
				math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z,
				math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
			)
			local xReach = alongX and (reach + slideMax) or reach
			local zReach = alongX and reach or (reach + slideMax)
			if math.abs(cf.Position.X - centre.X) - extent.X <= xReach
				and math.abs(cf.Position.Z - centre.Z) - extent.Z <= zReach
			then
				table.insert(boxes, { cf.Position - extent, cf.Position + extent })
			end
		end
	end

	--[[ The surface height under each of 113 points on the base's own footprint, at a
		mount slid `along` studs down the car. A point with nothing under it is AIR and
		sorts to the bottom, which is exactly how an open cockpit loses the vote. ]]
	local SAMPLES = 11
	local function profile(along: number)
		local tops = {}
		for i = 0, SAMPLES - 1 do
			for j = 0, SAMPLES - 1 do
				local u = -reach + 2 * reach * i / (SAMPLES - 1)
				local v = -reach + 2 * reach * j / (SAMPLES - 1)
				if u * u + v * v <= reach * reach then
					local x = centre.X + (alongX and (along + u) or v)
					local z = centre.Z + (alongX and v or (along + u))
					local top = nil
					for _, b in ipairs(boxes) do
						if x >= b[1].X and x <= b[2].X and z >= b[1].Z and z <= b[2].Z then
							top = top and math.max(top, b[2].Y) or b[2].Y
						end
					end
					table.insert(tops, top or -math.huge)
				end
			end
		end
		table.sort(tops, function(a, b)
			return a > b
		end)
		return tops
	end

	--[[ Reads one profile: the height COVERAGE of the disc reaches, and how much of the
		disc that height actually seats (touching it, or standing no more proud of it
		than a rail is allowed to). That fraction is the score the slide search maximises. ]]
	local function seatOf(tops)
		local index = math.clamp(math.ceil(#tops * ChassisSpec.MOUNT_COVERAGE), 1, #tops)
		local level = tops[index]
		if level == -math.huge then
			return nil, 0
		end
		local seated = 0
		for _, top in ipairs(tops) do
			if top >= level - ChassisSpec.MOUNT_SEAT_TOL and top <= level + ChassisSpec.MOUNT_POKE_TOL then
				seated += 1
			end
		end
		return level, seated / math.max(#tops, 1)
	end

	local bestAlong = 0
	local bestLevel, bestSeat = seatOf(profile(0))

	--[[ Only a car that is genuinely standing on air pays for this. Nearest seat wins
		ties, so a mount never wanders further down the bonnet than it has to. ]]
	if not bestLevel or bestSeat < ChassisSpec.MOUNT_SEAT_OK then
		local step = math.max(ChassisSpec.MOUNT_SLIDE_STEP, 0.1)
		for k = 1, math.floor(slideMax / step) do
			for _, along in ipairs({ k * step, -k * step }) do
				local level, seat = seatOf(profile(along))
				if level and (not bestLevel or seat > bestSeat + 1e-6) then
					bestLevel, bestSeat, bestAlong = level, seat, along
				end
			end
		end
	end

	local topAboveCentre = bestLevel and (bestLevel - centre.Y) or (high.Y - low.Y) * 0.5
	local offset = Vector3.new(
		alongX and bestAlong or 0,
		topAboveCentre + ChassisSpec.MOUNT_CLEARANCE,
		alongX and 0 or bestAlong
	)
	-- ...turned onto the assembled car, exactly as CarFactory turns the bodywork.
	local mount = CFrame.Angles(0, math.rad(ChassisSpec.MODEL_FACING_YAW_DEG), 0) * offset
	mountMemo[memoKey] = mount
	return mount
end

--[=[ The TOP OF THE SILHOUETTE, on the centreline — the highest point of the bodywork
	anywhere on the car, measured from the same AABB centre mountOffset measures from.

	It exists because the mount stopped being that point. A weapon has to stand on
	something, so the mount seats on the roof the base covers and slides off centre when
	there is none; a NAMETAG has to clear the whole car, so it wants the tallest thing on
	it. Reading one off the other is what put the tag over the pickup's bed rather than
	over its cab, and what would have dropped the convertible's tag onto the bonnet with
	its gun. Two different questions, two marks. ]=]
function ChassisSpec.topOffset(model: Model): Vector3
	local low, high = ChassisSpec.measureExtents(model)
	if not low or not high then
		return Vector3.new(0, ChassisSpec.MOUNT_CLEARANCE, 0)
	end
	return Vector3.new(0, (high.Y - low.Y) * 0.5, 0)
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
