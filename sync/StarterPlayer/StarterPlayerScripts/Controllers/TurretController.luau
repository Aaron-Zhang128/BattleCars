--[[ TurretController — puts the weapon you are holding ON the car, and makes it move.

	PURPOSE
		Every player's powerup slot is already replicated (Player.PowerupSlot). This
		controller turns that one attribute into a physical weapon bolted to that
		player's roof, on EVERY client, and animates it: the turret swivels to the
		driver's aim, the barrel recoils and rolls when it fires, the nozzle judders.

	WHY IT IS A CONTROLLER AND NOT A SERVICE — the whole rig is client-side art
		Nothing here is replicated and nothing here is authoritative. The server never
		builds, welds or moves a weapon model: it only says WHO holds WHAT (an
		attribute) and WHEN a shot happened (WeaponFx). Each client draws its own copy.
		That buys three things a server-built, welded rig cannot have:
		  * your own turret tracks your camera with ZERO latency, because the aim
		    never leaves this machine;
		  * an animated part can never join the car's physics assembly, block a shot,
		    or fool the chassis ground probe;
		  * a turret costs the server nothing and the network nothing.
		The cost is that a remote turret's idle aim is inferred (see AIM below), which
		is invisible in practice because the server clamps aim into a narrow cone anyway.

	AIM
		LOCAL car   CameraController.getAimDirection() every frame — exactly what the
		            shot will use, so the barrel is never pointing somewhere you did
		            not shoot.
		REMOTE car  ChassisSpec.ATTR.AIM_DIR — the flat aim WeaponService publishes on
		            every accepted shot. The hold weapons fire 11-12x a second, so a
		            remote turret tracks properly through sustained fire and then HOLDS
		            the angle it last fired at. Before that car's first shot the
		            attribute is absent and the turret rests along the car's heading.

	FIRING
		LOCAL   WeaponController.noteFired -> this file, on the PRESS frame. Same
		        prediction deal FxController's flash has: if the server rejects the
		        shot you saw one free recoil and nothing else changed.
		REMOTE  WeaponFx (S->C) carries payload.userId, so a shot animates the car that
		        actually fired instead of the nearest one. We ignore our own userId
		        there — we already animated it locally and must not kick twice.

	DATA FLOW
		Workspace.Cars ChildAdded/Removed        -> mount / unmount            (§4)
		Player:GetAttributeChangedSignal(Slot)   -> swap the model              (§4)
		WeaponFx (S->C)                          -> remote fire animation       (§5)
		Heartbeat                                -> aim + WeaponRig.step        (§6)

	PUBLIC   getMuzzleWorld()  world point the LOCAL car's barrel fires from, or nil
	         getMuzzleWorldFor(userId, powerupId)  the same for ANY car
	         noteFired(id,dir) local prediction seam, called by WeaponController
	         getRig(car)       the live rig for a car, or nil
	ATTRIBUTES reads Player.PowerupSlot and Car.OwnerUserId. Writes NOTHING.
	INIT ORDER after ChassisController and CameraController (it reads both, lazily).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local WeaponRig = require(sharedFolder:WaitForChild("WeaponRig"))

local ATTR = Config.ATTR
local CAR = ChassisSpec.ATTR
local RIG = Config.WEAPON_RIG

local player = Players.LocalPlayer

local TurretController = {}

-- ==========================================================================
-- § 1) tunables
-- ==========================================================================
local CARS_FOLDER = "Cars" -- owned by SpawnService

-- A car can be parented before its Hull, its WeaponMount or its owner attribute have
-- replicated, so mounting polls briefly instead of giving up on the first frame.
local RESOLVE_TIMEOUT = 6
local RESOLVE_POLL = 0.1

-- ==========================================================================
-- § 2) state
-- ==========================================================================
local ctxRef = nil
local rigs = {} -- [car] = rig (WeaponRig table)
local bound = {} -- [car] = { conns = {}, owner = number?, pending = boolean }
local boundFolders = {}
local rigCount = 0
local warned = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("TurretController: " .. message)
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
-- § 3) car / owner helpers
-- ==========================================================================
local function carsFolder(): Instance?
	return workspace:FindFirstChild(CARS_FOLDER)
end

local function localCar(): Model?
	local car = safeCall("ChassisController", "getCar", nil)
	if typeof(car) == "Instance" and car:IsA("Model") and car.Parent then
		return car
	end
	local folder = carsFolder()
	local found = folder and folder:FindFirstChild("Car_" .. tostring(player.UserId))
	return (found and found:IsA("Model")) and found or nil
end

