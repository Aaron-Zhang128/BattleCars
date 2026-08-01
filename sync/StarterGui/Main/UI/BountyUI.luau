--[[ BountyUI
	Bounty mode's two pieces of screen: the TARGET ROLLER and the mark chip.

	UI module (see StarterGui.Main.Main for the ctx contract). Everything is built from
	code into its own ScreenGui at kit.DISPLAY_ORDER.BOUNTY (13) -- above the lucky-block
	reel, below the death and results cards, so neither is ever covered. Nothing is
	authored into the Studio tree.

	INERT IN EVERY OTHER MODE. Both pieces hide on any mode that is not bounty and on
	any phase that is not Match, and the frame loop early-outs before it does any work.

	READS (this module writes nothing -- no remotes fired, no attributes set)
		BountyEvent (S->C)  "roll"  { targetId, targetName, targetBounty, reel, landIndex,
		                              startedAt, duration }
		                    "claim" { victimName, amount, wasTarget }
		                    "lost"  { }
		Player attributes   BountyTarget / Bounty, through GameModes.targetIdOf /
		                    bountyOf, for the chip and for every tile's price.

	THE REEL IS KEYED TO SERVER TIME, never to a local clock: t = (now - startedAt) /
	duration. A client that receives the payload late gets a SHORT spin that still lands
	on the beat the server is writing the target on -- the same contract LuckyUI runs on,
	and the reason the reel can never show the wrong name.

	NO GuiButton ANYWHERE and the root is left non-Active on purpose: the chip sits in
	the top-left, which is inside InputController's SteerZone (the whole left half), and
	an Active element there would swallow a steering drag on a phone.

	LAYOUT
		chip    top-left under HudUI's lives pips (18, 78). Your mark, their price, what
		        YOU are worth, and a HUNTED pill when somebody is coming for you.
		roller  centred a third of the way down, popped in and out. Tiles are avatar
		        headshots -- rbxthumb loads them with no yield and no web call here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))

local player = Players.LocalPlayer
local UI = Config.UI
local ATTR = Config.ATTR
local CFG = Config.BOUNTY
local CARS_FOLDER = "Cars" -- owned by SpawnService
local PHASES = MatchState.PHASES

local BountyUI = {}

-- ==========================================================================
-- §1) constants
-- ==========================================================================
-- Chip: directly under HudUI's lives pips (TOP_INSET 44 + pip 24 + 10).
local CHIP_X = 18
local CHIP_Y = 78
local CHIP = Vector2.new(236, 58)
local CHIP_CAP_H = 18
local HUNTED_H = 22
local HUNTED_GAP = 6

-- Roller. STEP is the pitch between tiles and TILE is what is drawn, so the gap
-- between two tiles is the difference -- change STEP and the reel re-spaces itself.
local CARD = Vector2.new(340, 232)
local CARD_Y_SCALE = 0.34
local TITLE_H = 28
local WINDOW = Vector2.new(302, 104)
local TILE = Vector2.new(296, 84)
local STEP = 92
local FOOT_H = 26
--[[ Only tiles within this many steps of the window are drawn. The window is 104px
	against a 92px step, so the second tile out starts 138px from centre against a 52px
	half-window -- it is already fully off-screen, which is what makes culling pop-free. ]]
local CULL_STEPS = 1.6
--[[ Approach curve. A plain ease-out quint crawls into the landing at a few px/s, which
	reads as the reel giving up rather than stopping; 2.6 still enters the last tile fast
	and lets the landing punch do the stopping. ]]
local APPROACH = 2.6
local LAND_HOLD = 1.1 -- seconds the winner sits there before the card pops out
local PUNCH_TIME = 0.26
local PUNCH_SCALE = 0.16
local TICK_GAP = 0.045 -- floor between reel ticks, so a fast pass is a rattle not a tone

local AVATAR = 60
local NAME_CAP = 22
local PRICE_CAP = 20

