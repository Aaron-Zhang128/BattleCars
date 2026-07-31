--[[ WeaponTestService — "/test", the dev commands: the weapon carousel and the
	endless round.

	A DEV TOOL. Cycles you through every modelled weapon on a fixed timer and keeps its
	ammo topped up, so you can sit in one round and watch each turret mount, swivel,
	recoil and fire without hunting crates or lucky blocks for an hour — and holds that
	round open indefinitely so the arena never disappears mid-experiment.

	WHY IT IS ON THE SERVER
		Only WeaponService may write PowerupSlot / PowerupAmmo (see Main's attribute
		ownership table), so a client-side test command could not grant itself anything.
		This service never writes those attributes itself either — it calls
		WeaponService.givePowerup, so the carousel goes through exactly the same door a
		crate does and can never produce a state a real grant could not. The endless
		round is the same arrangement: MatchService owns the phase machine and this only
		asks it. The command lives here because this file owns the word "/test", and two
		services cannot both answer one chat message.

	COMMANDS (chat)
		/test           start or stop the weapon carousel
		/test 3         start it with a 3-second window per weapon
		/test off       stop it
		/test game      START A ROUND NOW AND NEVER END IT (MatchService.setEndless):
		                the lobby stops waiting for players, the match clock stops
		                running out, and nobody is ever out of lives.
		/test game off  back to the normal Lobby -> Match -> Results rotation, which
		                means ending the round that is currently running
		Aliases: /testweapons, /weapons; and round / match / endless / start for "game".

		The two halves are independent — the carousel arms weapons, "/test game" only
		holds the phase open. Type both to sit in one endless round cycling every gun.

	WHO GETS IT
		Studio, or the place owner in a live server — the same rule /weaponview uses.
		For anyone else the message is ignored entirely. Nothing here is reachable from
		a remote, so a scripted client cannot invoke it at all.

	IF CHAT DOES NOT REACH THE SERVER (some TextChatService setups swallow
	Player.Chatted), set Config.TEST.WEAPON_CYCLE_AUTOSTART = true and the carousel
	starts by itself for every player in Studio. That flag is the fallback, not the
	normal path, and like every TEST key it is gated on RunService:IsStudio() here.

	CYCLE ORDER   PowerupDefs.list() filtered to the ids that have a Config.WEAPON_RIGS
	              model — the four weapons you can actually SEE on the roof. SHIELD is
	              skipped: it is a bubble, and there is no turret to look at.

	AMMO          topped back up whenever it falls to a quarter, so a held trigger never
	              empties the slot mid-window. A 1-ammo weapon (cannon) therefore reloads
	              a fraction of a second after each shot, which is the point.

	REQUIRES      MatchState (only runs during Match — outside it WeaponService clears
	              every slot on the phase change anyway).
	INIT ORDER    last. Resolves WeaponService LAZILY, so it does not care.
	SHIPPING      harmless if left in: without IsStudio or place ownership it does
	              nothing at all. Delete the ORDER entry in Main to remove it outright.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")

local Config = require(core:WaitForChild("Config"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))

local ATTR = Config.ATTR

local WeaponTestService = {}

-- ==========================================================================
-- § 1) tunables
-- ==========================================================================
local COMMANDS = { ["/test"] = true, ["/testweapons"] = true, ["/weapons"] = true }
local STOP_WORDS = { off = true, stop = true, ["0"] = true }
-- The endless-round subcommand ("/test game"). It lives in this file because this
-- file owns the word "/test": a second service listening for the same head would
-- answer every carousel message too.
local ROUND_WORDS = { game = true, round = true, match = true, endless = true, start = true }

local MIN_SECONDS = 1
local MAX_SECONDS = 120
local REFILL_FRACTION = 0.25 -- top the slot up once it drops to this share of full

-- ==========================================================================
-- § 2) state
-- ==========================================================================
local ctx = nil
local cycles = {} -- [player] = { index, nextAt, seconds }
local connections = {}
local warnedMissing = false

