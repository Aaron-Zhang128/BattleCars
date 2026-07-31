--[[ InputController
	The player's entire input surface: touch (primary), keyboard, gamepad.

	PURPOSE
		Players ARE cars — CharacterAutoLoads = false — so Roblox's default touch
		controls never appear. This module BUILDS its own touch pad and turns every
		input device into four smoothed values the rest of the client reads.

	PUBLIC SURFACE (pinned in StarterPlayerScripts.Main)
		getThrottle() -> -1..1     getSteer() -> -1..1
		isDrifting() -> boolean    isFireHeld() -> boolean
		onFire(fn)                 setEnabled(boolean)

	DATA FLOW
		touch pad / UserInputService -> per-source state -> merged, damped -> getters
		ChassisController polls getThrottle/getSteer/isDrifting every frame.
		WeaponController subscribes with onFire and polls isFireHeld for automatic guns.

	AUTO_ACCELERATE (constant at the top — one edit to flip)
		ON  : touch players are always driving forward; the pad shows BRAKE / REVERSE only.
		OFF : a GAS button appears above BRAKE.
		Keyboard and gamepad throttle stays explicit either way, so a desktop player is
		never shoved forward by a button they cannot see.

	DRIFT is an explicit DRIFT button on touch (never a steer-angle threshold) so a hard
	turn can never make a kid slide by accident.

	REMOTES     CarLifecycle (S->C, read only) — spawned/destroyed shows/hides the pad.
	ATTRIBUTES  reads Player Alive (neutral values + pad visibility) and PowerupSlot
	            (FIRE button visibility). Writes none.
	INSTANCES   PlayerGui.CrashTouchControls — ScreenGui, DisplayOrder 4 (under the HUD
	            at Config.UI.DISPLAY_ORDER.HUD = 5). Built at runtime, owned only by this
	            module. Nothing is authored into the tree.

	INIT ORDER  first controller up. Siblings resolve lazily through ctx.ctrl, so nothing
	            here touches ChassisController at init time.

	STYLE NOTE  the widgets are built with Instance.new straight from Config.UI rather than
	            requiring StarterGui.Main.UIKit — PlayerScripts must not depend on a
	            PlayerGui module. Corner/stroke/gradient/press-feel mirror UIKit exactly.
	            Buttons deliberately carry no click sound: a held FIRE button would spam it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local MathUtil = require(core:WaitForChild("Shared"):WaitForChild("MathUtil"))

local UI = Config.UI

local InputController = {}

-- ==========================================================================
-- tuning — Config has no INPUT section, so these are the knobs. All named.
-- ==========================================================================
local AUTO_ACCELERATE = true -- genre convention: touch players always drive forward
local STEER_SMOOTH_RATE = 22 -- MathUtil.damp rate, per second (higher = snappier)
local STEER_SNAP_EPSILON = 0.002 -- close enough to the target to just land on it
local STICK_DEAD_ZONE = 0.10 -- fraction of full travel ignored around centre
local STEER_TRAVEL_PX = 96 -- finger travel (scaled) for full lock
local GAMEPAD_DEAD_ZONE = 0.15
local TRIGGER_DEAD_ZONE = 0.06

local TOUCH_DISPLAY_ORDER = 4 -- deliberately under Config.UI.DISPLAY_ORDER.HUD (5)
local GUI_NAME = "CrashTouchControls"
local RENDER_BIND = "CrashCarsInputSmooth"

-- Layout is authored for a 640px-short-side phone and scaled from there.
local REFERENCE_SHORT_SIDE = 640
local LAYOUT_SCALE_MIN = 0.8
local LAYOUT_SCALE_MAX = 1.3
local PAD_PX = 24 -- screen-edge padding
local GAP_PX = 16 -- gap between controls
local STICK_TRACK_PX = 190
local STICK_KNOB_PX = 84
local BRAKE_W_PX = 122
local BRAKE_H_PX = 96
local FIRE_PX = 132
local DRIFT_PX = 104
local KNOB_HOME_TIME = 0.18
local STEER_ZONE_WIDTH = 0.5 -- the whole left half of the screen grabs the stick

local KNOB_HOME_INFO = TweenInfo.new(KNOB_HOME_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(UI.PRESS_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_INFO = TweenInfo.new(UI.HOVER_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_IN_INFO = TweenInfo.new(UI.POP_IN.time, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local FORWARD_KEYS = { [Enum.KeyCode.W] = true, [Enum.KeyCode.Up] = true }
local BACK_KEYS = { [Enum.KeyCode.S] = true, [Enum.KeyCode.Down] = true }
local LEFT_KEYS = { [Enum.KeyCode.A] = true, [Enum.KeyCode.Left] = true }
local RIGHT_KEYS = { [Enum.KeyCode.D] = true, [Enum.KeyCode.Right] = true }
local DRIFT_KEYS = { [Enum.KeyCode.Space] = true, [Enum.KeyCode.ButtonA] = true }
local FIRE_KEYS = { [Enum.KeyCode.E] = true, [Enum.KeyCode.ButtonX] = true, [Enum.KeyCode.ButtonR1] = true }

-- ==========================================================================
-- state
-- ==========================================================================
local player = Players.LocalPlayer

local ctxRef = nil
local enabled = true
local carLifecycleAlive = nil -- nil = no CarLifecycle event seen yet

local steerValue = 0 -- smoothed, what getSteer returns

local keyForward, keyBack, keyLeft, keyRight = false, false, false, false
local keyDrift, keyFire = false, false
local padSteer, padGas, padBrake = 0, 0, 0
local mouseFire = false

local touchSteer = 0
local touchBrake, touchGas, touchDrift, touchFire = false, false, false, false

local activeTouch: InputObject? = nil
local steerOrigin = Vector2.zero

local fireCallbacks = {}
local connections = {}
local viewportConn: RBXScriptConnection? = nil

local gui: ScreenGui? = nil
local controlsRoot: Frame? = nil
local stickTrack: Frame? = nil
local stickKnob: Frame? = nil
local steerZone: TextButton? = nil
local brakeButton: TextButton? = nil
local gasButton: TextButton? = nil
local fireButton: TextButton? = nil
local driftButton: TextButton? = nil

local stickHome = UDim2.fromOffset(0, 0)
local knobClampPx = (STICK_TRACK_PX - STICK_KNOB_PX) * 0.5
local travelPx = STEER_TRAVEL_PX
local fireShown = false

-- ==========================================================================
-- small helpers
-- ==========================================================================
local function track(conn: RBXScriptConnection): RBXScriptConnection
	table.insert(connections, conn)
	return conn
end

local function viewportSize(): Vector2
	local camera = workspace.CurrentCamera
	local size = camera and camera.ViewportSize or Vector2.new(1280, 720)
	if size.X < 1 or size.Y < 1 then
		return Vector2.new(1280, 720)
	end
	return size
end

local function layoutScale(): number
	local size = viewportSize()
	return math.clamp(math.min(size.X, size.Y) / REFERENCE_SHORT_SIDE, LAYOUT_SCALE_MIN, LAYOUT_SCALE_MAX)
end

-- Rescales past the dead zone so control starts at 0 instead of jumping.
local function deadZone(value: number, zone: number): number
	local magnitude = math.abs(value)
	if magnitude <= zone then
		return 0
	end
	return math.sign(value) * math.min((magnitude - zone) / (1 - zone), 1)
end

local function strongest(...): number
	local best = 0
	for index = 1, select("#", ...) do
		local value = select(index, ...) or 0
		if math.abs(value) > math.abs(best) then
			best = value
		end
	end
	return math.clamp(best, -1, 1)
end

-- The local car, if ChassisController is up and still holds one. Never errors.
local function localCar(): Model?
	local ctrl = ctxRef and ctxRef.ctrl
	local chassis = ctrl and ctrl.ChassisController
	if type(chassis) ~= "table" or type(chassis.getCar) ~= "function" then
		return nil
	end
	local ok, car = pcall(chassis.getCar)
	if not ok or typeof(car) ~= "Instance" or not car.Parent then
		return nil
	end
	return car
end

--[[ True when input should actually reach the car. Most trustworthy source wins:
	a live local car > CarLifecycle > the Alive attribute > permissive.
	Permissive last on purpose — an unpublished attribute must never lock a kid out. ]]
local function controlsLive(): boolean
	if not enabled then
		return false
	end
	if localCar() then
		return true
	end
	if carLifecycleAlive ~= nil then
		return carLifecycleAlive
	end
	local aliveFlag = player and player:GetAttribute(Config.ATTR.ALIVE)
	if aliveFlag == nil then
		return true
	end
	return aliveFlag == true
end

-- ==========================================================================
-- house primitives (mirror UIKit so the pad reads as the same system)
-- ==========================================================================
local function corner(inst: Instance, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius and UDim.new(0, radius) or UDim.new(0.5, 0)
	c.Parent = inst
end

local function stroke(inst: Instance, thickness: number?, color: Color3?, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or UI.STROKE
	s.Color = color or UI.INK
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
end

local function gradient(inst: Instance, colors: { Color3 })
	local keys = {}
	local count = #colors
	for index, color in ipairs(colors) do
		table.insert(keys, ColorSequenceKeypoint.new(count == 1 and 0 or (index - 1) / (count - 1), color))
	end
	if count == 1 then
		table.insert(keys, ColorSequenceKeypoint.new(1, colors[1]))
	end
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(keys)
	g.Rotation = 90
	g.Parent = inst
end

local function ensureScale(inst: Instance): UIScale
	local existing = inst:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Parent = inst
	return s
end

-- hover x1.07 / press x0.92 through a UIScale, house feel, no sound (see header).
local function addButtonFeedback(btn: GuiButton)
	local scale = ensureScale(btn)
	local hovering = false

	local function to(target: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = target }):Play()
	end

	track(btn.MouseEnter:Connect(function()
		hovering = true
		to(UI.HOVER_SCALE, HOVER_INFO)
	end))
	track(btn.MouseLeave:Connect(function()
		hovering = false
		to(1, HOVER_INFO)
	end))
	track(btn.MouseButton1Down:Connect(function()
		to(UI.PRESS_SCALE, PRESS_INFO)
	end))
	track(btn.MouseButton1Up:Connect(function()
		to(hovering and UI.HOVER_SCALE or 1, PRESS_INFO)
	end))
end

local function popIn(inst: GuiObject)
	local scale = ensureScale(inst)
	scale.Scale = UI.POP_IN.from
	inst.Visible = true
	TweenService:Create(scale, POP_IN_INFO, { Scale = 1 }):Play()
end

--[[ Hold binding for touch + mouse. Releases are caught three ways (on the button,
	off the button, and globally) so a held control can never stick down. ]]
local function bindHold(btn: GuiButton, setter: (boolean) -> ())
	local held: InputObject? = nil

	track(btn.InputBegan:Connect(function(input)
		if held then
			return
		end
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1 then
			return
		end
		held = input
		setter(true)
	end))

	local function release(input: InputObject?)
		if held and (input == nil or input == held) then
			held = nil
			setter(false)
		end
	end

	track(btn.InputEnded:Connect(release))
	track(UserInputService.InputEnded:Connect(release))
end

local function touchButton(name: string, text: string, accent: Color3, textCap: number, roundPill: boolean): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.BackgroundColor3 = accent
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Selectable = false -- gamepad drives the car, it must never select the pad
	btn.Text = text
	btn.Font = Enum.Font.GothamBlack
	btn.TextColor3 = UI.PAPER
	btn.TextScaled = true
	btn.ZIndex = 2
	btn.Parent = controlsRoot

	corner(btn, if roundPill then nil else UI.BUTTON_CORNER)
	gradient(btn, { accent:Lerp(UI.PAPER, 0.35), accent, accent:Lerp(UI.INK, 0.25) })
	stroke(btn, UI.STROKE, UI.INK)

	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = textCap
	cap.MinTextSize = 8
	cap.Parent = btn

	local labelStroke = Instance.new("UIStroke")
	labelStroke.Thickness = 2.5
	labelStroke.Color = UI.INK
	labelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	labelStroke.Parent = btn

	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.Size = UDim2.new(1, -10, 1, -10)
	gloss.Position = UDim2.fromScale(0.5, 0.5)
	gloss.AnchorPoint = Vector2.new(0.5, 0.5)
	gloss.BackgroundTransparency = 1
	gloss.ZIndex = 0
	gloss.Parent = btn
	corner(gloss, if roundPill then nil else UI.BUTTON_CORNER - 3)
	stroke(gloss, 1.25, UI.PAPER, 0.55)

	addButtonFeedback(btn)
	return btn
end

-- ==========================================================================
-- fire dispatch
-- ==========================================================================
local function dispatchFire()
	if not controlsLive() then
		return
	end
	for _, callback in ipairs(fireCallbacks) do
		local ok, err = pcall(callback)
		if not ok then
			warn("InputController: onFire callback errored -> " .. tostring(err))
		end
	end
end

-- ==========================================================================
-- steering stick
-- ==========================================================================
--[[ ScreenGui.IgnoreGuiInset is true, so gui offsets and InputObject.Position share the
	window's top-left origin and no GuiService inset conversion is needed. ]]
local function inputPoint(input: InputObject): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

local function updateStick(input: InputObject)
	if not stickKnob then
		return
	end
	local delta = inputPoint(input) - steerOrigin
	touchSteer = deadZone(math.clamp(delta.X / math.max(travelPx, 1), -1, 1), STICK_DEAD_ZONE)
	-- the knob follows the finger in both axes (feel only; steer is X)
	stickKnob.Position = UDim2.new(
		0.5,
		math.clamp(delta.X, -knobClampPx, knobClampPx),
		0.5,
		math.clamp(delta.Y, -knobClampPx, knobClampPx)
	)
end

local function endStick()
	activeTouch = nil
	touchSteer = 0
	if stickKnob then
		TweenService:Create(stickKnob, KNOB_HOME_INFO, { Position = UDim2.fromScale(0.5, 0.5) }):Play()
	end
	if stickTrack then
		TweenService:Create(stickTrack, KNOB_HOME_INFO, { Position = stickHome }):Play()
	end
end

--[[ The stick re-centres under wherever the finger landed in the left half — grabbing a
	small fixed stick on a phone is miserable. Clamped so the track stays on screen. ]]
local function beginStick(input: InputObject)
	if not stickTrack then
		return
	end
	activeTouch = input
	local point = inputPoint(input)
	local area = viewportSize()
	local half = stickTrack.Size.X.Offset * 0.5
	local margin = half + PAD_PX * 0.5
	steerOrigin = Vector2.new(
		math.clamp(point.X, margin, math.max(margin, area.X * STEER_ZONE_WIDTH - PAD_PX * 0.5)),
		math.clamp(point.Y, margin, math.max(margin, area.Y - margin))
	)
	stickTrack.Position = UDim2.fromOffset(steerOrigin.X, steerOrigin.Y)
	updateStick(input)
end

-- ==========================================================================
-- layout
-- ==========================================================================
local function applyLayout()
	if not controlsRoot or not stickTrack or not stickKnob then
		return
	end
	local scale = layoutScale()
	local pad = PAD_PX * scale
	local gap = GAP_PX * scale
	local trackPx = STICK_TRACK_PX * scale
	local knobPx = STICK_KNOB_PX * scale
	local brakeW, brakeH = BRAKE_W_PX * scale, BRAKE_H_PX * scale
	local firePx = FIRE_PX * scale
	local driftPx = DRIFT_PX * scale

	knobClampPx = (trackPx - knobPx) * 0.5
	travelPx = STEER_TRAVEL_PX * scale

	stickTrack.Size = UDim2.fromOffset(trackPx, trackPx)
	stickKnob.Size = UDim2.fromOffset(knobPx, knobPx)
	stickHome = UDim2.new(0, pad + trackPx * 0.5, 1, -(pad + trackPx * 0.5))
	if not activeTouch then
		stickTrack.Position = stickHome
	end

	if brakeButton then
		brakeButton.Size = UDim2.fromOffset(brakeW, brakeH)
		brakeButton.Position = UDim2.new(0, pad + trackPx + gap + brakeW, 1, -pad)
	end
	if gasButton then
		gasButton.Size = UDim2.fromOffset(brakeW, brakeH)
		gasButton.Position = UDim2.new(0, pad + trackPx + gap + brakeW, 1, -(pad + brakeH + gap))
	end
	if fireButton then
		fireButton.Size = UDim2.fromOffset(firePx, firePx)
		fireButton.Position = UDim2.new(1, -pad, 1, -pad)
	end
	if driftButton then
		driftButton.Size = UDim2.fromOffset(driftPx, driftPx)
		driftButton.Position = UDim2.new(1, -(pad + firePx + gap), 1, -pad)
	end
end

-- ==========================================================================
-- touch pad construction
-- ==========================================================================
local function refreshFireButton()
	if not fireButton then
		return
	end
	local slot = player and player:GetAttribute(Config.ATTR.POWERUP)
	local hasPowerup = type(slot) == "string" and slot ~= ""
	if hasPowerup == fireShown then
		return
	end
	fireShown = hasPowerup
	if hasPowerup then
		popIn(fireButton)
	else
		fireButton.Visible = false
		touchFire = false
	end
end

local function buildTouchPad()
	if gui then
		return
	end
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		playerGui = player and player:WaitForChild("PlayerGui", 10)
	end
	if not playerGui then
		warn("InputController: no PlayerGui — touch controls unavailable")
		return
	end

	local existing = playerGui:FindFirstChild(GUI_NAME)
	if existing then
		existing:Destroy()
	end

	gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = TOUCH_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	controlsRoot = Instance.new("Frame")
	controlsRoot.Name = "Controls"
	controlsRoot.Size = UDim2.fromScale(1, 1)
	controlsRoot.BackgroundTransparency = 1
	controlsRoot.Parent = gui

	-- left half grabs the stick; ZIndex 0 keeps it under every button
	steerZone = Instance.new("TextButton")
	steerZone.Name = "SteerZone"
	steerZone.Size = UDim2.fromScale(STEER_ZONE_WIDTH, 1)
	steerZone.Position = UDim2.fromScale(0, 0)
	steerZone.BackgroundTransparency = 1
	steerZone.Text = ""
	steerZone.AutoButtonColor = false
	steerZone.Selectable = false
	steerZone.ZIndex = 0
	steerZone.Parent = controlsRoot

	stickTrack = Instance.new("Frame")
	stickTrack.Name = "SteerTrack"
	stickTrack.AnchorPoint = Vector2.new(0.5, 0.5)
	stickTrack.BackgroundColor3 = UI.GLASS
	stickTrack.BackgroundTransparency = 0.35
	stickTrack.BorderSizePixel = 0
	stickTrack.ZIndex = 1
	stickTrack.Parent = controlsRoot
	corner(stickTrack)
	stroke(stickTrack, 3, UI.INK)

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.Size = UDim2.new(1, -14, 1, -14)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.Parent = stickTrack
	corner(ring)
	stroke(ring, 1.5, UI.GOLD, 0.4)

	stickKnob = Instance.new("Frame")
	stickKnob.Name = "Knob"
	stickKnob.AnchorPoint = Vector2.new(0.5, 0.5)
	stickKnob.Position = UDim2.fromScale(0.5, 0.5)
	stickKnob.BackgroundColor3 = UI.GOLD
	stickKnob.BorderSizePixel = 0
	stickKnob.ZIndex = 2
	stickKnob.Parent = stickTrack
	corner(stickKnob)
	gradient(stickKnob, { UI.GOLD_LIGHT, UI.GOLD, UI.GOLD_DEEP })
	stroke(stickKnob, UI.STROKE, UI.INK)

	local knobGloss = Instance.new("Frame")
	knobGloss.Name = "Gloss"
	knobGloss.Size = UDim2.new(1, -12, 1, -12)
	knobGloss.Position = UDim2.fromScale(0.5, 0.5)
	knobGloss.AnchorPoint = Vector2.new(0.5, 0.5)
	knobGloss.BackgroundTransparency = 1
	knobGloss.Parent = stickKnob
	corner(knobGloss)
	stroke(knobGloss, 1.25, UI.PAPER, 0.55)

	brakeButton = touchButton("Brake", "BRAKE", UI.GLASS:Lerp(UI.PAPER, 0.12), 18, false)
	bindHold(brakeButton, function(down)
		touchBrake = down
	end)

	if not AUTO_ACCELERATE then
		gasButton = touchButton("Gas", "GAS", UI.CONFIRM, 18, false)
		bindHold(gasButton, function(down)
			touchGas = down
		end)
	end

	fireButton = touchButton("Fire", "FIRE", UI.DANGER, 22, true)
	fireButton.Visible = false
	bindHold(fireButton, function(down)
		touchFire = down
		if down then
			dispatchFire()
		end
	end)

	driftButton = touchButton("Drift", "DRIFT", UI.GOLD, 18, true)
	bindHold(driftButton, function(down)
		touchDrift = down
	end)

	track(steerZone.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or activeTouch then
			return
		end
		beginStick(input)
	end))
	track(UserInputService.TouchMoved:Connect(function(input)
		if input == activeTouch then
			updateStick(input)
		end
	end))
	track(UserInputService.TouchEnded:Connect(function(input)
		if input == activeTouch then
			endStick()
		end
	end))

	applyLayout()
	refreshFireButton()
end

-- ==========================================================================
-- enable / visibility
-- ==========================================================================
local function releaseHeld()
	keyForward, keyBack, keyLeft, keyRight = false, false, false, false
	keyDrift, keyFire = false, false
	padSteer, padGas, padBrake = 0, 0, 0
	mouseFire = false
	touchBrake, touchGas, touchDrift, touchFire = false, false, false, false
	if activeTouch then
		endStick()
	end
end

local function refreshTouchPad()
	local show = UserInputService.TouchEnabled and controlsLive()
	if show and not gui then
		buildTouchPad()
	end
	if not controlsRoot then
		return
	end
	if controlsRoot.Visible == show then
		return
	end
	controlsRoot.Visible = show
	if not show then
		touchBrake, touchGas, touchDrift, touchFire = false, false, false, false
		if activeTouch then
			endStick()
		end
	else
		refreshFireButton()
	end
end

-- ==========================================================================
-- device bindings — UserInputService only, so nothing is double-bound
-- ==========================================================================
local function isGamepad(input: InputObject): boolean
	return input.UserInputType.Name:sub(1, 7) == "Gamepad"
end

local function setKeyState(keyCode: Enum.KeyCode, down: boolean)
	if FORWARD_KEYS[keyCode] then
		keyForward = down
	elseif BACK_KEYS[keyCode] then
		keyBack = down
	elseif LEFT_KEYS[keyCode] then
		keyLeft = down
	elseif RIGHT_KEYS[keyCode] then
		keyRight = down
	elseif DRIFT_KEYS[keyCode] then
		keyDrift = down
	elseif FIRE_KEYS[keyCode] then
		local was = keyFire
		keyFire = down
		if down and not was then
			dispatchFire()
		end
	end
end

local function bindDevices()
	track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return -- chat / UI took it (a tap on our own FIRE button arrives via bindHold)
		end
		if input.UserInputType == Enum.UserInputType.Keyboard or isGamepad(input) then
			setKeyState(input.KeyCode, true)
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			if not mouseFire then
				mouseFire = true
				dispatchFire()
			end
		end
	end))

	-- releases ignore gameProcessed: a key must never stick down
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard or isGamepad(input) then
			setKeyState(input.KeyCode, false)
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseFire = false
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not isGamepad(input) then
			return
		end
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			padSteer = deadZone(input.Position.X, GAMEPAD_DEAD_ZONE)
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			padGas = input.Position.Z
		elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
			padBrake = input.Position.Z
		end
	end))

	track(UserInputService.GamepadDisconnected:Connect(function()
		padSteer, padGas, padBrake = 0, 0, 0
	end))

	-- alt-tab must not leave the throttle pinned
	track(UserInputService.WindowFocusReleased:Connect(releaseHeld))

	track(UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(refreshTouchPad))
end

-- ==========================================================================
-- per-frame steer smoothing (Input priority: ahead of the camera and the chassis)
-- ==========================================================================
local function steerTarget(): number
	if not controlsLive() then
		return 0
	end
	local keySteer = 0
	if keyLeft ~= keyRight then
		keySteer = keyLeft and -1 or 1
	end
	return strongest(touchSteer, padSteer, keySteer)
end

local function step(dt: number)
	-- watchdog: a touch whose TouchEnded never arrived
	if activeTouch and activeTouch.UserInputState == Enum.UserInputState.End then
		endStick()
	end

	local target = steerTarget()
	steerValue = MathUtil.damp(steerValue, target, STEER_SMOOTH_RATE, dt)
	if math.abs(steerValue - target) < STEER_SNAP_EPSILON then
		steerValue = target
	end
end

-- ==========================================================================
-- public surface
-- ==========================================================================
function InputController.getThrottle(): number
	if not controlsLive() then
		return 0
	end
	if touchBrake then
		return -1 -- deliberate brake / reverse beats everything else
	end
	if touchGas then
		return 1
	end

	local keyThrottle = 0
	if keyForward ~= keyBack then
		keyThrottle = keyForward and 1 or -1
	end
	local padThrottle = deadZone(math.clamp(padGas - padBrake, -1, 1), TRIGGER_DEAD_ZONE)
	local explicit = strongest(padThrottle, keyThrottle)
	if explicit ~= 0 then
		return explicit
	end

	if AUTO_ACCELERATE and UserInputService.TouchEnabled then
		return 1 -- touch sessions are always driving forward
	end
	return 0
end

function InputController.getSteer(): number
	if not controlsLive() then
		return 0
	end
	return math.clamp(steerValue, -1, 1)
end

function InputController.isDrifting(): boolean
	if not controlsLive() then
		return false
	end
	return touchDrift or keyDrift
end

function InputController.isFireHeld(): boolean
	if not controlsLive() then
		return false
	end
	return touchFire or keyFire or mouseFire
end

-- Callbacks live for the session; WeaponController registers one at init.
function InputController.onFire(callback: () -> ())
	if type(callback) ~= "function" then
		warn("InputController.onFire: expected a function")
		return
	end
	table.insert(fireCallbacks, callback)
end

-- Lobby / Results disable input: getters go neutral and the touch pad hides.
function InputController.setEnabled(on: boolean)
	local want = on == true
	if enabled == want then
		return
	end
	enabled = want
	if not enabled then
		releaseHeld()
	end
	refreshTouchPad()
end

-- ==========================================================================
-- init / teardown
-- ==========================================================================
local function teardown()
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_BIND)
	end)
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)
	if viewportConn then
		viewportConn:Disconnect()
		viewportConn = nil
	end
	if gui then
		gui:Destroy()
	end
	gui, controlsRoot, stickTrack, stickKnob, steerZone = nil, nil, nil, nil, nil
	brakeButton, gasButton, fireButton, driftButton = nil, nil, nil, nil
	fireShown = false
	releaseHeld()
	steerValue = 0
end

local function watchViewport()
	if viewportConn then
		viewportConn:Disconnect()
		viewportConn = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
	end
end

function InputController.init(ctx)
	teardown() -- safe to re-init: never two render bindings, never two guis
	ctxRef = ctx
	player = Players.LocalPlayer
	if not player then
		warn("InputController: no LocalPlayer")
		return
	end
	enabled = true

	if UserInputService.TouchEnabled then
		buildTouchPad()
	end
	bindDevices()

	track(player:GetAttributeChangedSignal(Config.ATTR.POWERUP):Connect(refreshFireButton))
	track(player:GetAttributeChangedSignal(Config.ATTR.ALIVE):Connect(refreshTouchPad))

	local lifecycle = ctx and ctx.net and ctx.net.CarLifecycle
	if lifecycle and lifecycle:IsA("RemoteEvent") then
		track(lifecycle.OnClientEvent:Connect(function(action)
			if action == "spawned" then
				carLifecycleAlive = true
			elseif action == "destroyed" then
				carLifecycleAlive = false
			end
			refreshTouchPad()
		end))
	end

	watchViewport()
	track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		watchViewport()
		applyLayout()
	end))

	refreshTouchPad()
	RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Input.Value, step)
end

return InputController