--[[ THE MARKER. A name and a price are not a target until you can find the car, and
	this arena is 903 studs across -- without this the mode reads as "you have been
	given homework". On screen it sits over the car; off screen it pins to the edge
	with a stem pointing the way, which is the whole navigation. ]]
local MARKER = 40
local MARKER_BODY = 20 -- the diamond: a square rotated 45deg, so no font glyph to trust
local STEM = Vector2.new(7, 20)
local STEM_OUT = 21 -- pixels from the diamond centre to the stem's
local EDGE_MARGIN = 62 -- keeps the pinned marker clear of the HUD's own furniture
local MARKER_LIFT = 9 -- studs above the car, so it never sits inside the bodywork
local NEAR_STUDS = 170 -- inside this the marker breathes: they are RIGHT THERE
local PULSE_HZ = 2.4
local PULSE_DEPTH = 0.16
local DIST_CAP = 14
local CHIP_PUNCH = 0.14 -- the flash a silent hand-off gets instead of a roller
local CHIP_PUNCH_TIME = 0.22

local initialized = false

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit
local gui, chip, chipCaption, chipYou, chipName, chipPrice, huntedPill, huntedLabel
local chipScale
local card, cardScale, reelHolder, footLabel
local marker, markerScale, markerStem, markerBody, markerDist
local tiles = {} -- the strip currently on the reel, rebuilt per roll
local markCar = nil -- the mark's live car model, re-resolved on the chip's own beat
local chipPunch = 0

local spin = nil -- { startedAt, duration, landIndex, endsAt } while a reel is running
local lastTickIndex = 0
local lastTickAt = 0
local chipAccum = 0

-- ==========================================================================
-- §3) helpers
-- ==========================================================================
local function money(n: number): string
	return "$" .. MathUtil.comma(math.max(0, math.floor(tonumber(n) or 0)))
end

local function headshot(userId: number): string
	return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=150&h=150"
end

-- Bounty is a MATCH mode: outside the round there is no mark and no price to draw.
local function modeIsLive(): boolean
	return GameModes.hasBounty() and MatchState.getPhase() == PHASES.MATCH
end

