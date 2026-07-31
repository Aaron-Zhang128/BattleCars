--[[ RailUI (UI module — the button rail and the money counters)
	The game's ONLY navigation. Every window this UI registers is opened from here.

	NOTHING HERE IS GENERATED. Both pieces are CLONES of authored kit art that already
	ships in this place:
		Alternate.SideUI.Left3      -> the right-edge button rail
		Alternate.SideUI.Counters   -> the coin / best-run counters
	The kit ScreenGui stays DISABLED and is used purely as a template library, so no
	piece of it is ever drawn twice.

	WHY THIS MODULE EXISTS — the bug it fixes, written down so nobody re-opens it.
		The kit rail was already ON SCREEN: Alternate sits at DisplayOrder 45, above
		Main's 40, with SideUI.Left3 Visible. None of its buttons were wired to anything,
		so a player tapped Store / Index / Sell / Config and got nothing.
		Meanwhile every window the game DOES register — Shop, Index, Daily, CarShop,
		Settings — had no opener at all. The only openers in the codebase (LobbyUI's card
		and corner GARAGE buttons, ShopUI's cross-link) all pointed at "Garage", a name
		only GarageUI registers, and GarageUI is deliberately absent from Main's ORDER.
		So the visible buttons were dead and the live windows were unreachable.
	This module joins the two halves that were already there.

	A BUTTON WHOSE FRAME IS NOT REGISTERED IS HIDDEN, never left on screen. That rule is
	the whole point: a rail button that does nothing is exactly the bug above.

	THE KIT'S OWN MIRRORING BUG — see §3. "Left3" is the left rail "Lef1" moved to the
	right edge, but only the OUTER frame was mirrored: every row inside still lays its
	buttons out growing RIGHTWARD from a centred origin. Four buttons therefore run off
	the right of the screen (measured: content 240px wide ending at x=922 on an 871px
	viewport, so the last button is entirely invisible). The rows are re-anchored here
	rather than in the kit, because the kit is shared template art.

	MOBILE. InputController owns the ENTIRE LEFT HALF (SteerZone), the bottom-left
	(stick + brake) and the bottom-right (fire + drift). After the re-anchor the rail sits
	x 0.72-1.0, y 0.37-0.63 — clear of all three, which is the only reason it can stay up
	during a match instead of hiding every round. The counters are display-only: every
	GuiButton inside that clone is hidden, so it passes touches straight through.

	Frame       none registered. This module OPENS windows, it never owns one.
	Reads       Player attributes  Config.ATTR.COINS, BEST_CROWNS, EQUIPPED
	Writes      nothing — no remotes, no attributes.

	Sections:
		§1  constants + wiring table
		§2  kit resolution
		§3  rail layout repair
		§4  the rail
		§5  the car button's live render
		§6  the counters
		§7  init
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local MathUtil = require(core:WaitForChild("Shared"):WaitForChild("MathUtil"))

local ATTR = Config.ATTR

local player = Players.LocalPlayer

local RailUI = {}

-- ==========================================================================
-- §1) constants + wiring table
-- ==========================================================================
local KIT_GUI = "Alternate"
local RESOLVE_TIMEOUT = 20

local SCREEN_NAME = "CrashRail"

--[[ Authored button -> the frame name its module registers with kit.registerFrame.
	Table order IS left-to-right order on screen (§4 stamps LayoutOrder from it) — the
	kit ships two buttons on the same LayoutOrder, so display order was down to sibling
	order and would have shuffled the moment one was hidden.
	`label` is what the player reads: the kit was authored for a different game, so its
	"Sell" slot becomes the car garage here. Copy stays one word, kid-simple. ]]
local WIRING = {
	{ row = "Row1", button = "Sell", frame = "CarShop", label = "Cars", cars = true },
	{ row = "Row1", button = "Store", frame = "Shop", label = "Store" },
	{ row = "Row1", button = "Index", frame = "Index", label = "Index" },
	{ row = "Row1", button = "Gifts", frame = "Daily", label = "Daily" },
	{ row = "Row3", button = "Config", frame = "Settings", label = "Config" },
}

--[[ Authored slots this game has no feature for. HIDDEN, never deleted — the kit is a
	template library, and a later feature switches one back on with two lines. ]]
local UNUSED = {
	{ row = "Row1", button = "Rebirth" },
	{ row = "Row3", button = "Invite" },
	{ row = "Other", button = "Button1" }, -- the previous game's "Slow: On" toggle
}

local COUNTER_INSET = Vector2.new(14, 46) -- clears the Roblox topbar; HudUI's band is centred

local initialized = false

-- ==========================================================================
-- §2) kit resolution — a missing kit disables the rail, never breaks the game
-- ==========================================================================
local function findKitFrame(path: { string }): Instance?
	local roots = {}
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
		local node = index == 1 and root:WaitForChild(KIT_GUI, RESOLVE_TIMEOUT) or root:FindFirstChild(KIT_GUI)
		for _, step in ipairs(path) do
			node = node and node:FindFirstChild(step)
		end
		if node and node:IsA("GuiObject") then
			return node
		end
	end
	return nil
end

-- ==========================================================================
-- §3) rail layout repair — see the header note on the kit's mirroring bug
-- ==========================================================================
--[[ Pins a row's RIGHT edge to the rail's right edge and makes its list grow leftward.
	Content wider than the row's own box then overflows INTO the screen instead of off it,
	which is what lets the rail carry four buttons at any viewport width. ]]
