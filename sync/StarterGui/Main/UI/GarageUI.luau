--[[ GarageUI (UI module — the shop)
	The screen that sells the roster. One card per Config.CARS entry, cheapest first:
	a REAL viewport render of the model CarFactory publishes, the car name + rarity chip,
	four comparable stat bars, its signature powerup, and ONE state-driven action button
	(price / EQUIP / DRIVING).

	AUTHORITY: the server owns money and ownership. This module NEVER predicts a result —
	it fires GarageAction and repaints only when OwnedCars / EquippedCar / Coins / Gems
	change. A failed action flashes the server's own message on that card.

	Frame       registered as "Garage" (pinned) — LobbyUI opens it via kit.openFrame("Garage").
	            Lives under ctx.frames, hidden until opened, Close button top-right.
	Remote      GarageAction  C->S (action, carId)   S->C (ok, message, carId)
	Attributes  reads only: Coins Gems EquippedCar OwnedCars ProfileLoaded Alive
	Assets      ReplicatedStorage.CrashCore.Assets.Previews[carId] (published at server init;
	            a missing preview degrades to a colored placeholder and warns once)

	MOTION: header drift + one spin per viewport, connected ONLY while the panel is visible
	and disconnected the moment it closes — 8 live RenderStepped spins behind a hidden frame
	is wasted mobile frame time. Manual RenderStepped math, no tween loops (house rule).

	SOUND + HOVER: the whole card is the choice, so the card (not just its button) hovers —
	it lifts and its rarity ring brightens. The reply from the server is what makes a
	noise, never the click: BUY_OK for a purchase, the lighter TOGGLE for an equip, DENY
	for any refusal. Exactly one sound per action, which is why rec.pending records what we
	asked for — OwnedCars usually replicates BEFORE the reply and repaints "buy" into
	"equip", so reading rec.state at reply time would sound an equip for a purchase.
	The Close button is hand-built and deliberately gets NO addButtonFeedback here:
	kit.registerFrame attaches it, and a second copy would double the hover sound.

	Sections:
		§1  constants + layout table
		§2  state
		§3  small helpers (money, fit scale, button repaint)
		§4  card state + refresh (reactive, never a rebuild)
		§5  actions (fire + inline flash)
		§6  construction (panel, header, card)
		§7  motion
		§8  init
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local CarRegistry = require(sharedFolder:WaitForChild("CarRegistry"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))

local player = Players.LocalPlayer

local GarageUI = {}

local ATTR = Config.ATTR
local UI = Config.UI

-- ==========================================================================
-- §1) constants + layout
-- ==========================================================================
local FRAME_NAME = "Garage" -- pinned: LobbyUI calls kit.openFrame("Garage")

local PANEL_SCALE = Vector2.new(0.86, 0.84)
local PANEL_MAX = Vector2.new(1120, 700)
local PANEL_MIN = Vector2.new(340, 240)
local HEADER_HEIGHT = 0.16 -- fraction of the panel
local GRID_HEIGHT = 0.75

-- House card recipe, taller than the 150x118 default: a render, four bars and a button
-- have to stack inside one cell. Width stays near the house 150.
local CARD_W, CARD_H = 164, 292
local CARD_GAP = 10
local CARD_HOVER_SCALE = 1.05 -- cells sit CARD_GAP apart; the house 1.07 would overlap
local FIT_MIN = 0.7 -- phone floor (DNA says >= 65%); four stat bars need the pixels

--[[ Measured, not guessed: with UIKit's FOV 40 the DNA default 0.72 overflows the frame for
	every car in the roster (~1.9x). 1.55 fits all 8 across a full spin with no clipping,
	filling 56-65% of the well's width and 67-87% of its height. ]]
local VIEW_ZOOM = 1.55
local LOCK_TINT = Color3.fromRGB(148, 148, 156) -- locked render greys out but stays readable

local SPIN_DPS = 24
local SPIN_STAGGER = 1.5 -- per-card speed offset (25-36 deg/s) so the grid is not in lockstep
local DRIFT_FREQ, DRIFT_AMP = 1.5, 3

local FLASH_SECONDS = 1.5
local CLICK_LOCK = 0.55 -- >= Net.REQUEST_GAP (0.5) so a double tap cannot outrun the reply
local PREVIEW_TIMEOUT = 20

local GEM = UI.RARITY.EPIC -- gems wear the epic purple, coins the gold ramp
local GEM_RAMP = { GEM:Lerp(UI.PAPER, 0.5), GEM, GEM:Lerp(UI.INK, 0.3) }

-- Short words a kid can compare at a glance, in CarRegistry.statBars() key order.
local STATS = {
	{ key = "speed", label = "SPEED", color = UI.GOLD },
	{ key = "accel", label = "ACCEL", color = UI.LIME },
	{ key = "turn", label = "TURN", color = UI.RARITY.RARE },
	{ key = "tough", label = "TOUGH", color = UI.CONFIRM },
}

-- Everything inside a card is scale-based, so one cell size fits every screen.
local L = {
	wellY = 0.036,
	wellH = 0.325,
	nameY = 0.375,
	nameH = 0.072,
	chipY = 0.455,
	chipH = 0.056,
	statY = 0.522,
	statH = 0.056,
	statGap = 0.064,
	loveY = 0.782,
	loveH = 0.058,
	btnY = 0.852,
	btnH = 0.112,
	width = 0.88,
}

local FLASH_TINT = { good = UI.CONFIRM, bad = UI.DANGER, wait = UI.GOLD }

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit, net, frames
local panel, header, headerBase, gridFrame, gridLayout, loadingLabel
local coinValue, gemValue

-- carId -> { car, root, render, shade, button, stroke, flash, flashLabel, state, busy,
--            pending (action in flight, so the reply sounds the right note), order }
local cards = {}
local motionConns = {}
local boundCameras = {}
local cardsBuilt = false
local warnedPreview = false

-- ==========================================================================
-- §3) helpers
-- ==========================================================================
local function readMoney(attr: string): number
	local value = player:GetAttribute(attr)
	return type(value) == "number" and value or 0
end

--[[ Cards are fixed-offset cells, so shrink them until a whole row fits the grid on a
	phone in landscape. Derived from the camera, not AbsoluteSize, so it is valid before
	the first layout pass. ]]
local function fitScale(): number
	local cam = workspace.CurrentCamera
	local viewY = cam and cam.ViewportSize.Y or 720
	if viewY < 1 then
		return 1
	end
	local panelH = math.clamp(viewY * PANEL_SCALE.Y, PANEL_MIN.Y, PANEL_MAX.Y)
	local gridH = panelH * GRID_HEIGHT
	return math.clamp(gridH / (CARD_H + CARD_GAP * 2), FIT_MIN, 1)
end

local function applyFit()
	if not gridLayout then
		return
	end
	local f = fitScale()
	gridLayout.CellSize = UDim2.fromOffset(math.floor(CARD_W * f), math.floor(CARD_H * f))
	gridLayout.CellPadding = UDim2.fromOffset(math.floor(CARD_GAP * f), math.floor(CARD_GAP * f))
end

local function watchViewport()
	local function bind(cam: Instance?)
		if not cam or boundCameras[cam] then
			return
		end
		boundCameras[cam] = true
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyFit)
	end

	bind(workspace.CurrentCamera)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bind(workspace.CurrentCamera)
		applyFit()
	end)
