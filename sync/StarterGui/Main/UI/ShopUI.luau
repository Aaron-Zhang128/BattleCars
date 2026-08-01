--[[ ShopUI (UI module — the Robux store)

	The shop screen, built on the uploaded kit's Store window. Every row is derived from
	Config.SHOP.TABS + Config.PRODUCTS / PASSES / CARS, so adding a catalog entry needs no
	edit in this file. A catalog entry that no tab claims still renders, in a trailing "More"
	section, so a product can never go silently unbuyable.

	AUTHORITY: the client never grants. A tap opens a confirm that states exactly what is
	bought for what; confirming fires Monetization and then this module waits. Balances and
	perks repaint ONLY from attributes the server writes, and from the server's own reply.

	HONESTY (Config's monetization comment is the spec, not decoration):
	  * Every id in Config.PRODUCTS / PASSES is 0 today. Those rows render as a deliberate
	    "Soon" state and can never open a purchase prompt that would error.
	  * The LIMITED offer and its countdown are recomputed here from LIMITED_POOL and
	    LIMITED_ROTATION_SECONDS with the SAME os.time() integer division
	    MonetizationService.currentLimited() uses, so client and server agree with zero
	    replication and the timer physically cannot invent urgency.
	  * Config.SHOP.LIMITED_DISCOUNT is deliberately NOT drawn. What a player is charged is
	    fixed by the dev product id, so a struck-through "was 99" would be a claim this UI
	    cannot keep. See HANDOFF.
	  * No gacha odds are displayed anywhere, so none can drift from the roll.

	Frame       registered as "Shop" (pinned) — open with ctx.kit.openFrame("Shop").
	            Cloned at runtime from PlayerGui.Alternate.Frames.Store into ctx.frames.
	            The kit ScreenGui is an art library: nothing inside it is modified or shown.
	Remote      Monetization  C->S ("product"|"pass", key)
	                          S->C (kind, payload) kind = granted|owned|failed|limited
	Attributes  reads only: Money Gems Vip DoubleMoney Magnet GoldenCar Spins
	            MoneyMultiplier OwnedCars EquippedCar ProfileLoaded
	Assets      ReplicatedStorage.CrashCore.Assets.Previews[carId] — real renders for the
	            car row (house rule: game imagery is the actual model, never drawn art)

	MOBILE: InputController owns the whole LEFT HALF of the screen for touch steering, and
	kit.bindHover sets Active = true on whatever it touches. Nothing this module makes Active
	is on screen during a match: the Store is a centred modal, every Active element (cards,
	buttons, the scrolling list) lives inside it, and the confirm's dim shade is deliberately
	left Active = false so it can never swallow a steering drag.

	Sections:
		§1  constants
		§2  state
		§3  helpers
		§4  kit templates (harvested before the container is cleared)
		§5  painters (card + buy-button states)
		§6  catalog -> sections
		§7  purchase flow (SellInfo confirm)
		§8  motion (manual RenderStepped math — house rule, no tween loops)
		§9  init
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local CarRegistry = require(sharedFolder:WaitForChild("CarRegistry"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))

local player = Players.LocalPlayer

local ShopUI = {}

local ATTR = Config.ATTR
local UI = Config.UI
local ART = Config.ART

-- ==========================================================================
-- §1) constants
-- ==========================================================================
local CROWN_ICON = "rbxassetid://98309176624393" -- the kit crown SideUI.Counters already uses
local BACKDROP_TRANSPARENCY = 0.45 -- the dim the kit art is drawn for
local FRAME_NAME = "Shop" -- pinned: the entry point calls kit.openFrame("Shop")
local CONFIRM_NAME = "ShopConfirm"
-- CarShopUI's pinned frame; the car row is a doorway to it. Was "Garage", which no
-- loaded module registers.
local GARAGE_FRAME = "CarShop"

local KIT_GUI = "Alternate" -- the uploaded kit's ScreenGui, used only as an art library
local KIT_TIMEOUT = 5 -- PlayerGui clones both ScreenGuis together; this is a safety net

--[[ Attributes MonetizationService owns. They are NOT in Config.ATTR yet — that service
	says so in its own header and keeps a local table for the same reason. HANDOFF has the
	paste-ready block. Named once here so no bare string is scattered through the file. ]]
local MON_ATTR = {
	VIP = "Vip",
	DOUBLE_MONEY = "DoubleMoney",
	MAGNET = "Magnet",
	GOLDEN_CAR = "GoldenCar",
	SPINS = "Spins",
	MONEY_MULTIPLIER = "MoneyMultiplier",
}

--[[ perk name (Config.PASSES[*].perk) -> the attribute mirroring it. Driven by perk, not
	pass key, exactly like MonetizationService. `starterPack` is absent on purpose: it is a
	one-time grant, not a standing perk, and nothing replicates it. See HANDOFF. ]]
local PERK_ATTR = {
	vip = MON_ATTR.VIP,
	doubleMoney = MON_ATTR.DOUBLE_MONEY,
	magnet = MON_ATTR.MAGNET,
	goldenCar = MON_ATTR.GOLDEN_CAR,
}

-- A change here means a grant may have landed: repaint, and answer a purchase in flight.
local GRANT_ATTR = {
	ATTR.MONEY,
	ATTR.GEMS,
	ATTR.OWNED,
	MON_ATTR.VIP,
	MON_ATTR.DOUBLE_MONEY,
	MON_ATTR.MAGNET,
	MON_ATTR.GOLDEN_CAR,
	MON_ATTR.SPINS,
	MON_ATTR.MONEY_MULTIPLIER,
}

-- A change here only repaints. Equipping a car must never sound like a purchase.
local REFRESH_ATTR = { ATTR.EQUIPPED }

--[[ Kit art ids, reused so the shop is the same drawing as the rest of the kit. Only the
	two with certain meaning are used semantically: the cash icon (it labels the amount on
	every kit money pack and heads the SellInfo dialog) and Robux (it sits beside every kit
	price). The rest are taken from the kit slot whose own label matched, and anything
	unmapped falls back to the kit's neutral chip tinted with the row accent — a deliberate
	coloured tile rather than a guessed object. ]]
local IMG = {
	CASH = ART.MONEY, -- the currency mark; shared with the rail counter and the arena pickup
	WALLET = ART.MONEY_WALLET,
	MONEYBAG = ART.MONEY_BAG,
	PILE = ART.MONEY_PILE,
	ROBUX = "rbxassetid://115923778456233",
	CHIP = "rbxassetid://71150462109394",
	CROWN = "rbxassetid://98284918132985", -- kit VIP banner icon
	MULTIPLIER = ART.MONEY_BUNDLE, -- kit "2x Cash" pass icon
	BOX = "rbxassetid://83666594802115", -- kit reward-box icon
	SPIN = "rbxassetid://112399300086939", -- kit lucky-block icon
}

--[[ Config `icon` name -> { image, tint }. Unmapped names fall through to the neutral chip.
	The three money packs each draw their own tier art (wallet -> bag -> vault) while plain
	`money` stays the bundle, so a pack reads as MORE of the thing the counter shows rather
	than as a different currency. ]]
local ICONS = {
	money = { image = IMG.CASH },
	moneyWallet = { image = IMG.WALLET },
	moneyBag = { image = IMG.MONEYBAG },
	moneyPile = { image = IMG.PILE },
	gem = { image = IMG.CASH, tint = UI.RARITY.EPIC },
	crown = { image = IMG.CROWN },
	gift = { image = IMG.BOX },
	spin = { image = IMG.SPIN },
}

-- Row accents. Drive the card sheen, the starburst and the price ramp.
local GRANT_ACCENT = {
	gems = UI.RARITY.EPIC,
	money = UI.CONFIRM, -- cash green, to match the art; gold now belongs to crowns alone
	spins = UI.RARITY.RARE,
	extraLife = UI.DANGER,
}
local PERK_ACCENT = {
	vip = UI.GOLD,
	doubleMoney = UI.LIME,
	magnet = UI.RARITY.RARE,
	goldenCar = UI.RARITY.LEGENDARY,
	starterPack = UI.CONFIRM,
}

-- Kid words for what a product actually hands over.
local GRANT_WORD = {
	gems = "Gems",
	money = "Money",
	spins = "Spins",
	extraLife = "Extra Life",
}

--[[ Layout, in Container-relative scale. The heights ARE the kit's own row heights, so a
	rebuilt shop measures exactly like the art it came from. ]]
local PER_ROW = 3
local CARD_W = 0.316 -- kit card width inside a row
local ROW_W = 0.945
local ROW_H = { pack = 0.43, pass = 0.536, box = 0.692 }
local BANNER_H = 0.41
local CAPTION_W, CAPTION_H = 0.9, 0.03
--[[ 0.05, not the kit's 0.06: the kit authors a caption as a 0.03-tall frame holding a
	label 3x that height, so the glyphs overflow ~14px past the frame at both ends. The gap has
	to clear that overflow or a caption touches the row above it. ]]
local LIST_PADDING = 0.05

local EXTRA_KEY = "EXTRA"
local EXTRA_LABEL = "More" -- trailing section for catalog entries no tab claimed

local BUY_LOCK = 0.6 -- >= Net.REQUEST_GAP (0.5) so a double tap cannot outrun the reply
local AWAIT_WINDOW = 150 -- a Robux prompt is a human round trip; BUY_OK waits this long
local SCROLL_MARGIN = 8 -- pixels of breathing room above a deep-linked section
local TICK_SECONDS = 1 -- countdown repaint rate

local BURST_DPS = 9 -- limited-banner starburst, degrees per second
local DRIFT_FREQ, DRIFT_AMP = 1.2, 4 -- quick-button bob

local OWNED_STROKE_MULT = 2 -- multiplies the kit's authored stroke; see refreshEntry
local CARD_HOVER = 1.04 -- cards sit a hair apart; the house 1.07 would overlap

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit, net, frames
local panel, container
local confirm, confirmShade, confirmNotice, confirmTitle
local moneyValue, gemValue
local quickButtons = {}

local TPL = {} -- kit templates, harvested before the container is cleared

local entries = {} -- [id] = record; see §6
local backdrop -- the dim behind the window; see init
local sectionAnchors = {} -- [tab key] = caption frame to scroll to
local limitedRec = nil -- { key, endsAt, timer, banner }
local motionConns = {}
local carWells = {} -- [carId] = Frame waiting for a preview model
local pendingRec = nil -- the record the confirm is currently asking about
local awaiting = nil -- { key, at } — the purchase whose grant we are listening for
local orderSeq = 0
local warnedPreview = false

-- ==========================================================================
-- §3) helpers
-- ==========================================================================
local function readNumber(attr: string): number
	local value = player:GetAttribute(attr)
	return type(value) == "number" and value or 0
end

local function nextOrder(): number
	orderSeq += 1
	return orderSeq
end

--[[ Kit frames carry a TextLabel called "Name", which shadows Instance.Name on a dot
	lookup. Every kit-label read goes through here so that trap is impossible. ]]
local function childNamed(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	return parent:FindFirstChild(name)
end

local function findDeep(root: Instance?, name: string): Instance?
	if not root then
		return nil
	end
	return root:FindFirstChild(name, true)
end

local function setText(parent: Instance?, name: string, text: string)
	local label = childNamed(parent, name)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function ramp3(color: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, color:Lerp(UI.PAPER, 0.35)),
		ColorSequenceKeypoint.new(0.5, color),
		ColorSequenceKeypoint.new(1, color:Lerp(UI.INK, 0.25)),
	})
