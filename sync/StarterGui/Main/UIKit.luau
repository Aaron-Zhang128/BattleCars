--[[ UIKit
	The shared UI contract. Every UI module builds through these helpers so the whole
	game reads as one system: same fonts, same INK strokes, same pop timings, same button feel.

	Owned by the orchestrator — UI modules CONSUME this, they do not edit it.

	Sections:
		§1  palette + font constants
		§2  primitives (corner, stroke, gradient, scale)
		§3  button feel (addButtonFeedback)
		§4  pop in / pop out
		§5  component recipes (screen, card, button, label, pill, bar, segmentBar)
		§6  frame manager (register / open / close)
		§7  notifications
		§8  viewport render (real model, 3/4 front-left)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CrashCore"):WaitForChild("Config"))

local UIKit = {}

-- ==========================================================================
-- §1) palette + fonts
-- ==========================================================================
local UI = Config.UI

UIKit.INK = UI.INK
UIKit.PAPER = UI.PAPER
UIKit.GLASS = UI.GLASS
UIKit.GOLD = UI.GOLD
UIKit.GOLD_LIGHT = UI.GOLD_LIGHT
UIKit.GOLD_DEEP = UI.GOLD_DEEP
UIKit.LIME = UI.LIME
UIKit.CONFIRM = UI.CONFIRM
UIKit.DANGER = UI.DANGER
UIKit.RARITY = UI.RARITY
UIKit.DISPLAY_ORDER = UI.DISPLAY_ORDER

UIKit.FONT_BLACK = Enum.Font.GothamBlack
UIKit.FONT_BOLD = Enum.Font.GothamBold

UIKit.GOLD_RAMP = { UI.GOLD_LIGHT, UI.GOLD, UI.GOLD_DEEP }
UIKit.MOOD_RAMPS = {
	red = { Color3.fromRGB(255, 176, 158), Color3.fromRGB(255, 72, 48), Color3.fromRGB(158, 12, 8) },
	green = { Color3.fromRGB(182, 255, 178), Color3.fromRGB(72, 224, 96), Color3.fromRGB(16, 128, 46) },
	gold = { Color3.fromRGB(255, 236, 170), Color3.fromRGB(255, 196, 64), Color3.fromRGB(176, 120, 8) },
}

local POP_IN_INFO = TweenInfo.new(UI.POP_IN.time, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT_INFO = TweenInfo.new(UI.POP_OUT.time, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_INFO = TweenInfo.new(UI.HOVER_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(UI.PRESS_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ==========================================================================
-- §2) primitives
-- ==========================================================================
function UIKit.corner(parent: Instance, radius: number?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or UI.CARD_CORNER)
	c.Parent = parent
	return c
end

function UIKit.pill(parent: Instance): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = parent
	return c
end

function UIKit.stroke(parent: Instance, thickness: number?, color: Color3?, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or UI.STROKE
	s.Color = color or UI.INK
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- Vertical gradient (house default Rotation 90) from a list of 2-4 colors.
function UIKit.gradient(parent: Instance, colors: { Color3 }, rotation: number?): UIGradient
	local keys = {}
	local n = #colors
	for i, color in ipairs(colors) do
		table.insert(keys, ColorSequenceKeypoint.new(n == 1 and 0 or (i - 1) / (n - 1), color))
	end
	if n == 1 then
		table.insert(keys, ColorSequenceKeypoint.new(1, colors[1]))
	end

	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(keys)
	g.Rotation = rotation or 90
	g.Parent = parent
	return g
end

-- One UIScale per element, reused. All motion goes through this, never Size.
function UIKit.ensureScale(inst: Instance): UIScale
	local existing = inst:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Parent = inst
	return s
end

function UIKit.textConstraint(label: Instance, maxSize: number, minSize: number?): UITextSizeConstraint
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = maxSize
	c.MinTextSize = minSize or 8
	c.Parent = label
	return c
end

function UIKit.padding(parent: Instance, px: number): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.Parent = parent
	return p
end

-- ==========================================================================
-- §3) button feel — hover x1.07 / press x0.92, with sound
-- ==========================================================================
local function playSound(id: string, volume: number, pitch: number)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = pitch
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	-- Safety net only; Ended fires first for anything shorter. 8s clears the longest
	-- cue in the kit (Random/Wheel Spin, 9.04s is deliberately excluded from playSfx).
	task.delay(8, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

--[[ §3b) SOUND KIT — the game's own library, at the previously SHIPPED balance.
	Every id is from SoundService.GameSFX, the sound library already in this place, and
	every level here is lifted from the tuning that shipped in Alternate.Main lines 940-971
	and 3574-3593 — not guessed. That script is disabled, but it is the record of what
	these samples were balanced to, so read it before re-tuning anything below.

	THE ONE CONVERSION TO REMEMBER: the shipped code routed every sound through the
	GameSFX SoundGroup, whose authored Volume is 0.5, so its numbers are TWICE what they
	sound like. playSfx here builds an ungrouped Sound (which is what lets SettingsUI's
	"Menu Sounds" bus adopt it), so every volume below is the shipped value HALVED.
	Shipped 1.6 click -> 0.80 here. Multiply by 2 before comparing to that script.

	Corrections it forced on a first pass done by ear-free guesswork:
	  * HOVER is the CLICK tick pitched up to ~1.5 and dropped to about half volume, not a
	    different sample. Ticker is the spinner's per-slice tick (0.3), never a hover.
	  * Everything was pitched far too quiet. Click shipped at 1.6, Kaching at 3.

	DELIBERATELY NOT USED: GameSFX's 220hz / 440hz / 880hz read like ideal UI blips and are
	10-SECOND SUSTAINED TONES; one hover would drone until the cleanup timer killed it.
	Clock Ticking (5.6s), Heartbeat (14.9s) and Random/Wheel Spin (9.0s) are the same trap —
	measure TimeLength before adopting anything else from that folder.

	GameSFX itself is never touched: adopting into it would apply that 0.5 a second time.
	Swap an id here and the whole game follows. ]]
UIKit.SFX = {
	--[[ UI. The shipped kit proved one idea: there is ONE ui sound, the Click tick, and
		everything else is that tick at a different pitch and weight. Open/close/toggle
		follow the same rule here rather than introducing new samples. ]]
	HOVER = { id = "rbxassetid://108127985603309", volume = 0.45, pitch = { 1.46, 1.54 } },
	CLICK = { id = "rbxassetid://108127985603309", volume = 0.80, pitch = { 0.98, 1.03 } },
	TOGGLE = { id = "rbxassetid://108127985603309", volume = 0.65, pitch = { 0.84, 0.90 } },
	OPEN = { id = "rbxassetid://108127985603309", volume = 0.70, pitch = { 1.10, 1.16 } },
	CLOSE = { id = "rbxassetid://108127985603309", volume = 0.60, pitch = { 0.86, 0.92 } },

	-- Money. Kaching is the full register; Cash is a quiet 0.7s stub, which is exactly
	-- why it suits a crown chime that can fire several times a second and Kaching does not.
	BUY_OK = { id = "rbxassetid://91318974453588", volume = 1.50, pitch = { 1.00, 1.00 } },
	REWARD = { id = "rbxassetid://359623376", volume = 1.20, pitch = { 1.05, 1.15 } },

	DENY = { id = "rbxassetid://111912485125241", volume = 0.50, pitch = { 0.95, 1.02 } },
	TICK = { id = "rbxassetid://6042053626", volume = 0.18, pitch = { 1.00, 1.10 } },
	THUD = { id = "rbxassetid://140626490819228", volume = 0.60, pitch = { 0.95, 1.05 } },
	IMPACT = { id = "rbxassetid://140626490819228", volume = 0.70, pitch = { 0.88, 1.00 } },

	--[[ Moments, at the shipped balance. VICTORY was played LOUDER when the win was
		yours (1.6 vs 1.15 before the group scale) — worth reproducing with a volumeScale
		of about 1.4 on the local player's own win rather than a second entry. ]]
	VICTORY = { id = "rbxassetid://127039883737564", volume = 0.58, pitch = { 1.00, 1.00 } },
	LOSE = { id = "rbxassetid://125623877509633", volume = 0.50, pitch = { 1.00, 1.00 } },
	KILL = { id = "rbxassetid://93866204681438", volume = 0.50, pitch = { 1.00, 1.00 } },
	SPIN_START = { id = "rbxassetid://117570443671176", volume = 0.30, pitch = { 1.00, 1.00 } },
	DRUMROLL = { id = "rbxassetid://4398694764", volume = 0.20, pitch = { 1.00, 1.00 } },
	REVEAL = { id = "rbxassetid://80736831159506", volume = 0.55, pitch = { 1.00, 1.00 } },
	BIG_REVEAL = { id = "rbxassetid://8389878748", volume = 0.60, pitch = { 1.00, 1.00 } },
	COUNT = { id = "rbxassetid://124541655253143", volume = 0.45, pitch = { 1.00, 1.00 } },
	CONFIRM = { id = "rbxassetid://91250397348244", volume = 0.50, pitch = { 1.00, 1.08 } },
}

UIKit.SOUND_HOVER = UIKit.SFX.HOVER.id
UIKit.SOUND_CLICK = UIKit.SFX.CLICK.id

local sfxLastAt = {}
local SFX_MIN_GAP = 0.04 -- one name cannot machine-gun while hovering across a grid

--[[ Plays a named entry from UIKit.SFX. Pitch is randomised inside the entry's range so
	repeats never sound robotic. Rate-limited per name; safe to call from a hover handler. ]]
function UIKit.playSfx(name: string, volumeScale: number?)
	local def = UIKit.SFX[name]
	if not def then
		warn("UIKit.playSfx: unknown sfx '" .. tostring(name) .. "'")
		return
	end
	local now = os.clock()
	if (sfxLastAt[name] or 0) + SFX_MIN_GAP > now then
		return
	end
	sfxLastAt[name] = now
	local lo, hi = def.pitch[1], def.pitch[2]
	playSound(def.id, def.volume * (volumeScale or 1), lo + math.random() * (hi - lo))
end

function UIKit.addButtonFeedback(btn: Instance)
	local scale = UIKit.ensureScale(btn)
	local hovering = false

	local function to(target: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = target }):Play()
	end

	btn.MouseEnter:Connect(function()
		hovering = true
		to(UI.HOVER_SCALE, HOVER_INFO)
		UIKit.playSfx("HOVER")
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		to(1, HOVER_INFO)
	end)
	btn.MouseButton1Down:Connect(function()
		to(UI.PRESS_SCALE, PRESS_INFO)
	end)
	btn.MouseButton1Up:Connect(function()
		to(hovering and UI.HOVER_SCALE or 1, PRESS_INFO)
	end)
	btn.Activated:Connect(function()
		UIKit.playSfx("CLICK")
	end)

	return btn
end

--[[ Hover feedback for anything that is NOT a GuiButton — cards, list rows, stat tiles.
	GuiObjects only fire MouseEnter/Leave when Active, so this sets Active itself.
	NEVER call this on an element in the LEFT HALF of the screen during a match:
	InputController captures that whole half for touch steering, and an Active element
	there swallows the drag and makes the game undriveable on a phone.
	opts = { scale, sfx (name or false to silence), stroke (UIStroke to brighten) } ]]
function UIKit.bindHover(inst: GuiObject, opts)
	opts = opts or {}
	local scaleTarget = opts.scale or UI.HOVER_SCALE
	local scale = UIKit.ensureScale(inst)
	inst.Active = true
	local stroke = opts.stroke
	local baseTransparency = stroke and stroke.Transparency or 0
	inst.MouseEnter:Connect(function()
		TweenService:Create(scale, HOVER_INFO, { Scale = scaleTarget }):Play()
		if stroke then
			TweenService:Create(stroke, HOVER_INFO, { Transparency = 0 }):Play()
		end
		if opts.sfx ~= false then
			UIKit.playSfx(opts.sfx or "HOVER")
		end
	end)
	inst.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_INFO, { Scale = 1 }):Play()
		if stroke then
			TweenService:Create(stroke, HOVER_INFO, { Transparency = baseTransparency }):Play()
		end
	end)
	return inst
end

-- ==========================================================================
-- §4) pop in / pop out
-- ==========================================================================
function UIKit.popIn(inst: Instance, from: number?)
	local scale = UIKit.ensureScale(inst)
	scale.Scale = from or UI.POP_IN.from
	inst.Visible = true
	TweenService:Create(scale, POP_IN_INFO, { Scale = 1 }):Play()
end

function UIKit.popOut(inst: Instance, onDone: (() -> ())?)
	local scale = UIKit.ensureScale(inst)
	local tween = TweenService:Create(scale, POP_OUT_INFO, { Scale = UI.POP_OUT.to })
	tween.Completed:Once(function()
		inst.Visible = false
		scale.Scale = 1
		if onDone then
			onDone()
		end
	end)
	tween:Play()
end

-- ==========================================================================
-- §5) component recipes
-- ==========================================================================
function UIKit.screen(name: string, displayOrder: number): ScreenGui
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

--[[ House card: PAPER body, sheen gradient, INK stroke, inset accent ring.
	opts = { parent, size (UDim2), position, anchor, accent (Color3), corner } ]]
function UIKit.card(opts): Frame
	local accent = opts.accent or UI.GOLD
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "Card"
	frame.Size = opts.size or UDim2.fromOffset(150, 118)
	frame.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	frame.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	frame.BackgroundColor3 = UI.PAPER
	frame.BorderSizePixel = 0
	frame.Parent = opts.parent

	UIKit.corner(frame, opts.corner or UI.CARD_CORNER)
	UIKit.gradient(frame, { accent:Lerp(UI.GLASS, 0.8), UI.GLASS })
	UIKit.stroke(frame, UI.STROKE, UI.INK)

	local inset = Instance.new("Frame")
	inset.Name = "Inset"
	inset.Size = UDim2.new(1, -12, 1, -12)
	inset.Position = UDim2.fromScale(0.5, 0.5)
	inset.AnchorPoint = Vector2.new(0.5, 0.5)
	inset.BackgroundTransparency = 1
	inset.Parent = frame
	UIKit.corner(inset, (opts.corner or UI.CARD_CORNER) - 3)
	UIKit.stroke(inset, 1.5, accent, 0.4)

	return frame
end

--[[ House button: gold/accent ramp, INK stroke, glossy inner bevel, GothamBlack label.
	opts = { parent, text, size, position, anchor, accent, onClick, textCap } ]]
function UIKit.button(opts): TextButton
	local accent = opts.accent or UI.GOLD
	local btn = Instance.new("TextButton")
	btn.Name = opts.name or "Button"
	btn.Size = opts.size or UDim2.fromOffset(160, 46)
	btn.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	btn.BackgroundColor3 = accent
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Text = opts.text or ""
	btn.Font = UIKit.FONT_BLACK
	btn.TextColor3 = UI.PAPER
	btn.TextScaled = true
	btn.Parent = opts.parent

	UIKit.corner(btn, UI.BUTTON_CORNER)
	UIKit.gradient(btn, { accent:Lerp(UI.PAPER, 0.35), accent, accent:Lerp(UI.INK, 0.25) })
	UIKit.stroke(btn, UI.STROKE, UI.INK)
	UIKit.textConstraint(btn, opts.textCap or 16)

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
	UIKit.corner(gloss, UI.BUTTON_CORNER - 3)
	UIKit.stroke(gloss, 1.25, UI.PAPER, 0.55)

	UIKit.addButtonFeedback(btn)
	if opts.onClick then
		btn.Activated:Connect(opts.onClick)
	end
	return btn
end

--[[ opts = { parent, text, size, position, anchor, cap, font, color, ramp, align, stroke } ]]
function UIKit.label(opts): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = opts.name or "Label"
	lbl.Size = opts.size or UDim2.fromScale(1, 1)
	lbl.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	lbl.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	lbl.BackgroundTransparency = 1
	lbl.Text = opts.text or ""
	lbl.Font = opts.font or UIKit.FONT_BLACK
	lbl.TextColor3 = opts.color or UI.PAPER
	lbl.TextScaled = true
	lbl.TextXAlignment = opts.align or Enum.TextXAlignment.Center
	lbl.Parent = opts.parent

	UIKit.textConstraint(lbl, opts.cap or 20)
	-- Contextual, NOT the Border default UIKit.stroke applies: on a transparent
	-- TextLabel, Border draws an INK rectangle around the label instead of
	-- outlining the glyphs. The house look is an outlined glyph.
	local textStroke = UIKit.stroke(lbl, opts.stroke or 2, UI.INK)
	textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	if opts.ramp then
		UIKit.gradient(lbl, opts.ramp)
	end
	return lbl
end

--[[ Rounded progress/health bar. Returns track, setFill(fraction).
	NOTE: defaults to AnchorPoint (0.5,0.5) like every other recipe here. Inside a
	UIListLayout that offsets the track by half its size — pass anchor = Vector2.new(0,0)
	when laying bars out in a list. ]]
function UIKit.bar(opts)
	local track = Instance.new("Frame")
	track.Name = opts.name or "Bar"
	track.Size = opts.size or UDim2.fromOffset(160, 14)
	track.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	track.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	track.BackgroundColor3 = UI.GLASS
	track.BorderSizePixel = 0
	track.Parent = opts.parent
	UIKit.pill(track)
	UIKit.stroke(track, 2, UI.INK)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = opts.color or UI.CONFIRM
	fill.BorderSizePixel = 0
	fill.Parent = track
	UIKit.pill(fill)
	UIKit.gradient(fill, { (opts.color or UI.CONFIRM):Lerp(UI.PAPER, 0.4), opts.color or UI.CONFIRM })

	local function setFill(fraction: number)
		fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
		fill.Visible = fraction > 0.001
	end

	return track, setFill
end

--[[ Segmented health bar — one CELL per `perSegment` points, so damage reads as
	chunks knocked off rather than as a smoothly sliding fraction. Returns
	track, setValue(value, maxValue).

	The cell layout is rebuilt ONLY when maxValue changes (a car swap), never per hit:
	a chunked bar that re-instantiated its cells on every point of damage would rebuild
	itself several times a second under machine-gun fire.

	A maxValue that is not a whole multiple of perSegment gets a NARROWER final cell
	holding the remainder, so one full-width cell always means the same amount of
	health no matter which car you are in — the whole point of chunking it. ]]
function UIKit.segmentBar(opts)
	local perSegment = opts.perSegment or 100
	local maxCells = opts.maxCells or 12 -- past this, cells get too thin to read
	local gap = opts.gap or 3
	local inset = opts.inset or 3
	local baseColor = opts.color or UI.CONFIRM
	local emptyColor = opts.emptyColor or UI.INK
	local cellRadius = opts.cellRadius or 3
	local ramp = opts.ramp -- optional (fraction) -> Color3, re-applied on every setValue

	local track = Instance.new("Frame")
	track.Name = opts.name or "SegmentBar"
	track.Size = opts.size or UDim2.fromOffset(220, 18)
	track.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	track.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	track.BackgroundColor3 = opts.trackColor or UI.GLASS
	track.BorderSizePixel = 0
	track.Parent = opts.parent
	UIKit.corner(track, opts.radius or 6)
	UIKit.stroke(track, opts.stroke or UI.STROKE, UI.INK)

	-- Cells live inside an inset row so they never sit under the INK stroke.
	local row = Instance.new("Frame")
	row.Name = "Cells"
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.5)
	row.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
	row.BackgroundTransparency = 1
	row.Parent = track

	local cells = {}
	local builtFor = -1

	--[[ Widths are scale MINUS a proportional share of the total gap, and each cell's
		X position adds that share back, so the row always ends exactly flush with its
		right edge whatever the cell count or the bar's pixel width. ]]
	local function rebuild(maxValue: number)
		for _, cell in ipairs(cells) do
			cell.frame:Destroy()
		end
		table.clear(cells)

		local count = math.ceil(maxValue / perSegment)
		local per = perSegment
		if count > maxCells then
			count = maxCells
			per = maxValue / count -- degraded: a cell stops meaning exactly perSegment
		end
		local totalGap = gap * (count - 1)
		local cursor = 0

		for i = 1, count do
			local capacity = math.min(per, maxValue - (i - 1) * per)
			local width = capacity / maxValue

			local frame = Instance.new("Frame")
			frame.Name = "Cell" .. i
			frame.Size = UDim2.new(width, -totalGap * width, 1, 0)
			frame.Position = UDim2.new(cursor, -totalGap * cursor + gap * (i - 1), 0, 0)
			frame.BackgroundColor3 = emptyColor
			frame.BorderSizePixel = 0
			frame.ClipsDescendants = true
			frame.Parent = row
			UIKit.corner(frame, cellRadius)

			local fill = Instance.new("Frame")
			fill.Name = "Fill"
			fill.Size = UDim2.fromScale(1, 1)
			fill.BackgroundColor3 = baseColor
			fill.BorderSizePixel = 0
			fill.Parent = frame
			UIKit.corner(fill, cellRadius)
			-- A WHITE->GREY gradient tints multiplicatively, so this sheen survives the
			-- runtime recolour a colour-pair gradient (like UIKit.bar's) would fight.
			UIKit.gradient(fill, { Color3.fromRGB(255, 255, 255), Color3.fromRGB(186, 186, 186) })

			table.insert(cells, { frame = frame, fill = fill, capacity = capacity })
			cursor += width
		end
		builtFor = maxValue
	end

	local function setValue(value: number, maxValue: number?)
		local maxV = math.max(tonumber(maxValue) or builtFor, 1)
		if maxV ~= builtFor then
			rebuild(maxV)
		end
		local v = math.clamp(tonumber(value) or 0, 0, maxV)
		local color = ramp and ramp(v / maxV) or baseColor
		local remaining = v
		for _, cell in ipairs(cells) do
			local filled = math.clamp(remaining / cell.capacity, 0, 1)
			cell.fill.Size = UDim2.fromScale(filled, 1)
			cell.fill.Visible = filled > 0.001
			cell.fill.BackgroundColor3 = color
			remaining -= cell.capacity
		end
	end

	rebuild(perSegment)
	return track, setValue
end

-- ==========================================================================
-- §6) frame manager — modal windows live under StarterGui.Main.Frames
-- ==========================================================================
local registered: { [string]: Instance } = {}
local openName: string? = nil

--[[ Registers a modal frame. Requires a descendant GuiButton named "Close".
	Starts hidden. Only one registered frame is open at a time. ]]
function UIKit.registerFrame(name: string, frame: Instance)
	registered[name] = frame
	frame.Visible = false

	local close = frame:FindFirstChild("Close", true)
	if close and close:IsA("GuiButton") then
		UIKit.addButtonFeedback(close)
		close.Activated:Connect(function()
			UIKit.closeFrame(name)
		end)
	else
		warn("UIKit.registerFrame: '" .. name .. "' has no descendant GuiButton named Close")
	end
end

--[[ True once a module has registered this frame name. RailUI hides any rail button
	whose window did not load, rather than leaving a dead button on screen. ]]
function UIKit.isFrameRegistered(name: string): boolean
	return registered[name] ~= nil
end

function UIKit.openFrame(name: string)
	local frame = registered[name]
	if not frame then
		warn("UIKit.openFrame: unknown frame '" .. tostring(name) .. "'")
		return
	end
	if openName and openName ~= name then
		UIKit.closeFrame(openName)
	end
	openName = name
	UIKit.playSfx("OPEN")
	UIKit.popIn(frame)
end

function UIKit.closeFrame(name: string)
	local frame = registered[name]
	if not frame or not frame.Visible then
		return
	end
	if openName == name then
		openName = nil
	end
	UIKit.playSfx("CLOSE")
	UIKit.popOut(frame)
end

function UIKit.isFrameOpen(name: string?): boolean
	if name then
		return openName == name
	end
	return openName ~= nil
end

function UIKit.toggleFrame(name: string)
	if openName == name then
		UIKit.closeFrame(name)
	else
		UIKit.openFrame(name)
	end
end

-- ==========================================================================
-- §7) notifications — 4s life, max 5, newest on top
-- ==========================================================================
local notifGui: ScreenGui? = nil
local notifList: Frame? = nil
local notifCount = 0
local notifSeq = 0

local function ensureNotifGui()
	if notifGui then
		return
	end
	notifGui = UIKit.screen("CrashNotifications", UI.DISPLAY_ORDER.NOTIF)

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Size = UDim2.fromScale(0.34, 0.5)
	-- 0.16, not 0.08: HudUI reserves the top-centre band (crown counter + round timer)
	list.Position = UDim2.new(0.5, 0, 0.16, 0)
	list.AnchorPoint = Vector2.new(0.5, 0)
	list.BackgroundTransparency = 1
	list.Parent = notifGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	notifList = list
end

--[[ mood = "gold" | "green" | "red". Copy stays ~5 words, kid-simple. ]]
function UIKit.notify(text: string, mood: string?)
	ensureNotifGui()
	if notifCount >= UI.NOTIF_MAX then
		local oldest, oldestOrder = nil, -math.huge
		for _, child in ipairs(notifList:GetChildren()) do
			if child:IsA("Frame") and child.LayoutOrder > oldestOrder then
				oldest, oldestOrder = child, child.LayoutOrder
			end
		end
		if oldest then
			oldest:Destroy()
			notifCount -= 1
		end
	end

	notifSeq += 1
	notifCount += 1

	local ramp = UIKit.MOOD_RAMPS[mood or "gold"] or UIKit.MOOD_RAMPS.gold

	local toast = Instance.new("Frame")
	toast.Name = "Toast"
	toast.Size = UDim2.fromOffset(340, 46)
	toast.BackgroundColor3 = UI.GLASS
	toast.BackgroundTransparency = 0.15
	toast.BorderSizePixel = 0
	toast.LayoutOrder = -notifSeq -- newest on top
	toast.Parent = notifList
	UIKit.corner(toast, UI.CARD_CORNER)
	UIKit.stroke(toast, UI.STROKE, UI.INK)

	UIKit.label({
		parent = toast,
		text = text,
		size = UDim2.new(1, -16, 1, -10),
		cap = 22,
		ramp = ramp,
		stroke = 2.5,
	})

	UIKit.popIn(toast, 0.6)

	task.delay(UI.NOTIF_LIFETIME, function()
		if not toast.Parent then
			return
		end
		local fade = TweenService:Create(
			toast,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		fade.Completed:Once(function()
			if toast.Parent then
				toast:Destroy()
				notifCount -= 1
			end
		end)
		fade:Play()
	end)
end

-- ==========================================================================
-- §8) viewport render — real model, 3/4 front-left. MANDATORY for car imagery.
-- ==========================================================================
function UIKit.viewport(opts): ViewportFrame
	local vp = Instance.new("ViewportFrame")
	vp.Name = opts.name or "Render"
	vp.Size = opts.size or UDim2.fromScale(1, 1)
	vp.Position = opts.position or UDim2.fromScale(0.5, 0.5)
	vp.AnchorPoint = opts.anchor or Vector2.new(0.5, 0.5)
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromRGB(165, 160, 155)
	vp.LightColor = Color3.fromRGB(255, 250, 240)
	vp.LightDirection = Vector3.new(-0.4, -1, -0.6)
	vp.Parent = opts.parent

	local cam = Instance.new("Camera")
	cam.FieldOfView = 40
	cam.Parent = vp
	vp.CurrentCamera = cam

	if opts.model then
		local clone = opts.model:Clone()
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
			elseif d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("Script") or d:IsA("LocalScript") then
				d:Destroy()
			end
		end
		clone.Parent = vp
		if clone.PrimaryPart then
			clone:PivotTo(CFrame.new())
		end

		local _, size = clone:GetBoundingBox()
		local center = clone:GetBoundingBox().Position
		-- 1.55, not the DNA's 0.72: at this ViewportFrame's FOV 40 the 0.72 distance
		-- crops every car in the roster (bounding sphere overflows the frame ~1.9x).
		-- Measured by projecting each car's bounding-box corners through a full 360 spin.
		local dist = size.Magnitude * (opts.zoom or 1.55)
		local dir = Vector3.new(-0.55, 0.42, -1).Unit
		cam.CFrame = CFrame.lookAt(center + dir * dist, center)
	end

	return vp
end

-- Spins the model inside a viewport with manual RenderStepped math (house rule: no TweenService loops).
function UIKit.spinViewport(vp: ViewportFrame, degreesPerSecond: number?): RBXScriptConnection
	local speed = degreesPerSecond or 40
	local t = 0
	return RunService.RenderStepped:Connect(function(dt)
		if not vp.Visible or not vp.Parent then
			return
		end
		local model = vp:FindFirstChildOfClass("Model")
		if not model then
			return
		end
		t += dt
		model:PivotTo(CFrame.Angles(0, math.rad((t * speed) % 360), 0))
	end)
end

return UIKit
