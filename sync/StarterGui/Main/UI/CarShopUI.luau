--[[ CarShopUI (UI module — the kit-art car showroom)
	The uploaded kit's Frames.Shop1 panel, re-skinned as the CrashCars shop. One scrolling
	row per Config.CARS entry in roster order: a REAL viewport render of the model
	CarFactory publishes, the car's name + rarity, a speed / tough readout, and ONE
	state-driven action button wearing the kit's own four faces
	(buy / equip / equipped / locked).

	AUTHORITY: the server owns money and ownership. This module NEVER predicts a result —
	it fires GarageAction and repaints only when OwnedCars / EquippedCar / Money / Gems
	change. An unaffordable card still TAPS: the server's own "Need more money!" teaches
	more than a dead button, so the locked sheet is a NON-Active Frame and never swallows
	the click underneath it.

	Frame       registered as "CarShop". Built by CLONING Alternate.Frames.Shop1 (the
	            StarterGui template first, the PlayerGui copy as fallback) into ctx.frames.
	            The kit's own Header.Buttons.Close already satisfies kit.registerFrame.
	Remote      GarageAction  C->S (action, carId)   S->C (ok, message, carId)
	Attributes  reads only: Money Gems EquippedCar OwnedCars ProfileLoaded Alive
	Assets      ReplicatedStorage.CrashCore.Assets.Previews[carId] (published by CarFactory
	            at server init; a missing preview degrades to the car's body colour and
	            warns exactly once)

	KIT NOTES — why this looks the way it does
		* The kit outlines with 0.01-0.18px UIStrokes, i.e. effectively none. House DNA's
		  2px INK stroke reads as foreign here AND muddies white glyphs, so nothing gains
		  one; the single label this module creates gets a matching hairline.
		* State is expressed the kit's way: two UIGradients per button with .Enabled
		  toggled — "Buy/Equip" is the lime->green ramp, "Equipped/Locked" the grey ramp.
		  Exactly one is ever enabled.
		* "Name" is an Instance PROPERTY: card.Info.Name returns the string "Info", not the
		  kit's label. Every lookup goes through ff() for precisely that reason.
		* Rarity colour is injected by rebuilding the kit's 4-stop 0/0.1/0.9/1 ramp shape,
		  so a recoloured label still reads as kit art rather than a flat tint.

	MOTION: header drift plus ONE RenderStepped spinning every viewport — not one
	connection per card — disconnected the moment the panel closes. Eight live spins
	behind a hidden frame is wasted mobile frame time. Manual sine math, no tween loops
	(house rule).

	SOUND: the reply from the server is what makes a noise, never the click — BUY_OK for a
	purchase, the lighter TOGGLE for an equip, DENY for any refusal. rec.pending records
	what we ASKED for, because OwnedCars usually replicates before the reply and would
	otherwise repaint "buy" into "equip" and sound the wrong note.

	Sections:
		§1  constants
		§2  state
		§3  helpers
		§4  card refresh (property writes only, never a rebuild)
		§5  actions
		§6  construction
		§7  motion
		§8  init
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local CarRegistry = require(sharedFolder:WaitForChild("CarRegistry"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))

local player = Players.LocalPlayer

local CarShopUI = {}

local ATTR = Config.ATTR
local UI = Config.UI

-- ==========================================================================
-- §1) constants
-- ==========================================================================
local FRAME_NAME = "CarShop" -- pinned: entry points call kit.openFrame("CarShop")
local KIT_GUI = "Alternate"
local KIT_FRAME = "Shop1"
local CARD_TEMPLATE = "1" -- the kit ships 7 dummy rows; row 1 becomes our stamp
local KIT_CARD_COUNT = 7

-- Kit child names, spelled out once. Two of them contain slashes and can never be
-- reached with dot access.
local ACTION_BTN = "Buy/Equip/Equipped/Locked"
local ACTION_LABEL = "Cost/Equip/Equipped/Locked"
local GRAD_LIVE = "Buy/Equip" -- lime -> green: this button does something
local GRAD_DIM = "Equipped/Locked" -- grey: already yours, or out of reach

--[[ The kit's flat icon art is drawn with its own padding baked in, so it sat at 0.8 of
	the tile. A 3D render has no such padding and the tile is otherwise empty, so the
	viewport fills more of it. Same centre, same ZIndex as the ImageLabel it replaces. ]]
local VIEW_SIZE = 0.92
local VIEW_ZOOM = 1.55 -- UIKit's measured default; the DNA 0.72 crops every car in the roster
local LOCK_TINT = Color3.fromRGB(148, 148, 156) -- unowned render greys out but stays readable

local ROW_HOVER = 1.02 -- rows are full-panel width; the house 1.07 would burst the scroller
local SPIN_DPS = 24
local SPIN_STAGGER = 1.5 -- per-row speed offset so the list is not in lockstep
local SPIN_PHASE = 37 -- degrees of per-row head start
local DRIFT_FREQ, DRIFT_AMP = 1.4, 3

local FLASH_SECONDS = 1.5
local CLICK_LOCK = 0.55 -- >= Net.REQUEST_GAP (0.5), so a double tap cannot outrun the reply
local PREVIEW_TIMEOUT = 20
local KIT_TIMEOUT = 10

--[[ The kit's Locked sheet is INK at 0.25 (75% opaque) because "you need 3 rebirths"
	means the row is over. "You cannot afford this yet" is a softer state and the card has
	to stay readable — you are meant to look at what you are saving for. ]]
local LOCK_SHEET = 0.55
--[==[ The equipped ring is a MULTIPLE of the kit's own authored weight, never a pixel
	count. A UIStroke on these kit cards expands by roughly the card's own WIDTH per unit
	of Thickness -- which is why the kit authors 0.02-0.18, and why HAIRLINE below is 0.12.
	An absolute 2 does not draw a 2px ring; it drops a solid CONFIRM-green slab several
	cards wide over the list. Same trap as IndexUI. ]==]
local EQUIPPED_STROKE_MULT = 2
local HAIRLINE = 0.12 -- kit stroke weight, for the one label this module creates

local RARITY_WORD = {
	COMMON = "Common",
	UNCOMMON = "Uncommon",
	RARE = "Rare",
	EPIC = "Epic",
	LEGENDARY = "Legendary",
}

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit, net, frames
local panel, container, header, headerBase, cardTemplate, loadingLabel

-- carId -> { car, row, render, actionLabel, gradLive, gradDim, lockSheet, lockWord,
--            stroke, strokeColor, strokeThickness, spin, phase, state, busy,
--            pending (action in flight, so the reply sounds the right note), flashSeq }
local cards = {}
local motionConns = {}
local cardsBuilt = false
local warnedPreview = false

-- ==========================================================================
-- §3) helpers
-- ==========================================================================
--[[ "Name" is an Instance property, so kitRow.Info.Name is the string "Info". Every kit
	lookup in this module goes through here so that trap cannot be walked into. ]]