end

local function iconFor(name: string?, accent: Color3): (string, Color3)
	local def = name and ICONS[name] or nil
	if def then
		return def.image, def.tint or UI.PAPER
	end
	return IMG.CHIP, accent
end

local function grantWord(def): string
	return GRANT_WORD[def.grant] or def.name or "Reward"
end

--[[ What an offer hands over, in the fewest honest words: "250 Gems", "1 Extra Life".
	The card and the confirm both read this, so the two can never describe different things. ]]
local function offerLine(source: string, def): string
	if source == "PRODUCTS" and type(def.amount) == "number" then
		return MathUtil.comma(def.amount) .. " " .. grantWord(def)
	end
	return def.name or "Offer"
end

local function isConfigured(def): boolean
	return type(def.id) == "number" and def.id ~= 0
end

local function ownsPass(def): boolean
	local attr = type(def.perk) == "string" and PERK_ATTR[def.perk] or nil
	if not attr then
		return false -- no replicated perk (starterPack): the server still refuses a re-buy
	end
	return player:GetAttribute(attr) == true
end

--[[ The limited offer, from the clock alone. The same derivation, line for line, as
	MonetizationService.currentLimited() — os.time() is UTC epoch seconds on every machine,
	which is what lets this countdown be true without a single packet. ]]