-- CarFactory writes OwnerUserId; the name is the fallback for a car mid-replication.
local function ownerOf(car: Model): number?
	local owner = car:GetAttribute(CAR.OWNER)
	if type(owner) == "number" then
		return owner
	end
	return tonumber(string.match(car.Name, "^Car_(%d+)$"))
end

local function slotOf(userId: number?): string?
	if type(userId) ~= "number" then
		return nil
	end
	local owner = Players:GetPlayerByUserId(userId)
	if not owner then
		return nil
	end
	local id = owner:GetAttribute(ATTR.POWERUP)
	return type(id) == "string" and id ~= "" and id or nil
end

-- ==========================================================================
-- § 4) mount / unmount
-- ==========================================================================
local function dropRig(car: Model)
	local rig = rigs[car]
	if not rig then
		return
	end
	rigs[car] = nil
	rigCount = math.max(0, rigCount - 1)
	WeaponRig.destroy(rig)
end

--[[ Rebuilds the car's weapon to match its driver's slot. Cheap and idempotent: it
	early-outs when the right model is already mounted, so it is safe to call from an
	attribute signal that also fires on ammo-only changes. ]]
local function refresh(car: Model)
	if not car.Parent then
		dropRig(car)
		return
	end

	local entry = bound[car]
	local wanted = slotOf(entry and entry.owner)
	if not WeaponRig.isModelled(wanted) then
		dropRig(car) -- empty slot, or a powerup with no model (SHIELD)
		return
	end

	local current = rigs[car]
	if current and current.id == wanted and current.folder and current.folder.Parent then
		return -- already wearing it
	end

	dropRig(car)
	if rigCount >= RIG.MAX_RIGS then
		return -- hard ceiling; a full round is under this, a runaway spawn is not
	end

	local rig = WeaponRig.build(car, wanted)
	if rig then
		rigs[car] = rig
		rigCount += 1
	end
end

local function unbind(car: Model)
	local entry = bound[car]
	if entry then
		for _, conn in ipairs(entry.conns) do
			conn:Disconnect()
		end
		bound[car] = nil
	end
	dropRig(car)
end

local function onCarAdded(car: Instance)
	if not car:IsA("Model") or bound[car] then
		return
	end
	bound[car] = { conns = {}, owner = nil }

	task.spawn(function()
		--[[ Poll for the pieces a rig needs. Every one of these can arrive a frame or
			several after the Model itself, and re-checking car.Parent after each yield
			is what keeps a car destroyed mid-wait from leaving a dangling binding. ]]
		local deadline = os.clock() + RESOLVE_TIMEOUT
		local owner, driver
		while os.clock() < deadline do
			if not car.Parent or not bound[car] then
				return
			end
			owner = ownerOf(car)
			driver = type(owner) == "number" and Players:GetPlayerByUserId(owner) or nil
			local hull = ChassisSpec.getHull(car)
			if driver and hull and hull:FindFirstChild(ChassisSpec.MOUNT_ATT) then
				break
			end
			driver = nil
			task.wait(RESOLVE_POLL)
		end

		local entry = bound[car]
		if not car.Parent or not entry or not driver then
			return
		end
		entry.owner = owner

		-- The slot attribute IS the weapon: one signal drives mount, swap and unmount.
		table.insert(entry.conns, driver:GetAttributeChangedSignal(ATTR.POWERUP):Connect(function()
			if rigs[car] or car.Parent then
				refresh(car)
			end
		end))

		refresh(car)
	end)
end

local function onCarRemoved(car: Instance)
	if car:IsA("Model") then
		unbind(car)
	end
end

-- ==========================================================================
-- § 5) fire triggers
-- ==========================================================================
local function rigForUser(userId: number?)
	if type(userId) ~= "number" then
		return nil, nil
	end
	for car, rig in pairs(rigs) do
		local entry = bound[car]
		if entry and entry.owner == userId then
			return rig, car
		end
	end
	return nil, nil
end

--[[ Local prediction seam. Called by WeaponController on the frame you press fire,
	for the same reason FxController's muzzle flash is: a recoil that waits for the
	round trip reads as input lag, and a recoil on a shot the server later refuses
	costs nothing but one wasted animation. ]]
function TurretController.noteFired(powerupId: any, dir: any)
	local car = localCar()
	local rig = car and rigs[car]
	if not rig or rig.id ~= powerupId then
		return
	end
	if typeof(dir) == "Vector3" and dir.Magnitude > 1e-3 then
		WeaponRig.setAim(rig, dir)
	end
	WeaponRig.fire(rig)
end