end

--[[ Repaints a kit button in place — same 3-stop ramp UIKit.button builds, so a state
	change never rebuilds the button (and never restarts its UIScale feel). ]]
local function paintButton(btn: TextButton, accent: Color3, textColor: Color3, dim: boolean)
	local body = dim and accent:Lerp(UI.GLASS, 0.55) or accent
	btn.BackgroundColor3 = body

	local grad = btn:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, body:Lerp(UI.PAPER, 0.35)),
			ColorSequenceKeypoint.new(0.5, body),
			ColorSequenceKeypoint.new(1, body:Lerp(UI.INK, 0.25)),
		})
	end

	btn.TextColor3 = textColor
	btn.TextTransparency = dim and 0.2 or 0
end

local function refreshMoney()
	if coinValue then
		coinValue.Text = MathUtil.comma(readMoney(ATTR.COINS))
	end
	if gemValue then
		gemValue.Text = MathUtil.comma(readMoney(ATTR.GEMS))
	end
end

-- ==========================================================================
-- §4) card refresh — property writes only, never a teardown
-- ==========================================================================
local function refreshCard(carId: string)
	local rec = cards[carId]
	if not rec then
		return
	end

	local car = rec.car
	local owned = CarRegistry.owns(player, carId)
	local equipped = CarRegistry.equippedId(player) == carId
	local isGems = car.currency == "Gems"
	local balance = isGems and readMoney(ATTR.GEMS) or readMoney(ATTR.COINS)
	local affordable = CarRegistry.isFree(car) or balance >= (car.price or 0)

	-- Locked reads locked, but you can still see exactly what you are missing.
	rec.shade.Visible = not owned
	rec.render.ImageColor3 = owned and UI.PAPER or LOCK_TINT

	-- House "selected" rule: the card stroke swaps to confirm green at 3px.
	if rec.stroke then
		rec.stroke.Color = equipped and UI.CONFIRM or UI.INK
		rec.stroke.Thickness = equipped and 3 or UI.STROKE
	end

	local btn = rec.button
	if equipped then
		rec.state = "driving"
		btn.Text = "DRIVING"
		btn.Active = false
		btn.Selectable = false
		paintButton(btn, UI.CONFIRM:Lerp(UI.GLASS, 0.45), UI.PAPER, false)
	elseif owned then
		rec.state = "equip"
		btn.Text = "EQUIP"
		btn.Active = true
		btn.Selectable = true
		paintButton(btn, UI.CONFIRM, UI.PAPER, rec.busy)
	else
		rec.state = "buy"
		btn.Text = CarRegistry.priceText(car)
		btn.Active = true
		btn.Selectable = true
		-- Too poor: dimmed with a DANGER price, but still tappable — the server's
		-- "Need more coins!" teaches more than a dead button.
		paintButton(
			btn,
			isGems and GEM or UI.GOLD,
			affordable and UI.PAPER or UI.DANGER,
			rec.busy or not affordable
		)
	end
