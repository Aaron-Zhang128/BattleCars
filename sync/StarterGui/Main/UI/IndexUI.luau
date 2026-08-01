--[[ IndexUI (UI module — the kit-art car collection index)
	The uploaded kit's Frames.Index panel, re-skinned as the CrashCars collection book.
	One card per Config.CARS entry: a REAL viewport render of the model CarFactory
	publishes, the car's name and the powerup it loves — or "???" and a black silhouette
	if you have never owned it. The rail of tabs filters the grid by rarity and the quest
	bar underneath is the honest whole-roster count.

	READ-ONLY. This module fires no remote and writes no attribute; the index is a mirror
	of OwnedCars and EquippedCar and nothing else. Buying happens in CarShopUI.

	Frame       registered as "Index". Built by CLONING Alternate.Frames.Index (the
	            StarterGui template first, the PlayerGui copy as fallback) into ctx.frames.
	            The kit's own Header.Buttons.Close already satisfies kit.registerFrame.
	Attributes  reads only: OwnedCars EquippedCar ProfileLoaded
	Assets      ReplicatedStorage.CrashCore.Assets.Previews[carId] (published by CarFactory
	            at server init; a missing preview degrades to the car's body colour)

	MOBILE FIX — the kit hangs TypeButtons off the LEFT edge at Position.X -0.162, which
	lands the rail around screen x 0.16-0.28. InputController captures the ENTIRE left half
	for touch steering, and an ImageButton swallows a drag whether or not it is Active, so
	a phone player who opened the index mid-match would find the rail eating their steering
	the moment they closed it over that spot. The rail is MIRRORED to the right edge
	(1 - x): identical floating-rail look, completely clear of the steer zone. Done on our
	clone at runtime, so the kit instance in StarterGui.Alternate is left untouched.

	KIT NOTES — why this looks the way it does
		* The kit outlines with 0.02-0.18px UIStrokes, i.e. effectively none. Nothing here
		  gains a house 2px INK stroke; it would read as foreign and eat the white glyphs.
		* Tab state is the kit's own: two UIGradients per button, "Selected" (lime->green)
		  and "NotSelected" (flat INK), with exactly one .Enabled at a time.
		* Tabs are matched to rarities by LAYOUT ORDER, not by the kit's names
		  (Normal/Gold/Diamond/Rainbow/Clover), so renaming them cannot reshuffle the rail.
		* "Name" is an Instance PROPERTY: card.Name is the instance's own name, never the
		  kit's label. Every lookup goes through ff() for precisely that reason.

	MOTION: header drift plus ONE RenderStepped spinning every render — not one connection
	per card — which skips cards the active tab has filtered out and is disconnected the
	moment the panel closes. Manual sine math, no tween loops (house rule).

	Sections:
		§1  constants
		§2  state
		§3  helpers
		§4  card + progress refresh (property writes only, never a rebuild)
		§5  tabs
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

local player = Players.LocalPlayer

local IndexUI = {}

local ATTR = Config.ATTR
local UI = Config.UI

-- ==========================================================================
-- §1) constants
-- ==========================================================================
local FRAME_NAME = "Index" -- pinned: entry points call kit.openFrame("Index")
local KIT_GUI = "Alternate"
local KIT_FRAME = "Index"
local CARD_TEMPLATE = "1" -- the kit ships 16 dummy cells; cell 1 becomes our stamp
local KIT_CARD_COUNT = 16

--[[ Tab order. These are the five keys in Config.UI.RARITY, in progression order — the
	kit's Normal/Gold/Diamond/Rainbow/Clover names belong to a different game and are
	replaced wholesale. Matched to buttons by LayoutOrder, never by name. ]]
local RARITY_ORDER = { "COMMON", "UNCOMMON", "RARE", "EPIC", "LEGENDARY" }

local RARITY_WORD = {
	COMMON = "Common",
	UNCOMMON = "Uncommon",
	RARE = "Rare",
	EPIC = "Epic",
	LEGENDARY = "Legendary",
}

local UNKNOWN = "???" -- what an undiscovered car tells you about itself

local VIEW_ZOOM = 1.55 -- UIKit's measured default; the DNA 0.72 crops every car in the roster
-- Undiscovered cars render as a near-black silhouette: the shape is the tease, the paint
-- is the reward. Owned cars render at full PAPER (no tint at all).
local SILHOUETTE = Color3.fromRGB(52, 52, 62)

local CARD_HOVER = 1.05 -- cells sit 0.033 apart; the house 1.07 would touch its neighbour
local SPIN_DPS = 22
local SPIN_STAGGER = 1.5 -- per-card speed offset so the grid is not in lockstep
local SPIN_PHASE = 41 -- degrees of per-card head start
local DRIFT_FREQ, DRIFT_AMP = 1.3, 3

--[==[ The equipped ring is a MULTIPLE of whatever the kit authored, never a pixel count.
	A UIStroke on these kit cards expands by roughly the card's own WIDTH per unit of
	Thickness -- which is why the kit authors 0.02-0.18 and why CarShopUI's HAIRLINE is
	0.12. The old absolute 2 therefore did not draw a 2px ring: it drew a solid
	CONFIRM-green slab about three cards wide across the whole grid, behind every card. ]==]
local EQUIPPED_STROKE_MULT = 2
local PREVIEW_TIMEOUT = 20
local KIT_TIMEOUT = 10

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit, frames
local panel, container, header, headerBase, titleLabel, cardTemplate
local progressBar, progressAmount

-- carId -> { car, wrapper, card, render, nameLabel, typeLabel, stroke, strokeColor,
--            strokeThickness, spin, phase }
local cards = {}
-- rarityKey -> { key, button, selected, notSelected, label }
local tabs = {}
local tabOrder = {}
local activeTab = RARITY_ORDER[1]

local motionConns = {}
local cardsBuilt = false
local warnedPreview = false

-- ==========================================================================
-- §3) helpers
-- ==========================================================================
--[[ "Name" is an Instance property, so kitCard.Name is the instance's own name rather
	than the kit's label. Every kit lookup goes through here so that trap cannot be
	walked into. ]]
local function ff(inst: Instance?, childName: string): Instance?
	if not inst then
		return nil
	end
	return inst:FindFirstChild(childName)
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

-- The kit gave some labels a gradient and others none; this levels them so every rarity
-- word is painted the same way.
local function ensureGradient(inst: Instance): UIGradient
	local grad = inst:FindFirstChildOfClass("UIGradient")
	if not grad then
		grad = Instance.new("UIGradient")
		grad.Rotation = 90
		grad.Parent = inst
	end
	return grad
end

local function paintGradient(inst: Instance?, color: Color3)
	if inst then
		ensureGradient(inst).Color = ramp4(color)
	end
end

local function specialName(car): string
	local powerup = Config.POWERUPS[car.special]
	return powerup and powerup.name or "Crates"
end

-- ==========================================================================
-- §4) refresh — property writes only, never a teardown
-- ==========================================================================
local function refreshCard(carId: string, ownedSet: { [string]: boolean }?)
	local rec = cards[carId]
	if not rec then
		return
	end

	--[[ When refreshAll() hands us its single decode, trust it — INCLUDING for the cars it
		says you do not own. Falling through to CarRegistry.owns() on a false would re-decode
		the OwnedCars JSON once per unowned car, which is the exact cost the shared set
		exists to avoid. ]]
	local owned
	if ownedSet then
		owned = ownedSet[carId] == true
	else
		owned = CarRegistry.owns(player, carId)
	end
	local equipped = CarRegistry.equippedId(player) == carId

	rec.nameLabel.Text = owned and rec.car.name or UNKNOWN
	if rec.typeLabel then
		rec.typeLabel.Text = owned and specialName(rec.car) or UNKNOWN
	end
	rec.render.ImageColor3 = owned and UI.PAPER or SILHOUETTE

	-- House "selected" rule (stroke swaps to confirm green), spoken through the kit's
	-- own card stroke rather than through a new element. Only an OWNED car can be equipped.
	rec.stroke.Color = equipped and UI.CONFIRM or rec.strokeColor
	rec.stroke.Thickness = equipped and rec.strokeThickness * EQUIPPED_STROKE_MULT or rec.strokeThickness
