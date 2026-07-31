--[[ EngineController — the engine note under every car.

	One looped Sound per car, parented to that car's HULL so it is positional: you hear
	other people's engines from where they actually are, and your own from under you.
	Pitch and volume follow that car's SPEED, read straight off the hull's assembly
	velocity — the one signal every client already has for every car. No remote, no
	attribute, nothing new to replicate.

	ENTIRELY LOCAL AND COSMETIC. Every Sound is created on this client and parented to
	the car it belongs to, so it dies with that car, the server never sees it, and
	nothing here can affect a single gameplay outcome.

	SOURCE   SoundService.GameSFX["Car Driving Sound Effect"], CLONED — the template is
	         never played in place, so its authored properties stay exactly as they are.

	WHICH VOLUME SLIDER IT LANDS ON. SettingsUI runs an adopter that sorts ungrouped
	Sounds into two client-local buses BY PARENT: anything under Workspace becomes a
	"World Sound", anything under SoundService becomes a "Menu Sound". Parenting to the
	hull therefore files the engine under World Sounds for free, which is where a player
	would look for it. Leave SoundGroup nil or that adoption stops working.

	FEEL — the ramp is mostly PITCH, not volume
		A car that only gets LOUDER as it speeds up reads as broken; one that changes
		NOTE reads as accelerating. So volume moves across a narrow band and pitch does
		the work. Both are damped toward their target rather than set outright, so a
		single stuttery velocity read cannot make the engine warble.
		Each car also starts its loop at a random TimePosition: twelve copies of one
		5-second sample all starting together phase-lock and read as a single engine.

	INIT ORDER  after ChassisController (it asks which car is yours, to sit your own
	            engine slightly forward in the mix). Resolved lazily, so it is not fussy.
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

local player = Players.LocalPlayer

local EngineController = {}

-- ==========================================================================
-- § 1) tunables
-- ==========================================================================
local ENGINE = {
	CARS_FOLDER = "Cars",
	LIBRARY = "GameSFX",
	TEMPLATE = "Car Driving Sound Effect",
	SOUND_NAME = "EngineLoop",

	IDLE_PITCH = 0.62,
	MAX_PITCH = 1.55,
	--[[ Below 1, so more of the pitch range is spent in the LOW speeds — which is where
		a corner actually lives. A linear ramp makes everything under half throttle
		sound identical. ]]
	PITCH_CURVE = 0.72,

	IDLE_VOLUME = 0.16,
	MAX_VOLUME = 0.42,
	OWN_SCALE = 1.35, -- your own engine sits a little forward in the mix

	BOOST_PITCH = 0.22, -- added on top while a boost pad is live
	RESPONSE = 6.5, -- damping rate for both pitch and volume

	ROLLOFF_MIN = 16,
	ROLLOFF_MAX = 260,

	--[[ nil plays the whole 5.01s sample. If the loop CLICKS, the sample has a fade or
		a transient on its ends: set this to the clean middle (e.g.
		NumberRange.new(0.35, 4.7)) and the seam goes away. Trimming a sample that was
		already seamless would ADD a click, so the honest default is to trim nothing. ]]
	LOOP_REGION = nil,

	RESOLVE_TIMEOUT = 6, -- a car can be parented before its Hull replicates
	RESOLVE_POLL = 0.1,
	MAX_ENGINES = 12, -- one per car in a full round; a ceiling on client cost
}

-- ==========================================================================
-- § 2) state
-- ==========================================================================
local ctxRef = nil
local engines = {} -- [car] = { sound, hull, spec, pitch, volume, own }
local engineCount = 0
local boundFolders = {}
local rng = Random.new()
local warned = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("EngineController: " .. message)
end

local function template(): Sound?
	local library = SoundService:FindFirstChild(ENGINE.LIBRARY)
	local sound = library and library:FindFirstChild(ENGINE.TEMPLATE)
	if not (sound and sound:IsA("Sound")) then
		warnOnce("template", "SoundService." .. ENGINE.LIBRARY .. "." .. ENGINE.TEMPLATE .. " missing — no engine audio")
		return nil
	end
	return sound
end

local function localCar(): Model?
	local ctrl = ctxRef and ctxRef.ctrl and ctxRef.ctrl.ChassisController
	local getCar = ctrl and ctrl.getCar
	if type(getCar) == "function" then
		local ok, car = pcall(getCar)
		if ok and typeof(car) == "Instance" and car:IsA("Model") and car.Parent then
			return car
		end
	end
	local folder = workspace:FindFirstChild(ENGINE.CARS_FOLDER)
	local found = folder and folder:FindFirstChild("Car_" .. tostring(player.UserId))
	return (found and found:IsA("Model")) and found or nil
end

-- ==========================================================================
-- § 3) attach / detach
-- ==========================================================================
local function detach(car: Model)
	local entry = engines[car]
	if not entry then
		return
	end
	engines[car] = nil
	engineCount = math.max(0, engineCount - 1)
	pcall(function()
		entry.sound:Destroy()
	end)