end

local function refreshAllCards()
	for carId in pairs(cards) do
		refreshCard(carId)
	end
end

-- ==========================================================================
-- §5) actions
-- ==========================================================================
local function flashCard(carId: string, text: string, tone: string)
	local rec = cards[carId]
	if not rec then
		return
	end

	rec.flashSeq += 1
	local seq = rec.flashSeq
	rec.flashLabel.Text = text
	rec.flashLabel.TextColor3 = FLASH_TINT[tone] or UI.DANGER
	kit.popIn(rec.flash, 0.7)

	task.delay(FLASH_SECONDS, function()
		if rec.flashSeq ~= seq or not rec.flash.Parent or not rec.flash.Visible then
			return
		end
		kit.popOut(rec.flash)
	end)
end

--[[ Fires and waits. No optimistic flip: OwnedCars / EquippedCar repaint the card.
	The button dims for CLICK_LOCK seconds so a double tap cannot spend twice. ]]
local function onAction(carId: string)
	local rec = cards[carId]
	if not rec or rec.busy or rec.state == "driving" then
		return
	end
	if not net or not net.GarageAction then
		return
	end
	if player:GetAttribute(ATTR.PROFILE_LOADED) ~= true then
		kit.playSfx("DENY") -- a tap that cannot land still has to answer
		flashCard(carId, "One second...", "wait")
		return
	end

	-- Remember what we asked for; the reply cannot infer it (see the header note).
	local action = rec.state == "equip" and "equip" or "buy"
	rec.pending = action
	rec.busy = true
	refreshCard(carId)

	task.delay(CLICK_LOCK, function()
		if rec.busy then
			rec.busy = false
			refreshCard(carId)
		end
	end)

	net.GarageAction:FireServer(action, carId)