local function rightAlignRow(row: Instance)
	local layout = row:FindFirstChildOfClass("UIListLayout")
	if layout and layout.FillDirection == Enum.FillDirection.Horizontal then
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	end
	if row:IsA("GuiObject") then
		row.AnchorPoint = Vector2.new(1, row.AnchorPoint.Y)
		row.Position = UDim2.new(1, 0, row.Position.Y.Scale, row.Position.Y.Offset)
	end
end

-- ==========================================================================
-- §4) the rail
-- ==========================================================================
local function findButton(rail: Instance, rowName: string, buttonName: string): Instance?
	local buttons = rail:FindFirstChild("Buttons")
	local row = buttons and buttons:FindFirstChild(rowName)
	local btn = row and row:FindFirstChild(buttonName)
	if btn and btn:IsA("GuiButton") then
		return btn
	end
	return nil
end

local function setLabel(btn: Instance, text: string)
	local label = btn:FindFirstChild("Name")
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

--[[ The kit badges "Gifts" and "Rebirth" with an always-on Notif dot. Nothing here knows
	whether a daily reward is actually waiting, and a badge that is permanently lit is a
	lie the player learns to ignore — so it is switched off. Wiring it to DailyUI's
	claimable state is the follow-up. ]]
local function silenceBadge(btn: Instance)
	local notif = btn:FindFirstChild("Notif")
	if notif and notif:IsA("GuiObject") then
		notif.Visible = false
	end
end

-- ==========================================================================
-- §5) the car button's live render — the equipped car, not a stud texture
-- ==========================================================================
--[[ The kit's "Sell" slot carries a stud-grid icon, which says nothing about cars. The
	place already publishes a preview model per car (CarFactory -> CrashCore.Assets.Previews,
	the same source CarShopUI renders from), so the button shows the car being driven.
	Every step is guarded: no Previews folder, no attribute or no model just leaves the
	authored icon alone. A rail button must never fail to open its window because a
	decoration was missing. ]]
local function bindCarRender(kit, btn: Instance, conns: { RBXScriptConnection })
	local icon = btn:FindFirstChild("Icon")
	if not icon or not icon:IsA("GuiObject") then
		return
	end

	local assets = core:FindFirstChild("Assets")
	if not assets then
		return
	end

	--[[ Previews are published by CarFactory at server init, so a fresh client may not
		have them yet and Studio's edit DataModel never does. CarModels is the same roster
		under the same ids and is always present, so it stands in rather than leaving a
		stud-grid texture sitting where a car belongs. Same reason for falling back to the
		first car in the roster: the equipped attribute arrives with the profile, and the
		button is on screen before that. ]]
	local function resolveModel(): Model?
		local carId = player:GetAttribute(ATTR.EQUIPPED)
		if carId == nil then
			local first = Config.CARS and Config.CARS[1]
			carId = first and first.id
		end
		if carId == nil then
			return nil
		end
		for _, folderName in ipairs({ "Previews", "CarModels" }) do
			local folder = assets:FindFirstChild(folderName)
			local model = folder and folder:FindFirstChild(tostring(carId))
			if model and model:IsA("Model") then
				return model
			end
		end
		return nil
	end

	local current: Instance? = nil

	local function refresh()
		local model = resolveModel()
		if not model then
			return
		end

		local ok, render = pcall(kit.viewport, {
			parent = btn,
			name = "CarRender",
			model = model,
			size = icon.Size,
			position = icon.Position,
			anchor = icon.AnchorPoint,
		})
		if not ok or not render then
			return
		end

		render.ZIndex = icon.ZIndex
		if current then
			current:Destroy()
		end
		current = render
		icon.Visible = false
	end

	refresh()
	table.insert(conns, player:GetAttributeChangedSignal(ATTR.EQUIPPED):Connect(refresh))
	-- Previews replicating in later must upgrade the CarModels placeholder render.
	table.insert(conns, assets.ChildAdded:Connect(function(child)
		if child.Name == "Previews" then
			task.defer(refresh)
		end
	end))
end