local function svcCall(name: string, fnName: string, ...)
	local service = ctx and ctx.svc and ctx.svc[name]
	local fn = service and service[fnName]
	if type(fn) ~= "function" then
		if not warnedMissing then
			warnedMissing = true
			warn("WeaponTestService: " .. name .. "." .. fnName .. " unavailable — /test can grant nothing")
		end
		return nil
	end
	return fn(...)
end

local function notify(player: Player, text: string, mood: string)
	local remote = ctx and ctx.net and ctx.net.Notify
	if remote then
		remote:FireClient(player, text, mood)
	end
end

-- ==========================================================================
-- § 3) the cycle list
-- ==========================================================================
--[[ Rebuilt per start rather than cached: Config is the single source of truth and a
	weapon added to WEAPON_RIGS mid-session should just appear in the carousel. ]]
local function modelledWeapons()
	local list = {}
	for _, def in ipairs(PowerupDefs.list()) do
		if Config.WEAPON_RIGS and Config.WEAPON_RIGS[def.id] then
			table.insert(list, def)
		end
	end
	return list
end

local function allowed(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

-- ==========================================================================
-- § 4) start / stop
-- ==========================================================================
function WeaponTestService.stop(player: Player, quiet: boolean?)
	if not cycles[player] then
		return
	end
	cycles[player] = nil
	svcCall("WeaponService", "clearPowerup", player)
	if not quiet then
		notify(player, "Weapon test off", "red")
		print("[/test] off for " .. player.Name)
	end
end

function WeaponTestService.start(player: Player, seconds: number?)
	local list = modelledWeapons()
	if #list == 0 then
		notify(player, "No modelled weapons", "red")
		warn("WeaponTestService: no powerup in PowerupDefs.ORDER has a Config.WEAPON_RIGS entry")
		return
	end

	local window = math.clamp(tonumber(seconds) or Config.TEST.WEAPON_CYCLE_SECONDS or 10, MIN_SECONDS, MAX_SECONDS)
	-- index 0 + nextAt 0 means the very first step() swaps immediately: no dead window
	-- between typing the command and holding a gun.
	cycles[player] = { index = 0, nextAt = 0, seconds = window }

	local names = {}
	for _, def in ipairs(list) do
		table.insert(names, def.name)
	end
	notify(player, string.format("Weapon test: %ds each", window), "gold")
	print(string.format("[/test] on for %s — %ds each: %s", player.Name, window, table.concat(names, ", ")))
	if not MatchState.isMatch() then
		notify(player, "Waiting for the round", "gold")
	end
end

--[[ "/test game" — an endless round, so a dev can sit in the arena and iterate.
	Purely a request: MatchService decides. A missing or broken MatchService says so
	out loud rather than leaving you typing into a void. ]]
function WeaponTestService.setRound(player: Player, on: boolean)
	local state = svcCall("MatchService", "setEndless", on)
	if state == nil then
		notify(player, "Round control unavailable", "red")
		return
	end
	if state then
		notify(player, "Endless round — starting now", "gold")
		print("[/test game] endless round ON (" .. player.Name .. ")")
	else
		notify(player, "Endless round off", "red")
		print("[/test game] endless round OFF, back to the normal rotation (" .. player.Name .. ")")
	end
end

function WeaponTestService.toggle(player: Player, seconds: number?)
	if cycles[player] then
		WeaponTestService.stop(player)
	else
		WeaponTestService.start(player, seconds)
	end
end

function WeaponTestService.isRunning(player: Player): boolean
	return cycles[player] ~= nil
end

-- ==========================================================================
-- § 5) step
-- ==========================================================================
--[[ One loop for everyone. Nothing here yields, and every write goes through
	WeaponService, so a carousel can never leave a slot in a state a crate could not. ]]