local function ff(inst: Instance?, childName: string): Instance?
	if not inst then
		return nil
	end
	return inst:FindFirstChild(childName)
end

local function readMoney(attr: string): number
	local value = player:GetAttribute(attr)
	return type(value) == "number" and value or 0
end

--[[ The kit paints every gradient as four stops pinned at 0 / 0.1 / 0.9 / 1 — a flat
	band, a short blend, a flat band. Rebuilding a rarity ramp in that exact shape is what
	keeps a recoloured label reading as kit art instead of a tint someone dropped on. ]]
local function ramp4(color: Color3): ColorSequence
	local light = color:Lerp(UI.PAPER, 0.45)
	local deep = color:Lerp(UI.INK, 0.30)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, light),
		ColorSequenceKeypoint.new(0.1, light),
		ColorSequenceKeypoint.new(0.9, deep),
		ColorSequenceKeypoint.new(1, deep),
	})
end

-- Recolours whatever single UIGradient the kit already put on this element.
local function paintGradient(inst: Instance?, color: Color3)
	local grad = inst and inst:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ramp4(color)
	end
end

--[[ Two numbers a kid can compare at a glance, both in real units rather than the raw
	multipliers: studs/second off Config.CHASSIS, and the car's actual hit points. ]]
local function statLine(car): string
	local speed = math.round(car.stats.topSpeed * Config.CHASSIS.TOP_SPEED)
	return string.format("%d SPEED  ·  %d HP", speed, math.round(car.stats.hp))
end

local function shortfallText(car, balance: number): string
	local missing = math.max(0, (car.price or 0) - balance)
	local word = car.currency == "Gems" and "gems" or "money"
	return "Need " .. MathUtil.comma(missing) .. " more " .. word
end

-- ==========================================================================
-- §4) card refresh — property writes only, never a teardown
-- ==========================================================================
--[[ One button, four faces, expressed the kit's way: flip which of its two gradients is
	enabled and rewrite its label. Never rebuilds the button, so its UIScale feel survives. ]]
local function paintAction(rec, live: boolean, text: string)
	rec.actionLabel.Text = text
	rec.gradLive.Enabled = live
	rec.gradDim.Enabled = not live
end

local function refreshCard(carId: string)
	local rec = cards[carId]
	if not rec then
		return
	end

	local car = rec.car
	local owned = CarRegistry.owns(player, carId)
	local equipped = CarRegistry.equippedId(player) == carId
	local isGems = car.currency == "Gems"
	local balance = isGems and readMoney(ATTR.GEMS) or readMoney(ATTR.MONEY)
	local affordable = CarRegistry.isFree(car) or balance >= (car.price or 0)

	rec.render.ImageColor3 = owned and UI.PAPER or LOCK_TINT

	-- House "selected" rule (stroke swaps to confirm green), spoken through the kit's
	-- own card stroke rather than through a new element.
	rec.stroke.Color = equipped and UI.CONFIRM or rec.strokeColor
	rec.stroke.Thickness = equipped and rec.strokeThickness * EQUIPPED_STROKE_MULT or rec.strokeThickness

	-- A non-Active Frame: it dims the row and names the shortfall without eating the tap.
	-- Skipped while a flash message owns the sheet (flashSeq ahead of flashShown).
	if rec.flashSeq == rec.flashShown then
		local blocked = (not owned) and not affordable
		rec.lockSheet.Visible = blocked
		if blocked then
			rec.lockWord.Text = shortfallText(car, balance)
		end
	end

	if equipped then
		rec.state = "equipped"
		paintAction(rec, false, "Equipped")
	elseif owned then
		rec.state = "equip"
		paintAction(rec, not rec.busy, "Equip")
	else
		rec.state = "buy"
		paintAction(rec, affordable and not rec.busy, CarRegistry.priceText(car))
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
--[[ Reuses the kit's own Locked sheet as the message surface: no extra element, and the
	place a refusal appears is the place a refusal already lives. ]]
local function flashCard(carId: string, text: string)
	local rec = cards[carId]
	if not rec then
		return
	end

	rec.flashSeq += 1
	local seq = rec.flashSeq
	rec.lockWord.Text = text
	kit.popIn(rec.lockSheet, 0.85)

	task.delay(FLASH_SECONDS, function()
		if rec.flashSeq ~= seq or not rec.lockSheet.Parent then
			return
		end
		rec.flashShown = seq
		refreshCard(carId) -- restores the sheet to whatever the real state wants
	end)
end

--[[ Fires and waits. No optimistic flip: OwnedCars / EquippedCar repaint the row. The
	button greys for CLICK_LOCK seconds so a double tap cannot spend twice. ]]
local function onAction(carId: string)
	local rec = cards[carId]
	if not rec or rec.busy or rec.state == "equipped" then
		return
	end
	if not net or not net.GarageAction then
		return
	end
	if player:GetAttribute(ATTR.PROFILE_LOADED) ~= true then
		kit.playSfx("DENY") -- a tap that cannot land still has to answer
		flashCard(carId, "One second...")
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
	Notify on a buy, and the row repainting to "Equipped" is the equip feedback. The one
	thing worth saying out loud is the honest mid-match caveat. ]]
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
		-- BUY_OK is the till, an equip is a lighter switch — never both.
		kit.playSfx(wasAction == "equip" and "TOGGLE" or "BUY_OK")
		if MatchState.isMatch() and player:GetAttribute(ATTR.ALIVE) == true then
			flashCard(carId, "Next life!")
		end
		return
	end

	kit.playSfx("DENY")
	local text = (type(message) == "string" and message ~= "") and message or "Not yet!"
	flashCard(carId, text)