-- ==========================================================================
-- §6) the counters
-- ==========================================================================
--[[ Strips the counter clone down to the two numbers this game actually has, then keeps
	them live off attributes. Everything removed is HIDDEN rather than destroyed, for the
	same template-library reason as §1's UNUSED list.

	The "+" buy shortcuts are hidden for two reasons, not one: Config.PRODUCTS is empty so
	they have nothing to sell, AND they are the only GuiButtons in this clone. With them
	off, the whole counter stack is inert and can never swallow a touch. ]]
local function bindCounters(counters: Instance, conns: { RBXScriptConnection })
	local function hide(child: Instance?)
		if child and child:IsA("GuiObject") then
			child.Visible = false
		end
	end

	local cash = counters:FindFirstChild("Cash")
	local speed = counters:FindFirstChild("Speed")
	hide(counters:FindFirstChild("Boost")) -- no friend boost in this game

	local coinLabel = cash and cash:FindFirstChild("Amount")
	local bestLabel = speed and speed:FindFirstChild("Amount")
	hide(cash and cash:FindFirstChild("Buy"))
	hide(speed and speed:FindFirstChild("Buy"))

	local function readNumber(name: string): number
		local value = player:GetAttribute(name)
		return tonumber(value) or 0
	end

	local function refreshCoins()
		if coinLabel and coinLabel:IsA("TextLabel") then
			coinLabel.Text = MathUtil.comma(readNumber(ATTR.COINS))
		end
	end

	local function refreshBest()
		if bestLabel and bestLabel:IsA("TextLabel") then
			bestLabel.Text = "Best: " .. MathUtil.comma(readNumber(ATTR.BEST_CROWNS))
		end
	end

	refreshCoins()
	refreshBest()
	table.insert(conns, player:GetAttributeChangedSignal(ATTR.COINS):Connect(refreshCoins))
	table.insert(conns, player:GetAttributeChangedSignal(ATTR.BEST_CROWNS):Connect(refreshBest))
end

-- ==========================================================================
-- §7) init
-- ==========================================================================
function RailUI.init(ctx)
	if initialized then
		return
	end
	initialized = true

	local kit = ctx.kit
	local conns = {}

	local railTemplate = findKitFrame({ "SideUI", "Left3" })
	if not railTemplate then
		warn("RailUI: kit rail (Alternate.SideUI.Left3) not found — no navigation built")
		return
	end

	-- If StarterGui.Main is ever re-copied (respawn), drop the previous rail so we never
	-- stack two screens or two sets of attribute listeners.
	local playerGui = player:WaitForChild("PlayerGui")
	local stale = playerGui:FindFirstChild(SCREEN_NAME)
	if stale then
		stale:Destroy()
	end

	local gui = kit.screen(SCREEN_NAME, kit.DISPLAY_ORDER.LOBBY + 1)

	local rail = railTemplate:Clone()
	rail.Name = "Rail"
	rail.Visible = true
	rail.Parent = gui

	for _, entry in ipairs(UNUSED) do
		local btn = findButton(rail, entry.row, entry.button)
		if btn then
			btn.Visible = false
		end
	end

	local repaired = {}
	for index, entry in ipairs(WIRING) do
		local btn = findButton(rail, entry.row, entry.button)
		if not btn then
			warn("RailUI: kit button " .. entry.row .. "." .. entry.button .. " missing — skipped")
			continue
		end

		if not kit.isFrameRegistered(entry.frame) then
			-- The window did not load. Hide the button rather than leave a dead one up.
			btn.Visible = false
			continue
		end

		if not repaired[entry.row] then
			repaired[entry.row] = true
			rightAlignRow(btn.Parent)
		end

		btn.Visible = true
		btn.LayoutOrder = index
		setLabel(btn, entry.label)
		silenceBadge(btn)
		kit.addButtonFeedback(btn)
		btn.Activated:Connect(function()
			kit.toggleFrame(entry.frame)
		end)

		if entry.cars then
			bindCarRender(kit, btn, conns)
		end
	end

	local counterTemplate = findKitFrame({ "SideUI", "Counters" })
	if counterTemplate then
		local counters = counterTemplate:Clone()
		counters.Name = "Counters"
		counters.Visible = true
		-- Authored bottom-LEFT, which is InputController's stick + brake cluster AND
		-- inside the SteerZone. Moved to the top-left, the one band no other UI claims:
		-- HudUI's top band is centred and its mini leaderboard hugs the top-right.
		counters.AnchorPoint = Vector2.new(0, 0)
		counters.Position = UDim2.new(0, COUNTER_INSET.X, 0, COUNTER_INSET.Y)
		counters.Parent = gui
		bindCounters(counters, conns)
	end

	gui.Destroying:Connect(function()
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
	end)
end

return RailUI
