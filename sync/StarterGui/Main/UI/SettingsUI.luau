--[[ SettingsUI (UI module — the settings window)
	Wires the uploaded kit's "Config/Settings" window: two volume sliders, drag or tap.
	Builds nothing except the fill bar inside each authored track.

	HONESTY ABOUT WHAT THESE SLIDERS DO — read this before renaming a row.
		The kit ships the rows labelled "Music" and "Sound Effects". This game has NO music:
		nothing anywhere creates a music Sound, and SoundService has no BackgroundMusic
		group to point at. A slider that moves and changes nothing is worse than no slider,
		so the rows are relabelled to the two buses that actually exist here:
			Game Sounds  — everything that plays out in the world (engines, rams, weapons,
			               explosions): Sounds parented anywhere under Workspace.
			Menu Sounds  — everything that plays flat: UIKit's whole sound kit, plus the
			               positionless cues FxController parents straight to SoundService.
		If music ever ships, put it in a SoundService.BackgroundMusic group and point row 1
		back at it — one line in BUSES below, and the label goes back to "Music".

	HOW A BUS CAN EXIST AT ALL. Nothing in this game assigns a SoundGroup: UIKit parents its
	sounds to SoundService and FxController parents its 3D sounds to holder parts, both with
	SoundGroup nil. So this module creates two CLIENT-LOCAL SoundGroups and adopts every
	ungrouped Sound as it appears. That adoption is an ADAPTER, not the right long-term home
	— HANDOFF asks for the one-line SoundGroup assignment inside UIKit and FxController,
	after which the hooks here can be deleted and the sliders keep working.
		SoundService.GameSFX is deliberately NOT reused: it is the previous game's group, it
		holds legacy sound templates, its authored Volume is 0.5, and adopting into it would
		quietly halve the volume of every sound in the game.

	PERSISTENCE: none, by design. Settings are client-local and there is no client-side
	store; the profile is server-owned and a volume slider is not worth a remote or a
	DataStore write. Both rows therefore start at full every session. Said plainly here so
	nobody later reads the absence as a bug.

	Frame       registered as "Settings" (pinned) — a HUD button opens it with
	            kit.openFrame("Settings"). This module opens nothing by itself.
	Source      PlayerGui.Alternate.Frames["Config/Settings"] (literal slash in the kit's
	            name), falling back to StarterGui. Cloned under ctx.frames; the kit copy is
	            left untouched.
	Remotes     none. Attributes none. Nothing here reaches the server.

	MOBILE  The window is hidden unless a player opened it, and the drag handler is gated on
	        that visibility AND on the pointer being inside a slider's own rect, so it can
	        never swallow a steering drag from InputController's left-half steer zone.

	Sections:
		§1  constants
		§2  state
		§3  kit resolution
		§4  audio buses
		§5  slider wiring
		§6  init
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))

local player = Players.LocalPlayer

local SettingsUI = {}

local UI = Config.UI

-- ==========================================================================
-- §1) constants
-- ==========================================================================
local FRAME_NAME = "Settings" -- pinned: a HUD button opens it via kit.openFrame("Settings")
local KIT_GUI = "Alternate"
local KIT_FRAME = "Config/Settings" -- literal slash: bracket-index, never dot-index
local RESOLVE_TIMEOUT = 20

local DEFAULT_VOLUME = 1 -- session-local, see the header
local TICK_STEP = 0.1 -- one TICK sound per 10% crossed while dragging
local GRAB_PAD_Y = 0.6 -- the grab rect is 60% taller than the track, for thumbs

--[[ Row -> bus. `where` is the only thing that decides which bus a sound lands in, which is
	also exactly what each label promises the player. ]]
local BUSES = {
	{ row = "Slider1", label = "Game Sounds", group = "CrashWorldSfx", where = "world" },
	{ row = "Slider2", label = "Menu Sounds", group = "CrashMenuSfx", where = "menu" },
}

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit
local panel, container
local rows = {} -- [index] = row record (see §5)
SettingsUI._rows = rows -- smoke-test seam only; nothing in the game reads it
local groups = {} -- ["world"|"menu"] = SoundGroup
local dragging = nil -- the row record currently under the pointer
local ready = false