local function step()
	if next(cycles) == nil then
		return
	end
	local now = os.clock()
	local list = modelledWeapons()
	if #list == 0 then
		return
	end

	for player, cycle in pairs(cycles) do
		if player.Parent == nil then
			cycles[player] = nil
			continue
		end
		-- Outside Match there is no car to bolt anything to, and WeaponService wipes
		-- every slot on the phase change. Idle rather than fight it.
		if not MatchState.isMatch() then
			continue
		end

		if now >= cycle.nextAt then
			cycle.index = (cycle.index % #list) + 1
			cycle.nextAt = now + cycle.seconds
			local def = list[cycle.index]
			svcCall("WeaponService", "givePowerup", player, def.id)
			notify(player, def.name, "gold")
		else
			-- Keep it loaded so a held trigger never empties the slot mid-window.
			local def = list[cycle.index]
			if def then
				local held = player:GetAttribute(ATTR.POWERUP)
				local ammo = player:GetAttribute(ATTR.POWERUP_AMMO)
				local floor = math.max(1, math.floor((def.ammo or 1) * REFILL_FRACTION))
				if held ~= def.id or type(ammo) ~= "number" or ammo <= floor then
					svcCall("WeaponService", "givePowerup", player, def.id)
				end
			end
		end
	end
end

-- ==========================================================================
-- § 6) the chat command
-- ==========================================================================
local function onChatted(player: Player, message: any)
	if type(message) ~= "string" or not allowed(player) then
		return
	end
	local text = string.lower(string.match(message, "^%s*(.-)%s*$") or message)
	local head = string.match(text, "^(%S+)")
	if not head or not COMMANDS[head] then
		return
	end

	local arg, arg2 = string.match(text, "^%S+%s+(%S+)%s+(%S+)")
	arg = arg or string.match(text, "^%S+%s+(%S+)")

	-- "/test game" / "/test game off" — the round, not the carousel.
	if arg and ROUND_WORDS[arg] then
		WeaponTestService.setRound(player, not (arg2 ~= nil and STOP_WORDS[arg2] == true))
		return
	end

	if arg and STOP_WORDS[arg] then
		WeaponTestService.stop(player)
		return
	end
	WeaponTestService.toggle(player, arg and tonumber(arg) or nil)
end

-- ==========================================================================
-- § 7) init
-- ==========================================================================
function WeaponTestService.init(context)
	ctx = context

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	local function bind(player: Player)
		table.insert(connections, player.Chatted:Connect(function(message)
			onChatted(player, message)
		end))
		--[[ Fallback path, Studio only and OFF by default: some TextChatService setups
			never deliver Player.Chatted to the server, which would leave /test dead with
			no way to tell. Flip Config.TEST.WEAPON_CYCLE_AUTOSTART to get the carousel
			without typing anything. ]]
		if RunService:IsStudio() and Config.TEST.WEAPON_CYCLE_AUTOSTART then
			WeaponTestService.start(player)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		bind(player)
	end
	table.insert(connections, Players.PlayerAdded:Connect(bind))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		cycles[player] = nil
	end))

	-- A new round starts everyone on the first weapon again rather than mid-list.
	table.insert(connections, MatchState.onPhaseChanged(function(phase: string)
		if phase == MatchState.PHASES.MATCH then
			for _, cycle in pairs(cycles) do
				cycle.index = 0
				cycle.nextAt = 0
			end
		end
	end))

	table.insert(connections, RunService.Heartbeat:Connect(step))

	--[[ The same fallback the carousel's autostart is, for the same reason: some
		TextChatService setups never deliver Player.Chatted to the server, which would
		leave "/test game" silently dead with no way to tell. Studio only. This service
		is LAST in Main's ORDER, so MatchService is already in ctx.svc. ]]
	if RunService:IsStudio() and Config.TEST.ENDLESS_ROUND then
		svcCall("MatchService", "setEndless", true)
		print("[/test game] endless round ON at boot (Config.TEST.ENDLESS_ROUND)")
	end
end

return WeaponTestService