end

--[[ Server reply. Success is deliberately quiet — GarageService already fires its own
	Notify on a buy, and the card repainting to DRIVING is the equip feedback. The one
	thing worth saying is the honest mid-match caveat: the new car lands next spawn. ]]
local function onServerReply(ok, message, carId)
	if type(carId) ~= "string" then
		return
	end
	local rec = cards[carId]
	if not rec then
		return
	end

	local wasAction = rec.pending
	rec.pending = nil
	rec.busy = false
	refreshCard(carId)

	if ok == true then
		-- BUY_OK is the till, an equip is a lighter switch — never both. The "Next life!"
		-- flash below stays silent so one action still makes exactly one sound.
		kit.playSfx(wasAction == "equip" and "TOGGLE" or "BUY_OK")
		if MatchState.isMatch() and player:GetAttribute(ATTR.ALIVE) == true then
			flashCard(carId, "Next life!", "good")
		end
		return
	end

	kit.playSfx("DENY")
	local text = (type(message) == "string" and message ~= "") and message or "Not yet!"
	flashCard(carId, text, "bad")
end

-- ==========================================================================
-- §6) construction
-- ==========================================================================
local function moneyChip(parent: Instance, word: string, accent: Color3, ramp: { Color3 }, order: number): TextLabel
	local chip = Instance.new("Frame")
	chip.Name = word
	chip.Size = UDim2.fromScale(0.46, 1)
	chip.BackgroundColor3 = UI.GLASS
	chip.BackgroundTransparency = 0.12
	chip.BorderSizePixel = 0
	chip.LayoutOrder = order
	chip.Parent = parent
	kit.pill(chip)
	kit.stroke(chip, UI.STROKE, UI.INK)

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.Size = UDim2.new(1, -8, 1, -8)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.Parent = chip
	kit.pill(ring)
	kit.stroke(ring, 1.5, accent, 0.4)

	kit.label({
		parent = chip,
		name = "Word",
		text = word,
		font = kit.FONT_BOLD,
		color = accent,
		size = UDim2.new(0.42, 0, 0.5, 0),
		position = UDim2.new(0.08, 0, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		align = Enum.TextXAlignment.Left,
		cap = 14,
		stroke = 1.5,
	})

	return kit.label({
		parent = chip,
		name = "Value",
		text = "0",
		ramp = ramp,
		size = UDim2.new(0.46, 0, 0.66, 0),
		position = UDim2.new(0.94, 0, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		align = Enum.TextXAlignment.Right,
		cap = 22,
		stroke = 2.5,
	})
end

--[[ Hand-built rather than kit.button on purpose: UIKit.registerFrame attaches
	addButtonFeedback to the "Close" descendant itself, and kit.button would attach a
	second copy (double hover sound). Same house treatment, feel added once. ]]
local function buildClose(parent: Instance): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = "Close"
	btn.Size = UDim2.fromOffset(42, 42)
	btn.Position = UDim2.new(1, -14, 0, 14)
	btn.AnchorPoint = Vector2.new(1, 0)
	btn.BackgroundColor3 = UI.DANGER
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Text = "X"
	btn.Font = kit.FONT_BLACK
	btn.TextColor3 = UI.PAPER
	btn.TextScaled = true
	btn.ZIndex = 4
	btn.Parent = parent

	kit.corner(btn, UI.BUTTON_CORNER)
	kit.gradient(btn, { UI.DANGER:Lerp(UI.PAPER, 0.35), UI.DANGER, UI.DANGER:Lerp(UI.INK, 0.25) })
	kit.stroke(btn, UI.STROKE, UI.INK)
	kit.textConstraint(btn, 22)

	local labelStroke = Instance.new("UIStroke")
	labelStroke.Thickness = 2
	labelStroke.Color = UI.INK
	labelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	labelStroke.Parent = btn

	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.Size = UDim2.new(1, -8, 1, -8)
	gloss.Position = UDim2.fromScale(0.5, 0.5)
	gloss.AnchorPoint = Vector2.new(0.5, 0.5)
	gloss.BackgroundTransparency = 1
	gloss.ZIndex = 0
	gloss.Parent = btn
	kit.corner(gloss, UI.BUTTON_CORNER - 3)
	kit.stroke(gloss, 1.25, UI.PAPER, 0.55)

	return btn
end

local function buildHeader()
	header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, -86, HEADER_HEIGHT, 0)
	header.Position = UDim2.new(0, 18, 0.035, 0)
	header.BackgroundTransparency = 1
	header.Parent = panel
	headerBase = header.Position

	kit.label({
		parent = header,
		name = "Title",
		text = "GARAGE",
		size = UDim2.new(0.34, 0, 0.54, 0),
		position = UDim2.new(0, 0, 0.02, 0),
		anchor = Vector2.new(0, 0),
		align = Enum.TextXAlignment.Left,
		cap = 24,
		ramp = kit.GOLD_RAMP,
		stroke = 3,
	})

	kit.label({
		parent = header,
		name = "Tagline",
		text = "Pick your ride!",
		font = kit.FONT_BOLD,
		size = UDim2.new(0.34, 0, 0.3, 0),
		position = UDim2.new(0, 0, 0.62, 0),
		anchor = Vector2.new(0, 0),
		align = Enum.TextXAlignment.Left,
		cap = 16,
		stroke = 1.6,
	})

	local wallet = Instance.new("Frame")
	wallet.Name = "Wallet"
	wallet.Size = UDim2.new(0.54, 0, 0.58, 0)
	wallet.Position = UDim2.new(1, 0, 0.5, 0)
	wallet.AnchorPoint = Vector2.new(1, 0.5)
	wallet.BackgroundTransparency = 1
	wallet.Parent = header

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Right
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0.03, 0)
	row.Parent = wallet

	coinValue = moneyChip(wallet, "COINS", UI.GOLD_LIGHT, kit.GOLD_RAMP, 1)
	gemValue = moneyChip(wallet, "GEMS", GEM, GEM_RAMP, 2)
