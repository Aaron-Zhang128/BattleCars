--[[ HudUI
	The always-on match HUD: lives, powerup slot, speedometer, HP bar, mini leaderboard
	and kill feed. The top-centre crown counter and round clock were REMOVED on request —
	all that is left of them is the crown chime and the last-ten-seconds tick.
	Shown ONLY during the Match phase; popped away in Lobby and Results.

	READS (this module writes nothing — no remotes fired, no attributes set):
		Player attributes   Config.ATTR.CROWNS, LIVES, POWERUP, POWERUP_AMMO
		Car attributes      ChassisSpec.ATTR.HP / MAX_HP on the local car model
		Match state         MatchState.getPhase() / timeLeft() / formatClock()
		Remotes (S->C)      MatchEvent "crown" | "kill" | "board"
		                    CarLifecycle "spawned" | "destroyed"
		Controllers         ChassisController.getSpeedFraction() / getSpeed() / getCar()
		                    resolved LAZILY and tolerated missing (shows 0)

	LAYOUT — deliberately clear of InputController's touch zones. It owns the bottom-LEFT
	(stick + brake) and bottom-RIGHT (fire + drift) corners, and its SteerZone captures the
	ENTIRE LEFT HALF of the screen — so this HUD contains NO GuiButton and sets Active
	nowhere. Every element is a plain Frame or TextLabel, which passes touches straight
	through. The stack lives in the top band and the bottom CENTRE, slim enough to fit
	between the two touch clusters on the narrowest phone viewport.

	MOTION — exactly ONE RenderStepped connection drives every looped animation with
	manual sine math (house rule: never TweenService for loops). One-shot punches,
	slides and fades use tweens.

	SOUND — three moments, every one deduped ABOVE UIKit's 0.04s per-name floor, because
	each can fire many times a second: crowns chime REWARD at most once per CROWN_SFX_GAP,
	the final ten seconds TICK once per whole second keyed on the second VALUE, and a
	gained powerup TOGGLEs only when LuckyUI's reel is NOT on screen (a spin-granted
	weapon is already paid off by the reel's own REWARD). Losing a life is deliberately
	SILENT — see §5.

	STILL NOTHING ACTIVE. No element here is passed to kit.bindHover. This HUD is up while
	driving and InputController's SteerZone owns the ENTIRE LEFT HALF as a TextButton at
	DisplayOrder 4, below our 5 — so one Active frame here would eat a steering drag.
	Audio was added without making a single element interactive.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))

local UI = Config.UI
local ATTR = Config.ATTR
local CAR_ATTR = ChassisSpec.ATTR
local PHASES = MatchState.PHASES

local player = Players.LocalPlayer

local HudUI = {}

-- ==========================================================================
-- §1) constants
-- ==========================================================================
local TOP_INSET = 44 -- clears the Roblox topbar
local SIDE_INSET = 18
local BOTTOM_INSET = 48 -- house bottom-HUD offset


local TIMER_DANGER_SECONDS = 10 -- clock turns DANGER and pulses below this

local CROWN_SFX_GAP = 0.5 -- REWARD floor: a magnet run must chime, never machine-gun

local PIP_SIZE = Vector2.new(30, 24)
local PIP_STEP = 34
local LIVES_SHAKE_TIME = 0.32
local LIVES_SHAKE_AMP = 6
local LIVES_SHAKE_FREQ = 46

-- Bottom stack widths: must clear InputController's clusters (stick+brake left,
-- fire+drift right) even on an 800x480 viewport, hence the slim 240px panel.
local BOTTOM_PANEL_W = 240
local POWER_SIZE = Vector2.new(190, 40)
-- LuckyUI's screen + card, read-only: the powerup slot stays quiet while the reel is
-- taking the credit for the same grant. Names pinned to LuckyUI's build().
local LUCKY_GUI, LUCKY_CARD = "LuckySpin", "LuckyCard"
-- The HP bar is CHUNKED — one cell per HP_PER_CHUNK points — so it is taller than
-- the old sliding bar: at 14px the cell gaps read as noise rather than as divisions.
local HP_SIZE = Vector2.new(220, 18)
local HP_CORNER = 6 -- rounded rect, not a pill: square-ish cells need square-ish ends
local HP_PER_CHUNK = Config.HP_PER_CHUNK or 100
local HP_DEFAULT_MAX = HP_PER_CHUNK * 4 -- a normal car, used only until MaxHp arrives
local SPEED_SIZE = Vector2.new(170, 9)
local BOOST_PULSE_SPEED = 12
local COUNTER_TEXT_SIZE = 13 -- house fixed size, counters only
local SPEED_DAMP = 10 -- needle smoothing rate
local HP_LOW = 0.3 -- below this the HP ring pulses DANGER
local HP_LOW_PULSE_SPEED = 10
local HP_FLASH_FROM = 0.35
local HP_FLASH_TIME = 0.3