end

local function refreshProgress(ownedSet: { [string]: boolean })
	local roster = CarRegistry.all()
	local total = #roster
	local owned = 0
	for _, car in ipairs(roster) do
		if ownedSet[car.id] then
			owned += 1
		end
	end

	local fraction = total > 0 and owned / total or 0
	if progressBar then
		progressBar.Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
		progressBar.Visible = fraction > 0.001
	end
	if progressAmount then
		progressAmount.Text = string.format("%d/%d Collected", owned, total)
	end
end

--[[ One decode of the OwnedCars JSON feeds every card AND the bar, instead of eight
	separate CarRegistry.owns() calls each re-decoding the same attribute. ]]
local function refreshAll()
	local ownedSet = CarRegistry.ownedSet(player)
	for carId in pairs(cards) do
		refreshCard(carId, ownedSet)
	end
	refreshProgress(ownedSet)
end

-- ==========================================================================
-- §5) tabs
-- ==========================================================================
local function selectTab(key: string, quiet: boolean?)
	if not tabs[key] then
		return
	end
	activeTab = key

	for tabKey, tab in pairs(tabs) do
		local on = tabKey == key
		tab.selected.Enabled = on
		tab.notSelected.Enabled = not on
	end

	if titleLabel then
		titleLabel.Text = "Index: " .. (RARITY_WORD[key] or key)
	end

	-- Filtering is a visibility flip, never a rebuild: UIListLayout skips hidden children
	-- and reflows on its own, and every viewport keeps rendering the model it already has.
	for _, rec in pairs(cards) do
		rec.wrapper.Visible = rec.car.rarity == key
	end

	if not quiet then
		kit.playSfx("TOGGLE")
	end
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