local function currentLimited(): (string?, number)
	local shop = Config.SHOP
	local pool = shop and shop.LIMITED_POOL or nil
	local period = shop and shop.LIMITED_ROTATION_SECONDS or nil
	if type(pool) ~= "table" or #pool == 0 then
		return nil, 0
	end
	if type(period) ~= "number" or period ~= period or period <= 0 then
		return nil, 0
	end
	local slot = math.floor(os.time() / period)
	return pool[slot % #pool + 1], (slot + 1) * period
end

-- "New deal in 5h 12m" — one clause, kid-simple, always rounded DOWN.
local function countdownText(endsAt: number): string
	local left = math.max(0, math.floor(endsAt - os.time()))
	local hours = math.floor(left / 3600)
	local minutes = math.floor((left % 3600) / 60)
	if hours > 0 then
		return string.format("New deal in %dh %dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("New deal in %dm", minutes)
	end
	return string.format("New deal in %ds", left)
end

local function catalogDef(key: string)
	local product = Config.PRODUCTS[key]
	if product then
		return "PRODUCTS", product
	end
	local pass = Config.PASSES[key]
	if pass then
		return "PASSES", pass
	end
	return nil, nil
end

local function accentFor(source: string, def): Color3
	if source == "PASSES" then
		return PERK_ACCENT[def.perk] or UI.GOLD
	end
	return GRANT_ACCENT[def.grant] or UI.GOLD
end

-- Stable, cheapest first — the kit's reading order and the garage's.
local function sortedKeys(catalog): { string }
	local keys = {}
	for key in pairs(catalog) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		local ra = tonumber(catalog[a].robux) or 0
		local rb = tonumber(catalog[b].robux) or 0
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	return keys
end

-- ==========================================================================
-- §4) kit templates
-- ==========================================================================

--[[ Kit windows are authored translucent because they open over a dimmed backdrop this
	game does not have; over the arena they wash out. BackgroundTransparency cannot fix it,
	because the gradient's alpha multiplies on top — so the sequence itself is flattened. ]]
local function flattenGradient(inst: Instance?)
	if not inst then
		return
	end
	local grad = inst:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Transparency = NumberSequence.new(0)
	end
end

--[[ Clones one of every kit shape the shop needs. Runs BEFORE the container is emptied,
	because the templates ARE the kit's rows. ]]
local function harvest(): boolean
	local cash = childNamed(container, "Cash")
	local column1 = childNamed(cash, "column1")
	local pack = childNamed(column1, "1")
	local gamepasses = childNamed(container, "Gamepasses")
	local pass = childNamed(gamepasses, "SuperLuck")
	local lucky = childNamed(container, "LuckyBlocks")
	local box = childNamed(lucky, "Secret")
	local banner = childNamed(container, "StarterPack")
	local caption = childNamed(container, "TextFrame")
	local info = childNamed(pack, "Info")

	if not (pack and info and gamepasses and pass and box and banner and caption) then
		warn("ShopUI: the kit Store is missing a template row — shop not built")
		return false
	end

	TPL.pack = pack:Clone()
	TPL.pass = pass:Clone()
	TPL.box = box:Clone()
	TPL.banner = banner:Clone()
	TPL.caption = caption:Clone()
	TPL.info = info:Clone() -- amount + currency icon; also the header wallet pill

	-- An empty row: the kit's own 3-across strip with its cards taken out.
	TPL.row = gamepasses:Clone()
	for _, child in ipairs(TPL.row:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	-- The kit's green buy ramp, kept so a configured price repaints back to it exactly.
	local buyButtons = findDeep(TPL.pass, "BuyButtons")
	local button = childNamed(buyButtons, "1")
	local grad = button and button:FindFirstChildOfClass("UIGradient")
	TPL.buyRamp = grad and grad.Color or ramp3(UI.CONFIRM)
	return true
end

local function clearContainer()
	for _, child in ipairs(container:GetChildren()) do
		--[[ The kit's ScrollBarAdjuster goes with the rows: it is foreign code from the
			uploaded kit and this window sets its own bar. The UIListLayout and UIPadding
			stay — they are the window's geometry, not its content. ]]
		if child:IsA("GuiObject") or child:IsA("LuaSourceContainer") then
			child:Destroy()
		end
	end
end

-- ==========================================================================
-- §5) painters
-- ==========================================================================

--[[ House card sheen (accent -> GLASS) written onto the kit card's OWN gradient, so every
	row reads as its own thing without one new shape being introduced. ]]
local function styleCard(card: Instance, accent: Color3)
	local grad = card:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new(accent:Lerp(UI.GLASS, 0.55), UI.GLASS)
		grad.Transparency = NumberSequence.new(0)
	end
	local decor = childNamed(card, "Decor")
	local burst = findDeep(decor, "Starbust")
	if burst and burst:IsA("ImageLabel") then
		burst.ImageColor3 = accent
	end
	local fade = findDeep(decor, "IconFade")
	if fade and fade:IsA("ImageLabel") then
		fade.ImageColor3 = accent
	end
end

--[[ Repaints a kit buy button in place. The mode decides the whole button, so a state
	change is property writes only and never a rebuild (which would restart its UIScale feel).
	  robux  a real price, purchasable        soon   id not pasted yet, inert
	  owned  already held, not re-purchasable money  a money/gem price (the car row)
	  free   the starter car                  busy   a request is in flight ]]
local function paintBuy(rec, mode: string)
	local btn = rec.buy
	if not btn then
		return
	end
	local info = childNamed(btn, "Info")
	local price = childNamed(info, "Price")
	local icon = info and info:FindFirstChildWhichIsA("ImageLabel") or nil
	local grad = btn:FindFirstChildOfClass("UIGradient")

	local text, ramp, image, tint, active = "", TPL.buyRamp, nil, UI.PAPER, true

	if mode == "robux" then
		text = tostring(rec.def.robux or 0)
		image = IMG.ROBUX
	elseif mode == "money" then
		text = MathUtil.comma(rec.price or 0)
		ramp = ramp3(rec.accent)
		image = IMG.CASH
		tint = rec.currency == "Gems" and UI.RARITY.EPIC or UI.PAPER
	elseif mode == "owned" then
		text = "Owned"
		ramp = ramp3(UI.CONFIRM:Lerp(UI.GLASS, 0.35))
		active = false
	elseif mode == "soon" then
		text = "Soon"
		ramp = ramp3(UI.GLASS:Lerp(UI.PAPER, 0.3))
	elseif mode == "busy" then
		text = "..."
		ramp = ramp3(UI.GLASS:Lerp(UI.PAPER, 0.3))
		active = false
	elseif mode == "free" then
		text = "Free"
		ramp = ramp3(UI.CONFIRM)
	end

	if price and price:IsA("TextLabel") then
		price.Text = text
	end
	if icon then
		icon.Visible = image ~= nil
		if image then
			icon.Image = image
			icon.ImageColor3 = tint
		end
	end
	if grad then
		grad.Color = ramp
		grad.Transparency = NumberSequence.new(0)
	end

	btn.Active = active
	btn.Selectable = active
	btn.AutoButtonColor = false
	rec.mode = mode
end

local function refreshEntry(rec)
	if rec.kind == "car" then
		local owned = CarRegistry.owns(player, rec.carId)
		if owned then
			paintBuy(rec, "owned")
		elseif (rec.price or 0) <= 0 then
			paintBuy(rec, "free")
		else
			paintBuy(rec, "money")
		end
		if rec.stroke then
			--[==[ House "selected" rule: an owned card's stroke swaps to confirm green and
				thickens. The thickness is a MULTIPLE of the kit's OWN authored weight, never a
				pixel count: a UIStroke on kit art expands by roughly the card's own WIDTH per
				unit of Thickness (the kit authors 0.02-0.18), so an absolute 3 does not draw a
				3px ring -- it drops a solid green slab several cards wide over the section.
				Same trap as IndexUI / CarShopUI. ]==]
			rec.stroke.Color = owned and UI.CONFIRM or UI.INK
			rec.stroke.Thickness = owned and (rec.strokeBase or 0) * OWNED_STROKE_MULT or rec.strokeBase
		end
		return
	end

	if rec.busy then
		paintBuy(rec, "busy")
		return
	end
	if rec.source == "PASSES" and ownsPass(rec.def) then
		paintBuy(rec, "owned")
		return
	end
	paintBuy(rec, isConfigured(rec.def) and "robux" or "soon")
end

local function refreshAll()
	for _, rec in pairs(entries) do
		refreshEntry(rec)
	end
end

local function refreshWallet()
	if moneyValue then
		moneyValue.Text = MathUtil.comma(readNumber(ATTR.MONEY))
	end
	if gemValue then
		gemValue.Text = MathUtil.comma(readNumber(ATTR.GEMS))
	end
end

-- ==========================================================================
-- §6) catalog -> sections
-- ==========================================================================
local openConfirm -- defined in §7, called from the card wiring below

local function openGarage()
	if kit.isFrameRegistered(GARAGE_FRAME) then
		kit.openFrame(GARAGE_FRAME) -- closes this window on the way, one at a time
	else
		kit.notify("Garage is loading!", "gold")
	end
end

local function wireCard(rec)
	styleCard(rec.card, rec.accent)

	rec.stroke = rec.card:FindFirstChildOfClass("UIStroke")
	rec.strokeBase = rec.stroke and rec.stroke.Thickness or nil
	--[[ The whole card is the choice, so the card hovers, not just its button. Safe to make
		Active: it only exists inside a centred modal that is never open while driving. ]]
	kit.bindHover(rec.card, { scale = CARD_HOVER, stroke = rec.stroke })

	if rec.buy then
		kit.addButtonFeedback(rec.buy)
		rec.buy.Activated:Connect(function()
			if rec.kind == "car" then
				openGarage()
				return
			end
			if rec.mode == "owned" or rec.mode == "busy" then
				return
			end
			if rec.mode == "soon" then
				-- Never prompt a purchase that would error. Say so rather than going dead.
				kit.notify("Coming soon!", "gold")
				return
			end
			openConfirm(rec)
		end)
	end

	entries[rec.id] = rec
	refreshEntry(rec)
end

local function newRow(kind: string): Frame
	local row = TPL.row:Clone()
	row.Name = "Row"
	row.Size = UDim2.new(ROW_W, 0, ROW_H[kind] or ROW_H.pass, 0)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = container
	return row
end

local function addCaption(key: string, label: string)
	local caption = TPL.caption:Clone()
	caption.Name = "Caption_" .. key
	caption.Size = UDim2.new(CAPTION_W, 0, CAPTION_H, 0)
	caption.BackgroundTransparency = 1
	caption.LayoutOrder = nextOrder()
	caption.Parent = container
	setText(caption, "Text", label)
	sectionAnchors[key] = caption
end

--[[ A money / spins / extra-life pack: the kit's cash card. Everything it says comes
	straight out of Config — name, how much, price — so it cannot describe something else. ]]
local function fillPack(card, rec)
	setText(card, "Name", rec.def.name or rec.key)
	local info = childNamed(card, "Info")
	setText(info, "Amount", MathUtil.comma(rec.def.amount or 0))
	local icon = info and info:FindFirstChildWhichIsA("ImageLabel") or nil
	if icon then
		local image, tint = iconFor(rec.def.icon, rec.accent)
		icon.Image = image
		icon.ImageColor3 = tint
	end
end

-- A pass: the kit's gamepass card. The blurb is Config's own one-liner, verbatim.
local function fillPass(card, rec)
	setText(card, "Name", rec.def.name or rec.key)
	setText(card, "Des", rec.def.blurb or "")
	local icon = childNamed(card, "Icon")
	if icon and icon:IsA("ImageLabel") then
		local image, tint = iconFor(rec.def.icon, rec.accent)
		icon.Image = image
		icon.ImageColor3 = tint
	end
end

--[[ A car: the kit's box card with a REAL viewport render where its icon was (house rule —
	game imagery is the actual model, never drawn art). Its button is a doorway, not a till:
	cars cost money, and the garage owns that flow and that remote. ]]
local function fillCar(card, rec)
	setText(card, "Name", rec.car.name)

	local icon = childNamed(card, "Icon")
	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Size = (icon and icon.Size) or UDim2.fromScale(0.758, 0.586)
	well.Position = (icon and icon.Position) or UDim2.fromScale(0.5, 0.41)
	well.AnchorPoint = (icon and icon.AnchorPoint) or Vector2.new(0.5, 0.5)
	well.BackgroundTransparency = 1
	well.ZIndex = (icon and icon.ZIndex) or 1
	well.Parent = card
	if icon then
		icon:Destroy()
	end

	local decorIcon = findDeep(childNamed(card, "Decor"), "Icon")
	if decorIcon and decorIcon:IsA("ImageLabel") then
		decorIcon.ImageColor3 = rec.accent
		decorIcon.ImageTransparency = 0.75
	end
	carWells[rec.car.id] = well

	--[[ The odds strip this card wears in the kit describes a gacha this card is not. It
		becomes the rarity word instead, in the rarity's own colour. ]]
	local outcomes = childNamed(card, "Outcomes")
	if outcomes then
		local rarity = TPL.caption:Clone()
		rarity.Name = "Rarity"
		rarity.Size = outcomes.Size
		rarity.Position = outcomes.Position
		rarity.AnchorPoint = outcomes.AnchorPoint
		rarity.BackgroundTransparency = 1
		rarity.ZIndex = outcomes.ZIndex
		rarity.Parent = card

		local word = childNamed(rarity, "Text")
		if word and word:IsA("TextLabel") then
			word.Size = UDim2.fromScale(0.9, 1)
			word.Text = rec.car.rarity or "COMMON"
			word.TextColor3 = rec.accent
			local grad = word:FindFirstChildOfClass("UIGradient")
			if grad then
				grad:Destroy()
			end
		end
		outcomes:Destroy()
	end
end

local function addGrid(list: { any }, kind: string, fill)
	local row, placed = nil, 0
	for _, rec in ipairs(list) do
		if placed % PER_ROW == 0 then
			row = newRow(kind)
		end
		local card = TPL[kind]:Clone()
		card.Name = rec.id
		card.Size = UDim2.fromScale(CARD_W, 1)
		card.LayoutOrder = placed + 1
		card.Parent = row
		rec.card = card
		rec.buy = childNamed(findDeep(card, "BuyButtons"), "1")
		fill(card, rec)
		wireCard(rec)
		placed += 1
	end
end

--[[ What the limited offer actually hands over, for the banner's reward slots. Derived from
	the same Config fields the server grants from, so it cannot promise something else. ]]
local function limitedRewards(source: string, def): { any }
	local list = {}
	if source == "PRODUCTS" then
		table.insert(list, {
			icon = def.icon,
			name = grantWord(def),
			amount = "+" .. MathUtil.comma(def.amount or 0),
		})
		return list
	end
	if type(def.grantMoney) == "number" and def.grantMoney > 0 then
		table.insert(list, { icon = "money", name = "Money", amount = "+" .. MathUtil.comma(def.grantMoney) })
	end
	if type(def.grantCar) == "string" then
		local car = CarRegistry.get(def.grantCar)
		table.insert(list, { icon = "car", name = "Car", amount = car and car.name or def.grantCar })
	end
	if #list == 0 then
		table.insert(list, { icon = def.icon, name = def.name or "Perk", amount = "Forever" })
	end
	return list
end

local function addLimited(tabKey: string, label: string, offerKey: string)
	local source, def = catalogDef(offerKey)
	if not def then
		return
	end

	addCaption(tabKey, label)

	local banner = TPL.banner:Clone()
	banner.Name = "Limited"
	banner.Size = UDim2.new(ROW_W, 0, BANNER_H, 0)
	banner.LayoutOrder = nextOrder()
	banner.Parent = container

	local rec = {
		id = "LIMITED_" .. offerKey,
		key = offerKey,
		source = source,
		def = def,
		kind = "banner",
		accent = accentFor(source, def),
		card = banner,
		buy = childNamed(findDeep(banner, "BuyButtons"), "1"),
	}

	setText(banner, "Name", def.name or offerKey)

	local rewards = childNamed(banner, "Rewards")
	if rewards then
		local wanted = limitedRewards(source, def)
		-- By name, never GetChildren order: the kit's slots are "1".."3" and must stay so.
		for slot = 1, 3 do
			local frame = childNamed(rewards, tostring(slot))
			if frame then
				local reward = wanted[slot]
				if reward then
					setText(frame, "Name", reward.name)
					setText(frame, "Amount", reward.amount)
					local icon = childNamed(frame, "Icon")
					if icon and icon:IsA("ImageLabel") then
						local image, tint = iconFor(reward.icon, rec.accent)
						icon.Image = image
						icon.ImageColor3 = tint
					end
				else
					frame:Destroy()
				end
			end
		end
	end

	wireCard(rec)

	local timer = childNamed(banner, "Timer")
	local _, endsAt = currentLimited()
	if timer and timer:IsA("TextLabel") then
		timer.Text = countdownText(endsAt)
	end
	limitedRec = { key = offerKey, endsAt = endsAt, timer = timer, banner = banner }
end

local function makeProductRec(key: string)
	local def = Config.PRODUCTS[key]
	return {
		id = "PRODUCTS_" .. key,
		key = key,
		source = "PRODUCTS",
		def = def,
		kind = "pack",
		accent = accentFor("PRODUCTS", def),
	}
end

local function makePassRec(key: string)
	local def = Config.PASSES[key]
	return {
		id = "PASSES_" .. key,
		key = key,
		source = "PASSES",
		def = def,
		kind = "pass",
		accent = accentFor("PASSES", def),
	}
end

local function buildSections()
	local claimed = {}

	local function productList(filter: string?): { any }
		local list = {}
		for _, key in ipairs(sortedKeys(Config.PRODUCTS)) do
			if filter == nil or Config.PRODUCTS[key].grant == filter then
				claimed[key] = true
				table.insert(list, makeProductRec(key))
			end
		end
		return list
	end

	local function passList(): { any }
		local list = {}
		for _, key in ipairs(sortedKeys(Config.PASSES)) do
			claimed[key] = true
			table.insert(list, makePassRec(key))
		end
		return list
	end

	local function carList(): { any }
		local list = {}
		for _, car in ipairs(CarRegistry.all()) do
			table.insert(list, {
				id = "CARS_" .. car.id,
				key = car.id,
				source = "CARS",
				kind = "car",
				car = car,
				carId = car.id,
				price = car.price or 0,
				currency = car.currency or "Money",
				accent = CarRegistry.rarityColor(car),
			})
		end
		return list
	end

	local tabs = (Config.SHOP and Config.SHOP.TABS) or {}
	for _, tab in ipairs(tabs) do
		if type(tab) == "table" and type(tab.key) == "string" then
			local label = tab.label or tab.key
			if tab.source == "PRODUCTS" then
				local list = productList(tab.filter)
				if #list > 0 then
					addCaption(tab.key, label)
					addGrid(list, "pack", fillPack)
				end
			elseif tab.source == "PASSES" then
				local list = passList()
				if #list > 0 then
					addCaption(tab.key, label)
					addGrid(list, "pass", fillPass)
				end
			elseif tab.source == "CARS" then
				local list = carList()
				if #list > 0 then
					addCaption(tab.key, label)
					-- The box card is the widest kit shape, so a real render has room.
					addGrid(list, "box", fillCar)
				end
			elseif tab.source == "LIMITED" then
				local offerKey = currentLimited()
				if offerKey then
					addLimited(tab.key, label, offerKey)
				end
			end
		end
	end

	--[[ Anything the tabs did not claim still gets a home. Without this, a product whose
		grant no tab filters for (spins and extraLife — three entries TODAY) would be
		invisible and unbuyable while looking perfectly configured in Config. ]]
	local extraProducts, extraPasses = {}, {}
	for _, key in ipairs(sortedKeys(Config.PRODUCTS)) do
		if not claimed[key] then
			table.insert(extraProducts, makeProductRec(key))
		end
	end
	for _, key in ipairs(sortedKeys(Config.PASSES)) do
		if not claimed[key] then
			table.insert(extraPasses, makePassRec(key))
		end
	end
	if #extraProducts > 0 or #extraPasses > 0 then
		addCaption(EXTRA_KEY, EXTRA_LABEL)
		if #extraProducts > 0 then
			addGrid(extraProducts, "pack", fillPack)
		end
		if #extraPasses > 0 then
			addGrid(extraPasses, "pass", fillPass)
		end
	end
end

--[[ Deep link. The kit's own scroll helper left with its disabled script, so this is the
	whole of it: measure the caption against the viewport and jump the canvas. ]]
local function scrollTo(key: string)
	local anchor = sectionAnchors[key]
	if not anchor or not anchor.Parent or container.AbsoluteSize.Y <= 0 then
		return
	end
	local offset = anchor.AbsolutePosition.Y - container.AbsolutePosition.Y + container.CanvasPosition.Y
	container.CanvasPosition = Vector2.new(0, math.max(0, offset - SCROLL_MARGIN))
	kit.playSfx("TICK")
end

-- ==========================================================================
-- §7) purchase flow
-- ==========================================================================
local function closeConfirm()
	if not confirm or not confirm.Visible then
		return
	end
	if confirmShade then
		confirmShade.Visible = false
	end
	kit.playSfx("CLOSE")
	kit.popOut(confirm)
end

--[[ Deliberately NOT registered with the frame manager: that manager is one-window-at-a-
	time, so registering the confirm would slam the shop shut underneath it. ]]
function openConfirm(rec)
	if not confirm then
		return
	end
	pendingRec = rec

	if confirmTitle then
		confirmTitle.Text = "Buy this?"
	end
	if confirmNotice then
		-- Exactly what is bought, for exactly what. Never a rounded or discounted price.
		confirmNotice.Text = string.format("%s for %d Robux?", offerLine(rec.source, rec.def), rec.def.robux or 0)
	end
	if confirmShade then
		confirmShade.Visible = true
	end
	kit.playSfx("OPEN")
	kit.popIn(confirm)
end

--[[ Fires and waits. No optimistic flip anywhere: the button dims for BUY_LOCK so a double
	tap cannot spend twice, and the only things that repaint the shop afterwards are the
	server's reply and the attributes the server writes. ]]
local function confirmPurchase()
	local rec = pendingRec
	pendingRec = nil
	closeConfirm()
	if not rec or rec.busy then
		return
	end
	if not isConfigured(rec.def) then
		return -- unreachable through the UI; belt and braces so no path can prompt at id 0
	end
	if not net or not net.Monetization then
		kit.playSfx("DENY")
		kit.notify("Shop is offline!", "red")
		return
	end
	if player:GetAttribute(ATTR.PROFILE_LOADED) ~= true then
		kit.playSfx("DENY")
		kit.notify("One second...", "gold")
		return
	end

	rec.busy = true
	refreshEntry(rec)
	awaiting = { key = rec.key, at = os.clock() }

	task.delay(BUY_LOCK, function()
		if rec.busy then
			rec.busy = false
			refreshEntry(rec)
		end
	end)

	net.Monetization:FireServer(rec.source == "PASSES" and "pass" or "product", rec.key)
end

--[[ The server pushes only refusals today — every success already lands as an attribute the
	shop is watching — but the pinned contract names four kinds, and all four are handled so
	a later server change cannot go unheard. ]]
local function onServerReply(kind, payload)
	if kind == "failed" then
		local reason = type(payload) == "table" and payload.reason or nil
		awaiting = nil
		kit.playSfx("DENY")
		kit.notify(type(reason) == "string" and reason ~= "" and reason or "Not available yet!", "red")
		refreshAll()
	elseif kind == "granted" or kind == "owned" then
		awaiting = nil
		kit.playSfx("BUY_OK")
		kit.notify("Thanks!", "green")
		refreshAll()
	elseif kind == "limited" then
		-- The server rotated first. Repaint from the clock; both sides compute the same key.
		if limitedRec and limitedRec.timer then
			local _, endsAt = currentLimited()
			limitedRec.endsAt = endsAt
			limitedRec.timer.Text = countdownText(endsAt)
		end
	end
end

--[[ A grant lands as an attribute, never as a message, so this is where a purchase is
	actually confirmed to the player: one sound, once, and only inside the window in which a
	real Robux prompt could still have been open. ]]
local function onGrantAttribute()
	refreshWallet()
	refreshAll()
	if awaiting and os.clock() - awaiting.at <= AWAIT_WINDOW then
		awaiting = nil
		kit.playSfx("BUY_OK")
		kit.notify("Thanks!", "green")
	end
end

local function buildConfirm(kitFrames: Instance): boolean
	local template = childNamed(kitFrames, "SellInfo")
	if not template then
		warn("ShopUI: kit SellInfo missing — a purchase would have no confirm, shop not built")
		return false
	end

	--[[ Dim, never a blocker. Active = true here would swallow a touch drag, and
		InputController reads the left half of the screen as steering (see the mobile note). ]]
	confirmShade = Instance.new("Frame")
	confirmShade.Name = "ShopConfirmShade"
	confirmShade.Size = UDim2.fromScale(1, 1)
	confirmShade.Position = UDim2.fromScale(0.5, 0.5)
	confirmShade.AnchorPoint = Vector2.new(0.5, 0.5)
	confirmShade.BackgroundColor3 = UI.INK
	confirmShade.BackgroundTransparency = 0.45
	confirmShade.BorderSizePixel = 0
	confirmShade.Active = false
	confirmShade.Visible = false
	confirmShade.ZIndex = panel.ZIndex + 100
	confirmShade.Parent = frames

	confirm = template:Clone()
	confirm.Name = CONFIRM_NAME
	confirm.Position = UDim2.fromScale(0.5, 0.5)
	confirm.AnchorPoint = Vector2.new(0.5, 0.5)
	confirm.Visible = false
	confirm.ZIndex = panel.ZIndex + 101
	confirm.Parent = frames
	flattenGradient(confirm)

	local header = childNamed(confirm, "Header")
	flattenGradient(header)
	confirmTitle = childNamed(header, "Name")
	confirmNotice = childNamed(confirm, "Notice")

	local buttons = childNamed(confirm, "Buttons")
	local buy = childNamed(buttons, "Sell")
	local cancel = childNamed(buttons, "Cancel")
	local close = childNamed(childNamed(header, "Buttons"), "Close")

	if buy and buy:IsA("GuiButton") then
		setText(buy, "Name", "Buy")
		kit.addButtonFeedback(buy)
		buy.Activated:Connect(confirmPurchase)
	end
	if cancel and cancel:IsA("GuiButton") then
		setText(cancel, "Name", "Cancel")
		kit.addButtonFeedback(cancel)
		cancel.Activated:Connect(function()
			pendingRec = nil
			closeConfirm()
		end)
	end
	if close and close:IsA("GuiButton") then
		kit.addButtonFeedback(close)
		close.Activated:Connect(function()
			pendingRec = nil
			closeConfirm()
		end)
	end
	return true
end

-- ==========================================================================
-- §8) motion — manual RenderStepped math (house rule), alive only while open
-- ==========================================================================
local function stopMotion()
	for _, conn in ipairs(motionConns) do
		conn:Disconnect()
	end
	table.clear(motionConns)
	for _, entry in ipairs(quickButtons) do
		entry.inst.Position = entry.base
	end
end

local function startMotion()
	if #motionConns > 0 then
		return
	end

	local burst = limitedRec and findDeep(childNamed(limitedRec.banner, "Decor"), "Starbust") or nil
	if burst and not burst:IsA("ImageLabel") then
		burst = nil
	end

	local t, since = 0, 0
	table.insert(
		motionConns,
		RunService.RenderStepped:Connect(function(dt)
			if not panel.Visible then
				return
			end
			t += dt
			since += dt

			-- Each button gets its own phase so the pair never bobs in lockstep.
			for i, entry in ipairs(quickButtons) do
				entry.inst.Position = entry.base
					+ UDim2.fromOffset(0, MathUtil.drift(t, DRIFT_FREQ, i * 0.9, DRIFT_AMP))
			end

			if burst and burst.Parent then
				burst.Rotation = (t * BURST_DPS) % 360
			end

			if since < TICK_SECONDS then
				return
			end
			since = 0

			if limitedRec and limitedRec.timer and limitedRec.timer.Parent then
				if os.time() >= limitedRec.endsAt then
					local key, endsAt = currentLimited()
					limitedRec.endsAt = endsAt
					if key and key ~= limitedRec.key then
						--[[ The offer itself rolled over mid-session. Retitle in place: a
							rebuild would yank the list out from under the player's thumb. ]]
						limitedRec.key = key
						local _, def = catalogDef(key)
						if def then
							setText(limitedRec.banner, "Name", def.name or key)
						end
					end
				end
				limitedRec.timer.Text = countdownText(limitedRec.endsAt)
			end
		end)
	)
end

-- ==========================================================================
-- §6b) authored sections — the kit Store's own rows, bound to this catalog
-- ==========================================================================
--[[ RESTORE, DON'T REBUILD. The shop used to clearContainer() and generate its rows from
	Config, which threw away every authored section — the hero banner, the limited card,
	the gamepass strip, the money grid — and replaced them with flat generated cards that
	all painted "Soon", because every id in PRODUCTS/PASSES is still 0. The window kept its
	beautiful frame and lost everything inside it.

	So the kit's rows STAY, and the catalog is bound onto the slots the kit already drew.
	SLOTS below is the whole mapping and the only thing to edit when the catalog changes:
	every one of the 16 catalog entries claims exactly one authored buy button, and each
	`hide` entry is a kit slot this game has no product for. Nothing is generated, nothing
	is destroyed, and no key is bound twice (two records under one key would collide in
	`entries` and one of them would stop repainting forever).

	What is deliberately NOT done here: styleCard(). The generated shop recoloured every
	card's gradient to a per-row accent, which is exactly what flattened the kit's art. The
	authored gradients are the reason this window looks the way it does, so they are left
	alone; only the BUY BUTTON repaints, because a button that cannot be pressed must not
	keep looking purchasable. ]]
local SLOTS = {
	captions = {
		{ "TextFrame", "Best Deals" },
		{ "TextFrame1", "Most Popular" },
		{ "TextFrame2", "Gamepasses" },
		{ "TextFrame3", "Packs" },
		{ "TextFrame4", "Lucky Spins" },
		{ "TextFrame5", "Money & Gems" },
	},
	-- Kit sections with no counterpart in this game. Hidden, never destroyed.
	hide = { "ServerLuck", "LegacyPasses", "PROPack" },
	cards = {
		-- hero banner: three gem tiers on the kit's own x1 / x3 / x10 buttons
		{ path = { "Exclusive" }, buy = "1", key = "GEMS_S", name = "GEM DEAL", amount = "80" },
		{ path = { "Exclusive" }, buy = "2", key = "GEMS_L", amount = "700" },
		{ path = { "Exclusive" }, buy = "3", key = "GEMS_XL", amount = "1.8K" },
		{ path = { "CelestialBull" }, buy = "1", key = "GOLDEN_CAR", name = "Golden Car", car = "supercar" },
		{ path = { "VIP" }, buy = "1", key = "VIP", name = "VIP", desc = "More money, and everyone sees it." },
		{ path = { "LuckyBlocks", "Secret" }, buy = "1", key = "SPINS_5", name = "5 Spins" },
		{ path = { "LuckyBlocks", "Alien" }, buy = "1", key = "SPINS_25", name = "25 Spins" },
		{ path = { "LuckyBlocks", "GOD" }, buy = "1", key = "EXTRA_LIFE", name = "Extra Life" },
		{ path = { "Gamepasses", "2xCash" }, buy = "1", key = "DOUBLE_MONEY", name = "2x Money", desc = "Double all the money you earn" },
		{ path = { "Gamepasses", "SuperLuck" }, buy = "1", key = "CROWN_MAGNET", name = "Crown Magnet", desc = "Crowns fly to you", icon = CROWN_ICON },
		{ path = { "Gamepasses", "MEGALuck" }, hide = true },
		{ path = { "StarterPack" }, buy = "1", key = "STARTER_PACK", name = "Starter Pack", chips = { ["2"] = { "Money", "+10K" } } },
		{ path = { "Cash", "column1", "1" }, buy = "1", key = "MONEY_S", name = "Wallet of Money" },
		{ path = { "Cash", "column1", "2" }, buy = "1", key = "MONEY_M", name = "Bag of Money" },
		{ path = { "Cash", "column2", "1" }, buy = "1", key = "MONEY_L", name = "Pile of Money" },
		{ path = { "Cash", "column2", "2" }, buy = "1", key = "GEMS_M", name = "Bag of Gems" },
		{ path = { "Cash", "column3", "1" }, buy = "1", key = "GEMS_XXL", name = "Mountain of Gems" },
	},
	-- The kit's two floating tabs, pointed at sections that actually exist now.
	quick = {
		{ button = "Limiteds", label = "Deals", anchor = "TextFrame" },
		{ button = "Limiteds1", label = "Spins", anchor = "TextFrame4" },
	},
}

local function resolvePath(steps: { string }): Instance?
	local node: Instance? = container
	for _, step in ipairs(steps) do
		node = node and childNamed(node, step)
	end
	return node
end

--[[ The kit's Outcomes strip advertises drop rates ("0.5%", "$10/s") for a game that had
	them. This one publishes no odds anywhere on purpose — see the header — so the strip
	comes off rather than carrying numbers nothing here can honour. ]]
local function stripOdds(card: Instance)
	local outcomes = childNamed(card, "Outcomes")
	if outcomes and outcomes:IsA("GuiObject") then
		outcomes.Visible = false
	end
end

local function bindAuthoredSections()
	for _, entry in ipairs(SLOTS.captions) do
		local caption = resolvePath({ entry[1] })
		if caption then
			setText(caption, "Text", entry[2])
			sectionAnchors[entry[1]] = caption
		end
	end

	for _, name in ipairs(SLOTS.hide) do
		local section = resolvePath({ name })
		if section and section:IsA("GuiObject") then
			section.Visible = false
		end
	end

	for _, slot in ipairs(SLOTS.cards) do
		local card = resolvePath(slot.path)
		if not card or not card:IsA("GuiObject") then
			warn("ShopUI: kit slot " .. table.concat(slot.path, ".") .. " missing — skipped")
			continue
		end

		if slot.hide then
			card.Visible = false
			continue
		end

		local source, def = catalogDef(slot.key)
		if not def then
			-- The catalog lost this key. Hide the slot; never leave a priced card that
			-- points at nothing.
			card.Visible = false
			warn("ShopUI: no catalog entry '" .. tostring(slot.key) .. "' — kit slot hidden")
			continue
		end

		if slot.name then
			setText(card, "Name", slot.name)
		end
		--[[ The kit's art was drawn for another game's catalog, so a few cards would end up
			labelled one thing and picturing another (the pass slot reused here is drawn
			"3X Luck"). Only those get an override, and only from icons already in this kit. ]]
		if slot.icon then
			local art = childNamed(card, "Icon")
			if art and art:IsA("ImageLabel") then
				art.Image = slot.icon
			end
		end
		if slot.desc then
			-- Kit cards label their blurb "Des" on the pass strip and "TextLabel" elsewhere.
			setText(card, "Des", slot.desc)
			setText(card, "TextLabel", slot.desc)
		end
		stripOdds(card)

		--[[ Authored leftovers with no data behind them here: "999 Remaining!" is invented
			scarcity for a stock system this game does not have, and InfoFrame carries the
			other game's cash-per-second stat. Hidden, not deleted. ]]
		for _, junk in ipairs({ "AmountLeft", "InfoFrame" }) do
			local node = childNamed(card, junk)
			if node and node:IsA("GuiObject") then
				node.Visible = false
			end
		end

		-- Reward chips: keep the ones this pack actually grants, hide the rest.
		if slot.chips then
			local rewards = childNamed(card, "Rewards")
			for _, chip in ipairs(rewards and rewards:GetChildren() or {}) do
				if chip:IsA("GuiObject") then
					local want = slot.chips[chip.Name]
					if want then
						setText(chip, "Name", want[1])
						setText(chip, "Amount", want[2])
					else
						chip.Visible = false
					end
				end
			end
		end

		local timer = childNamed(card, "Timer")
		if timer and timer:IsA("GuiObject") then
			-- Authored countdowns ("6d 23h left..") on offers that do not expire here.
			timer.Visible = false
		end

		local buyButtons = childNamed(card, "BuyButtons")
		local btn = buyButtons and childNamed(buyButtons, slot.buy)
		if not btn or not btn:IsA("GuiButton") then
			warn("ShopUI: kit slot " .. table.concat(slot.path, ".") .. " has no buy button " .. tostring(slot.buy))
			continue
		end

		if slot.amount then
			setText(btn, "Amount", slot.amount)
		end

		--[[ A real render for the exclusive car, filled by fillCarRenders once the server
			publishes previews. The authored icon is faded rather than removed so the slot
			never goes blank if they never arrive. ]]
		if slot.car then
			local icon = childNamed(card, "Icon")
			-- The authored art stays up; fillCarRenders hides it only once a render actually
			-- lands, so a missing Previews folder leaves a drawn card, never a blank one.
			if icon and icon:IsA("ImageLabel") then
				carWells[slot.car] = icon
			end
		end

		local rec = {
			key = slot.key,
			source = source,
			def = def,
			buy = btn,
			accent = accentFor(source, def),
			busy = false,
		}
		entries[slot.key] = rec

		kit.addButtonFeedback(btn)
		btn.Activated:Connect(function()
			if rec.busy or not isConfigured(rec.def) then
				kit.playSfx("DENY")
				return
			end
			openConfirm(rec)
		end)
	end
end

local function bindQuickButtons()
	local quick = childNamed(panel, "QuickButtons")
	if not quick then
		return
	end
	for _, link in ipairs(SLOTS.quick) do
		local btn = childNamed(quick, link.button)
		if btn and btn:IsA("GuiButton") then
			if sectionAnchors[link.anchor] then
				setText(btn, "Name", link.label)
				kit.addButtonFeedback(btn)
				btn.Activated:Connect(function()
					scrollTo(link.anchor)
				end)
				table.insert(quickButtons, { inst = btn, base = btn.Position })
			else
				btn.Visible = false -- nothing to jump to: never offer a dead button
			end
		end
	end
end

-- ==========================================================================
-- §9) init
-- ==========================================================================
local function buildQuickButtons()
	local quick = childNamed(panel, "QuickButtons")
	if not quick then
		return
	end

	-- The kit's two floating tabs, retitled and pointed at real sections of this shop.
	local links = {
		{ button = "Limiteds", label = "Deals", target = "LIMITED" },
		{ button = "Limiteds1", label = "Cars", target = "CARS" },
	}

	for _, link in ipairs(links) do
		local btn = childNamed(quick, link.button)
		if btn and btn:IsA("GuiButton") then
			if sectionAnchors[link.target] then
				setText(btn, "Name", link.label)
				kit.addButtonFeedback(btn)
				btn.Activated:Connect(function()
					scrollTo(link.target)
				end)
				table.insert(quickButtons, { inst = btn, base = btn.Position })
			else
				btn.Visible = false -- nothing to jump to: never offer a dead button
			end
		end
	end
end

local function buildWalletSlot(parent: Instance, name: string, order: number, tint: Color3?): TextLabel?
	local slot = Instance.new("Frame")
	slot.Name = name
	slot.Size = UDim2.fromScale(0.46, 1)
	slot.BackgroundTransparency = 1
	slot.LayoutOrder = order
	slot.ZIndex = 4
	slot.Parent = parent

	--[[ The kit's own amount readout, cloned whole: same face, same hairline outline, same
		icon spacing. The kit authors it 5x oversized around a centred list layout, which is
		what keeps the icon+number pair centred at any width — so the clone keeps that. ]]
	local info = TPL.info:Clone()
	info.Size = UDim2.new(5, 0, 0.86, 0)
	info.Position = UDim2.fromScale(0.5, 0.5)
	info.AnchorPoint = Vector2.new(0.5, 0.5)
	info.ZIndex = 5
	info.Parent = slot

	local layout = info:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end

	local icon = info:FindFirstChildWhichIsA("ImageLabel")
	if icon then
		icon.Image = IMG.CASH
		icon.ImageColor3 = tint or UI.PAPER
		icon.ZIndex = 5
	end

	local amount = childNamed(info, "Amount")
	if amount and amount:IsA("TextLabel") then
		amount.Text = "0"
		amount.ZIndex = 5
		return amount
	end
	return nil
end

local function buildWallet()
	local header = childNamed(panel, "Header")
	if not header then
		return
	end

	local wallet = Instance.new("Frame")
	wallet.Name = "Wallet"
	wallet.Size = UDim2.fromScale(0.30, 0.52)
	wallet.Position = UDim2.fromScale(0.955, 0.5)
	wallet.AnchorPoint = Vector2.new(1, 0.5)
	wallet.BackgroundTransparency = 1
	wallet.ZIndex = 4
	wallet.Parent = header

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.05, 0)
	layout.Parent = wallet

	moneyValue = buildWalletSlot(wallet, "Money", 1, nil)
	-- Gems wear the epic purple the garage already gives them: same icon, own colour.
	gemValue = buildWalletSlot(wallet, "Gems", 2, UI.RARITY.EPIC)
end

--[[ Real renders, filled in once the server publishes them. Yields, so it runs in its own
	task and degrades to the kit's tinted icon rather than erroring if they never arrive. ]]
local function fillCarRenders()
	local assets = core:FindFirstChild("Assets") or core:WaitForChild("Assets", 20)
	local previews = assets and (assets:FindFirstChild("Previews") or assets:WaitForChild("Previews", 20))
	-- Both lookups yield: the GUI could have been torn down underneath us.
	if not previews or not panel or not panel.Parent then
		return
	end

	for carId, well in pairs(carWells) do
		if well.Parent then
			local model = previews:FindFirstChild(carId)
			if model then
				kit.viewport({ parent = well, name = "Render", model = model, size = UDim2.fromScale(1, 1) })
				if well:IsA("ImageLabel") then
					well.ImageTransparency = 1 -- the render is up; retire the placeholder art
				end
			elseif not warnedPreview then
				warnedPreview = true
				warn("ShopUI: no preview model for '" .. tostring(carId) .. "' — car row shows icons")
			end
		end
	end
end

function ShopUI.init(ctx)
	kit = ctx and ctx.kit
	net = ctx and ctx.net
	frames = ctx and ctx.frames
	if not kit or not frames then
		warn("ShopUI: ctx is missing kit or frames — shop not built")
		return
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local kitGui = playerGui and (playerGui:FindFirstChild(KIT_GUI) or playerGui:WaitForChild(KIT_GUI, KIT_TIMEOUT))
	local kitFrames = kitGui and childNamed(kitGui, "Frames")
	local storeTemplate = kitFrames and childNamed(kitFrames, "Store")
	if not storeTemplate then
		warn("ShopUI: kit Store window not found under PlayerGui." .. KIT_GUI .. " — shop not built")
		return
	end

	panel = storeTemplate:Clone()
	panel.Name = FRAME_NAME
	panel.Visible = false
	panel.Parent = frames
	--[[ NEVER FLATTEN THIS WINDOW. flattenGradient() forces a gradient's Transparency to 0
		to stop kit art washing out over the arena. On this panel that is catastrophic: the
		Store's own gradient is near-BLACK (15,15,15) with a 0.65 -> 0.35 transparency ramp,
		i.e. a dark glass scrim, and flattening it turns the whole window into a solid black
		rectangle. Every card inside is authored translucent too, so they then composite
		against black and the entire shop renders as one black box with a few price labels
		floating in it. Verified by screenshot both ways. The wash-out it was guarding
		against is solved properly below, with a backdrop behind the window. ]]

	--[[ The dim the kit was drawn for. Kit windows are authored to sit over a darkened
		screen; without one they read washed out over a bright arena. Active is left FALSE
		on purpose so this can never swallow a steering drag from InputController's
		left-half SteerZone, and it sits one ZIndex below the window it dims. ]]
	backdrop = Instance.new("Frame")
	backdrop.Name = "ShopBackdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = UI.INK
	backdrop.BackgroundTransparency = BACKDROP_TRANSPARENCY
	backdrop.BorderSizePixel = 0
	backdrop.Active = false
	backdrop.Visible = false
	backdrop.ZIndex = panel.ZIndex - 1
	backdrop.Parent = frames

	local storeFrame = childNamed(panel, "StoreFrame")
	container = storeFrame and childNamed(storeFrame, "Container")
	if not container or not container:IsA("ScrollingFrame") then
		warn("ShopUI: the kit Store has no Container scroller — shop not built")
		panel:Destroy()
		panel = nil
		return
	end

	if not harvest() then
		panel:Destroy()
		panel = nil
		return
	end

	container.ScrollingDirection = Enum.ScrollingDirection.Y
	container.CanvasSize = UDim2.new()
	container.AutomaticCanvasSize = Enum.AutomaticSize.Y
	container.ScrollBarThickness = 8
	container.ScrollBarImageColor3 = UI.PAPER
	container.ScrollBarImageTransparency = 0.45

	--[[ DO NOT "FIX" THE LIST LAYOUT. The kit authors this container's UIListLayout with
		FillDirection = Horizontal, and with that value the sections stack VERTICALLY and
		fit the width exactly — measured: 13 sections, x 224..642 inside a 208..663 frame,
		canvas 1182px tall. Setting it to Vertical, which is what it looks like it wants,
		inverts it: the sections spread ACROSS x -890..1755 and overlap each other eight
		deep. (The container is inside a CanvasGroup and the padding is scale-based, which
		is the likely cause.) The old code set Vertical here and got away with it only
		because it then destroyed every authored row and generated its own. The kit's rows
		are back, so the kit's layout stays exactly as authored — direction, alignment,
		sort order and padding all untouched. ]]

	setText(childNamed(panel, "Header"), "Name", "Store")
	buildWallet()
	bindAuthoredSections()
	bindQuickButtons()

	if not buildConfirm(kitFrames) then
		panel:Destroy()
		panel = nil
		return
	end

	-- Hides it, wires Header.Buttons.Close, and gives it pop in/out + one-at-a-time.
	kit.registerFrame(FRAME_NAME, panel)
	refreshWallet()
	refreshAll()

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if backdrop then
			backdrop.Visible = panel.Visible
		end
		if panel.Visible then
			startMotion()
		else
			stopMotion()
			pendingRec = nil
			closeConfirm()
		end
	end)

	for _, attr in ipairs(GRANT_ATTR) do
		player:GetAttributeChangedSignal(attr):Connect(onGrantAttribute)
	end
	for _, attr in ipairs(REFRESH_ATTR) do
		player:GetAttributeChangedSignal(attr):Connect(refreshAll)
	end

	if net and net.Monetization then
		net.Monetization.OnClientEvent:Connect(onServerReply)
	else
		warn("ShopUI: Monetization remote missing — the shop cannot reach the server")
	end

	task.spawn(fillCarRenders)
end

return ShopUI