end

local function buildPanel()
	panel = kit.card({
		parent = frames,
		name = FRAME_NAME,
		size = UDim2.fromScale(PANEL_SCALE.X, PANEL_SCALE.Y),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		accent = UI.GOLD,
	})

	local sizeCap = Instance.new("UISizeConstraint")
	sizeCap.MaxSize = PANEL_MAX
	sizeCap.MinSize = PANEL_MIN
	sizeCap.Parent = panel

	buildHeader()
	buildClose(panel)

	gridFrame = Instance.new("ScrollingFrame")
	gridFrame.Name = "Cars"
	gridFrame.Size = UDim2.new(1, -34, GRID_HEIGHT, 0)
	gridFrame.Position = UDim2.new(0.5, 0, 0.215, 0)
	gridFrame.AnchorPoint = Vector2.new(0.5, 0)
	gridFrame.BackgroundTransparency = 1
	gridFrame.BorderSizePixel = 0
	gridFrame.ClipsDescendants = true
	gridFrame.ScrollBarThickness = 6
	gridFrame.ScrollBarImageColor3 = UI.PAPER
	gridFrame.ScrollBarImageTransparency = 0.45
	gridFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	gridFrame.CanvasSize = UDim2.new()
	gridFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	gridFrame.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	gridFrame.Parent = panel
	kit.padding(gridFrame, 6)

	gridLayout = Instance.new("UIGridLayout")
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.Parent = gridFrame
	applyFit()
	watchViewport()

	loadingLabel = kit.label({
		parent = panel,
		name = "Loading",
		text = "Loading...",
		size = UDim2.new(0.6, 0, 0.1, 0),
		position = UDim2.fromScale(0.5, 0.56),
		anchor = Vector2.new(0.5, 0.5),
		cap = 20,
		stroke = 2,
	})
