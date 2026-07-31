--[[ LuckyBlockService (server service)
	Lucky blocks: drive through one and a reel spins for a weapon.

	The whole point is the REVEAL, so the ordering matters. The winner is rolled the
	instant the block is taken — one server-side roll, no client input — but the powerup
	is not handed over until the reel lands. Both sides key that beat to the same absolute
	clock (workspace:GetServerTimeNow()), so a client that hitches sees a shorter spin,
	never a wrong winner and never a HUD slot that fills early.

	The roll is PowerupDefs.roll, the SAME call PickupService uses for crates, so a lucky
	block is a spectacle and a destination rather than a balance change.

	COLLECTION IS PROXIMITY-FIRST, NOT TOUCH-FIRST.
		A server-side distance check against each live hull is the primary trigger, and the
		Trigger ball's Touched is only a secondary. Touched depends on the physics broadphase
		agreeing about two bodies when the hull is simulated by the DRIVING CLIENT and the
		block is an anchored non-collidable part — which is exactly the case most likely to
		drop a contact at 130 studs/s. The distance check cannot miss: it runs off positions
		the server already gathers for the idle-animation cull, and at ANIM_HZ 20 a car
		crossing a 15-stud ball is sampled every ~6 studs of travel. Both paths funnel into
		one latched collect(), so a block can still only ever pay out once.

	DATA FLOW
		init(ctx)        builds Workspace.LuckyBlocks, starts ONE Heartbeat (spawn cadence +
		                 idle motion + collection) and follows the match phase itself.
		phase -> Match   startRound(): seeds the field, enables spawning.
		phase -> other   stopRound(): clears the field; pending grants no-op.
		collect          roll -> LuckySpin to that ONE client -> after SPIN_SECONDS ->
		                 WeaponService.givePowerup + Notify.

	REMOTES (send only — nothing here is client-driven, so there is nothing to validate)
		LuckySpin  S->C  FireClient(player, { reel, winner, landIndex, startedAt, duration })
		WeaponFx   S->C  ("IMPACT", { origin, color, radius })  pop where the block stood
		Notify     S->C  (text, "gold")                         on LAND, not on collect

	ATTRIBUTES
		Writes NOTHING on the Player — the powerup slot belongs to WeaponService.
		Writes LuckyBlock = true on each block Model; this service owns that attribute.

	INIT ORDER
		Siblings (ArenaService, SpawnService, WeaponService) are resolved LAZILY at call
		time, never captured at init, so init order does not matter. Nothing spawns until
		the Match phase, which is long after every service is up.

	OWNS AT RUNTIME
		Workspace.LuckyBlocks and every descendant. Reads Workspace.Cars (SpawnService's).

	PERF
		The same two bounds PickupService uses, for the same reason — server-driven idle
		motion replicates every moved part. Motion ticks at Config.LUCKY.ANIM_HZ rather
		than per frame, and a block with no car within ANIM_RADIUS is skipped entirely.
		Motion is derived from an absolute clock, never integrated per frame, so a block
		that comes back into range resumes exactly where continuous motion would have put
		it — no pop. The car list is gathered ONCE per tick and serves the cull, the motion
		and the collection check, so adding collection cost nothing.

		Every part is CanQuery = false: a chassis hover ray or a bullet must never see a
		lucky block. The Trigger ball is sized from Config.LUCKY.TRIGGER_RADIUS.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))
local CarRegistry = require(sharedFolder:WaitForChild("CarRegistry"))

local CFG = Config.LUCKY
local UI = Config.UI

-- ==========================================================================
-- CONSTANTS — assembly only. Every gameplay number lives in Config.LUCKY.
-- ==========================================================================

local ROOT_FOLDER = "LuckyBlocks"
local CARS_FOLDER = "Cars" -- read-only; SpawnService owns this folder
local ATTR_LUCKY = "LuckyBlock"

local SPAWN_TRIES = 8 -- separation retries per tick, then skip the tick
local SPAWN_MISS_WARN = 30 -- consecutive failed ticks before we suspect the arena
local ANIM_MIN_HZ = 1 -- floor under Config.LUCKY.ANIM_HZ so a bad value cannot divide by zero
local SEED_FRACTION = 0.6 -- fraction of the active cap placed instantly on startRound
local WALK_UP_LIMIT = 6 -- ancestor hops looking for the car model
local NOTIFY_MOOD = "gold"

-- Cosmetic proportions, all against Config.LUCKY.BLOCK_SIZE so the block scales.
local BAND_THICKNESS = 0.22 -- fraction of the cube edge
local BAND_OVERHANG = 1.03 -- bands stand just proud of the cube so they never z-fight
local BLOCK_TRANSPARENCY = 0.1
-- A constant lean applied after the idle yaw: the cube tumbles on a tilted axis, which
-- reads as "prize" rather than "crate" without costing a second animated value.
local TILT = CFrame.Angles(math.rad(14), 0, math.rad(12))
local MARK_TEXT = "?"
local MARK_SIZE = Vector2.new(56, 56)
local MARK_TEXT_SIZE = 46

-- ==========================================================================
-- STATE
-- ==========================================================================

local LuckyBlockService = {}

local ctxRef = nil
local rng = Random.new()

local rootFolder = nil
local active = {} -- array of block records
local count = 0
local nextSpawnAt = 0
local spinBusyUntil = {} -- player -> os.clock() until which they cannot take another block

local spawning = false
local elapsed = 0 -- absolute animation clock; motion is derived from it, never integrated
local animAccum = 0
local spawnMissStreak = 0
local fieldEpoch = 0 -- bumped by clearAll, so a pending grant from a dead round no-ops

local heartbeatConn, phaseConn, playerConn = nil, nil, nil
local warned = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("LuckyBlockService: " .. message)
end

-- Studio-only diagnostics, on the same flag the bootstrap uses. Never prints for players.
local function trace(message: string)
	if Config.VERBOSE_BOOT then
		print("[LuckyBlocks] " .. message)
	end
end

-- Lazy sibling lookup. Never called during init.
local function svc(name: string)
	local bag = ctxRef and ctxRef.svc
	local found = bag and bag[name]
	if not found then
		warnOnce("svc_" .. name, name .. " unavailable")
	end
	return found
end

local function remote(name: string)
	local found = ctxRef and ctxRef.net and ctxRef.net[name]
	if not found then
		warnOnce("net_" .. name, name .. " remote missing")
	end
	return found
end

local function isPlayer(value): boolean
	return typeof(value) == "Instance" and value:IsA("Player") and value.Parent ~= nil
end

--[[ Studio gets a much denser field. In production 5 blocks 55 studs apart across a
	420-stud arena is the intended rarity; in a 40-second solo test it is a field you
	never find, which reads as a broken feature. Gated at the point of use per house rule. ]]
function LuckyBlockService.maxActive(): number
	if RunService:IsStudio() then
		return Config.TEST.LUCKY_MAX_ACTIVE or CFG.MAX_ACTIVE
	end
	return CFG.MAX_ACTIVE
end

function LuckyBlockService.minSeparation(): number
	if RunService:IsStudio() then
		return Config.TEST.LUCKY_MIN_SEPARATION or CFG.MIN_SEPARATION
	end
	return CFG.MIN_SEPARATION
end

-- ==========================================================================
-- ARENA QUERIES — ArenaService owns the geometry, so we only ask it questions.
-- ==========================================================================

local function randomGround(): Vector3?
	local arena = svc("ArenaService")
	if not arena or type(arena.randomGroundPoint) ~= "function" then
		return nil
	end
	local ok, point = pcall(arena.randomGroundPoint, CFG.SPAWN_INSET)
	if not ok or typeof(point) ~= "Vector3" then
		warnOnce("randomGround", "ArenaService.randomGroundPoint gave no point")
		return nil
	end
	return point
end

--[[ Every live car as { pos, car }. Built at most ONCE per tick and reused by the animation
	cull, the motion write and the collection check. ]]
local function liveCars(): { { pos: Vector3, car: Model } }
	local out = {}
	local carsFolder = Workspace:FindFirstChild(CARS_FOLDER)
	if not carsFolder then
		return out -- SpawnService has not made its folder yet; nobody is out there
	end
	for _, child in ipairs(carsFolder:GetChildren()) do
		if child:IsA("Model") then
			local hull = ChassisSpec.getHull(child)
			if hull then
				table.insert(out, { pos = hull.Position, car = child })
			end
		end
	end
	return out
end

-- ==========================================================================
-- BUILD — primitives only, this place has no art assets.
-- ==========================================================================

local function newPart(name: string, size: Vector3, color: Color3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false -- you drive THROUGH a lucky block, you do not bump it
	part.CanTouch = false -- collection is the Trigger's job, never a cosmetic's
	part.CanQuery = false -- keep chassis hover rays and bullets off it
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[ Cube + two crossed bands + a "?" billboard + the trigger ball = 4 parts.
	Returns the model and its trigger. ]]
local function buildBlock(): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "LuckyBlock"

	local diameter = CFG.TRIGGER_RADIUS * 2
	local trigger = Instance.new("Part")
	trigger.Name = "Trigger"
	trigger.Shape = Enum.PartType.Ball
	trigger.Size = Vector3.new(diameter, diameter, diameter)
	trigger.Transparency = 1
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.CanTouch = true
	trigger.CanQuery = false
	trigger.CastShadow = false
	trigger.Parent = model

	local edge = CFG.BLOCK_SIZE
	local cube = newPart("Cube", Vector3.new(edge, edge, edge), CFG.COLOR, model)
	cube.Transparency = BLOCK_TRANSPARENCY
	cube.CastShadow = true
	cube.CFrame = CFrame.new()

	-- Two crossed bands read as a wrapped prize rather than a plain glowing cube.
	local band = edge * BAND_THICKNESS
	local span = edge * BAND_OVERHANG
	local bandFlat = newPart("BandFlat", Vector3.new(span, band, span), CFG.ACCENT, model)
	bandFlat.CFrame = CFrame.new()
	local bandUpright = newPart("BandUpright", Vector3.new(band, span, span), CFG.ACCENT, model)
	bandUpright.CFrame = CFrame.new()

	--[[ The "?" rides a billboard rather than a SurfaceGui so it faces the driver from any
		approach. AlwaysOnTop is FALSE on purpose: a beacon that shines through the arena
		walls would read as a block you can reach when you cannot. ]]
	local mark = Instance.new("BillboardGui")
	mark.Name = "Mark"
	mark.Size = UDim2.fromOffset(MARK_SIZE.X, MARK_SIZE.Y)
	mark.StudsOffsetWorldSpace = Vector3.new(0, CFG.MARK_HEIGHT, 0)
	mark.AlwaysOnTop = false
	mark.LightInfluence = 0
	mark.MaxDistance = CFG.MARK_DISTANCE
	mark.Adornee = cube
	mark.Parent = cube

	local markLabel = Instance.new("TextLabel")
	markLabel.Name = "Q"
	markLabel.Size = UDim2.fromScale(1, 1)
	markLabel.BackgroundTransparency = 1
	markLabel.Text = MARK_TEXT
	markLabel.Font = Enum.Font.GothamBlack
	markLabel.TextColor3 = UI.PAPER
	markLabel.TextSize = MARK_TEXT_SIZE
	markLabel.TextStrokeColor3 = UI.INK
	markLabel.TextStrokeTransparency = 0
	markLabel.Parent = mark

	model.PrimaryPart = trigger
	return model, trigger
end

-- ==========================================================================
-- FIELD BOOKKEEPING
-- ==========================================================================

local onTriggerTouched -- forward declaration; defined once its dependencies exist

local function removeRecord(record): boolean
	for i = #active, 1, -1 do
		if active[i] == record then
			active[i] = active[#active]
			active[#active] = nil
			return true
		end
	end
	return false
end

local function destroyRecord(record)
	if record.conn then
		record.conn:Disconnect()
		record.conn = nil
	end
	if record.model then
		record.model:Destroy()
		record.model = nil
	end
end

-- A taken block holds its slot for RESPAWN_DELAY, so the field genuinely thins out.
local function releaseSlot()
	local delay = CFG.RESPAWN_DELAY or 0
	if delay <= 0 then
		count = math.max(0, count - 1)
		return
	end

	local epoch = fieldEpoch
	task.delay(delay, function()
		if epoch ~= fieldEpoch then
			return -- field was cleared under us; the counter is already zeroed
		end
		count = math.max(0, count - 1)
	end)
end

local function createBlock(groundPos: Vector3): boolean
	if not rootFolder then
		warnOnce("folder", "root folder missing")
		return false
	end

	local model, trigger = buildBlock()
	local basePos = Vector3.new(groundPos.X, groundPos.Y + CFG.FLOAT_HEIGHT, groundPos.Z)

	model:SetAttribute(ATTR_LUCKY, true)
	CollectionService:AddTag(model, ChassisSpec.LUCKY_TAG)
	model:PivotTo(CFrame.new(basePos))
	model.Parent = rootFolder

	local record = {
		model = model,
		basePos = basePos,
		phase = rng:NextNumber(0, math.pi * 2), -- so the field never pulses in lockstep
		spinOffset = rng:NextNumber(0, 360),
		taken = false,
		conn = nil,
	}
	record.conn = trigger.Touched:Connect(function(hitPart)
		onTriggerTouched(record, hitPart)
	end)

	table.insert(active, record)
	count += 1
	return true
end

-- XZ-only separation, so a block near a ramp still counts against one on the floor beside it.
local function farEnough(pos: Vector3): boolean
	local min = LuckyBlockService.minSeparation()
	local minSq = min * min
	for _, record in ipairs(active) do
		local dx = record.basePos.X - pos.X
		local dz = record.basePos.Z - pos.Z
		if dx * dx + dz * dz < minSq then
			return false
		end
	end
	return true
end

-- Bounded retries: a crowded field skips this tick rather than spinning on the spot.
local function trySpawn(): boolean
	for _ = 1, SPAWN_TRIES do
		local ground = randomGround()
		if not ground then
			return false
		end
		if farEnough(ground) then
			return createBlock(ground)
		end
	end
	return false
end

-- The whistle must not blow on an arena with nothing worth driving to.
local function seedField()
	local target = math.max(1, math.floor(LuckyBlockService.maxActive() * SEED_FRACTION))
	while count < target do
		if not trySpawn() then
			break
		end
	end
	trace(string.format("seeded %d of a %d cap", #active, LuckyBlockService.maxActive()))
end

-- ==========================================================================
-- THE SPIN
-- ==========================================================================

--[[ The car they are actually driving decides the signature-powerup bonus. Equipped id is
	the fallback for the frame between equipping and respawning. ]]
local function drivingCarId(player: Instance): string
	local spawnSvc = svc("SpawnService")
	if spawnSvc and type(spawnSvc.getCar) == "function" then
		local ok, car = pcall(spawnSvc.getCar, player)
		if ok and typeof(car) == "Instance" then
			local id = car:GetAttribute(ChassisSpec.ATTR.CAR_ID)
			if type(id) == "string" and id ~= "" then
				return id
			end
		end
	end
	return CarRegistry.equippedId(player)
end

--[[ The tile strip the client scrolls. The winner sits at landIndex with REEL_TAIL tiles
	behind it, so the client's settle never runs off the end of the strip. Consecutive
	duplicates are avoided because two identical tiles side by side read as a stalled reel. ]]
local function buildReel(winnerId: string): ({ string }, number)
	local defs = PowerupDefs.list()
	if #defs == 0 then
		return { winnerId }, 1
	end

	local reel = {}
	local previous = nil
	for _ = 1, math.max(1, CFG.REEL_TILES - 1) do
		local pick = defs[rng:NextInteger(1, #defs)].id
		for _ = 1, 3 do
			if pick ~= previous then
				break
			end
			pick = defs[rng:NextInteger(1, #defs)].id
		end
		previous = pick
		table.insert(reel, pick)
	end

	table.insert(reel, winnerId)
	local landIndex = #reel

	for _ = 1, math.max(0, CFG.REEL_TAIL) do
		table.insert(reel, defs[rng:NextInteger(1, #defs)].id)
	end

	return reel, landIndex
end

--[[ Rolls, tells that ONE client to spin, and schedules the grant for the moment the reel
	lands. The powerup deliberately does NOT arrive early: WeaponService filling the slot is
	what pops the HUD, and popping it before the reel stops spoils the reveal.

	A player who dies mid-spin still gets the weapon — they drove through the block before
	they died, and taking it back on a technicality is the kind of thing players notice. ]]
local function startSpin(player: Instance)
	local def = PowerupDefs.roll(drivingCarId(player), rng)
	if not def then
		warnOnce("roll", "PowerupDefs.roll returned nothing")
		return
	end

	local reel, landIndex = buildReel(def.id)
	local duration = CFG.SPIN_SECONDS
	local startedAt = Workspace:GetServerTimeNow()

	spinBusyUntil[player] = os.clock() + duration + CFG.BUSY_TAIL

	local spinRemote = remote("LuckySpin")
	if spinRemote then
		spinRemote:FireClient(player, {
			reel = reel,
			winner = def.id,
			landIndex = landIndex,
			startedAt = startedAt,
			duration = duration,
		})
	end
	trace(string.format("%s spun -> %s (reel %d tiles, land %d)", player.Name, def.id, #reel, landIndex))

	local epoch = fieldEpoch
	task.delay(duration, function()
		if epoch ~= fieldEpoch then
			return -- the round ended while the reel was spinning
		end
		if not isPlayer(player) then
			return -- left mid-spin
		end

		local weapons = svc("WeaponService")
		if weapons and type(weapons.givePowerup) == "function" then
			weapons.givePowerup(player, def.id)
		end

		local notify = remote("Notify")
		if notify then
			notify:FireClient(player, "Lucky! " .. def.name .. "!", NOTIFY_MOOD)
		end
	end)
end

-- ==========================================================================
-- COLLECTION
-- ==========================================================================

local function popFx(position: Vector3)
	local fx = remote("WeaponFx")
	if not fx then
		return
	end
	-- Reusing the pinned "IMPACT" kind: FxController already knows how to sparkle it.
	fx:FireAllClients("IMPACT", {
		origin = position,
		color = CFG.COLOR,
		radius = CFG.FX_RADIUS,
		vfx = "STAR", -- a lucky block goes off like the prize it is
	})
end

--[[ The ONE way a block is ever consumed. Both the proximity check and the Trigger's
	Touched land here, and `record.taken` latches before anything that can yield, so a
	block can only ever pay out once no matter how many paths fire in the same frame. ]]
local function collect(record, car: Model)
	if record.taken then
		return
	end
	if not MatchState.isMatch() then
		return -- lucky blocks are inert outside the Match phase
	end

	local spawnSvc = svc("SpawnService")
	if not spawnSvc or type(spawnSvc.playerFromCar) ~= "function" then
		return
	end

	local okOwner, player = pcall(spawnSvc.playerFromCar, car)
	if not okOwner or not isPlayer(player) then
		return
	end
	if type(spawnSvc.isAlive) == "function" and not spawnSvc.isAlive(player) then
		return
	end

	--[[ One reel at a time per player. A second spin starting mid-reel would restart the
		card and overwrite the first prize, so the block is LEFT STANDING instead — they can
		come back for it. This also covers a car straddling two blocks at once. ]]
	if os.clock() < (spinBusyUntil[player] or 0) then
		return
	end

	record.taken = true
	removeRecord(record)
	releaseSlot()

	local position = record.basePos
	destroyRecord(record)
	popFx(position)

	-- pcall'd: WeaponService erroring must not leave the field bookkeeping half-updated.
	local ok, err = pcall(startSpin, player)
	if not ok then
		warn("LuckyBlockService: startSpin failed -> " .. tostring(err))
	end
end

local function carFromPart(part: BasePart): Model?
	local node: Instance? = part
	for _ = 1, WALK_UP_LIMIT do
		if not node then
			return nil
		end
		if node:IsA("Model") and CollectionService:HasTag(node, ChassisSpec.CAR_TAG) then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Secondary path only; the per-tick distance check is what actually catches fast cars.
onTriggerTouched = function(record, hitPart: BasePart)
	if record.taken then
		return
	end
	local car = carFromPart(hitPart)
	if car then
		collect(record, car)
	end
end

-- ==========================================================================
-- PUBLIC API
-- ==========================================================================

function LuckyBlockService.clearAll()
	fieldEpoch += 1

	for i = #active, 1, -1 do
		destroyRecord(active[i])
		active[i] = nil
	end
	count = 0
	nextSpawnAt = 0 -- the next tick may spawn immediately

	if rootFolder then
		-- Anything the folder holds outside `active` (a reload leftover) goes too.
		for _, child in ipairs(rootFolder:GetChildren()) do
			child:Destroy()
		end
	end
end

function LuckyBlockService.startRound()
	LuckyBlockService.clearAll()
	spawnMissStreak = 0
	spawning = true
	seedField()
end

function LuckyBlockService.stopRound()
	spawning = false
	LuckyBlockService.clearAll()
end

-- How many blocks are standing right now.
function LuckyBlockService.activeCount(): number
	return #active
end

-- ==========================================================================
-- LOOP + INIT
-- ==========================================================================

local function stepSpawning(now: number)
	if not spawning then
		return
	end
	if now < nextSpawnAt then
		return
	end

	nextSpawnAt = now + CFG.SPAWN_INTERVAL
	if count >= LuckyBlockService.maxActive() then
		return
	end

	-- A field that is due for a block but never places one means the arena is not answering.
	if trySpawn() then
		spawnMissStreak = 0
	else
		spawnMissStreak += 1
		if spawnMissStreak >= SPAWN_MISS_WARN then
			warnOnce("spawnStarved", "no block placed in " .. SPAWN_MISS_WARN .. " due ticks — check ArenaService")
		end
	end
end

--[[ One throttled pass over the field doing motion AND collection off a single car list.

	Manual sine math per the house rule: no TweenService for looped motion. Throttled to
	Config.LUCKY.ANIM_HZ and culled to ANIM_RADIUS, because every moved part replicates.
	`now` is an absolute clock, so a block that was skipped resumes at the exact CFrame
	continuous motion would have given it — coming back into range never pops.

	Collections are DEFERRED to after the loop: collect() calls removeRecord(), which
	swap-removes out of `active`, and mutating the array mid-ipairs would silently skip
	the block that got swapped into the freed index. ]]
local function stepBlocks(now: number, dt: number)
	animAccum += dt
	local interval = 1 / math.max(ANIM_MIN_HZ, CFG.ANIM_HZ)
	if animAccum < interval then
		return
	end
	animAccum %= interval

	if #active == 0 then
		return
	end

	local cars = liveCars() -- ONCE per tick, shared by the cull, the motion and collection
	if #cars == 0 then
		return -- nobody is out there to see it; every block holds its last CFrame
	end

	local animRadiusSq = CFG.ANIM_RADIUS * CFG.ANIM_RADIUS
	local takeRadiusSq = CFG.TRIGGER_RADIUS * CFG.TRIGGER_RADIUS
	local pending = nil

	for _, record in ipairs(active) do
		local base = record.basePos
		local seen = false
		local hitCar = nil

		for _, entry in ipairs(cars) do
			local pos = entry.pos
			local dx, dy, dz = pos.X - base.X, pos.Y - base.Y, pos.Z - base.Z
			local distSq = dx * dx + dy * dy + dz * dz
			if distSq <= takeRadiusSq then
				hitCar = entry.car
				break -- first car to reach it takes it
			end
			if distSq <= animRadiusSq then
				seen = true
			end
		end

		if hitCar then
			pending = pending or {}
			table.insert(pending, { record = record, car = hitCar })
		elseif seen then
			local bob = MathUtil.drift(now, CFG.BOB_SPEED, record.phase, CFG.BOB_HEIGHT)
			local yaw = math.rad((now * CFG.SPIN_SPEED + record.spinOffset) % 360)
			record.model:PivotTo(CFrame.new(base + Vector3.new(0, bob, 0)) * CFrame.Angles(0, yaw, 0) * TILT)
		end
	end

	if pending then
		for _, item in ipairs(pending) do
			collect(item.record, item.car)
		end
	end
end

function LuckyBlockService.init(ctx)
	ctxRef = ctx

	rootFolder = Workspace:FindFirstChild(ROOT_FOLDER)
	if not rootFolder then
		rootFolder = Instance.new("Folder")
		rootFolder.Name = ROOT_FOLDER
		rootFolder.Parent = Workspace
	end

	spawning = false
	elapsed = 0
	animAccum = 0
	spawnMissStreak = 0
	LuckyBlockService.clearAll()

	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	-- ONE loop for every job: spawn cadence, idle motion and collection.
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		stepSpawning(elapsed)
		stepBlocks(elapsed, dt)
	end)

	if playerConn then
		playerConn:Disconnect()
	end
	playerConn = Players.PlayerRemoving:Connect(function(player)
		spinBusyUntil[player] = nil
	end)

	--[[ Phase-driven on purpose: MatchService does not need to know this service exists.
		onPhaseChanged fires once with the current phase, so joining mid-Match still seeds. ]]
	if phaseConn then
		phaseConn:Disconnect()
	end
	phaseConn = MatchState.onPhaseChanged(function(phase)
		if phase == MatchState.PHASES.MATCH then
			if not spawning then
				LuckyBlockService.startRound()
			end
		elseif spawning then
			LuckyBlockService.stopRound()
		end
	end)

	trace(string.format("init: cap %d, separation %d", LuckyBlockService.maxActive(), LuckyBlockService.minSeparation()))
end

return LuckyBlockService
