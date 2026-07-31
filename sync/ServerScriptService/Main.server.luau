--[[ Main (server bootstrap)
	Builds every remote, then inits every service in dependency order.

	SERVICE CONTRACT (pinned — every service in Services/ obeys this):
		local Service = {}
		function Service.init(ctx) end     -- ctx.net[remoteName], ctx.svc[serviceName]
		return Service

	ctx.svc is ONE shared table filled as we go. A service must resolve siblings
	LAZILY (inside functions, at call time) — never capture ctx.svc.Other at init time,
	because later services do not exist yet when earlier ones init.

	Players have NO character except on the Lobby hub, where LobbyService loads one
	and takes it away again at the round start. The car IS the avatar in a round;
	CharacterAutoLoads is off so nothing but LobbyService can spawn a humanoid, and
	CameraController drives the camera manually.

	ATTRIBUTE OWNERSHIP (exactly one writer each, do not cross these lines):
		ProfileService  Coins Gems EquippedCar OwnedCars BestCrowns TotalKills ProfileLoaded
		MonetizationService Vip DoubleCoins Magnet GoldenCar Spins CoinMultiplier
		SpawnService    Alive Lives (+ stamps car.Invuln once, at spawn)
		ScoreService    Crowns Kills
		WeaponService   PowerupSlot PowerupAmmo
		CombatService   Shielded Frozen, car.Hp, car.FrozenUntil, car.Invuln, car.StaggerUntil
		                also BORROWS hull network ownership for the stagger window and
		                hands it back; SpawnService still owns spawn-time assignment.
		MatchService    Phase PhaseEndsAt RoundId AliveCount
		ModeService     ModeId ModeName Team Juggernaut
		MapVoteService  nothing — it decides the map, ArenaService still writes MapId/MapName
		(WeaponTestService writes NOTHING — the "/test" carousel grants only by
		 calling WeaponService.givePowerup, so it cannot invent a state a crate cannot.)
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Net = require(core:WaitForChild("Net"))
local ChassisSpec = require(core.Shared:WaitForChild("ChassisSpec"))
local Config = require(core:WaitForChild("Config"))

-- The car is the avatar; no humanoid characters anywhere.
Players.CharacterAutoLoads = false

-- Cars collide with each other (that IS the game) and with the arena.
local ok = pcall(function()
	PhysicsService:RegisterCollisionGroup(ChassisSpec.COLLISION_GROUP)
end)
if ok then
	PhysicsService:CollisionGroupSetCollidable(ChassisSpec.COLLISION_GROUP, ChassisSpec.COLLISION_GROUP, true)
	PhysicsService:CollisionGroupSetCollidable(ChassisSpec.COLLISION_GROUP, "Default", true)
end

local ctx = {
	net = Net.buildAll(),
	svc = {},
}

-- Dependency order. Earlier services must not call later ones during init.
local ORDER = {
	"ProfileService",
	"MonetizationService", -- before any registrant reads a perk
	"DailyRewardService", -- grants through ProfileService, so must follow it
	-- The round's ruleset. Early: SpawnService asks it how many lives a round gives the
	-- moment a player joins, and CarFactory asks it what BODY to build on every spawn.
	"ModeService",
	"ArenaService",
	-- The lobby ballot. After ArenaService (it reads the map that is already standing to
	-- keep it OFF the ballot) and before MatchService, which drives it phase by phase.
	"MapVoteService",
	"LobbyService", -- the hub is a place cars live in, so it exists before SpawnService
	"CarFactory",
	"SpawnService",
	"PickupService",
	"LuckyBlockService",
	"WeaponService",
	"CombatService",
	"ScoreService",
	"MatchService",
	"GarageService",
	-- Last, and inert unless you ask for it: the "/test" weapon carousel. Gated on
	-- Studio or place ownership, reachable from no remote, and it grants only through
	-- WeaponService. Delete this line to remove the tool outright.
	"WeaponTestService",
}

local servicesFolder = ServerScriptService:WaitForChild("Services")

for _, name in ipairs(ORDER) do
	local moduleScript = servicesFolder:FindFirstChild(name)
	if not moduleScript then
		warn("Main: missing service " .. name)
		continue
	end

	local okRequire, service = pcall(require, moduleScript)
	if not okRequire then
		warn("Main: failed to require " .. name .. " -> " .. tostring(service))
		continue
	end

	ctx.svc[name] = service

	if type(service.init) == "function" then
		local okInit, err = pcall(service.init, ctx)
		if not okInit then
			warn("Main: " .. name .. ".init failed -> " .. tostring(err))
		end
	end
end

if Config.VERBOSE_BOOT then
	print(string.format("[CrashCars] server up — %d services", #ORDER))
end

-- Studio-only: single-player rounds so you can test alone.
-- Gated at the point of use; MatchService reads Config.TEST for the rest.
if RunService:IsStudio() then
	if Config.VERBOSE_BOOT then
		print("[CrashCars] STUDIO — Config.TEST overrides active")
	end
end
