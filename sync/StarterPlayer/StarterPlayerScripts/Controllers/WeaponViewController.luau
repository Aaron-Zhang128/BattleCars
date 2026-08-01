--[[ WeaponViewController
	The /weaponview authoring tool. Draws Hull.WeaponMount — the one pinned point anything
	bolts onto a car — on every car in the world, and prints the mount offset for ALL ten
	cars whether or not a single one is spawned.

	ENTIRELY LOCAL. No remote, no server state, no instance the server can see. Every
	marker is created on this client and parented to the car it decorates, so it dies with
	that car, nobody else sees your debug view, and toggling it cannot desync anything.
	That is also why the markers are Adornments rather than parts: an Adornment follows its
	Adornee for free, so a car at 200 studs/sec keeps a perfectly glued marker with zero
	per-frame work and nothing to clean up if the car despawns mid-view.

	WHO GETS IT   Studio, or the place owner in a live server. For anyone else the command
	              is never registered, so it does not autocomplete and does nothing.

	TRIGGERING — two paths, on purpose:
		1. a TextChatCommand under TextChatService.TextChatCommands. The documented route,
		   and it SWALLOWS the message, so "/weaponview" never shows up in chat.
		2. a MessageReceived fallback. It can only ever see the text if path 1 failed to
		   register — a matched command is never delivered to a channel — so the two can
		   never both fire for one message and the toggle can never run twice.

	READS   ChassisSpec.MOUNT_ATT / .mountOffset (the exact math CarFactory builds with, so
	        the printed table and the live markers cannot drift apart), the CrashCar tag,
	        Config.CARS and Assets.CarModels.
	PUBLIC  WeaponViewController.toggle() / .isShown() — the command is just a caller.
	INIT    order-independent; it touches no sibling controller.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(core:WaitForChild("Shared"):WaitForChild("ChassisSpec"))

local player = Players.LocalPlayer

local WeaponViewController = {}

-- ==========================================================================
-- § 1) tunables
-- ==========================================================================
local COMMAND = "/weaponview"
local ALIAS = "/wv"

local MARK = {
	DOT_RADIUS = 0.42,
	DOT_COLOR = Color3.fromRGB(255, 214, 64), -- the mount point itself
	FACING_COLOR = Color3.fromRGB(90, 220, 255), -- which way a weapon bolted here would aim
	FACING_LENGTH = 3.2,
	FACING_THICKNESS = 0.16,
	TIP_SIZE = 0.44,
	STALK_COLOR = Color3.fromRGB(255, 255, 255), -- hull centre -> mount, so the offset reads
	STALK_THICKNESS = 0.09,
	STALK_TRANSPARENCY = 0.45,
	HULL_COLOR = Color3.fromRGB(120, 255, 140), -- the collider, for context while placing
	HULL_TRANSPARENCY = 0.88,
	Z_INDEX = 6,
	LABEL_W = 210,
	LABEL_H = 40,
	LABEL_LIFT = 1.15,
	RESOLVE_TIMEOUT = 6, -- a car can be tagged before its Hull has finished replicating
}

-- The car drives along -Z, which is exactly an Attachment's own LookVector.
local FORWARD = Vector3.new(0, 0, -1)

-- ==========================================================================
-- § 2) state
-- ==========================================================================
local shown = false
local marks = {} -- [car] = { Instance }
local conns = {}

-- ==========================================================================
-- § 3) markers
-- ==========================================================================
local function adorn(className: string, hull: BasePart, cf: CFrame, color: Color3, onTop: boolean)
	local a = Instance.new(className)
	a.Name = "WeaponViewMark"
	a.Adornee = hull
	a.CFrame = cf
	a.Color3 = color
	a.AlwaysOnTop = onTop
	a.ZIndex = MARK.Z_INDEX
	a.Parent = hull
	return a
end

local function carLabel(car: Model): string
	local id = car:GetAttribute(ChassisSpec.ATTR.CAR_ID)
	local def = id and Config.CARS_BY_ID and Config.CARS_BY_ID[id]
	return def and def.name or tostring(id or car.Name)
end