end

local function attach(car: Model, hull: BasePart)
	if engines[car] or engineCount >= ENGINE.MAX_ENGINES then
		return
	end
	local source = template()
	if not source then
		return
	end

	local sound = source:Clone()
	sound.Name = ENGINE.SOUND_NAME
	sound.Looped = true
	sound.Volume = ENGINE.IDLE_VOLUME
	sound.PlaybackSpeed = ENGINE.IDLE_PITCH
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = ENGINE.ROLLOFF_MIN
	sound.RollOffMaxDistance = ENGINE.ROLLOFF_MAX
	-- Left nil ON PURPOSE: SettingsUI's adopter files an ungrouped Sound under Workspace
	-- into the World Sounds bus. Assigning a group here would opt the engine out of the
	-- player's own volume slider.
	sound.SoundGroup = nil
	if ENGINE.LOOP_REGION then
		pcall(function()
			sound.LoopRegion = ENGINE.LOOP_REGION
		end)
	end
	sound.Parent = hull

	-- Stagger the phase so a grid of cars does not read as one giant engine.
	pcall(function()
		sound.TimePosition = rng:NextNumber(0, math.max(sound.TimeLength - 0.05, 0.05))
	end)
	sound:Play()

	engines[car] = {
		sound = sound,
		hull = hull,
		spec = ChassisSpec.resolveCar(car),
		pitch = ENGINE.IDLE_PITCH,
		volume = ENGINE.IDLE_VOLUME,
	}
	engineCount += 1
end

--[[ A car is parented before its Hull is guaranteed to have replicated, so this polls
	briefly and re-checks the car still exists after every yield. ]]
local function onCarAdded(car: Instance)
	if not car:IsA("Model") or engines[car] then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + ENGINE.RESOLVE_TIMEOUT
		while os.clock() < deadline do
			if not car.Parent then
				return
			end
			local hull = ChassisSpec.getHull(car)
			if hull and hull.Parent then
				if car.Parent and not engines[car] then
					attach(car, hull)
				end
				return
			end
			task.wait(ENGINE.RESOLVE_POLL)
		end
	end)
end

local function onCarRemoved(car: Instance)
	if car:IsA("Model") then
		detach(car)
	end
end

-- ==========================================================================
-- § 4) step
-- ==========================================================================
--[[ Heartbeat, not RenderStepped: the value being read is a physics one (the hull's
	assembly velocity), so it should be sampled on the physics beat — the same reason
	the chassis and the turrets run there. ]]
local function step(dt: number)
	if engineCount == 0 then
		return
	end
	local now = workspace:GetServerTimeNow()
	local mine = localCar()

	for car, entry in pairs(engines) do
		local hull = entry.hull
		if not car.Parent or not hull.Parent or not entry.sound.Parent then
			detach(car)
		else
			local velocity = hull.AssemblyLinearVelocity
			local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			local top = (entry.spec and entry.spec.topSpeed) or Config.CHASSIS.TOP_SPEED
			local fraction = math.clamp(speed / math.max(top, 1), 0, 1) ^ ENGINE.PITCH_CURVE

			local targetPitch = MathUtil.lerp(ENGINE.IDLE_PITCH, ENGINE.MAX_PITCH, fraction)
			if ChassisSpec.isBoosting(car, now) then
				targetPitch += ENGINE.BOOST_PITCH
			end

			local targetVolume = MathUtil.lerp(ENGINE.IDLE_VOLUME, ENGINE.MAX_VOLUME, fraction)
			if car == mine then
				targetVolume *= ENGINE.OWN_SCALE
			end

			entry.pitch = MathUtil.damp(entry.pitch, targetPitch, ENGINE.RESPONSE, dt)
			entry.volume = MathUtil.damp(entry.volume, targetVolume, ENGINE.RESPONSE, dt)
			entry.sound.PlaybackSpeed = entry.pitch
			entry.sound.Volume = entry.volume
		end
	end
end

-- ==========================================================================
-- § 5) folder watching (same idiom as FxController: it may not exist yet)
-- ==========================================================================
local function watchFolder(name: string, onAdd, onRemove)
	local function bind(folder: Instance)
		if boundFolders[folder] then
			return
		end
		boundFolders[folder] = true
		for _, child in ipairs(folder:GetChildren()) do
			onAdd(child)
		end
		folder.ChildAdded:Connect(onAdd)
		folder.ChildRemoved:Connect(onRemove)
	end

	local existing = workspace:FindFirstChild(name)
	if existing then
		bind(existing)
	end
	workspace.ChildAdded:Connect(function(child)
		if child.Name == name then
			bind(child)
		end
	end)
end

-- ==========================================================================
-- § 6) init
-- ==========================================================================
function EngineController.init(ctx)
	ctxRef = ctx
	watchFolder(ENGINE.CARS_FOLDER, onCarAdded, onCarRemoved)

	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warnOnce("step", "step errored -> " .. tostring(err))
		end
	end)
end

return EngineController