end

local function buildCard(car, order: number, previewModel: Instance?)
	local accent = CarRegistry.rarityColor(car)

	-- AnchorPoint (0,0): UIGridLayout writes Position/Size assuming a top-left origin.
	local root = kit.card({
		parent = gridFrame,
		name = car.id,
		size = UDim2.fromOffset(CARD_W, CARD_H),
		position = UDim2.new(),
		anchor = Vector2.new(0, 0),
		accent = accent,
	})
	root.LayoutOrder = order

	--[[ Hover the whole card, not just its button: the card IS the choice. The stroke we
		hand bindHover is the rarity ring on kit.card's Inset (accent at 0.4 transparency),
		so it brightens to full on hover and settles back on leave — the outer stroke is
		already opaque and is owned by the equipped state. This makes the card Active;
		safe even though LobbyUI's corner button can open the garage mid-match, because
		the grid is a ScrollingFrame that already consumes drags over this area. ]]
	local inset = root:FindFirstChild("Inset")
	kit.bindHover(root, {
		scale = CARD_HOVER_SCALE,
		stroke = inset and inset:FindFirstChildOfClass("UIStroke") or nil,
	})

	-- display bay for the render
	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = UDim2.new(L.width, 0, L.wellH, 0)
	well.Position = UDim2.new(0.5, 0, L.wellY, 0)
	well.AnchorPoint = Vector2.new(0.5, 0)
	well.BackgroundColor3 = UI.PAPER
	well.BorderSizePixel = 0
	well.ClipsDescendants = true
	well.Parent = root
	kit.corner(well, UI.CARD_CORNER - 3)
	kit.gradient(well, { accent:Lerp(UI.GLASS, 0.55), UI.GLASS })
	kit.stroke(well, 1.5, accent, 0.4)

	local render = kit.viewport({
		parent = well,
		name = "Render",
		model = previewModel,
		size = UDim2.fromScale(1, 1),
		zoom = VIEW_ZOOM,
	})

	if not previewModel then
		-- Degrade, never error: a colored block in the car's own body color.
		local block = Instance.new("Frame")
		block.Name = "Placeholder"
		block.Size = UDim2.fromScale(0.66, 0.4)
		block.Position = UDim2.fromScale(0.5, 0.56)
		block.AnchorPoint = Vector2.new(0.5, 0.5)
		block.BackgroundColor3 = (car.build and car.build.bodyColor) or UI.PAPER
		block.BorderSizePixel = 0
		block.Parent = well
		kit.corner(block, 8)
		kit.stroke(block, 2, UI.INK)

		if not warnedPreview then
			warnedPreview = true
			warn("GarageUI: no preview model for '" .. tostring(car.id) .. "' — showing placeholders")
		end
	end

	local shade = Instance.new("Frame")
	shade.Name = "Lock"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = UI.INK
	shade.BackgroundTransparency = 0.55
	shade.BorderSizePixel = 0
	shade.ZIndex = 2
	shade.Parent = well

	kit.label({
		parent = shade,
		name = "Word",
		text = "LOCKED",
		size = UDim2.new(0.8, 0, 0.24, 0),
		position = UDim2.new(0.5, 0, 0.94, 0),
		anchor = Vector2.new(0.5, 1),
		cap = 14,
		stroke = 2,
	})

	kit.label({
		parent = root,
		name = "CarName",
		text = car.name,
		size = UDim2.new(0.9, 0, L.nameH, 0),
		position = UDim2.new(0.5, 0, L.nameY, 0),
		anchor = Vector2.new(0.5, 0),
		cap = 18,
		stroke = 2,
		ramp = { UI.PAPER, accent:Lerp(UI.PAPER, 0.35) },
	})

	local chip = Instance.new("Frame")
	chip.Name = "Rarity"
	chip.Size = UDim2.new(0.56, 0, L.chipH, 0)
	chip.Position = UDim2.new(0.5, 0, L.chipY, 0)
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.BackgroundColor3 = accent:Lerp(UI.INK, 0.6)
	chip.BorderSizePixel = 0
	chip.Parent = root
	kit.pill(chip)
	kit.stroke(chip, 2, UI.INK)

	kit.label({
		parent = chip,
		name = "Word",
		text = car.rarity or "COMMON",
		font = kit.FONT_BOLD,
		color = accent,
		size = UDim2.new(1, -10, 0.78, 0),
		cap = 14,
		stroke = 1.5,
	})

	local bars = CarRegistry.statBars(car)
	for i, stat in ipairs(STATS) do
		local row = Instance.new("Frame")
		row.Name = stat.label
		row.Size = UDim2.new(L.width, 0, L.statH, 0)
		row.Position = UDim2.new(0.5, 0, L.statY + (i - 1) * L.statGap, 0)
		row.AnchorPoint = Vector2.new(0.5, 0)
		row.BackgroundTransparency = 1
		row.Parent = root

		kit.label({
			parent = row,
			name = "Word",
			text = stat.label,
			font = kit.FONT_BOLD,
			size = UDim2.new(0.31, 0, 1, 0),
			position = UDim2.fromScale(0, 0.5),
			anchor = Vector2.new(0, 0.5),
			align = Enum.TextXAlignment.Left,
			cap = 13,
			stroke = 1.2,
		})

		local _, setFill = kit.bar({
			parent = row,
			name = "Track",
			size = UDim2.new(0.66, 0, 0.6, 0),
			position = UDim2.new(1, 0, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			color = stat.color,
		})
		setFill(bars[stat.key] or 0)
	end

	local special = Config.POWERUPS[car.special]
	kit.label({
		parent = root,
		name = "Special",
		text = special and ("Loves: " .. special.name) or "Loves: Crates",
		font = kit.FONT_BOLD,
		color = special and special.color or UI.PAPER,
		size = UDim2.new(0.9, 0, L.loveH, 0),
		position = UDim2.new(0.5, 0, L.loveY, 0),
		anchor = Vector2.new(0.5, 0),
		cap = 15,
		stroke = 1.6,
	})

	local button = kit.button({
		parent = root,
		name = "Action",
		text = CarRegistry.priceText(car),
		size = UDim2.new(L.width, 0, L.btnH, 0),
		position = UDim2.new(0.5, 0, L.btnY, 0),
		anchor = Vector2.new(0.5, 0),
		accent = UI.GOLD,
		textCap = 16,
		onClick = function()
			onAction(car.id)
		end,
	})

	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.new(0.94, 0, L.btnH, 0)
	flash.Position = UDim2.new(0.5, 0, L.btnY, 0)
	flash.AnchorPoint = Vector2.new(0.5, 0)
	flash.BackgroundColor3 = UI.GLASS
	flash.BackgroundTransparency = 0.08
	flash.BorderSizePixel = 0
	flash.ZIndex = 3
	flash.Visible = false
	flash.Parent = root
	kit.corner(flash, UI.BUTTON_CORNER)
	kit.stroke(flash, 2, UI.INK)

	local flashLabel = kit.label({
		parent = flash,
		name = "Word",
		text = "",
		font = kit.FONT_BOLD,
		color = UI.DANGER,
		size = UDim2.new(1, -10, 0.84, 0),
		cap = 14,
		stroke = 1.6,
	})

	cards[car.id] = {
		car = car,
		root = root,
		render = render,
		shade = shade,
		button = button,
		stroke = root:FindFirstChildOfClass("UIStroke"),
		flash = flash,
		flashLabel = flashLabel,
		flashSeq = 0,
		busy = false,
		order = order,
		state = "buy",
	}
end

-- Previews are published by CarFactory at server init, so they may not exist yet.
local function previewFolder(): Instance?
	local assets = core:FindFirstChild("Assets") or core:WaitForChild("Assets", PREVIEW_TIMEOUT)
	if not assets then
		return nil
	end
	return assets:FindFirstChild("Previews") or assets:WaitForChild("Previews", PREVIEW_TIMEOUT)
end

local function buildCards()
	if cardsBuilt then
		return
	end

	local folder = previewFolder()
	-- previewFolder() yields: the GUI could have been torn down underneath us.
	if not panel or not panel.Parent or not gridFrame then
		return
	end
	cardsBuilt = true

	local roster = CarRegistry.all()
	for i, car in ipairs(roster) do
		local model = nil
		if folder then
			-- Only the first lookup waits; publishPreviews() writes them in one pass.
			model = folder:FindFirstChild(car.id) or (i == 1 and folder:WaitForChild(car.id, 2) or nil)
		end
		buildCard(car, i, model)
		refreshCard(car.id)
	end

	if loadingLabel then
		loadingLabel:Destroy()
		loadingLabel = nil
	end
end

-- ==========================================================================
-- §7) motion — alive only while the panel is on screen
-- ==========================================================================
local function stopMotion()
	for _, conn in ipairs(motionConns) do
		conn:Disconnect()
	end
	table.clear(motionConns)
	if header and headerBase then
		header.Position = headerBase
	end