--[[ The mark's car. Name first (SpawnService names them Car_<userId>, so this is one
	hash lookup), attribute second for the case where that ever stops being true. Called
	on the chip's quarter-second beat, never per frame. ]]
local function findCar(userId: number): Model?
	local folder = workspace:FindFirstChild(CARS_FOLDER)
	if not folder or userId == 0 then
		return nil
	end
	local byName = folder:FindFirstChild("Car_" .. tostring(userId))
	if byName and byName:IsA("Model") then
		return byName
	end
	for _, car in ipairs(folder:GetChildren()) do
		if car:IsA("Model") and car:GetAttribute(ChassisSpec.ATTR.OWNER) == userId then
			return car
		end
	end
	return nil
end

--[[ Is there anybody left to be sent after? "Nobody is driving" and "your reel is still
	spinning" are two different nothings and the chip must not say the same word for
	both -- one is the game waiting on the field, the other is about to hand you a name. ]]
local function rivalsAlive(): number
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other:GetAttribute(ATTR.ALIVE) == true then
			count += 1
		end
	end
	return count
end

local function clearTiles()
	for _, tile in ipairs(tiles) do
		tile.frame:Destroy()
	end
	table.clear(tiles)
end

-- ==========================================================================
-- §4) build
-- ==========================================================================
local function buildChip(parent)
	chip = Instance.new("Frame")
	chip.Name = "MarkChip"
	chip.Size = UDim2.fromOffset(CHIP.X, CHIP.Y)
	chip.Position = UDim2.fromOffset(CHIP_X, CHIP_Y)
	chip.AnchorPoint = Vector2.new(0, 0)
	chip.BackgroundColor3 = UI.INK
	chip.BackgroundTransparency = 0.25
	chip.BorderSizePixel = 0
	chip.Visible = false
	chip.Parent = parent
	chipScale = kit.ensureScale(chip)
	kit.corner(chip, 10)
	kit.stroke(chip, 2, UI.INK)

	chipCaption = kit.label({
		parent = chip,
		name = "Caption",
		text = "YOUR MARK",
		size = UDim2.new(0.5, -10, 0, CHIP_CAP_H),
		position = UDim2.fromOffset(10, 4),
		anchor = Vector2.new(0, 0),
		align = Enum.TextXAlignment.Left,
		color = UI.GOLD,
		cap = 12,
		stroke = 1.5,
	})

	-- What YOU are worth, on the same chip: the number every other car is reading.
	chipYou = kit.label({
		parent = chip,
		name = "You",
		text = "",
		size = UDim2.new(0.5, -10, 0, CHIP_CAP_H),
		position = UDim2.new(1, -10, 0, 4),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		color = UI.PAPER,
		cap = 12,
		stroke = 1.5,
	})

	chipName = kit.label({
		parent = chip,
		name = "Mark",
		text = "NO TARGET",
		size = UDim2.new(1, -96, 0, CHIP.Y - CHIP_CAP_H - 10),
		position = UDim2.fromOffset(10, CHIP_CAP_H + 3),
		anchor = Vector2.new(0, 0),
		align = Enum.TextXAlignment.Left,
		color = CFG.TARGET_COLOR,
		cap = NAME_CAP,
	})

	chipPrice = kit.label({
		parent = chip,
		name = "Price",
		text = "",
		size = UDim2.fromOffset(84, CHIP.Y - CHIP_CAP_H - 10),
		position = UDim2.new(1, -10, 0, CHIP_CAP_H + 3),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		color = UI.GOLD,
		cap = PRICE_CAP,
	})

	--[[ The paranoia line. Knowing somebody is coming for you is half of what makes the
		mode tense, and it costs one attribute scan on the chip's own refresh. ]]
	huntedPill = Instance.new("Frame")
	huntedPill.Name = "Hunted"
	huntedPill.Size = UDim2.fromOffset(CHIP.X, HUNTED_H)
	huntedPill.Position = UDim2.fromOffset(CHIP_X, CHIP_Y + CHIP.Y + HUNTED_GAP)
	huntedPill.BackgroundColor3 = UI.DANGER
	huntedPill.BackgroundTransparency = 0.15
	huntedPill.BorderSizePixel = 0
	huntedPill.Visible = false
	huntedPill.Parent = parent
	kit.pill(huntedPill)
	kit.stroke(huntedPill, 2, UI.INK)

	huntedLabel = kit.label({
		parent = huntedPill,
		name = "Label",
		text = "HUNTED",
		size = UDim2.fromScale(1, 1),
		cap = 14,
		color = UI.PAPER,
	})
end

local function buildMarker(parent)
	marker = Instance.new("Frame")
	marker.Name = "MarkMarker"
	marker.Size = UDim2.fromOffset(MARKER, MARKER)
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundTransparency = 1
	marker.Visible = false
	marker.Parent = parent
	markerScale = kit.ensureScale(marker)

	--[[ Drawn BEHIND the diamond and hidden while the car is on screen: a stem that
		stayed up would read as an arrow pointing at something you are already looking
		at. It is positioned around the diamond rather than rotated about it -- a Frame
		rotates about its own centre, so the offset has to be done in pixels. ]]
	markerStem = Instance.new("Frame")
	markerStem.Name = "Stem"
	markerStem.Size = UDim2.fromOffset(STEM.X, STEM.Y)
	markerStem.AnchorPoint = Vector2.new(0.5, 0.5)
	markerStem.Position = UDim2.fromScale(0.5, 0.5)
	markerStem.BackgroundColor3 = CFG.TARGET_COLOR
	markerStem.BorderSizePixel = 0
	markerStem.ZIndex = 2
	markerStem.Visible = false
	markerStem.Parent = marker
	kit.pill(markerStem)
	kit.stroke(markerStem, 2, UI.INK)

	markerBody = Instance.new("Frame")
	markerBody.Name = "Diamond"
	markerBody.Size = UDim2.fromOffset(MARKER_BODY, MARKER_BODY)
	markerBody.AnchorPoint = Vector2.new(0.5, 0.5)
	markerBody.Position = UDim2.fromScale(0.5, 0.5)
	markerBody.Rotation = 45
	markerBody.BackgroundColor3 = CFG.TARGET_COLOR
	markerBody.BorderSizePixel = 0
	markerBody.ZIndex = 3
	markerBody.Parent = marker
	kit.stroke(markerBody, 2.5, UI.INK)

	markerDist = kit.label({
		parent = marker,
		name = "Distance",
		text = "",
		size = UDim2.fromOffset(MARKER * 2, 16),
		position = UDim2.new(0.5, 0, 1, 2),
		anchor = Vector2.new(0.5, 0),
		cap = DIST_CAP,
		color = UI.PAPER,
	})
	markerDist.ZIndex = 3
end

local function buildCard(parent)
	card = kit.card({
		parent = parent,
		name = "RollerCard",
		size = UDim2.fromOffset(CARD.X, CARD.Y),
		position = UDim2.fromScale(0.5, CARD_Y_SCALE),
		accent = CFG.TARGET_COLOR,
	})
	card.Visible = false
	cardScale = kit.ensureScale(card)

	kit.label({
		parent = card,
		name = "Title",
		text = "NEW TARGET",
		size = UDim2.new(1, -24, 0, TITLE_H),
		position = UDim2.fromOffset(12, 10),
		anchor = Vector2.new(0, 0),
		color = UI.GOLD,
		ramp = kit.GOLD_RAMP,
		cap = 24,
	})

	local window = Instance.new("Frame")
	window.Name = "Window"
	window.Size = UDim2.fromOffset(WINDOW.X, WINDOW.Y)
	window.Position = UDim2.fromOffset(CARD.X * 0.5, TITLE_H + 20)
	window.AnchorPoint = Vector2.new(0.5, 0)
	window.BackgroundColor3 = UI.INK
	window.BackgroundTransparency = 0.35
	window.BorderSizePixel = 0
	window.ClipsDescendants = true -- the reel is a strip; this is the slot it runs behind
	window.Parent = card
	kit.corner(window, 8)

	reelHolder = Instance.new("Frame")
	reelHolder.Name = "Reel"
	reelHolder.Size = UDim2.fromScale(1, 1)
	reelHolder.BackgroundTransparency = 1
	reelHolder.Parent = window

	-- Two dashes flanking the winning slot: the reel needs somewhere to be pointing.
	for _, side in ipairs({ -1, 1 }) do
		local dash = Instance.new("Frame")
		dash.Name = "Marker"
		dash.Size = UDim2.fromOffset(10, 4)
		dash.AnchorPoint = Vector2.new(0.5, 0.5)
		dash.Position = UDim2.new(side < 0 and 0 or 1, side * -9, 0.5, 0)
		dash.BackgroundColor3 = UI.PAPER
		dash.BorderSizePixel = 0
		dash.ZIndex = 6
		dash.Parent = window
		kit.pill(dash)
	end

	footLabel = kit.label({
		parent = card,
		name = "Foot",
		text = "",
		size = UDim2.new(1, -24, 0, FOOT_H),
		position = UDim2.new(0.5, 0, 1, -14),
		anchor = Vector2.new(0.5, 1),
		color = UI.PAPER,
		cap = 18,
	})
end

local function buildTile(entry, index: number)
	local frame = Instance.new("Frame")
	frame.Name = "Tile" .. index
	frame.Size = UDim2.fromOffset(TILE.X, TILE.Y)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.BackgroundColor3 = UI.GLASS
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = reelHolder
	kit.corner(frame, 8)

	local face = Instance.new("ImageLabel")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(AVATAR, AVATAR)
	face.Position = UDim2.new(0, 10, 0.5, 0)
	face.AnchorPoint = Vector2.new(0, 0.5)
	face.BackgroundColor3 = UI.INK
	face.BorderSizePixel = 0
	face.Image = headshot(entry.userId)
	face.Parent = frame
	kit.corner(face, 8)

	kit.label({
		parent = frame,
		name = "Name",
		text = entry.name or "?",
		size = UDim2.new(1, -(AVATAR + 110), 1, -20),
		position = UDim2.new(0, AVATAR + 20, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		align = Enum.TextXAlignment.Left,
		cap = NAME_CAP,
	})

	kit.label({
		parent = frame,
		name = "Price",
		text = money(entry.bounty),
		size = UDim2.fromOffset(84, TILE.Y - 24),
		position = UDim2.new(1, -12, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		align = Enum.TextXAlignment.Right,
		color = UI.GOLD,
		cap = PRICE_CAP,
	})

	return { frame = frame, scale = kit.ensureScale(frame) }
end

-- ==========================================================================
-- §5) the chip
-- ==========================================================================
local function refreshChip()
	if not modeIsLive() then
		chip.Visible = false
		huntedPill.Visible = false
		return
	end
	chip.Visible = true
	chipYou.Text = money(GameModes.bountyOf(player)) .. " ON YOU"

	local id = GameModes.targetIdOf(player)
	if id == 0 then
		--[[ THREE different nothings, and none of them may read the same: a reel that is
			still spinning is about to hand you a name, an empty field has nobody left to
			send you after, and the gap between the two is the game thinking. ]]
		markCar = nil
		if spin then
			chipName.Text = "ROLLING..."
			chipName.TextColor3 = UI.GOLD
		elseif rivalsAlive() == 0 then
			chipName.Text = "NO RIVALS"
			chipName.TextColor3 = UI.PAPER
		else
			chipName.Text = "FINDING TARGET"
			chipName.TextColor3 = UI.PAPER
		end
		chipPrice.Text = ""
	else
		local mark = Players:GetPlayerByUserId(id)
		chipName.Text = mark and mark.DisplayName or "?"
		chipName.TextColor3 = CFG.TARGET_COLOR
		chipPrice.Text = mark and money(GameModes.bountyOf(mark)) or ""
		if not markCar or markCar.Parent == nil then
			markCar = findCar(id) -- one resolve per beat, not per frame
		end
	end

	local hunters = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and GameModes.targetIdOf(other) == player.UserId then
			hunters += 1
		end
	end
	huntedPill.Visible = hunters > 0
	huntedLabel.Text = hunters > 1 and ("HUNTED BY " .. hunters) or "HUNTED"
end

-- ==========================================================================
-- §6) the reel
-- ==========================================================================
local function endSpin()
	spin = nil
	markCar = nil -- resolved fresh on the next chip beat, against the new mark
	clearTiles()
	if card.Visible then
		kit.popOut(card)
	end
	refreshChip()
end

local function startSpin(payload)
	if type(payload) ~= "table" or type(payload.reel) ~= "table" then
		return
	end
	local landIndex = tonumber(payload.landIndex) or 0
	if landIndex < 1 or landIndex > #payload.reel then
		return
	end

	clearTiles()
	for index, entry in ipairs(payload.reel) do
		tiles[index] = buildTile(entry, index)
	end

	spin = {
		startedAt = tonumber(payload.startedAt) or workspace:GetServerTimeNow(),
		duration = math.max(0.2, tonumber(payload.duration) or CFG.ROLL_SECONDS),
		landIndex = landIndex,
		name = payload.targetName or "?",
		bounty = tonumber(payload.targetBounty) or 0,
		landed = false,
		endsAt = nil,
	}
	lastTickIndex = 0
	lastTickAt = 0

	footLabel.Text = ""
	card.Visible = true
	kit.popIn(card)
	kit.playSfx("SPIN_START")
	refreshChip()
end

--[[ One frame of reel. The strip slides so that tile[landIndex] arrives at the window
	centre exactly at startedAt + duration -- both read off server time, so a client that
	got the payload late simply joins the spin already in progress rather than landing on
	a different name. ]]
local function stepSpin(dt: number, now: number)
	local t = math.clamp((now - spin.startedAt) / spin.duration, 0, 1)
	local progress = 1 - (1 - t) ^ APPROACH
	local offset = progress * (spin.landIndex - 1) * STEP

	for index, tile in ipairs(tiles) do
		local y = (index - 1) * STEP - offset
		local visible = math.abs(y) <= CULL_STEPS * STEP
		tile.frame.Visible = visible
		if visible then
			tile.frame.Position = UDim2.new(0.5, 0, 0.5, y)
		end
	end

	-- One tick per tile that passes the marker, floored so a fast pass rattles.
	local passed = math.floor(offset / STEP)
	if passed ~= lastTickIndex and os.clock() - lastTickAt >= TICK_GAP then
		lastTickIndex = passed
		lastTickAt = os.clock()
		kit.playSfx("TICK")
	end

	if t >= 1 and not spin.landed then
		spin.landed = true
		spin.endsAt = os.clock() + LAND_HOLD
		footLabel.Text = string.upper(spin.name) .. "   " .. money(spin.bounty)
		footLabel.TextColor3 = CFG.TARGET_COLOR
		kit.playSfx("REVEAL")
		local winner = tiles[spin.landIndex]
		if winner then
			winner.scale.Scale = 1 + PUNCH_SCALE
		end
		refreshChip()
	end

	if spin.landed then
		local winner = tiles[spin.landIndex]
		if winner and winner.scale.Scale > 1 then
			-- Per SECOND, not per frame: this game is played on 120Hz displays as well
			-- as 60, and a punch that decays per frame is twice as slow on one of them.
			winner.scale.Scale = math.max(1, winner.scale.Scale - (PUNCH_SCALE / PUNCH_TIME) * dt)
		end
		if os.clock() >= spin.endsAt then
			endSpin()
		end
	end
end

-- ==========================================================================
-- §7) the marker
-- ==========================================================================
--[[ One frame of the mark pointer. WorldToViewportPoint gives both the screen point and
	a Z that is NEGATIVE behind the camera -- and a point behind you projects MIRRORED,
	so the direction has to be flipped before it is clamped or the arrow confidently
	points the wrong way whenever your mark is behind you. That flip is the whole trick. ]]
local function stepMarker(dt: number)
	if chipPunch > 0 then
		chipPunch = math.max(0, chipPunch - dt / CHIP_PUNCH_TIME)
		chipScale.Scale = 1 + CHIP_PUNCH * chipPunch
	end

	if not modeIsLive() or not markCar or markCar.Parent == nil then
		marker.Visible = false
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		marker.Visible = false
		return
	end

	local ok, pivot = pcall(function()
		return markCar:GetPivot().Position
	end)
	if not ok then
		marker.Visible = false
		return
	end

	local world = pivot + Vector3.new(0, MARKER_LIFT, 0)
	local point, onScreen = camera:WorldToViewportPoint(world)
	local viewport = camera.ViewportSize
	local centre = viewport * 0.5
	local screen = Vector2.new(point.X, point.Y)
	if point.Z < 0 then
		screen = centre - (screen - centre) -- behind the camera projects mirrored
	end

	local edge = false
	local minX, maxX = EDGE_MARGIN, viewport.X - EDGE_MARGIN
	local minY, maxY = EDGE_MARGIN, viewport.Y - EDGE_MARGIN
	if point.Z < 0 or screen.X < minX or screen.X > maxX or screen.Y < minY or screen.Y > maxY then
		edge = true
		screen = Vector2.new(math.clamp(screen.X, minX, maxX), math.clamp(screen.Y, minY, maxY))
	end

	marker.Visible = true
	marker.Position = UDim2.fromOffset(screen.X, screen.Y)

	local away = screen - centre
	if edge and away.Magnitude > 1 then
		local dir = away.Unit
		markerStem.Visible = true
		markerStem.Position = UDim2.fromOffset(MARKER * 0.5 + dir.X * STEM_OUT, MARKER * 0.5 + dir.Y * STEM_OUT)
		-- The bar is drawn vertically, so 0deg already points UP: bearing + 90.
		markerStem.Rotation = math.deg(math.atan2(dir.Y, dir.X)) + 90
	else
		markerStem.Visible = false
	end

	local distance = (world - camera.CFrame.Position).Magnitude
	markerDist.Text = tostring(math.floor(distance))

	--[[ Inside NEAR_STUDS the marker breathes. That is the one thing the number cannot
		say fast enough while you are steering: they are RIGHT THERE. ]]
	if distance <= NEAR_STUDS then
		local wave = 0.5 + 0.5 * math.sin(os.clock() * math.pi * 2 * PULSE_HZ)
		markerScale.Scale = 1 + PULSE_DEPTH * wave
	elseif markerScale.Scale ~= 1 then
		markerScale.Scale = 1
	end
end

--[[ What a silent hand-off gets instead of a roller: the chip punches and ticks, which
	is enough to pull the eye up to a name that changed without a card in the way. ]]
local function flashChip()
	chipPunch = 1
	kit.playSfx("TICK")
	refreshChip()
end

-- ==========================================================================
-- §8) init
-- ==========================================================================
function BountyUI.init(ctx)
	if initialized then
		return
	end
	initialized = true
	kit = ctx.kit

	local stale = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("CrashBounty")
	if stale then
		stale:Destroy()
	end

	gui = kit.screen("CrashBounty", UI.DISPLAY_ORDER.BOUNTY or 13)
	buildChip(gui)
	buildMarker(gui)
	buildCard(gui)

	local remote = ctx.net and ctx.net.BountyEvent
	if remote then
		remote.OnClientEvent:Connect(function(kind, payload)
			if kind == "roll" then
				startSpin(payload)
			elseif kind == "assign" then
				--[[ The server only sends this when a reel could not have gone any other
					way (one candidate left on the field). A card that can only land on
					the one name is theatre, and on a small server it is theatre every
					few seconds. ]]
				flashChip()
			elseif kind == "claim" then
				local amount = tonumber(payload and payload.amount) or 0
				local who = payload and payload.victimName or "them"
				if payload and payload.wasTarget then
					kit.notify("CONTRACT PAID  " .. money(amount) .. "  (" .. who .. ")", "gold")
					kit.playSfx("BUY_OK")
				elseif amount > 0 then
					kit.notify(money(amount) .. " from " .. who, "green")
				end
			elseif kind == "lost" then
				--[[ Somebody else took your mark. Said out loud because the alternative
					is your red car simply going white with no explanation. ]]
				kit.notify("Your mark was wrecked", "red")
			end
		end)
	else
		warn("BountyUI: BountyEvent missing, roller disabled")
	end

	--[[ ONE frame loop for both pieces, and it early-outs on the first line in every
		mode but this one. The chip is refreshed on a timer rather than on every
		attribute change: prices tick on the server twice a second, and eight cars all
		changing at once would otherwise be eight redraws in one frame. ]]
	RunService.RenderStepped:Connect(function(dt)
		if spin then
			marker.Visible = false -- you have no mark while its name is still rolling
			stepSpin(dt, workspace:GetServerTimeNow())
			return
		end
		-- The marker is per FRAME (it tracks a car doing 190 studs/s); the chip is on a
		-- quarter-second beat, because eight prices ticking at once is eight redraws.
		stepMarker(dt)
		chipAccum += dt
		if chipAccum < 0.25 then
			return
		end
		chipAccum = 0
		refreshChip()
	end)

	-- A mode or phase we do not belong in must take the card down with it, not just
	-- stop refreshing: a roller left mid-spin over the results screen is a bug.
	MatchState.onPhaseChanged(function(phase)
		if phase ~= PHASES.MATCH and spin then
			endSpin()
		end
		refreshChip()
	end)
	GameModes.onModeChanged(function()
		if not GameModes.hasBounty() and spin then
			endSpin()
		end
		refreshChip()
	end)
end

return BountyUI