local function decorate(car: Model)
	if marks[car] then
		return
	end
	local hull = car:FindFirstChild(ChassisSpec.HULL)
	if not (hull and hull:IsA("BasePart")) then
		return
	end
	local mount = hull:FindFirstChild(ChassisSpec.MOUNT_ATT)
	if not (mount and mount:IsA("Attachment")) then
		warn(string.format("[weaponview] %s has no Hull.%s — it was built before the mount existed",
			car.Name, ChassisSpec.MOUNT_ATT))
		return
	end

	local at = mount.Position
	local made = {}

	-- the mount point
	local dot = adorn("SphereHandleAdornment", hull, CFrame.new(at), MARK.DOT_COLOR, true)
	dot.Radius = MARK.DOT_RADIUS
	table.insert(made, dot)

	-- where a weapon bolted here would point
	local bar = adorn("BoxHandleAdornment", hull,
		CFrame.new(at + FORWARD * (MARK.FACING_LENGTH * 0.5)), MARK.FACING_COLOR, true)
	bar.Size = Vector3.new(MARK.FACING_THICKNESS, MARK.FACING_THICKNESS, MARK.FACING_LENGTH)
	table.insert(made, bar)

	local tip = adorn("BoxHandleAdornment", hull,
		CFrame.new(at + FORWARD * MARK.FACING_LENGTH), MARK.FACING_COLOR, true)
	tip.Size = Vector3.new(MARK.TIP_SIZE, MARK.TIP_SIZE, MARK.TIP_SIZE)
	table.insert(made, tip)

	-- hull centre -> mount, so the offset you are about to hard-code is visible
	local stalk = adorn("BoxHandleAdornment", hull, CFrame.new(0, at.Y * 0.5, 0), MARK.STALK_COLOR, false)
	stalk.Size = Vector3.new(MARK.STALK_THICKNESS, math.max(at.Y, 0.01), MARK.STALK_THICKNESS)
	stalk.Transparency = MARK.STALK_TRANSPARENCY
	table.insert(made, stalk)

	-- the collider, which is SHORTER than the bodywork — the whole reason the mount is not
	-- measured off the hull. Depth-tested on purpose so it reads as a box around the car.
	local box = adorn("BoxHandleAdornment", hull, CFrame.new(), MARK.HULL_COLOR, false)
	box.Size = hull.Size
	box.Transparency = MARK.HULL_TRANSPARENCY
	table.insert(made, box)

	-- Adornee = the Attachment, so the label tracks the mount exactly, roll included.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "WeaponViewLabel"
	billboard.Adornee = mount
	billboard.Size = UDim2.fromOffset(MARK.LABEL_W, MARK.LABEL_H)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, MARK.LABEL_LIFT, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = math.huge
	billboard.Parent = mount

	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextColor3 = Color3.fromRGB(255, 255, 255)
	text.Text = string.format("%s  •  y %.2f", carLabel(car), at.Y)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 12, 16)
	stroke.Parent = text
	text.Parent = billboard
	table.insert(made, billboard)

	marks[car] = made
end

local function undecorate(car: Model)
	local made = marks[car]
	if not made then
		return
	end
	marks[car] = nil
	for _, inst in ipairs(made) do
		pcall(function()
			inst:Destroy()
		end)
	end
end

-- ==========================================================================
-- § 4) the printed table — every car, spawned or not
-- ==========================================================================
--[[ The visual half only shows cars that happen to exist. This is the half you actually
	author against: it measures the SOURCE models straight out of ReplicatedStorage through
	ChassisSpec.mountOffset, so it lists all ten mounts from the lobby, before a round, with
	nothing spawned. ]]