local BOARD_TOP = TOP_INSET + 42 -- leaves the top-right corner for LobbyUI's garage button
local BOARD_W = 214
local BOARD_ROWS = 5
local BOARD_ROW_H = 24
local BOARD_ROW_GAP = 4
local BOARD_HEADER_H = 20
local BOARD_H = BOARD_HEADER_H + BOARD_ROWS * (BOARD_ROW_H + BOARD_ROW_GAP)
local BOARD_NAME_MAX = 10

local FEED_W = 260
local FEED_ROW_H = 26
local FEED_MAX = 4
local FEED_LIFE = 4
local FEED_FADE = 0.35
local FEED_NAME_MAX = 9
local FEED_TOP = BOARD_TOP + BOARD_H + 10

local PUNCH_INFO = TweenInfo.new(UI.POP_IN.time, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_INFO = TweenInfo.new(FEED_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HP_FLASH_INFO = TweenInfo.new(HP_FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local initialized = false

-- ==========================================================================
-- §2) helpers
-- ==========================================================================
--[[ Chunk colour, driven by TOTAL health rather than by each cell's own fill, so the
	whole bar shifts green -> gold -> red as one thing. This is the SAME ramp FxController
	paints on the nametag bars, so a car reads identically whether you are looking at it
	or at your own HUD. ]]
local function hpChunkColor(fraction: number): Color3
	if fraction >= 0.5 then
		return UI.GOLD:Lerp(UI.CONFIRM, MathUtil.clamp01((fraction - 0.5) * 2))
	end
	return UI.DANGER:Lerp(UI.GOLD, MathUtil.clamp01(fraction * 2))
end

local function trim(name: any, maxLen: number): string
	local s = tostring(name or "?")
	if #s <= maxLen then
		return s
	end
	return string.sub(s, 1, maxLen - 1) .. "…"
end

local function whole(n: any): number
	return math.max(0, math.floor(tonumber(n) or 0))
end

function HudUI.init(ctx)
	if initialized then
		return
	end
	initialized = true

	local kit = ctx.kit
	local net = ctx.net or {}
	local conns = {}

	--[[ kit.label strokes in Border mode, which boxes a transparent TextLabel.
		House DNA wants the stroke on the glyphs, so flip it on every label we make. ]]
	local function textLabel(opts)
		local lbl = kit.label(opts)
		local s = lbl:FindFirstChildOfClass("UIStroke")
		if s then
			s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		end
		return lbl
	end

	local function setText(lbl: TextLabel, value: string)
		if lbl.Text ~= value then
			lbl.Text = value
		end
	end

	-- One-shot scale punch through the element's UIScale (never its Size).
	local function punch(inst: Instance, from: number)
		local scale = kit.ensureScale(inst)
		scale.Scale = from
		TweenService:Create(scale, PUNCH_INFO, { Scale = 1 }):Play()
	end

	-- ==========================================================================
	-- §3) screen + regions
	-- ==========================================================================
	-- If StarterGui.Main is ever re-copied (respawn), drop the previous HUD so we
	-- never stack two ScreenGuis / two frame loops.
	local playerGui = player:WaitForChild("PlayerGui")
	local stale = playerGui:FindFirstChild("CrashHud")
	if stale then
		stale:Destroy()
	end

	local gui = kit.screen("CrashHud", kit.DISPLAY_ORDER.HUD)

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = gui

	--[[ NO TOP-CENTRE BAND. The match clock and the crown counter used to live here; both
		were removed on request — the top of the screen belongs to the lucky-block reel now.
		Nothing is orphaned by that: the mini leaderboard on the right already shows every
		player's crown count including your own, the pickup keeps its REWARD chime (§4), and
		the final ten seconds still TICK once a second in the frame loop (§12). ]]

	-- ---------- top left: lives ----------
	local livesRow = Instance.new("Frame")
	livesRow.Name = "Lives"
	livesRow.Size = UDim2.fromOffset(PIP_STEP * Config.MATCH.LIVES, PIP_SIZE.Y)
	livesRow.Position = UDim2.new(0, SIDE_INSET, 0, TOP_INSET)
	livesRow.AnchorPoint = Vector2.new(0, 0)
	livesRow.BackgroundTransparency = 1
	livesRow.Parent = root

	local PIP_BODY_ON = kit.CONFIRM
	local PIP_CABIN_ON = kit.CONFIRM:Lerp(kit.PAPER, 0.35)
	local PIP_BODY_OFF = kit.GLASS:Lerp(kit.PAPER, 0.14)
	local PIP_CABIN_OFF = kit.GLASS:Lerp(kit.PAPER, 0.22)

	local pips = {}
	for i = 1, Config.MATCH.LIVES do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.Size = UDim2.fromOffset(PIP_SIZE.X, PIP_SIZE.Y)
		pip.Position = UDim2.fromOffset((i - 1) * PIP_STEP, 0)
		pip.BackgroundTransparency = 1
		pip.Parent = livesRow

		local cabin = Instance.new("Frame")
		cabin.Name = "Cabin"
		cabin.Size = UDim2.fromOffset(14, 8)
		cabin.Position = UDim2.new(0.5, 0, 0, 0)
		cabin.AnchorPoint = Vector2.new(0.5, 0)
		cabin.BackgroundColor3 = PIP_CABIN_ON
		cabin.BorderSizePixel = 0
		cabin.ZIndex = 0
		cabin.Parent = pip
		kit.corner(cabin, 3)
		kit.stroke(cabin, 1.5, kit.INK)

		local body = Instance.new("Frame")
		body.Name = "Body"
		body.Size = UDim2.fromOffset(28, 12)
		body.Position = UDim2.new(0.5, 0, 0, 6)
		body.AnchorPoint = Vector2.new(0.5, 0)
		body.BackgroundColor3 = PIP_BODY_ON
		body.BorderSizePixel = 0
		body.Parent = pip
		kit.corner(body, 4)
		kit.stroke(body, 1.75, kit.INK)

		for w = 0, 1 do
			local wheel = Instance.new("Frame")
			wheel.Name = "Wheel" .. w
			wheel.Size = UDim2.fromOffset(7, 7)
			wheel.Position = UDim2.fromOffset(5 + w * 13, 17)
			wheel.BackgroundColor3 = kit.INK
			wheel.BorderSizePixel = 0
			wheel.Parent = pip
			kit.pill(wheel)
		end

		pips[i] = { body = body, cabin = cabin }
	end

	-- ---------- top right: mini leaderboard ----------
	local boardPanel = Instance.new("Frame")
	boardPanel.Name = "Board"
	boardPanel.Size = UDim2.fromOffset(BOARD_W, BOARD_H)
	boardPanel.Position = UDim2.new(1, -SIDE_INSET, 0, BOARD_TOP)
	boardPanel.AnchorPoint = Vector2.new(1, 0)
	boardPanel.BackgroundTransparency = 1
	boardPanel.Parent = root

	textLabel({
		parent = boardPanel,
		name = "Header",
		text = "TOP 5",
		size = UDim2.fromOffset(80, BOARD_HEADER_H - 4),
		position = UDim2.new(1, -8, 0, 0),
		anchor = Vector2.new(1, 0),
		cap = 15,
		ramp = kit.GOLD_RAMP,
		align = Enum.TextXAlignment.Right,
		stroke = 2,
	})

	local function rowY(index: number): number
		return BOARD_HEADER_H + (index - 1) * (BOARD_ROW_H + BOARD_ROW_GAP)
	end

	local boardRows = {}
	for i = 1, BOARD_ROWS do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Size = UDim2.fromOffset(BOARD_W, BOARD_ROW_H)
		row.Position = UDim2.fromOffset(0, rowY(i))
		row.BackgroundColor3 = kit.GLASS
		row.BackgroundTransparency = 0.25
		row.BorderSizePixel = 0
		row.Visible = false
		row.Parent = boardPanel
		kit.corner(row, 8)
		local rowStroke = kit.stroke(row, 1.5, kit.INK)

		local rank = textLabel({
			parent = row,
			name = "Rank",
			text = "1",
			size = UDim2.fromOffset(18, 16),
			position = UDim2.new(0, 8, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			cap = 14,
			color = kit.GOLD,
			align = Enum.TextXAlignment.Left,
			stroke = 1.6,
		})

		local nameLabel = textLabel({
			parent = row,
			name = "Racer",
			text = "",
			size = UDim2.new(1, -92, 0, 16),
			position = UDim2.new(0, 30, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			cap = 14,
			font = kit.FONT_BOLD,
			align = Enum.TextXAlignment.Left,
			stroke = 1.6,
		})

		local scoreLabel = textLabel({
			parent = row,
			name = "Crowns",
			text = "0",
			size = UDim2.fromOffset(52, 16),
			position = UDim2.new(1, -10, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			cap = 14,
			color = kit.GOLD_LIGHT,
			align = Enum.TextXAlignment.Right,
			stroke = 1.6,
		})

		boardRows[i] = {
			frame = row,
			stroke = rowStroke,
			rank = rank,
			name = nameLabel,
			score = scoreLabel,
		}
	end

	-- ---------- right, under the board: kill feed ----------
	local feedPanel = Instance.new("Frame")
	feedPanel.Name = "KillFeed"
	feedPanel.Size = UDim2.fromOffset(FEED_W, FEED_MAX * (FEED_ROW_H + 4))
	feedPanel.Position = UDim2.new(1, -SIDE_INSET, 0, FEED_TOP)
	feedPanel.AnchorPoint = Vector2.new(1, 0)
	feedPanel.BackgroundTransparency = 1
	feedPanel.Parent = root

	local feedLayout = Instance.new("UIListLayout")
	feedLayout.FillDirection = Enum.FillDirection.Vertical
	feedLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	feedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	feedLayout.Padding = UDim.new(0, 4)
	feedLayout.Parent = feedPanel

	-- ---------- bottom centre: powerup, HP, speed ----------
	local bottomPanel = Instance.new("Frame")
	bottomPanel.Name = "Bottom"
	bottomPanel.Size = UDim2.fromOffset(BOTTOM_PANEL_W, 120)
	bottomPanel.Position = UDim2.new(0.5, 0, 1, -BOTTOM_INSET)
	bottomPanel.AnchorPoint = Vector2.new(0.5, 1)
	bottomPanel.BackgroundTransparency = 1
	bottomPanel.Parent = root

	local bottomLayout = Instance.new("UIListLayout")
	bottomLayout.FillDirection = Enum.FillDirection.Vertical
	bottomLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bottomLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	bottomLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bottomLayout.Padding = UDim.new(0, 8)
	bottomLayout.Parent = bottomPanel

	local powerPill = Instance.new("Frame")
	powerPill.Name = "Powerup"
	powerPill.Size = UDim2.fromOffset(POWER_SIZE.X, POWER_SIZE.Y)
	powerPill.BackgroundColor3 = kit.GLASS
	powerPill.BackgroundTransparency = 0.1
	powerPill.BorderSizePixel = 0
	powerPill.LayoutOrder = 1
	powerPill.Parent = bottomPanel
	kit.pill(powerPill)
	kit.stroke(powerPill, UI.STROKE, kit.INK)
	local powerGrad = kit.gradient(powerPill, { kit.GLASS:Lerp(kit.PAPER, 0.1), kit.GLASS })

	local powerRingFrame = Instance.new("Frame")
	powerRingFrame.Name = "Ring"
	powerRingFrame.Size = UDim2.new(1, -8, 1, -8)
	powerRingFrame.Position = UDim2.fromScale(0.5, 0.5)
	powerRingFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	powerRingFrame.BackgroundTransparency = 1
	powerRingFrame.Parent = powerPill
	kit.pill(powerRingFrame)
	local powerRing = kit.stroke(powerRingFrame, 1.5, kit.PAPER, 0.75)

	local powerName = textLabel({
		parent = powerPill,
		name = "PowerName",
		text = "NO POWER",
		size = UDim2.new(1, -78, 0.6, 0),
		position = UDim2.new(0, 16, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		cap = 17,
		align = Enum.TextXAlignment.Left,
		stroke = 2,
	})

	local powerAmmo = textLabel({
		parent = powerPill,
		name = "PowerAmmo",
		text = "",
		size = UDim2.fromOffset(44, 20),
		position = UDim2.new(1, -16, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		cap = 17,
		color = kit.GOLD_LIGHT,
		align = Enum.TextXAlignment.Right,
		stroke = 2,
	})

	-- anchor 0,0: a UIListLayout writes Position but still applies AnchorPoint,
	-- so the kit default of (0.5,0.5) would shift the bar half its size.
	local hpTrack, hpSetValue = kit.segmentBar({
		parent = bottomPanel,
		name = "Health",
		size = UDim2.fromOffset(HP_SIZE.X, HP_SIZE.Y),
		position = UDim2.fromOffset(0, 0),
		anchor = Vector2.new(0, 0),
		perSegment = HP_PER_CHUNK,
		radius = HP_CORNER,
		ramp = hpChunkColor,
	})
	hpTrack.LayoutOrder = 2
	local hpStroke = hpTrack:FindFirstChildOfClass("UIStroke")
	hpSetValue(0, HP_DEFAULT_MAX)

	local hpFlash = Instance.new("Frame")
	hpFlash.Name = "Flash"
	hpFlash.Size = UDim2.fromScale(1, 1)
	hpFlash.BackgroundColor3 = kit.DANGER
	hpFlash.BackgroundTransparency = 1
	hpFlash.BorderSizePixel = 0
	hpFlash.ZIndex = 3
	hpFlash.Parent = hpTrack
	kit.corner(hpFlash, HP_CORNER)

	local speedRow = Instance.new("Frame")
	speedRow.Name = "Speed"
	speedRow.Size = UDim2.fromOffset(SPEED_SIZE.X + 44, 14)
	speedRow.BackgroundTransparency = 1
	speedRow.LayoutOrder = 3
	speedRow.Parent = bottomPanel

	local speedTrack, speedSetFill = kit.bar({
		parent = speedRow,
		name = "SpeedBar",
		size = UDim2.fromOffset(SPEED_SIZE.X, SPEED_SIZE.Y),
		position = UDim2.new(0, 0, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		color = kit.LIME,
	})
	speedSetFill(0)
	local speedStroke = speedTrack:FindFirstChildOfClass("UIStroke")

	local speedNumber = Instance.new("TextLabel")
	speedNumber.Name = "SpeedNumber"
	speedNumber.Size = UDim2.fromOffset(40, 14)
	speedNumber.Position = UDim2.new(1, 0, 0.5, 0)
	speedNumber.AnchorPoint = Vector2.new(1, 0.5)
	speedNumber.BackgroundTransparency = 1
	speedNumber.Font = kit.FONT_BOLD
	speedNumber.Text = "0"
	speedNumber.TextColor3 = kit.PAPER
	speedNumber.TextScaled = false
	speedNumber.TextSize = COUNTER_TEXT_SIZE
	speedNumber.TextXAlignment = Enum.TextXAlignment.Right
	speedNumber.Parent = speedRow
	local speedNumberStroke = kit.stroke(speedNumber, 1.2, kit.INK)
	speedNumberStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual

	local REGIONS = { livesRow, boardPanel, bottomPanel }

	-- ==========================================================================
	-- §4) crown pickups — sound only, now that the counter is gone
	--
	-- The counter, its punch and the "+N" float all lived in the top band and went with it.
	-- What could NOT go is the moment: a crown you pick up has to be FELT, and this chime is
	-- the whole of that feedback now. The number itself still reads off the mini leaderboard.
	-- ==========================================================================
	local lastCrownSfx = -math.huge

	--[[ Audio rides a LONG gap on purpose. playSfx only rate-limits at 0.04s, so a magnet run
		hoovering five crowns a second would turn REWARD into mush; one chime per half second
		reads as a streak instead. ]]
	local function chimeCrown()
		local now = os.clock()
		if now - lastCrownSfx >= CROWN_SFX_GAP then
			lastCrownSfx = now
			kit.playSfx("REWARD", 0.7)
		end
	end

	-- ==========================================================================
	-- §5) lives
	--
	-- DELIBERATELY SILENT. Losing a pip and dying are the SAME instant, and DeathUI owns
	-- that sound (THUD while lives remain, IMPACT on the run-ending one), so a THUD here
	-- would stack two sounds on one event. The shake is this HUD's share of the feedback.
	-- ==========================================================================
	local shownLives = whole(player:GetAttribute(ATTR.LIVES))
	local shakeUntil = -math.huge
	local frameTime = 0

	local function paintPip(index: number, alive: boolean)
		local pip = pips[index]
		if not pip then
			return
		end
		pip.body.BackgroundColor3 = alive and PIP_BODY_ON or PIP_BODY_OFF
		pip.cabin.BackgroundColor3 = alive and PIP_CABIN_ON or PIP_CABIN_OFF
	end

	local function refreshLives()
		local lives = whole(player:GetAttribute(ATTR.LIVES))
		local lost = lives < shownLives
		for i = 1, #pips do
			paintPip(i, i <= lives)
		end

		if lost and root.Visible then
			shakeUntil = frameTime + LIVES_SHAKE_TIME
			local pip = pips[math.clamp(lives + 1, 1, #pips)]
			if pip then
				pip.body.BackgroundColor3 = kit.DANGER
				pip.cabin.BackgroundColor3 = kit.DANGER:Lerp(kit.PAPER, 0.3)
				TweenService:Create(pip.body, HP_FLASH_INFO, { BackgroundColor3 = PIP_BODY_OFF }):Play()
				TweenService:Create(pip.cabin, HP_FLASH_INFO, { BackgroundColor3 = PIP_CABIN_OFF }):Play()
			end
		end
		shownLives = lives
	end

	table.insert(conns, player:GetAttributeChangedSignal(ATTR.LIVES):Connect(refreshLives))
	for i = 1, #pips do
		paintPip(i, i <= shownLives)
	end

	-- ==========================================================================
	-- §6) powerup slot
	-- ==========================================================================
	--[[ Read-only peek at LuckyUI's card. We never touch it — we only ask whether the reel
		is on screen, so the slot can decline to sound a grant the reel is already paying
		off. Re-resolves if the ScreenGui was rebuilt, and tolerates it never existing. ]]
	local luckyGui: Instance? = nil
	local function luckyReelUp(): boolean
		if not luckyGui or not luckyGui.Parent then
			luckyGui = playerGui:FindFirstChild(LUCKY_GUI)
		end
		local reelCard = luckyGui and luckyGui:FindFirstChild(LUCKY_CARD)
		return reelCard ~= nil and reelCard.Visible == true
	end

	local function refreshPowerup(pop: boolean)
		local def, ammo = PowerupDefs.slotOf(player)
		if not def then
			powerGrad.Color = ColorSequence.new(kit.GLASS:Lerp(kit.PAPER, 0.1), kit.GLASS)
			powerRing.Color = kit.PAPER
			powerRing.Transparency = 0.75
			powerName.TextColor3 = kit.PAPER
			powerName.TextTransparency = 0.35
			setText(powerName, "NO POWER")
			setText(powerAmmo, "")
			return
		end

		local accent = def.color or kit.GOLD
		powerGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, accent:Lerp(kit.PAPER, 0.3)),
			ColorSequenceKeypoint.new(0.5, accent),
			ColorSequenceKeypoint.new(1, accent:Lerp(kit.INK, 0.35)),
		})
		powerRing.Color = accent:Lerp(kit.PAPER, 0.5)
		powerRing.Transparency = 0.3
		powerName.TextColor3 = kit.PAPER
		powerName.TextTransparency = 0
		setText(powerName, string.upper(PowerupDefs.shortName(def.id)))
		setText(powerAmmo, "x" .. tostring(whole(ammo)))
		if pop then
			punch(powerPill, UI.POP_IN.from)
			-- Crate pickups are the case that still needs audio; a reel grant is already
			-- announced by LuckyUI's REWARD as the strip stops on the winner.
			if not luckyReelUp() then
				kit.playSfx("TOGGLE")
			end
		end
	end

	local lastPowerId = player:GetAttribute(ATTR.POWERUP)
	table.insert(conns, player:GetAttributeChangedSignal(ATTR.POWERUP):Connect(function()
		local id = player:GetAttribute(ATTR.POWERUP)
		local gained = id ~= nil and id ~= "" and id ~= lastPowerId
		lastPowerId = id
		refreshPowerup(gained)
	end))
	table.insert(conns, player:GetAttributeChangedSignal(ATTR.POWERUP_AMMO):Connect(function()
		refreshPowerup(false)
	end))
	refreshPowerup(false)

	-- ==========================================================================
	-- §7) HP — one CHUNK per Config.HP_PER_CHUNK points, so a hit reads as chunks
	--     knocked off. Re-hooks on every respawn through CarLifecycle; the cell
	--     layout follows MaxHp, so swapping to a 6-chunk car just grows the bar.
	-- ==========================================================================
	local carConns = {}
	local currentCar: Instance? = nil
	local lastHp = 0
	local hpFraction = 0

	local function unhookCar()
		for _, c in ipairs(carConns) do
			c:Disconnect()
		end
		table.clear(carConns)
		currentCar = nil
		hpFraction = 0
		hpSetValue(0)
		if hpStroke then
			hpStroke.Color = kit.INK
		end
	end

	local function flashHp()
		hpFlash.BackgroundTransparency = HP_FLASH_FROM
		TweenService:Create(hpFlash, HP_FLASH_INFO, { BackgroundTransparency = 1 }):Play()
	end

	local function refreshHp()
		local car = currentCar
		if not car or not car.Parent then
			unhookCar()
			return
		end
		local hp = tonumber(car:GetAttribute(CAR_ATTR.HP)) or 0
		local maxHp = math.max(tonumber(car:GetAttribute(CAR_ATTR.MAX_HP)) or HP_DEFAULT_MAX, 1)
		hpFraction = math.clamp(hp / maxHp, 0, 1)
		hpSetValue(hp, maxHp)
		if hp < lastHp then
			flashHp()
		end
		lastHp = hp
	end

	local function hookCar(model: any)
		if typeof(model) ~= "Instance" or not model:IsA("Model") then
			return
		end
		if currentCar == model then
			return
		end
		unhookCar()
		currentCar = model
		lastHp = tonumber(model:GetAttribute(CAR_ATTR.HP)) or 0
		table.insert(carConns, model:GetAttributeChangedSignal(CAR_ATTR.HP):Connect(refreshHp))
		table.insert(carConns, model:GetAttributeChangedSignal(CAR_ATTR.MAX_HP):Connect(refreshHp))
		table.insert(carConns, model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				unhookCar()
			end
		end))
		refreshHp()
	end

	-- ==========================================================================
	-- §8) controllers — lazy, tolerated missing
	-- ==========================================================================
	local chassis = nil
	task.spawn(function()
		local folder = ctx.controllers and ctx.controllers() or nil
		if not folder then
			return
		end
		local moduleScript = folder:FindFirstChild("ChassisController")
		if not moduleScript then
			return
		end
		local ok, mod = pcall(require, moduleScript)
		if ok and type(mod) == "table" then
			chassis = mod
		end
	end)

	local function chassisNumber(fnName: string): number
		if not chassis or type(chassis[fnName]) ~= "function" then
			return 0
		end
		local ok, value = pcall(chassis[fnName])
		if ok and type(value) == "number" then
			return value
		end
		return 0
	end

	-- non-contract but present on ChassisController: lets the speedo read a boost
	local function chassisFlag(fnName: string): boolean
		if not chassis or type(chassis[fnName]) ~= "function" then
			return false
		end
		local ok, value = pcall(chassis[fnName])
		return ok and value == true
	end

	local function chassisCar(): Instance?
		if not chassis or type(chassis.getCar) ~= "function" then
			return nil
		end
		local ok, car = pcall(chassis.getCar)
		if ok and typeof(car) == "Instance" then
			return car
		end
		return nil
	end

	-- ==========================================================================
	-- §9) mini leaderboard + kill feed
	-- ==========================================================================
	local rowOwner = {} -- [rowRecord] = player name currently drawn

	local function clearBoard()
		rowOwner = {}
		for _, rec in ipairs(boardRows) do
			rec.frame.Visible = false
			kit.ensureScale(rec.frame).Scale = 1
		end
	end

	local function updateBoard(entries: any)
		if type(entries) ~= "table" then
			return
		end

		local count = math.min(#entries, BOARD_ROWS)
		local byName = {}
		for rec, name in pairs(rowOwner) do
			byName[name] = rec
		end

		local assigned, used = {}, {}
		for i = 1, count do
			local name = tostring(entries[i] and entries[i].name or "?")
			local rec = byName[name]
			if rec and not used[rec] then
				assigned[i] = rec
				used[rec] = true
			end
		end
		for i = 1, count do
			if not assigned[i] then
				for _, rec in ipairs(boardRows) do
					if not used[rec] then
						assigned[i] = rec
						used[rec] = true
						break
					end
				end
			end
		end

		local previous = rowOwner
		rowOwner = {}

		for i = 1, count do
			local rec, entry = assigned[i], entries[i]
			if rec and type(entry) == "table" then
				local name = tostring(entry.name or "?")
				local fresh = previous[rec] ~= name or not rec.frame.Visible
				setText(rec.rank, tostring(i))
				setText(rec.name, trim(name, BOARD_NAME_MAX))
				--[[ entry.score is whatever THIS MODE places on — crowns, wrecks or
					points — worked out server side by ScoreService, so the column never
					has to know which mode is running. Falls back to crowns so a payload
					from a server that predates modes still reads correctly. ]]
				setText(rec.score, tostring(whole(entry.score or entry.crowns)))

				--[[ ...and the NAME carries the side. Same GameModes.colorFor the world
					nametags and the through-wall highlights use, so one glance at the
					board, the car and the tag all agree on who is a team-mate and which
					one is the monster. nil in the four modes with no sides. ]]
				local rowPlayer = Players:GetPlayerByUserId(tonumber(entry.userId) or 0)
				local rowTint = rowPlayer and GameModes.colorFor(rowPlayer) or nil
				rec.name.TextColor3 = rowTint or kit.PAPER

				local isLocal = entry.userId == player.UserId
				rec.stroke.Color = isLocal and kit.CONFIRM or kit.INK
				rec.stroke.Thickness = isLocal and 2.5 or 1.5

				local target = UDim2.fromOffset(0, rowY(i))
				if fresh then
					rec.frame.Position = target
					kit.popIn(rec.frame, 0.7)
				elseif rec.frame.Position ~= target then
					TweenService:Create(rec.frame, SLIDE_INFO, { Position = target }):Play()
				end
				rowOwner[rec] = name
			end
		end

		for _, rec in ipairs(boardRows) do
			if not rowOwner[rec] and rec.frame.Visible then
				kit.popOut(rec.frame)
			end
		end
	end

	local feedSeq = 0

	local function clearFeed()
		for _, child in ipairs(feedPanel:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
	end

	local function pushFeed(message: string)
		-- LayoutOrder is -seq, so the largest LayoutOrder is the oldest entry.
		local existing = {}
		for _, child in ipairs(feedPanel:GetChildren()) do
			if child:IsA("Frame") then
				table.insert(existing, child)
			end
		end
		table.sort(existing, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		for i = 1, #existing - (FEED_MAX - 1) do
			existing[i]:Destroy()
		end

		feedSeq += 1
		local row = Instance.new("Frame")
		row.Name = "Feed" .. feedSeq
		row.Size = UDim2.fromOffset(FEED_W, FEED_ROW_H)
		row.BackgroundColor3 = kit.GLASS
		row.BackgroundTransparency = 0.28
		row.BorderSizePixel = 0
		row.LayoutOrder = -feedSeq -- newest on top
		row.Parent = feedPanel
		kit.corner(row, 8)
		local rowStroke = kit.stroke(row, 1.5, kit.INK)

		local label = textLabel({
			parent = row,
			name = "Text",
			text = message,
			size = UDim2.new(1, -18, 0.72, 0),
			cap = 15,
			font = kit.FONT_BOLD,
			align = Enum.TextXAlignment.Right,
			stroke = 1.8,
		})
		local labelStroke = label:FindFirstChildOfClass("UIStroke")

		kit.popIn(row, 0.6)

		task.delay(FEED_LIFE, function()
			if not row.Parent then
				return
			end
			TweenService:Create(row, FADE_INFO, { BackgroundTransparency = 1 }):Play()
			TweenService:Create(label, FADE_INFO, { TextTransparency = 1 }):Play()
			TweenService:Create(rowStroke, FADE_INFO, { Transparency = 1 }):Play()
			if labelStroke then
				TweenService:Create(labelStroke, FADE_INFO, { Transparency = 1 }):Play()
			end
			task.delay(FEED_FADE + 0.05, function()
				if row.Parent then
					row:Destroy()
				end
			end)
		end)
	end

	local function onKill(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local victim = trim(payload.victimName, FEED_NAME_MAX)
		if payload.killerName then
			pushFeed(trim(payload.killerName, FEED_NAME_MAX) .. " smashed " .. victim)
		else
			pushFeed(victim .. " fell off!")
		end
	end

	-- ==========================================================================
	-- §10) match events
	-- ==========================================================================
	local matchEvent = net.MatchEvent
	if matchEvent then
		table.insert(conns, matchEvent.OnClientEvent:Connect(function(kind, payload)
			if kind == "crown" then
				local amount = whole(type(payload) == "table" and payload.amount or 0)
				if amount > 0 then
					chimeCrown()
				end
			elseif kind == "board" then
				updateBoard(payload)
			elseif kind == "kill" then
				onKill(payload)
			end
		end))
	else
		warn("HudUI: MatchEvent remote missing — crowns, board and kill feed stay idle")
	end

	local carLifecycle = net.CarLifecycle
	if carLifecycle then
		table.insert(conns, carLifecycle.OnClientEvent:Connect(function(action, model)
			if action == "spawned" then
				hookCar(model)
			elseif action == "destroyed" then
				unhookCar()
			end
		end))
	end

	-- ==========================================================================
	-- §11) phase visibility
	-- ==========================================================================
	local hideToken = 0

	local function show()
		hideToken += 1
		root.Visible = true
		refreshLives()
		refreshPowerup(false)
		for _, region in ipairs(REGIONS) do
			kit.popIn(region)
		end
	end

	local function hide()
		hideToken += 1
		local token = hideToken
		for _, region in ipairs(REGIONS) do
			if region.Visible then
				kit.popOut(region)
			end
		end
		task.delay(UI.POP_OUT.time + 0.05, function()
			if hideToken == token then
				root.Visible = false
			end
		end)
	end

	local shown = false
	table.insert(conns, MatchState.onPhaseChanged(function(phase)
		local wantShown = phase == PHASES.MATCH
		if wantShown == shown then
			return
		end
		shown = wantShown
		if wantShown then
			clearBoard()
			clearFeed()
			show()
		else
			hide()
		end
	end))

	-- ==========================================================================
	-- §12) the single frame loop — manual sine math only
	-- ==========================================================================
	local speedShown = 0
	local carPoll = 0
	local lastTickSecond = nil -- whole second the danger clock last ticked on

	table.insert(conns, RunService.RenderStepped:Connect(function(dt)
		if not root.Visible then
			return
		end
		frameTime += dt

		--[[ The clock FACE went with the top band, but the final ten seconds still tick: one
			TICK per whole second, keyed on the second VALUE rather than elapsed time, so a
			frame hitch SKIPS a tick instead of firing two and the counter self-clears the
			moment the clock leaves the danger band. With no clock on screen this is the only
			thing telling you the round is nearly over — do not let it go quiet. ]]
		local left = MatchState.timeLeft()
		if left <= TIMER_DANGER_SECONDS then
			local second = math.ceil(left)
			if second > 0 and second ~= lastTickSecond then
				lastTickSecond = second
				kit.playSfx("TICK", 1.2)
			end
		else
			lastTickSecond = nil
		end

		-- lives shake on loss
		if frameTime < shakeUntil then
			local remain = (shakeUntil - frameTime) / LIVES_SHAKE_TIME
			local dx = math.sin(frameTime * LIVES_SHAKE_FREQ) * LIVES_SHAKE_AMP * remain
			livesRow.Position = UDim2.new(0, SIDE_INSET + dx, 0, TOP_INSET)
		elseif livesRow.Position.X.Offset ~= SIDE_INSET then
			livesRow.Position = UDim2.new(0, SIDE_INSET, 0, TOP_INSET)
		end

		-- speedometer
		speedShown = MathUtil.damp(speedShown, chassisNumber("getSpeedFraction"), SPEED_DAMP, dt)
		speedSetFill(speedShown)
		setText(speedNumber, tostring(math.floor(chassisNumber("getSpeed") + 0.5)))
		if speedStroke then
			if chassisFlag("isBoosting") then
				local mix = 0.5 + 0.5 * math.sin(frameTime * BOOST_PULSE_SPEED)
				speedStroke.Color = kit.INK:Lerp(kit.GOLD_DEEP, mix)
			elseif speedStroke.Color ~= kit.INK then
				speedStroke.Color = kit.INK
			end
		end

		-- low-HP ring pulse
		if hpStroke then
			if hpFraction > 0 and hpFraction < HP_LOW then
				local mix = 0.5 + 0.5 * math.sin(frameTime * HP_LOW_PULSE_SPEED)
				hpStroke.Color = kit.INK:Lerp(kit.DANGER, mix)
			elseif hpStroke.Color ~= kit.INK then
				hpStroke.Color = kit.INK
			end
		end

		-- late car pickup when we joined mid-life and missed the spawn event
		if not currentCar then
			carPoll += dt
			if carPoll >= 0.5 then
				carPoll = 0
				local car = chassisCar()
				if car then
					hookCar(car)
				end
			end
		end
	end))

	gui.Destroying:Connect(function()
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
		unhookCar()
	end)
end

return HudUI