-- ==========================================================================
-- §3) kit resolution — a missing kit disables the window, never breaks the game
-- ==========================================================================
local function findKitFrame(): Instance?
	local roots = {}
	-- `player` is nil in an edit-mode harness; a real client always has it by here.
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(roots, playerGui)
	end
	local starterGui = game:FindFirstChildOfClass("StarterGui")
	if starterGui then
		table.insert(roots, starterGui)
	end

	for index, root in ipairs(roots) do
		-- Only the FIRST lookup may wait; the fallback must not stall the boot.
		local gui = index == 1 and root:WaitForChild(KIT_GUI, RESOLVE_TIMEOUT) or root:FindFirstChild(KIT_GUI)
		local frames = gui and gui:FindFirstChild("Frames")
		local frame = frames and frames:FindFirstChild(KIT_FRAME)
		if frame and frame:IsA("GuiObject") then
			return frame
		end
	end
	return nil
end

--[[ Kit windows are authored translucent for a dimmed modal backdrop (this one's gradient
	ramps alpha 0.65 -> 0.35). There is no backdrop here, so over the open world the panel
	washes out; BackgroundTransparency cannot fix it because the gradient's alpha multiplies
	on top. Only the panel's OWN ramp is flattened — everything else is authored decoration. ]]
local function flattenGradient(root: Instance)
	local own = root:FindFirstChildOfClass("UIGradient")
	if own then
		own.Transparency = NumberSequence.new(0)
	end
end

-- ==========================================================================
-- §4) audio buses
-- ==========================================================================
local function ensureGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = DEFAULT_VOLUME -- 1, so adoption alone never changes how loud anything is
	group.Parent = SoundService
	return group
end

local function adopt(instance: Instance, group: SoundGroup)
	if instance:IsA("Sound") and instance.SoundGroup == nil then
		instance.SoundGroup = group
	end
end

--[[ The adapter. Two hooks, each doing one IsA test — deliberately the cheapest body that
	can work, because the world hook sees every part the FX system spawns. ]]
local function startAdoption()
	local menuGroup, worldGroup = groups.menu, groups.world

	if menuGroup then
		for _, child in ipairs(SoundService:GetChildren()) do
			adopt(child, menuGroup)
		end
		SoundService.ChildAdded:Connect(function(child)
			adopt(child, menuGroup)
		end)
	end

	if worldGroup then
		for _, item in ipairs(Workspace:GetDescendants()) do
			adopt(item, worldGroup)
		end
		Workspace.DescendantAdded:Connect(function(item)
			adopt(item, worldGroup)
		end)
	end
end

-- ==========================================================================
-- §5) slider wiring
-- ==========================================================================

-- The authored track has no filled portion, so the value only reads as a handle position.
-- One fill frame makes it legible at a glance, in the house green.
local function buildFill(track: Instance): Frame?
	local existing = track:FindFirstChild("Fill")
	if existing then
		return existing
	end
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UI.CONFIRM
	fill.BorderSizePixel = 0
	fill.ZIndex = track.ZIndex
	fill.Parent = track

	local corner = track:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = fill -- match the authored radius exactly
	end
	kit.gradient(fill, { UI.LIME, UI.CONFIRM })
	return fill
end