local function printTable()
	local assets = core:FindFirstChild("Assets")
	local models = assets and assets:FindFirstChild("CarModels")
	if not models then
		warn("[weaponview] Assets.CarModels missing — cannot list mount offsets")
		return
	end
	local lines = {
		string.format("[weaponview] Hull.%s — offset from the hull centre, in hull space (clearance %.2f)",
			ChassisSpec.MOUNT_ATT, ChassisSpec.MOUNT_CLEARANCE),
	}
	for _, carDef in ipairs(Config.CARS) do
		local model = carDef.model and models:FindFirstChild(carDef.model)
		if model then
			local offset = ChassisSpec.mountOffset(model)
			-- Z is non-zero on a car whose mount had to SLIDE to find a roof to stand on.
			table.insert(lines, string.format("   %-12s %-11s  mount = (%.2f, %.2f, %.2f)%s",
				carDef.id, carDef.model, offset.X, offset.Y, offset.Z,
				(math.abs(offset.X) > 0.01 or math.abs(offset.Z) > 0.01) and "   <- slid off centre" or ""))
		else
			table.insert(lines, string.format("   %-12s model '%s' MISSING", carDef.id, tostring(carDef.model)))
		end
	end
	print(table.concat(lines, "\n"))
end

-- ==========================================================================
-- § 5) toggle
-- ==========================================================================
local function show()
	if shown then
		return
	end
	shown = true

	for _, car in ipairs(CollectionService:GetTagged(ChassisSpec.CAR_TAG)) do
		decorate(car)
	end

	table.insert(conns, CollectionService:GetInstanceAddedSignal(ChassisSpec.CAR_TAG):Connect(function(car)
		task.spawn(function()
			local hull = car:WaitForChild(ChassisSpec.HULL, MARK.RESOLVE_TIMEOUT)
			if hull then
				hull:WaitForChild(ChassisSpec.MOUNT_ATT, MARK.RESOLVE_TIMEOUT)
			end
			if shown and car.Parent then
				decorate(car)
			end
		end)
	end))
	table.insert(conns, CollectionService:GetInstanceRemovedSignal(ChassisSpec.CAR_TAG):Connect(undecorate))
end

local function hide()
	shown = false
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	for car in pairs(marks) do
		undecorate(car)
	end
end

function WeaponViewController.isShown(): boolean
	return shown
end

function WeaponViewController.toggle()
	if shown then
		hide()
		print("[weaponview] off")
		return
	end
	show()
	printTable()
	local n = 0
	for _ in pairs(marks) do
		n += 1
	end
	print(string.format("[weaponview] on — %d car%s marked", n, n == 1 and "" or "s"))
end

-- ==========================================================================
-- § 6) the chat command
-- ==========================================================================
local function allowed(): boolean
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

--[[ Present at runtime whenever TextChatService.CreateDefaultCommands is on, which is the
	default. If it is off the folder never appears, and the engine still matches commands
	parented under that name, so making it is the correct fallback rather than a hack. ]]
local function commandsFolder(): Instance
	local folder = TextChatService:FindFirstChild("TextChatCommands")
		or TextChatService:WaitForChild("TextChatCommands", 5)
	if folder then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = "TextChatCommands"
	made.Parent = TextChatService
	return made
end

local function register()
	local ok, err = pcall(function()
		local cmd = Instance.new("TextChatCommand")
		cmd.Name = "WeaponViewCommand"
		cmd.PrimaryAlias = COMMAND
		cmd.SecondaryAlias = ALIAS
		cmd.AutocompleteVisible = true
		cmd.Enabled = true
		cmd.Triggered:Connect(function()
			WeaponViewController.toggle()
		end)
		cmd.Parent = commandsFolder()
	end)
	if not ok then
		warn("[weaponview] chat command did not register (" .. tostring(err) .. ") — using the fallback")
	end

	-- Unreachable while the command above is live: a matched command is never delivered to
	-- a channel, so this only ever sees the text when path 1 is absent.
	TextChatService.MessageReceived:Connect(function(message)
		local source = message.TextSource
		if not source or source.UserId ~= player.UserId then
			return
		end
		local text = string.lower(message.Text or "")
		text = string.match(text, "^%s*(.-)%s*$") or text
		if text == COMMAND or text == ALIAS or string.match(text, "^" .. COMMAND .. "%s") then
			WeaponViewController.toggle()
		end
	end)
end

function WeaponViewController.init(_ctx)
	if not allowed() then
		return
	end
	-- commandsFolder() can wait on replication; never block Main's boot loop for it.
	task.spawn(register)
end

return WeaponViewController
