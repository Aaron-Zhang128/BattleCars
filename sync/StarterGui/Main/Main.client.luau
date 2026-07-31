--[[ Main (UI bootstrap)
	§1) requires UIKit and hands every UI module the same ctx
	§2) inits UI modules in draw order
	§3) exposes the garage entry point (the only unprompted-free way in: a button)

	UI MODULE CONTRACT (pinned — every module in UI/ obeys this):
		local Module = {}
		function Module.init(ctx) end
		return Module

	ctx = {
		net        = { [remoteName] = remote },
		kit        = UIKit,
		root       = StarterGui.Main ScreenGui clone in PlayerGui,
		frames     = the Frames folder (modal windows register here),
		controllers() -> Controllers folder in PlayerScripts (lazy; may yield),
	}

	Frames a module creates must be parented under ctx.frames and registered with
	ctx.kit.registerFrame(name, frame) — that gives them Close-button wiring,
	pop in/out, and one-at-a-time behavior for free.

	NO unprompted popups. Every window opens from a player action or a phase change.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Net = require(core:WaitForChild("Net"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local Config = require(core:WaitForChild("Config"))

local player = Players.LocalPlayer

local ctx = {
	net = {},
	kit = UIKit,
	root = script.Parent,
	frames = script.Parent:WaitForChild("Frames"),
}

for name in pairs(Net.NAMES) do
	ctx.net[name] = Net.client(name)
end

-- Lazy: PlayerScripts may not have replicated when UI boots.
local controllersFolder = nil
function ctx.controllers()
	if controllersFolder then
		return controllersFolder
	end
	local scripts = player:WaitForChild("PlayerScripts", 20)
	controllersFolder = scripts and scripts:WaitForChild("Controllers", 20) or nil
	return controllersFolder
end

-- Draw order: HUD first (always on), then overlays that sit above it.
local ORDER = {
	-- HUD first (always on), then overlays, then the kit-art windows.
	"HudUI",
	"LuckyUI",
	"LobbyUI",
	"DeathUI",
	"ResultsUI",
	-- Kit-art windows. GarageUI is deliberately ABSENT: it and CarShopUI are the same
	-- screen on the same GarageAction remote, so loading both means one purchase runs
	-- two reply handlers -- a double card flash and a double sound. CarShopUI wears the
	-- kit art, so GarageUI is the one retired. The module is left in place for now so
	-- its four stat bars can be ported across before it is deleted.
	"CarShopUI",
	"IndexUI",
	"ShopUI",
	"DailyUI",
	"SettingsUI",
	-- Last on purpose: RailUI hides any button whose frame is not registered, so it
	-- has to run after every window above has had its init() call.
	"RailUI",
}

local uiFolder = script.Parent:WaitForChild("UI")

for _, name in ipairs(ORDER) do
	local moduleScript = uiFolder:FindFirstChild(name)
	if not moduleScript then
		warn("Main(UI): missing module " .. name)
		continue
	end

	local okRequire, module = pcall(require, moduleScript)
	if not okRequire then
		warn("Main(UI): failed to require " .. name .. " -> " .. tostring(module))
		continue
	end

	if type(module.init) == "function" then
		local okInit, err = pcall(module.init, ctx)
		if not okInit then
			warn("Main(UI): " .. name .. ".init failed -> " .. tostring(err))
		end
	end
end

--[[ Notify — the server's one-line toast channel. ScoreService fires the round payout
	down it, PickupService the name of a powerup out of a crate, GarageService a purchase,
	and ModeService the juggernaut headlines. NOTHING was listening to it: every one of
	those messages has been firing into a remote with no client end since the game was
	built. Wired here rather than in a UI module because it belongs to no window — and
	after the loop above, since UIKit.notify builds its own ScreenGui on first use. ]]
if ctx.net.Notify then
	ctx.net.Notify.OnClientEvent:Connect(function(text, mood)
		if type(text) ~= "string" or text == "" then
			return
		end
		UIKit.notify(text, type(mood) == "string" and mood or nil)
	end)
end

if Config.VERBOSE_BOOT then
	print(string.format("[CrashCars] ui up — %d modules", #ORDER))
end