local function onWeaponFx(kind: any, payload: any)
	if type(kind) ~= "string" or type(payload) ~= "table" then
		return
	end
	if not WeaponRig.isModelled(kind) then
		return -- IMPACT / RAM / SHIELD and friends never move a turret
	end
	local userId = payload.userId
	if type(userId) ~= "number" or userId == player.UserId then
		return -- ours was already animated locally; kicking again would double it
	end

	local rig = rigForUser(userId)
	if not rig or rig.id ~= kind then
		return
	end
	--[[ Start the swing on the same frame as the flash. The AimDir attribute sustains
		it afterwards; this only avoids waiting a replication hop to begin moving. ]]
	if typeof(payload.dir) == "Vector3" and payload.dir.Magnitude > 1e-3 then
		WeaponRig.setAim(rig, payload.dir.Unit)
	end
	WeaponRig.fire(rig)
end

-- ==========================================================================
-- § 6) step
-- ==========================================================================
function TurretController.getRig(car: Model?)
	return car and rigs[car] or nil
end

--[[ The live barrel tip of whichever car `userId` is driving, or nil if they have no
	rig — or if the rig is not the weapon being asked about, which is what keeps a
	stale fx from a swapped slot off the wrong gun.

	The fx path does NOT go through here — WeaponService gets the barrel from the
	client that fired and puts it in the WeaponFx payload, which is more truthful than
	any other client re-deriving it from a rig whose remote pose lags the shot. This
	stays as the accessor for anything that wants another car's live barrel directly,
	such as attaching an effect to someone else's turret. ]]
function TurretController.getMuzzleWorldFor(userId: number?, powerupId: string?): Vector3?
	local rig = rigForUser(userId)
	if not rig then
		return nil
	end
	if powerupId ~= nil and rig.id ~= powerupId then
		return nil
	end
	return WeaponRig.muzzleWorld(rig)
end

function TurretController.getMuzzleWorld(): Vector3?
	local car = localCar()
	local rig = car and rigs[car]
	return rig and WeaponRig.muzzleWorld(rig) or nil
end

local function aimFor(car: Model, rig, now: number): Vector3?
	if car == localCar() then
		local aim = safeCall("CameraController", "getAimDirection", nil)
		if typeof(aim) == "Vector3" and aim.Magnitude > 1e-3 then
			return aim
		end
		local look = safeCall("ChassisController", "getLook", nil)
		if typeof(look) == "Vector3" and look.Magnitude > 1e-3 then
			return look
		end
	else
		--[[ Somebody else's car. Their camera never leaves their machine, so the turret
			follows the flat aim WeaponService publishes on every accepted shot. It
			persists between shots on purpose — a gun holding the angle it last fired at
			reads far better than one snapping back to centre — and it is simply absent
			until that car's first shot, when centred is correct anyway. ]]
		local published = car:GetAttribute(CAR.AIM_DIR)
		if typeof(published) == "Vector3" and published.Magnitude > 1e-3 then
			return published
		end
	end
	-- Fallback for every case above: point where the car is going.
	local hull = rig.hull
	return (hull and hull.Parent) and hull.CFrame.LookVector or nil
end

--[[ Heartbeat, NOT RenderStepped — see the WeaponRig.step header. Assigning nil to
	the key `pairs` is currently on is defined behaviour in Lua, so dropping a dead
	rig mid-loop is safe and avoids a second pass. ]]
local function step(dt: number)
	if rigCount == 0 then
		return
	end
	local now = os.clock()
	for car, rig in pairs(rigs) do
		if not car.Parent then
			unbind(car)
		else
			WeaponRig.setAim(rig, aimFor(car, rig, now))
			if not WeaponRig.step(rig, dt, now) then
				dropRig(car)
			end
		end
	end
end

-- ==========================================================================
-- § 7) folder watching (same idiom as FxController: the folder may not exist yet)
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
-- § 8) init
-- ==========================================================================
function TurretController.init(ctx)
	ctxRef = ctx

	local remote = ctx.net and ctx.net.WeaponFx
	if remote then
		remote.OnClientEvent:Connect(onWeaponFx)
	else
		warnOnce("net.WeaponFx", "WeaponFx remote missing — remote turrets will not animate")
	end

	watchFolder(CARS_FOLDER, onCarAdded, onCarRemoved)

	-- A driver who leaves takes their turret with them even if the car lingers a frame.
	Players.PlayerRemoving:Connect(function(leaving)
		for car, entry in pairs(bound) do
			if entry.owner == leaving.UserId then
				unbind(car)
			end
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warnOnce("step", "step errored -> " .. tostring(err))
		end
	end)
end

return TurretController