end

-- ==========================================================================
-- §6) construction
-- ==========================================================================
--[[ The StarterGui template is preferred over the PlayerGui copy: it is replicated before
	client scripts run and nothing mutates it at runtime. WaitForChild returns immediately
	when the child is already there, so the happy path does not yield. ]]
local function findKitFrame(): Instance?
	local function lookup(gui: Instance?): Instance?
		local folder = gui and gui:FindFirstChild("Frames")
		return folder and folder:FindFirstChild(KIT_FRAME) or nil
	end

	local found = lookup(StarterGui:WaitForChild(KIT_GUI, KIT_TIMEOUT))
	if found then
		return found
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	return lookup(playerGui and playerGui:FindFirstChild(KIT_GUI))
end

local function buildCard(car, order: number, previewModel: Instance?)
	local accent = CarRegistry.rarityColor(car)

	local row = cardTemplate:Clone()
	row.Name = car.id
	row.LayoutOrder = order
	row.Parent = container

	local buyButtons = ff(row, "BuyButtons")
	local action = ff(buyButtons, ACTION_BTN)
	local actionLabel = ff(action, ACTION_LABEL)
	local gradLive = ff(action, GRAD_LIVE)
	local gradDim = ff(action, GRAD_DIM)
	local lockSheet = ff(row, "Locked")
	local lockWord = ff(lockSheet, "AmountNeeded")
	local iconFrame = ff(row, "IconFrame")
	local stroke = row:FindFirstChildOfClass("UIStroke")

	-- The kit is the contract here. If it ever changes shape, say so plainly instead of
	-- erroring halfway through a half-built row.
	if not (action and actionLabel and gradLive and gradDim and lockSheet and lockWord and iconFrame and stroke) then
		warn("CarShopUI: kit row is missing expected children — skipping '" .. tostring(car.id) .. "'")
		row:Destroy()
		return
	end

	-- ---------- name + rarity ----------
	local info = ff(row, "Info")
	local rarityLabel = ff(info, "Rarity")
	local nameLabel = ff(info, "Name")
	if rarityLabel then
		rarityLabel.Text = RARITY_WORD[car.rarity] or "Common"
		paintGradient(rarityLabel, accent)
	end
	if nameLabel then
		nameLabel.Text = car.name
	end

	-- ---------- the render ----------
	paintGradient(ff(iconFrame, "Rarity"), accent) -- the tile's rarity ring (a UIStroke)

	local flatIcon = ff(iconFrame, "Icon")
	local iconZ = flatIcon and flatIcon.ZIndex or -10
	if flatIcon then
		flatIcon.Visible = false -- MANDATORY: real game renders, never drawn icon art
	end

	local render = kit.viewport({
		parent = iconFrame,
		name = "Render",
		model = previewModel,
		size = UDim2.fromScale(VIEW_SIZE, VIEW_SIZE),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		zoom = VIEW_ZOOM,
	})
	render.ZIndex = iconZ

	if not previewModel then
		-- Degrade, never error: a block in the car's own body colour.
		local block = Instance.new("Frame")
		block.Name = "Placeholder"
		block.Size = UDim2.fromScale(0.7, 0.42)
		block.Position = UDim2.fromScale(0.5, 0.5)
		block.AnchorPoint = Vector2.new(0.5, 0.5)
		block.BackgroundColor3 = (car.build and car.build.bodyColor) or UI.PAPER
		block.BorderSizePixel = 0
		block.ZIndex = iconZ
		block.Parent = iconFrame
		kit.corner(block, 6)

		if not warnedPreview then
			warnedPreview = true
			warn("CarShopUI: no preview model for '" .. tostring(car.id) .. "' — showing placeholders")
		end
	end

	-- ---------- stat readout ----------
	local powerValue = ff(ff(row, "Power"), "Power")
	if powerValue then
		powerValue.Text = statLine(car)
	end

	-- ---------- buttons ----------
	-- Cars are bought with Money or Gems only; there is no per-car Robux SKU in
	-- Config.PRODUCTS, so the kit's Robux button stays off rather than lying about one.
	local robux = ff(buyButtons, "BuyRobux")
	if robux then
		robux.Visible = false
	end

	lockSheet.Visible = false
	lockSheet.Active = false -- explicit: the sheet must never swallow the tap beneath it
	lockSheet.BackgroundTransparency = LOCK_SHEET

	kit.addButtonFeedback(action)
	action.Activated:Connect(function()
		onAction(car.id)
	end)

	--[[ The whole row is the choice, so the row hovers, not just its button. This makes
		the row Active — safe here for the same reason it is safe in GarageUI: the kit
		Container is a ScrollingFrame, which already consumes drags over this area. ]]
	kit.bindHover(row, { scale = ROW_HOVER })

	cards[car.id] = {
		car = car,
		row = row,
		render = render,
		actionLabel = actionLabel,
		gradLive = gradLive,
		gradDim = gradDim,
		lockSheet = lockSheet,
		lockWord = lockWord,
		stroke = stroke,
		strokeColor = stroke.Color,
		strokeThickness = stroke.Thickness,
		spin = SPIN_DPS + order * SPIN_STAGGER,
		phase = order * SPIN_PHASE,
		flashSeq = 0,
		flashShown = 0,
		busy = false,
		order = order,
		state = "buy",
	}
