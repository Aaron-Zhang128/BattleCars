--[[ CarFactory
	Builds a drivable car from a REAL model, and the cosmetic twins the shop/garage render.

	Cars used to be generated from primitives. They are now the user's own low-poly models,
	stored at ReplicatedStorage.CrashCore.Assets.CarModels.<Config.CARS[i].model>.

	MEASURED FACTS about those models - verified on all ten, and NOT what they advertise:
		* their world bounding box is axis-aligned and already centred on the origin, with
		  the length running down Z.
		* their PIVOT is NOT the bounding-box centre. It is an arbitrary part's CFrame,
		  yawed 90 deg and offset by up to 8.5 studs, so model:PivotTo() and
		  model:GetBoundingBox() both MIS-PLACE the bodywork. This module ignores the pivot
		  entirely and re-centres on the parts' own measured extents.
		* their nose points +Z, but a chassis drives along -Z (CFrame.LookVector), so every
		  part is yawed by MODEL_FACING_YAW_DEG on assembly or the car drives backwards.
		  Evidence, consistent across all ten: red tail-light neon at -Z, white head-light
		  neon at +Z, and the pickup's cargo bed at -Z. Re-normalise the source models to
		  face -Z and that constant drops to 0 with no other change here.

	PRODUCES the pinned CAR MODEL CONTRACT in ChassisSpec — read that first, every sibling
	codes against it:
		Model "Car_<userId>", tagged ChassisSpec.CAR_TAG, PrimaryPart = Hull
		  Hull            the ONE collidable part, invisible, sized from Config.CARS[i].hull
		  Hull.RootAtt    Attachment at hull centre
		  Hull.WeaponMount Attachment on the centreline, MOUNT_CLEARANCE above the
		                  highest bodywork, facing the way the car drives
		  Hull.Drive      LinearVelocity  (World, force-limited)
		  Hull.Steer      AlignOrientation (OneAttachment)
		  Body/           every model part: Massless, non-collidable, welded to the Hull
		  Wheels/         see WHEELS below
		attributes CarId OwnerUserId Hp MaxHp SpawnedAt BoostUntil FrozenUntil Invuln StaggerUntil

	WHEELS: every part of every model is literally named "Part", so wheels can only be
	found geometrically. Attempted and REJECTED: clustering the dark parts in the lower
	corners does find four clean, symmetric clusters on all ten models, but a ground-
	constrained circle fit inside each cluster disagrees left-vs-right by up to 2.6 studs
	and returns radii from 1.1 to 2.7 studs on the SAME car, because the clusters also
	swallow wheel arches, side skirts and axle bars. An axle centre that wrong makes a
	wheel wobble rather than roll, so the folder is created EMPTY on purpose:
	ChassisController guards an empty Wheels folder and the car drives fine without wheel
	animation. A car with no wheel spin is fine, a car with the wrong parts spinning is not.

	Data flow: SpawnService.spawnCar -> build() -> parents into Workspace.Cars, then sets
	network ownership. This module never parents a car and never touches ownership.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(core:WaitForChild("Shared"):WaitForChild("ChassisSpec"))
local CarRegistry = require(core.Shared:WaitForChild("CarRegistry"))

local CarFactory = {}

-- ==========================================================================
-- tuning
-- ==========================================================================
-- Absolute mass is arbitrary — ram maths uses the RATIO — but it sets the scale for
-- Drive.MaxForce and for CombatService's impulses, so it is pinned here and scaled by
-- each car's stats.mass.
local BASE_MASS = 260
local FORCE_HEADROOM = 1.2 -- deliberately small: oversized force makes collisions feel weightless
local STEER_RESPONSIVENESS = 55
local STEER_ANGULAR_HEADROOM = 4
local PREVIEW_FOLDER = "Previews"
local MODEL_FOLDER = "CarModels"
-- The shipped models' noses point +Z; a chassis drives along -Z. See the header.
local MODEL_FACING_YAW_DEG = 180
-- A cosmetic part casts a shadow only if it is at least this fraction of the car's
-- largest part. ~230 shadow casters per car is a real mobile cost and the small trim
-- adds nothing to the silhouette: the big panels alone read as a car-shaped shadow.
local SHADOW_MIN_VOLUME_FRACTION = 0.12

local ctxRef = nil
local warned = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("CarFactory: " .. message)
end

-- ==========================================================================
-- helpers
-- ==========================================================================
local function modelsFolder(): Folder?
	local assets = core:FindFirstChild("Assets")
	return assets and assets:FindFirstChild(MODEL_FOLDER) or nil
end

local function sourceModel(carDef)
	local folder = modelsFolder()
	if not folder then
		warnOnce("nofolder", "Assets." .. MODEL_FOLDER .. " is missing — no car can be built")
		return nil
	end
	local m = carDef.model and folder:FindFirstChild(carDef.model)
	if not m then
		warnOnce("missing:" .. tostring(carDef.model),
			"no model '" .. tostring(carDef.model) .. "' for car '" .. carDef.id .. "'")
	end
	return m
end

--[==[ AlignOrientation torque, sized from the hull's REAL rotational inertia.

	This used to be Config.CHASSIS.UPRIGHT_TORQUE scaled by inertia RELATIVE to the starter
	car, which pins the absolute value to whatever the starter's hull happens to be. That
	was fine while every hull was the old 6 x 2.4 x 11 procedural box; it broke silently the
	moment the hulls became the real car bodies. Yaw inertia roughly tripled, the
	starter-relative ratio stayed 1.0 by construction, and so every car was left with about
	1.1 rad/s^2 — over a SECOND to reach the yaw rate ChassisController commands. The
	heading never caught up, that controller's YAW_RESYNC_DEG clamp fired every frame, and
	steering read as laggy and snatchy.

	So ask for an angular ACCELERATION — the thing that has to stay constant as the models
	change — and let the torque follow the box. Sized against YAW (rotation about Y), the
	hardest axis on a long car; roll and pitch then get more authority than they strictly
	need, which is exactly what you want for righting a car after a flip. ]==]
local UPRIGHT_ANGULAR_ACCEL_FALLBACK = 7.6 -- rad/s^2, only if Config predates the key
local function uprightTorqueFor(spec)
	local h = spec.hullSize
	-- solid-box inertia about the vertical axis
	local inertiaYaw = (BASE_MASS * spec.mass) * (h.X * h.X + h.Z * h.Z) / 12
	return inertiaYaw * (Config.CHASSIS.UPRIGHT_ANGULAR_ACCEL or UPRIGHT_ANGULAR_ACCEL_FALLBACK)
end

--[[ The one transform that lands a cloned model in car space, computed from the parts
	themselves. Deliberately does NOT use model:GetPivot() or model:GetBoundingBox(): the
	shipped models carry a 90-deg-yawed, off-centre pivot, so either would rotate and shift
	the bodywork off the hull (see header). Pre-multiply the result onto every part. ]]
local function normalisingTransform(model: Model): CFrame
	local low, high = ChassisSpec.measureExtents(model)
	if not low or not high then
		return CFrame.new()
	end
	return CFrame.Angles(0, math.rad(MODEL_FACING_YAW_DEG), 0) * CFrame.new(-(low + high) * 0.5)
end

--[[ Wheel spin.

	ChassisController was written for the ORIGINAL procedural cars, where each wheel was ONE
	cylinder named FL/FR/RL/RR. Every failed attempt here handed it a multi-part assembly
	instead, and the mismatch broke it three different ways (wheels detaching, then freezing
	in world space). So we give it exactly what it was built for: a single part.

	The car body is left completely untouched — every model part still welds rigidly to the
	Hull, which is the known-good car. We only ADD four cylinders and hide the model's own
	wheel blocks behind them. Nothing about the car's assembly changes, so this cannot
	regress driving; worst case the cylinders sit still.

	Positions come from Config.CARS[i].wheels, measured off each model's dark low geometry
	and symmetrised. Naming is derived from the resulting position, never from the measured
	labels, because the facing yaw swaps front and back. ]]
--[[ Scales a source clone about its own centre, BEFORE anything measures it.

	Model:ScaleTo is the right tool — it scales part sizes, mesh scales, attachments and
	the welds the model shipped with — and the shipped models' notorious off-centre pivot
	does not matter here, because normalisingTransform re-centres on the parts' own
	measured extents immediately afterwards either way.

	The manual fallback exists because ScaleTo throws on a model with no valid pivot, and
	a car that fails to build takes somebody's whole round with it. ]]
local function scaleModel(model: Model, scale: number)
	if scale == 1 or scale <= 0 or scale ~= scale then
		return
	end
	local ok = pcall(function()
		model:ScaleTo(scale)
	end)
	if ok then
		return
	end
	warnOnce("scaleto", "Model:ScaleTo failed — scaling parts by hand")

	local low, high = ChassisSpec.measureExtents(model)
	local centre = (low and high) and (low + high) * 0.5 or Vector3.zero
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local at = centre + (d.Position - centre) * scale
			d.Size = d.Size * scale
			d.CFrame = (d.CFrame - d.Position) + at
		end
	end
end

local WHEEL_WIDTH_RATIO = 0.85 -- tyre width as a fraction of its radius
local WHEEL_COLOR = Color3.fromRGB(26, 26, 30)

local function buildWheels(carDef, hull: BasePart, wheelsFolder: Folder, scale: number?)
	local w = carDef.wheels
	if not w then
		return {}
	end
	--[[ Every wheel number is a LENGTH measured off the stock model, so a scaled body
		scales all five of them together — the three positions, the track and the radius.
		Scaling only the radius floats the tyre; scaling only the positions leaves a
		stock-size wheel rattling around inside a double-size arch. ]]
	local s = tonumber(scale) or 1
	if s ~= 1 then
		w = {
			radius = w.radius * s,
			track = w.track * s,
			axleY = w.axleY * s,
			frontZ = w.frontZ * s,
			rearZ = w.rearZ * s,
		}
	end
	local yaw = CFrame.Angles(0, math.rad(MODEL_FACING_YAW_DEG), 0)
	local width = math.max(w.radius * WHEEL_WIDTH_RATIO, 0.8)
	local built = {}
	for _, corner in ipairs({
		{ -w.track, w.axleY, w.frontZ }, { w.track, w.axleY, w.frontZ },
		{ -w.track, w.axleY, w.rearZ }, { w.track, w.axleY, w.rearZ },
	}) do
		local pos = yaw * Vector3.new(corner[1], corner[2], corner[3])
		-- the car drives along -Z, so negative Z is the nose
		local name = (pos.Z < 0 and "F" or "R") .. (pos.X < 0 and "L" or "R")
		local wheel = Instance.new("Part")
		wheel.Name = name
		wheel.Shape = Enum.PartType.Cylinder
		-- a Cylinder's circular axis is its LOCAL X, which is also the axis
		-- ChassisController rolls about: CFrame.Angles(theta, 0, 0)
		wheel.Size = Vector3.new(width, w.radius * 2, w.radius * 2)
		wheel.Color = WHEEL_COLOR
		wheel.Material = Enum.Material.SmoothPlastic
		wheel.Anchored = false
		wheel.CanCollide = false
		wheel.CanQuery = false
		wheel.CanTouch = false
		wheel.CastShadow = false
		--[[ NOT Massless. Once ChassisController disables the weld, it only anchors the
			wheel if `part.AssemblyRootPart == part`; a lone massive part is unambiguously
			its own root. Density is already at the engine
			minimum (0.01), so four wheels add ~0.3% of assembly mass — both sides of a ram
			shift together, so the massRatio the damage maths uses is undisturbed. ]]
		wheel.Massless = false
		wheel.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0.3, 0.5, 1, 1)
		wheel.CFrame = CFrame.new(pos)
		local weld = Instance.new("WeldConstraint")
		weld.Name = "Weld" -- the exact name ChassisController looks for to free it
		weld.Part0 = hull
		weld.Part1 = wheel
		weld.Parent = wheel
		wheel.Parent = wheelsFolder
		table.insert(built, { part = wheel, pos = pos })
	end
	return built
end

-- A wheel block is dark AND close to a hub. Both tests matter: proximity alone swallows
-- wheel arches and side skirts, which is what defeated the earlier attempt.
local WHEEL_DARK_LUMA = 0.28
local function nearestHub(hubs, position: Vector3, captureRadius: number)
	local best, bestDist = nil, nil
	for _, h in ipairs(hubs) do
		local dist = (position - h.pos).Magnitude
		if not bestDist or dist < bestDist then
			best, bestDist = h, dist
		end
	end
	if best and bestDist <= captureRadius then
		return best
	end
	return nil
end

--[[ Turns every part of a cloned model into pure decoration welded to the hull, in car
	space. Welds each part DIRECTLY to the Hull rather than trusting the model's own
	internal welds: the models carry 180-297 of them but the graph is not guaranteed
	connected, and one unwelded part would fly off the car at speed. ~230 WeldConstraints
	is cheap insurance. Returns the number of parts welded. ]]
local function cosmeticise(model: Model, hull: BasePart, bodyFolder: Folder, hubs, captureRadius: number?): number
	local transform = normalisingTransform(model)

	-- Pass 1: collect parts, drop every joint the model shipped with. This MUST happen
	-- before anything moves - a surviving weld would drag its neighbours along with the
	-- part being re-centred. They are redundant once each part is welded to the Hull, and
	-- ~2,400 dead constraints across a full lobby is pure solver load.
	local parts, maxVolume = {}, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			local volume = d.Size.X * d.Size.Y * d.Size.Z
			if volume > maxVolume then
				maxVolume = volume
			end
		elseif d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		end
	end

	local shadowFloor = maxVolume * SHADOW_MIN_VOLUME_FRACTION
	for _, d in ipairs(parts) do
		d.CFrame = transform * d.CFrame
		d.Anchored = false
		d.CanCollide = false
		d.CanQuery = false -- ground probes and hitscan must only ever see the Hull
		d.CanTouch = false -- so a fender can never register a ram
		d.Massless = true -- all mass lives on the Hull, so AssemblyMass is exact
		d.CastShadow = (d.Size.X * d.Size.Y * d.Size.Z) >= shadowFloor
		-- Wheel blocks weld to their HUB so they turn with it; everything else to the Hull.
		local anchorPart = hull
		if hubs and #hubs > 0 and captureRadius then
			local colour = d.Color
			local luma = 0.299 * colour.R + 0.587 * colour.G + 0.114 * colour.B
			if luma < WHEEL_DARK_LUMA then
				-- Hide the model's own wheel blocks; the cylinder stands in for them. They stay
				-- welded to the Hull, so the car's assembly is exactly the known-good one.
				if nearestHub(hubs, d.Position, captureRadius) then
					d.Transparency = 1
					d.CastShadow = false
				end
			end
		end
		local weld = Instance.new("WeldConstraint")
		weld.Name = "Weld"
		weld.Part0 = anchorPart
		weld.Part1 = d
		weld.Parent = d
	end

	for _, c in ipairs(model:GetChildren()) do
		c.Parent = bodyFolder
	end
	return #parts
end

-- ==========================================================================
-- build
-- ==========================================================================
--[[ `mods` is the MODE's body request — today only the Juggernaut asks for one
	(Config.MODES.JUGG: 2x geometry, heavier, tougher, a little slower). nil is the
	ordinary car and the ordinary path. ChassisSpec.resolve applies all four multipliers
	at once, so hull size, hover height, mass, MaxForce, upright torque and MaxHp all
	follow from the spec below and nothing in this file has to know a mode exists. ]]
function CarFactory.build(carId: string, ownerUserId: number, mods): Model?
	local carDef = CarRegistry.getOrStarter(carId)
	if not carDef then
		warnOnce("nodef", "no car definition for '" .. tostring(carId) .. "'")
		return nil
	end
	local source = sourceModel(carDef)
	if not source then
		local starter = CarRegistry.get(Config.STARTER_CAR)
		source = starter and sourceModel(starter)
		if not source then
			return nil
		end
		carDef = starter
	end

	local spec = ChassisSpec.resolve(carDef.id, mods)
	local scale = spec.scale or 1
	local hullSize = spec.hullSize

	local car = Instance.new("Model")
	car.Name = "Car_" .. tostring(ownerUserId)

	-- the ONE collider
	local hull = Instance.new("Part")
	hull.Name = ChassisSpec.HULL
	hull.Size = hullSize
	hull.Transparency = 1
	hull.CastShadow = false -- invisible, but Roblox would still cast its box-shaped shadow
	hull.CanCollide = true
	hull.CanQuery = true
	hull.CanTouch = true
	hull.Anchored = false
	hull.Massless = false
	hull.TopSurface = Enum.SurfaceType.Smooth
	hull.BottomSurface = Enum.SurfaceType.Smooth
	hull.CFrame = CFrame.new()
	local okGroup = pcall(function()
		hull.CollisionGroup = ChassisSpec.COLLISION_GROUP
	end)
	if not okGroup then
		warnOnce("group", "collision group '" .. ChassisSpec.COLLISION_GROUP .. "' not registered")
	end

	-- density chosen so AssemblyMass lands EXACTLY on BASE_MASS * stats.mass whatever the
	-- hull volume: cosmetics are Massless, so hull mass IS assembly mass, and that is what
	-- ChassisSpec.ramResult's massRatio depends on.
	local volume = math.max(hullSize.X * hullSize.Y * hullSize.Z, 1e-3)
	local targetMass = BASE_MASS * spec.mass
	hull.CustomPhysicalProperties = PhysicalProperties.new(targetMass / volume, 0.3, 0.5, 1, 1)
	hull.Parent = car
	car.PrimaryPart = hull

	local rootAtt = Instance.new("Attachment")
	rootAtt.Name = ChassisSpec.ROOT_ATT
	rootAtt.Parent = hull

	local drive = Instance.new("LinearVelocity")
	drive.Name = ChassisSpec.DRIVE
	drive.Attachment0 = rootAtt
	drive.RelativeTo = Enum.ActuatorRelativeTo.World
	drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	drive.VectorVelocity = Vector3.zero
	drive.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	-- carries the car's weight AND accelerates it; small headroom so rams still shove it
	local peakAccel = spec.accel * Config.CHASSIS.BOOST_ACCEL_MULTIPLIER
	drive.MaxForce = targetMass * (Workspace.Gravity + peakAccel + spec.coastDrag) * FORCE_HEADROOM
	drive.Enabled = true
	drive.Parent = hull

	local steer = Instance.new("AlignOrientation")
	steer.Name = ChassisSpec.STEER
	steer.Mode = Enum.OrientationAlignmentMode.OneAttachment
	steer.Attachment0 = rootAtt
	steer.PrimaryAxisOnly = false
	steer.ReactionTorqueEnabled = false
	steer.RigidityEnabled = false
	steer.MaxTorque = uprightTorqueFor(spec)
	steer.MaxAngularVelocity = math.rad(spec.turnRate * STEER_ANGULAR_HEADROOM)
	steer.Responsiveness = STEER_RESPONSIVENESS
	steer.Enabled = true
	steer.Parent = hull

	local body = Instance.new("Folder")
	body.Name = ChassisSpec.BODY
	body.Parent = car
	local wheels = Instance.new("Folder")
	wheels.Name = ChassisSpec.WHEELS
	wheels.Parent = car
	-- Wheel spin is opt-in (Config.CHASSIS.WHEEL_SPIN, currently ON). With it OFF every
	-- part welds rigidly to the Hull, which is the known-good car and the safe fallback.
	local hubs, captureRadius = {}, 0
	if Config.CHASSIS.WHEEL_SPIN then
		hubs = buildWheels(carDef, hull, wheels, scale)
		-- 1.5x, not the old 2.0x: the radii themselves grew ~60% when they were corrected,
		-- and this must keep hiding the wheel WITHOUT reaching a dark bumper or sill.
		captureRadius = carDef.wheels and math.max(carDef.wheels.radius * scale * 1.5, 2.5) or 0
	end

	-- No PivotTo here: the shipped pivot is yawed 90 deg and off-centre, so it would put
	-- the bodywork sideways on the hull. cosmeticise() re-centres on the parts' own
	-- measured extents and applies the facing yaw.
	local clone = source:Clone()
	-- Before mountOffset and before cosmeticise: both MEASURE this clone, so it has to
	-- already be the size the car is going to be.
	scaleModel(clone, scale)
	local mountOffset = ChassisSpec.mountOffset(clone) -- BEFORE cosmeticise empties the clone
	cosmeticise(clone, hull, body, hubs, captureRadius)
	clone:Destroy()

	--[[ WEAPON MOUNT — the one pinned place anything bolts onto a car.

		cosmeticise re-centres the bodywork's measured AABB on the hull's centre, so the
		top of the bodywork is exactly half the MODEL's height above that centre. That is
		NOT hull.Size.Y * 0.5: carDef.hull is deliberately 2 x GROUND_CLEARANCE shorter
		than the body, so measuring off the hull would bury the mount inside the roof.

		Measured on all ten shipped models, that AABB top IS the cabin roof on eight of
		them (gap 0.00) and clears it by 0.70 on the black SUV and 1.31 on the pickup,
		whose beds drag the central column down. So one rule gives every car a mount that
		sits on the roofline and can never clip bodywork, spoiler or light bar.

		Identity rotation is deliberate: a chassis drives along -Z, which is exactly an
		Attachment's own LookVector, so anything welded here already points where the car
		is going, with no per-car correction.

		The arithmetic itself lives in ChassisSpec.mountOffset rather than here, so the
		/weaponview authoring tool derives the identical number client-side from the same
		source model without a car being spawned. ]]
	local mount = Instance.new("Attachment")
	mount.Name = ChassisSpec.MOUNT_ATT
	mount.CFrame = CFrame.new(mountOffset)
	mount.Parent = hull

	car:SetAttribute(ChassisSpec.ATTR.CAR_ID, carDef.id)
	car:SetAttribute(ChassisSpec.ATTR.OWNER, ownerUserId)
	car:SetAttribute(ChassisSpec.ATTR.MAX_HP, spec.maxHp)
	car:SetAttribute(ChassisSpec.ATTR.HP, spec.maxHp)
	car:SetAttribute(ChassisSpec.ATTR.SPAWNED_AT, Workspace:GetServerTimeNow())
	car:SetAttribute(ChassisSpec.ATTR.BOOST_UNTIL, 0)
	car:SetAttribute(ChassisSpec.ATTR.FROZEN_UNTIL, 0)
	car:SetAttribute(ChassisSpec.ATTR.INVULN, 0)
	car:SetAttribute(ChassisSpec.ATTR.STAGGER_UNTIL, 0)

	--[[ Body modifiers, stamped ONLY when they are not 1, so an ordinary car carries no
		extra attributes and ChassisSpec.modifiersOf answers nil for it. They must land
		before the model is parented into Workspace (SpawnService does that): the owning
		client reads Scale to derive its ride height, and a car that replicates without
		it drives one frame at the wrong height for every frame the attribute is late. ]]
	local m = ChassisSpec.normaliseMods(mods)
	if m.scale ~= 1 then
		car:SetAttribute(ChassisSpec.ATTR.SCALE, m.scale)
	end
	if m.mass ~= 1 then
		car:SetAttribute(ChassisSpec.ATTR.MASS_SCALE, m.mass)
	end
	if m.hp ~= 1 then
		car:SetAttribute(ChassisSpec.ATTR.HP_SCALE, m.hp)
	end
	if m.speed ~= 1 then
		car:SetAttribute(ChassisSpec.ATTR.SPEED_SCALE, m.speed)
	end

	CollectionService:AddTag(car, ChassisSpec.CAR_TAG)
	return car
end

-- ==========================================================================
-- previews (garage / shop / index viewports)
-- ==========================================================================
function CarFactory.buildPreview(carId: string): Model?
	local carDef = CarRegistry.getOrStarter(carId)
	local source = carDef and sourceModel(carDef)
	if not source then
		return nil
	end
	local preview = source:Clone()
	preview.Name = carDef.id
	local transform = normalisingTransform(preview)
	for _, d in ipairs(preview:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = transform * d.CFrame
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
		elseif d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("WeldConstraint")
			or d:IsA("JointInstance") or d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	-- The shipped PrimaryPart is an arbitrary yawed part; leaving it set would make the
	-- viewport helpers' GetBoundingBox()/PivotTo() frame the car off-axis. Clearing it
	-- makes the pivot the WorldPivot, which is now identity at the car's centre.
	preview.PrimaryPart = nil
	preview.WorldPivot = CFrame.new()
	return preview
end

--[[ Rebuilds Assets.Previews from scratch (idempotent). 16 ViewportFrames across the
	garage, shop, car shop and index clone from here, so a missing entry is a blank card. ]]
function CarFactory.publishPreviews(): number
	local assets = core:FindFirstChild("Assets")
	if not assets then
		warnOnce("noassets", "Assets folder missing — previews not published")
		return 0
	end
	local folder = assets:FindFirstChild(PREVIEW_FOLDER)
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER
	folder.Parent = assets

	local built = 0
	for _, carDef in ipairs(Config.CARS) do
		local ok, preview = pcall(CarFactory.buildPreview, carDef.id)
		if ok and preview then
			preview.Parent = folder
			built += 1
		else
			warn("CarFactory.publishPreviews: failed for '" .. carDef.id .. "' -> " .. tostring(preview))
		end
	end
	if built < #Config.CARS then
		warn(string.format("CarFactory.publishPreviews: only %d of %d previews published", built, #Config.CARS))
	end
	return built
end

function CarFactory.init(ctx)
	ctxRef = ctx
	CarFactory.publishPreviews()
end

return CarFactory