local function wireRow(bus, index: number)
	local row = container:FindFirstChild(bus.row)
	local track = row and row:FindFirstChild("Slider")
	local bar = track and track:FindFirstChild("BG")
	local handle = track and track:FindFirstChild("Button")
	if not row or not track or not handle then
		warn("SettingsUI: kit row " .. bus.row .. " is missing its Slider/Button — that row is disabled")
		return nil
	end

	local nameLabel = row:FindFirstChild("Name") -- the kit's LABEL, not row.Name the property
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = bus.label
	end

	local record = {
		label = bus.label,
		track = track,
		handle = handle,
		fill = bar and buildFill(bar) or nil,
		group = groups[bus.where],
		value = DEFAULT_VOLUME,
		lastTick = DEFAULT_VOLUME,
	}

	function record.set(value: number, quiet: boolean?)
		local clamped = math.clamp(value, 0, 1)
		record.value = clamped
		record.handle.Position = UDim2.new(clamped, 0, 0.5, 0)
		if record.fill then
			record.fill.Size = UDim2.fromScale(clamped, 1)
		end
		if record.group then
			record.group.Volume = clamped
		end
		if not quiet and math.abs(clamped - record.lastTick) >= TICK_STEP then
			record.lastTick = clamped
			kit.playSfx("TICK")
		end
	end

	function record.setFromX(x: number)
		local left = record.track.AbsolutePosition.X
		local width = math.max(1, record.track.AbsoluteSize.X)
		record.set((x - left) / width)
	end

	-- Main's ScreenGui is IgnoreGuiInset, so AbsolutePosition and input.Position share one
	-- coordinate space; no topbar fudge factor is needed here.
	function record.contains(position: Vector2): boolean
		local pos, size = record.track.AbsolutePosition, record.track.AbsoluteSize
		local padY = size.Y * GRAB_PAD_Y * 0.5
		return position.X >= pos.X
			and position.X <= pos.X + size.X
			and position.Y >= pos.Y - padY
			and position.Y <= pos.Y + size.Y + padY
	end

	handle.AutoButtonColor = false
	record.set(DEFAULT_VOLUME, true)
	return record
end

local function rowAt(position: Vector2)
	for _, record in ipairs(rows) do
		if record.contains(position) then
			return record
		end
	end
	return nil
end

local function bindInput()
	local function isPointer(input): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	--[[ Deliberately NOT filtered on gameProcessedEvent: the handle is a GuiButton and sinks
		its own presses, so a processed-only filter would make the handle the one part of the
		slider you cannot grab. Safe because every branch needs the window OPEN and the
		pointer inside a track. ]]
	UserInputService.InputBegan:Connect(function(input)
		if not ready or not panel.Visible or not isPointer(input) then
			return
		end
		local record = rowAt(Vector2.new(input.Position.X, input.Position.Y))
		if not record then
			return
		end
		dragging = record
		record.setFromX(input.Position.X)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragging.setFromX(input.Position.X)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if dragging and isPointer(input) then
			dragging = nil
		end
	end)

	-- Closing the window mid-drag must not leave the pointer captured.
	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if not panel.Visible then
			dragging = nil
		end
	end)
end

-- ==========================================================================
-- §6) init
-- ==========================================================================
function SettingsUI.init(ctx)
	kit = ctx and ctx.kit
	if not kit or not ctx.frames then
		warn("SettingsUI: no ctx.kit / ctx.frames — settings window disabled")
		return
	end

	local source = findKitFrame()
	if not source then
		warn("SettingsUI: kit frame " .. KIT_GUI .. '.Frames["' .. KIT_FRAME .. '"] not found — settings window disabled')
		return
	end

	panel = source:Clone()
	panel.Name = FRAME_NAME
	panel.Visible = false
	flattenGradient(panel)
	panel.Parent = ctx.frames

	container = panel:FindFirstChild("Container")
	if not container then
		warn("SettingsUI: kit frame has no Container — settings window disabled")
		panel:Destroy()
		panel = nil
		return
	end

	for _, bus in ipairs(BUSES) do
		groups[bus.where] = ensureGroup(bus.group)
	end

	for index, bus in ipairs(BUSES) do
		local record = wireRow(bus, index)
		if record then
			table.insert(rows, record)
		end
	end
	if #rows == 0 then
		warn("SettingsUI: no usable slider rows in the kit frame — settings window disabled")
		panel:Destroy()
		panel = nil
		return
	end

	ready = true
	startAdoption()
	bindInput()
	kit.registerFrame(FRAME_NAME, panel) -- hides it, wires Close, gives it pop in/out
end

return SettingsUI