end

local function buildPanel(): boolean
	local template = findKitFrame()
	if not template then
		warn("CarShopUI: kit frame " .. KIT_GUI .. ".Frames." .. KIT_FRAME .. " not found — shop not built")
		return false
	end

	panel = template:Clone()
	panel.Name = FRAME_NAME
	panel.Visible = false
	panel.Parent = frames

	container = ff(panel, "Container")
	header = ff(panel, "Header")
	if not container or not header then
		warn("CarShopUI: cloned kit frame has no Container/Header — shop not built")
		panel:Destroy()
		panel = nil
		return false
	end
	headerBase = header.Position

	local title = ff(header, "Name")
	if title then
		title.Text = "Car Shop"
	end

	-- Lift row 1 out as the stamp, then clear the six remaining dummy rows. The two SPACE
	-- spacers keep their LayoutOrders (-1e6 / 1e7) and stay as the list's end padding.
	cardTemplate = ff(container, CARD_TEMPLATE)
	if not cardTemplate then
		warn("CarShopUI: kit Container has no template row '" .. CARD_TEMPLATE .. "' — shop not built")
		panel:Destroy()
		panel = nil
		return false
	end
	cardTemplate.Parent = nil
	for i = 2, KIT_CARD_COUNT do
		local leftover = ff(container, tostring(i))
		if leftover then
			leftover:Destroy()
		end
	end

	loadingLabel = kit.label({
		parent = panel,
		name = "Loading",
		text = "Loading...",
		size = UDim2.fromScale(0.6, 0.1),
		position = UDim2.fromScale(0.5, 0.55),
		anchor = Vector2.new(0.5, 0.5),
		cap = 20,
		stroke = HAIRLINE, -- kit weight, not the house 2px: a heavy outline reads foreign here
	})

	return true
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
	if not panel or not panel.Parent or not container or not cardTemplate then
		return
	end
	cardsBuilt = true

	for i, car in ipairs(CarRegistry.all()) do
		local model = nil
		if folder then
			-- Only the first lookup waits; publishPreviews() writes them all in one pass.
			model = folder:FindFirstChild(car.id) or (i == 1 and folder:WaitForChild(car.id, 2) or nil)
		end
		buildCard(car, i, model)
		refreshCard(car.id)
	end

	cardTemplate:Destroy()
	cardTemplate = nil

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
			if not panel or not panel.Visible then
				return
			end
			t += dt

			if header and headerBase then
				header.Position = headerBase + UDim2.fromOffset(0, MathUtil.drift(t, DRIFT_FREQ, 0.4, DRIFT_AMP))
			end

			--[[ ONE loop drives every render. Eight separate RenderStepped connections
				would cost eight dispatches a frame to do the same trivial pivot. Manual
				math, never a tween loop (house rule). ]]
			for _, rec in pairs(cards) do
				local model = rec.render:FindFirstChildOfClass("Model")
				if model then
					model:PivotTo(CFrame.Angles(0, math.rad((t * rec.spin + rec.phase) % 360), 0))
				end
			end
		end)
	)