end

local function startMotion()
	if #motionConns > 0 then
		return
	end

	local t = 0
	table.insert(
		motionConns,
		RunService.RenderStepped:Connect(function(dt)
			if not panel.Visible then
				return
			end
			t += dt
			header.Position = headerBase + UDim2.fromOffset(0, MathUtil.drift(t, DRIFT_FREQ, 0.4, DRIFT_AMP))
		end)
	)

	for _, rec in pairs(cards) do
		table.insert(motionConns, kit.spinViewport(rec.render, SPIN_DPS + rec.order * SPIN_STAGGER))
	end
end

-- ==========================================================================
-- §8) init
-- ==========================================================================
function GarageUI.init(ctx)
	kit = ctx and ctx.kit
	net = ctx and ctx.net
	frames = ctx and ctx.frames
	if not kit or not frames then
		warn("GarageUI: ctx is missing kit or frames — garage not built")
		return
	end

	buildPanel()
	kit.registerFrame(FRAME_NAME, panel) -- hides it and wires Close + pop in/out
	refreshMoney()

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible then
			startMotion()
		else
			stopMotion()
		end
	end)

	-- Reactive repaint: the server's attributes are the only source of truth here.
	player:GetAttributeChangedSignal(ATTR.COINS):Connect(function()
		refreshMoney()
		refreshAllCards()
	end)
	player:GetAttributeChangedSignal(ATTR.GEMS):Connect(function()
		refreshMoney()
		refreshAllCards()
	end)
	player:GetAttributeChangedSignal(ATTR.OWNED):Connect(refreshAllCards)
	player:GetAttributeChangedSignal(ATTR.EQUIPPED):Connect(refreshAllCards)

	if net and net.GarageAction then
		net.GarageAction.OnClientEvent:Connect(onServerReply)
	else
		warn("GarageUI: GarageAction remote missing — cards cannot buy or equip")
	end

	-- First paint waits for the profile: drawing prices against Coins = 0 would lie.
	local function paintWhenReady()
		task.spawn(function()
			buildCards()
			refreshMoney()
			if panel.Visible then
				-- Opened while we were waiting: pick up the new viewports.
				stopMotion()
				startMotion()
			end
		end)
	end

	if player:GetAttribute(ATTR.PROFILE_LOADED) == true then
		paintWhenReady()
	else
		local conn
		conn = player:GetAttributeChangedSignal(ATTR.PROFILE_LOADED):Connect(function()
			if player:GetAttribute(ATTR.PROFILE_LOADED) ~= true then
				return
			end
			conn:Disconnect()
			paintWhenReady()
		end)
	end
end

return GarageUI
