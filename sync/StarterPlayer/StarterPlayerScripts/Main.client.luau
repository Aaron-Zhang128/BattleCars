--[[ Main (client bootstrap)
	Inits every controller in dependency order.

	CONTROLLER CONTRACT (pinned — every module in Controllers/ obeys this):
		local Controller = {}
		function Controller.init(ctx) end   -- ctx.net[remoteName], ctx.ctrl[controllerName]
		return Controller

	ctx.ctrl is ONE shared table filled as we go. Resolve siblings LAZILY inside
	functions, never at init time.

	Controllers own the DRIVING experience. UI lives in StarterGui.Main and may
	require these modules read-only through Players.LocalPlayer.PlayerScripts.Controllers
	(same client VM, so require returns this same instance).

	PUBLIC SURFACE each controller must expose (UI and siblings code against it):
		InputController   getThrottle() getSteer() isDrifting() isFireHeld() onFire(fn) setEnabled(b)
		                  SIGNS: getThrottle() +1 = forward. getSteer() +1 = RIGHT
		                  (D / Right arrow / stick right), matching VehicleSeat.Steer.
		ChassisController getCar() getSpeed() getSpeedFraction() isGrounded() isDrifting() getLook()
		CameraController  shake(intensity, seconds) getAimDirection() setTarget(model)
		WeaponController  (no public surface; owns FireWeapon + local prediction)
		FxController      shake passthrough not required; owns WeaponFx rendering
		TurretController  getMuzzleWorld() noteFired(powerupId, dir) — the car-mounted
		                  weapon models and their firing animation. Cosmetic and LOCAL.
		WeaponViewController  toggle() isShown() — the /weaponview mount overlay. Dev only
		                  (Studio or place owner), local, and touches no sibling.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Net = require(core:WaitForChild("Net"))
local Config = require(core:WaitForChild("Config"))

local ctx = {
	net = {},
	ctrl = {},
}

for name in pairs(Net.NAMES) do
	ctx.net[name] = Net.client(name)
end

-- Input before Chassis (chassis reads it every frame), Camera before fx that shake it.
local ORDER = {
	"InputController",
	"ChassisController",
	"CameraController",
	"WeaponController",
	"FxController",
	-- After ChassisController/CameraController (it reads both) and after FxController,
	-- which owns the muzzle flashes it fires alongside.
	"TurretController",
	-- The engine note under every car. Cosmetic, local, and lazily resolved, so it is
	-- last among the drivers of feel and depends on nothing that follows.
	"EngineController",
	-- Last, and deliberately inert: an authoring overlay with no gameplay effect.
	"WeaponViewController",
}

local controllersFolder = script.Parent:WaitForChild("Controllers")

for _, name in ipairs(ORDER) do
	local moduleScript = controllersFolder:FindFirstChild(name)
	if not moduleScript then
		warn("Main: missing controller " .. name)
		continue
	end

	local okRequire, controller = pcall(require, moduleScript)
	if not okRequire then
		warn("Main: failed to require " .. name .. " -> " .. tostring(controller))
		continue
	end

	ctx.ctrl[name] = controller

	if type(controller.init) == "function" then
		local okInit, err = pcall(controller.init, ctx)
		if not okInit then
			warn("Main: " .. name .. ".init failed -> " .. tostring(err))
		end
	end
end

if Config.VERBOSE_BOOT then
	print(string.format("[CrashCars] client up — %d controllers", #ORDER))
end