end

-- ==========================================================================
-- §8) init
-- ==========================================================================
function CarShopUI.init(ctx)
	kit = ctx and ctx.kit
	net = ctx and ctx.net
	frames = ctx and ctx.frames
	if not kit or not frames then
		warn("CarShopUI: ctx is missing kit or frames — shop not built")
		return
	end

	if not buildPanel() then
		return
	end

	kit.registerFrame(FRAME_NAME, panel) -- hides it and wires the kit's Close + pop in/out

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible then
			startMotion()
		else
			stopMotion()
		end
	end)

	-- Reactive repaint: the server's attributes are the only source of truth here.
	player:GetAttributeChangedSignal(ATTR.MONEY):Connect(refreshAllCards)
	player:GetAttributeChangedSignal(ATTR.GEMS):Connect(refreshAllCards)
	player:GetAttributeChangedSignal(ATTR.OWNED):Connect(refreshAllCards)
	player:GetAttributeChangedSignal(ATTR.EQUIPPED):Connect(refreshAllCards)

	if net and net.GarageAction then
		net.GarageAction.OnClientEvent:Connect(onServerReply)
	else
		warn("CarShopUI: GarageAction remote missing — rows cannot buy or equip")
	end

	-- First paint waits for the profile: drawing prices against Money = 0 would lie.
	local function paintWhenReady()
		task.spawn(function()
			buildCards()
			if panel and panel.Visible then
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

return CarShopUI