local function buildTabs()
	local rail = ff(panel, "TypeButtons")
	if not rail then
		warn("IndexUI: cloned kit frame has no TypeButtons rail — tabs not built")
		return
	end

	--[[ MOBILE: mirror the rail from the left edge to the right. See the header note —
		x 0.16-0.28 sits inside InputController's touch-steering half. ]]
	local pos = rail.Position
	rail.Position = UDim2.new(1 - pos.X.Scale, -pos.X.Offset, pos.Y.Scale, pos.Y.Offset)

	-- Match buttons to rarities by LayoutOrder, so the kit's names are irrelevant.
	local buttons = {}
	for _, child in ipairs(rail:GetChildren()) do
		if child:IsA("ImageButton") then
			table.insert(buttons, child)
		end
	end
	table.sort(buttons, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)

	for index, button in ipairs(buttons) do
		local key = RARITY_ORDER[index]
		if not key or not UI.RARITY[key] then
			-- More kit buttons than rarities: retire the spares rather than leave dead tabs.
			button:Destroy()
			continue
		end

		local selected = ff(button, "Selected")
		local notSelected = ff(button, "NotSelected")
		local label = ff(button, "Name")
		if not (selected and notSelected and label) then
			warn("IndexUI: kit tab is missing Selected/NotSelected/Name — skipping " .. button.Name)
			continue
		end

		button.Name = key -- kit names belong to another game; make the rail self-describing
		label.Text = RARITY_WORD[key] or key
		paintGradient(label, UI.RARITY[key])

		kit.addButtonFeedback(button)
		button.Activated:Connect(function()
			selectTab(key)
		end)

		tabs[key] = { key = key, button = button, selected = selected, notSelected = notSelected, label = label }
		table.insert(tabOrder, key)
	end

	if #tabOrder < #RARITY_ORDER then
		warn(string.format("IndexUI: kit rail has %d usable tabs, roster needs %d", #tabOrder, #RARITY_ORDER))
	end
end

local function buildCard(car, order: number, previewModel: Instance?)
	local accent = CarRegistry.rarityColor(car)

	local wrapper = cardTemplate:Clone()
	wrapper.Name = car.id
	wrapper.LayoutOrder = order
	wrapper.Parent = container

	local card = ff(wrapper, "Frame")
	local nameLabel = ff(card, "Name")
	local info = ff(card, "Info")
	local flatIcon = ff(card, "Icon")
	local stroke = card and card:FindFirstChildOfClass("UIStroke")

	-- The kit is the contract here. Say so plainly instead of erroring half-built.
	if not (card and nameLabel and flatIcon and stroke) then
		warn("IndexUI: kit cell is missing expected children — skipping '" .. tostring(car.id) .. "'")
		wrapper:Destroy()
		return
	end

	local typeLabel = ff(info, "Type")
	local rarityLabel = ff(info, "Rarity")
	if rarityLabel then
		rarityLabel.Text = RARITY_WORD[car.rarity] or "Common"
		paintGradient(rarityLabel, accent)
	end

	-- ---------- the render ----------
	-- The kit's card art is a full-bleed ImageLabel behind the text; the render takes its
	-- exact geometry and ZIndex so the layering is unchanged.
	local iconZ = flatIcon.ZIndex
	flatIcon.Visible = false -- MANDATORY: real game renders, never drawn icon art

	local render = kit.viewport({
		parent = card,
		name = "Render",
		model = previewModel,
		size = flatIcon.Size,
		position = flatIcon.Position,
		anchor = flatIcon.AnchorPoint,
		zoom = VIEW_ZOOM,
	})
	render.ZIndex = iconZ

	if not previewModel then
		-- Degrade, never error: a block in the car's own body colour.
		local block = Instance.new("Frame")
		block.Name = "Placeholder"
		block.Size = UDim2.fromScale(0.6, 0.34)
		block.Position = UDim2.fromScale(0.5, 0.55)
		block.AnchorPoint = Vector2.new(0.5, 0.5)
		block.BackgroundColor3 = (car.build and car.build.bodyColor) or UI.PAPER
		block.BorderSizePixel = 0
		block.ZIndex = iconZ
		block.Parent = card
		kit.corner(block, 6)

		if not warnedPreview then
			warnedPreview = true
			warn("IndexUI: no preview model for '" .. tostring(car.id) .. "' — showing placeholders")
		end
	end

	--[[ The whole cell is the subject, so the cell hovers. This makes it Active — safe for
		the same reason it is safe in GarageUI: the kit Container is a ScrollingFrame,
		which already consumes drags over this area. ]]
	kit.bindHover(card, { scale = CARD_HOVER })

	cards[car.id] = {
		car = car,
		wrapper = wrapper,
		card = card,
		render = render,
		nameLabel = nameLabel,
		typeLabel = typeLabel,
		stroke = stroke,
		strokeColor = stroke.Color,
		strokeThickness = stroke.Thickness,
		spin = SPIN_DPS + order * SPIN_STAGGER,
		phase = order * SPIN_PHASE,
	}
end

local function buildQuestLine()
	local quests = ff(panel, "Quests")
	local progress = ff(quests, "Progress")
	progressBar = ff(progress, "Bar")
	progressAmount = ff(progress, "Amount")

	--[[ The kit's strapline is three separate labels laid out left to right by LayoutOrder
		(Amount 0, Type 5, TextLabel 10) so the middle word can carry its own gradient.
		Reads as one sentence: "Collect All 8 Cars In CrashCars!" ]]
	local desc = ff(quests, "QuestDes")
	local total = #CarRegistry.all()
	local amount = ff(desc, "Amount")
	local kind = ff(desc, "Type")
	local tail = ff(desc, "TextLabel")
	if amount then
		amount.Text = "Collect All " .. tostring(total)
	end
	if kind then
		kind.Text = " Cars"
		paintGradient(kind, UI.GOLD)
	end
	if tail then
		tail.Text = " In CrashCars!"
	end
end

local function buildPanel(): boolean
	local template = findKitFrame()
	if not template then
		warn("IndexUI: kit frame " .. KIT_GUI .. ".Frames." .. KIT_FRAME .. " not found — index not built")
		return false
	end

	panel = template:Clone()
	panel.Name = FRAME_NAME
	panel.Visible = false
	panel.Parent = frames

	container = ff(panel, "Container")
	header = ff(panel, "Header")
	if not container or not header then
		warn("IndexUI: cloned kit frame has no Container/Header — index not built")
		panel:Destroy()
		panel = nil
		return false
	end
	headerBase = header.Position
	titleLabel = ff(header, "Name")

	-- Lift cell 1 out as the stamp, then clear the fifteen remaining dummy cells. The
	-- SPACE spacer keeps its LayoutOrder (-1e6) and stays as the grid's leading padding.
	cardTemplate = ff(container, CARD_TEMPLATE)
	if not cardTemplate then
		warn("IndexUI: kit Container has no template cell '" .. CARD_TEMPLATE .. "' — index not built")
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

	buildTabs()
	buildQuestLine()
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
	end

	cardTemplate:Destroy()
	cardTemplate = nil

	refreshAll()
	selectTab(activeTab, true) -- quiet: nobody pressed anything, this is the opening state
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

			--[[ ONE loop drives every render, and cards the active tab filtered out are
				skipped entirely — no point pivoting a model nobody can see. Manual math,
				never a tween loop (house rule). ]]
			for _, rec in pairs(cards) do
				if rec.wrapper.Visible then
					local model = rec.render:FindFirstChildOfClass("Model")
					if model then
						model:PivotTo(CFrame.Angles(0, math.rad((t * rec.spin + rec.phase) % 360), 0))
					end
				end
			end
		end)
	)
end

-- ==========================================================================
-- §8) init
-- ==========================================================================
function IndexUI.init(ctx)
	kit = ctx and ctx.kit
	frames = ctx and ctx.frames
	if not kit or not frames then
		warn("IndexUI: ctx is missing kit or frames — index not built")
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

	--[[ Reactive repaint. Money / Gems are deliberately NOT watched: the index shows no
		price and no button, so a balance change cannot alter a single pixel here. ]]
	player:GetAttributeChangedSignal(ATTR.OWNED):Connect(refreshAll)
	player:GetAttributeChangedSignal(ATTR.EQUIPPED):Connect(refreshAll)

	-- First paint waits for the profile: drawing "???" over cars you already own would lie.
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

return IndexUI
