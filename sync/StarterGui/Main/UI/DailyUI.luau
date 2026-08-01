--[[ DailyUI (UI module — the daily login track)
	Wires the uploaded kit's Daily window. Builds NOTHING: the seven cards, the header, the
	scroller and the "next reward" line are all authored art, cloned out of the kit ScreenGui
	and repainted from the server's state.

	AUTHORITY: this module renders `state` and asks. It never decides whether a day is
	claimable, never computes a day number, never counts a streak, and never shows a reward
	it was not sent — every card's text comes from state.rewards, which the server resolves
	per player. So a card physically cannot promise something the grant path will not pay.

	Frame       registered as "Daily" (pinned) — a HUD/lobby button opens it with
	            kit.openFrame("Daily"). This module opens nothing by itself: house rule, no
	            unprompted popups.
	Source      PlayerGui.Alternate.Frames.Daily (the kit ScreenGui, its own client disabled),
	            falling back to StarterGui. Cloned under ctx.frames; the kit copy is left
	            untouched and stays hidden.
	Remote      DailyAction  C->S ("claim" | "sync")   S->C (state)
	Attributes  none, reads or writes.

	COUNTDOWNS CANNOT LIE. state.nextAt is an absolute time in the
	workspace:GetServerTimeNow() domain, so every label is (nextAt - GetServerTimeNow()):
	a device clock that is hours out still shows the right numbers. nextAt == 0 is the
	server's "unavailable" sentinel (profile still loading, DataStore down, streak not
	persistable) and paints as offline — never as a fake countdown, and never as a Claim
	button the server would refuse.

	THE KIT'S REPAINT TRAP: each card's button is ONE ImageButton literally named
	"Claim/Claimed/Locked" (not three buttons), and it carries its green "Claim" gradient
	TWICE — once on the button and once on the opaque Decor.Stud overlay sitting above it at
	a higher ZIndex. Recolouring only the button changes nothing you can see, because the
	Stud covers it. Both copies move together here, which is what makePaint returns.

	COLOUR = STATE, one glance: GREEN is the card you can claim right now and the only
	interactive one; RED is the single next-up card, the one with the live countdown; GREY
	is everything else, collected and still-locked alike.

	MOTION  One RenderStepped connection, live ONLY while the window is visible and
	        disconnected the moment it closes. Manual sine pulse on the claimable card
	        (house rule: no TweenService for looped motion) plus a 4Hz text tick, which is
	        cheaper and steadier than a task loop per label.

	SOUND   REWARD when a claim lands, DENY when the server refuses. The button's own click
	        and hover come from kit.addButtonFeedback, attached once at build.

	MOBILE  Only the claimable card's button is Active; every other button is switched off,
	        so a locked card cannot swallow a touch. The whole window is hidden unless a
	        player opened it, so nothing here is ever Active over the left half of the
	        screen during a match (InputController owns that half for steering).

	Sections:
		§1  constants
		§2  state
		§3  kit resolution
		§4  card harvest
		§5  paint
		§6  render + countdown
		§7  claim + remote
		§8  motion
		§9  init
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local MathUtil = require(core:WaitForChild("Shared"):WaitForChild("MathUtil"))

local player = Players.LocalPlayer

local DailyUI = {}

local UI = Config.UI

-- ==========================================================================
-- §1) constants
-- ==========================================================================
local FRAME_NAME = "Daily" -- pinned: a HUD button opens it via kit.openFrame("Daily")
local KIT_GUI = "Alternate"
local KIT_FRAME = "Daily"
local RESOLVE_TIMEOUT = 20

-- The kit's own names. The slash is literal — index with brackets, never with a dot.
local BUTTON_NAME = "Claim/Claimed/Locked"
local CLAIM_GRADIENT = "Claim"
local DULL_GRADIENT = "Claimed/Locked"

local CLICK_LOCK = 0.55 -- >= Net.REQUEST_GAP (0.5), so a double tap cannot outrun the reply
local PENDING_TIMEOUT = 5 -- a claim with no answer by now stops waiting, silently
local BOUNDARY_SYNC_GAP = 5 -- rate limit on "my countdown hit zero, please repaint"
local TICK_SECONDS = 0.25 -- countdown refresh; the seconds digit still reads as live
local PULSE_SPEED, PULSE_AMP = 3.2, 0.025 -- the claimable card breathes, gently

-- The single next-up card wears the house danger ramp so "not yet" reads instantly.
local NEXT_RAMP = ColorSequence.new({
	ColorSequenceKeypoint.new(0, UI.DANGER),
	ColorSequenceKeypoint.new(1, UI.DANGER:Lerp(UI.INK, 0.45)),
})

local CLAIMED_ICON_FADE = 0.45 -- a collected day's icon dims instead of vanishing

local TEXT = {
	claim = "Claim",
	done = "Claimed",
	locked = "Locked",
	soon = "Soon!",
	ready = "Your daily reward is ready!",
	offline = "Daily rewards are offline",
	next = "Next daily reward in: %s",
}

-- ==========================================================================
-- §2) state
-- ==========================================================================
local kit, remote
local panel, container, nextLabel
local cards = {} -- [day] = record (see §4)
local iconForKind = {} -- kind -> kit image id, harvested from the kit's own cards

local state = nil -- the last server state, sanitized
local pendingDay = nil -- the day we are waiting on an answer for
local pendingAt = 0
local lastFireAt = 0
local lastBoundarySync = 0
local motionConn = nil
local visibilityConn = nil
local ready = false -- false disables the module: the game must survive a missing kit

-- ==========================================================================
-- §3) kit resolution — defensive, because a missing kit must not break the game
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
		-- Only the FIRST lookup is allowed to wait; the fallback must not stall the boot.
		local gui = index == 1 and root:WaitForChild(KIT_GUI, RESOLVE_TIMEOUT) or root:FindFirstChild(KIT_GUI)
		local frames = gui and gui:FindFirstChild("Frames")
		local frame = frames and frames:FindFirstChild(KIT_FRAME)
		if frame and frame:IsA("GuiObject") then
			return frame
		end
	end
	return nil
end

--[[ Kit windows are authored TRANSLUCENT because they open over a dimmed modal backdrop
	(this one's gradient ramps alpha 0.65 -> 0.35). This game has no backdrop, so over the
	open world the panel washes out. BackgroundTransparency cannot fix it — the gradient's
	alpha multiplies on top — so the ramp itself is flattened. ]]
local function flattenGradients(root: Instance)
	-- ONLY the panel's own ramp. Every other gradient in the kit is authored decoration
	-- (header sheen, button states, highlight strokes) and is left exactly as drawn.
	local own = root:FindFirstChildOfClass("UIGradient")
	if own then
		own.Transparency = NumberSequence.new(0)
	end
end

-- ==========================================================================
-- §4) card harvest — read the kit, keep what we need, change nothing structural
-- ==========================================================================
local function harvestCard(card: Instance, day: number)
	local button = card:FindFirstChild(BUTTON_NAME)
	if not button or not button:IsA("GuiButton") then
		return nil
	end
	local stud = button:FindFirstChild("Decor")
	stud = stud and stud:FindFirstChild("Stud") or nil

	--[[ BOTH copies of each gradient: the button's own, and the one on the opaque Stud
		overlay that draws on top of it. Painting one and not the other is invisible. ]]
	local claimGradients, dullGradients, dullBase = {}, {}, {}
	for _, holder in ipairs({ button, stud }) do
		if holder then
			local bright = holder:FindFirstChild(CLAIM_GRADIENT)
			local dull = holder:FindFirstChild(DULL_GRADIENT)
			if bright and bright:IsA("UIGradient") then
				table.insert(claimGradients, bright)
			end
			if dull and dull:IsA("UIGradient") then
				table.insert(dullGradients, dull)
				dullBase[dull] = dull.Color -- the kit's grey, restored when we stop nagging
			end
		end
	end

	local record = {
		day = day,
		root = card,
		name = card:FindFirstChild("Name"),
		amount = card:FindFirstChild("Amount"),
		icon = card:FindFirstChild("Icon"),
		button = button,
		label = button:FindFirstChild(BUTTON_NAME),
		claimGradients = claimGradients,
		dullGradients = dullGradients,
		dullBase = dullBase,
		scale = kit.ensureScale(card),
		mood = nil,
	}

	button.AutoButtonColor = false -- house feel comes from addButtonFeedback, not tinting
	kit.addButtonFeedback(button)
	button.Activated:Connect(function()
		DailyUI._claim(day)
	end)

	return record
end

--[[ The kit already ships a gem and a hero icon across its seven mock cards, so those are
	reused rather than invented. MONEY is the exception and is PINNED to Config.ART: the
	currency has one drawing everywhere else in the game (rail counter, wallet chip, shop
	packs, the note on the arena floor), and a daily card that paid out a different-looking
	reward would read as a different reward. ]]
local function harvestIcons()
	local function imageOf(day: number)
		local card = container and container:FindFirstChild(tostring(day))
		local icon = card and card:FindFirstChild("Icon")
		return icon and icon:IsA("ImageLabel") and icon.Image or nil
	end
	iconForKind.money = Config.ART.MONEY
	iconForKind.gems = imageOf(3)
	iconForKind.car = imageOf(7)
	iconForKind.spins = imageOf(7)
end

-- ==========================================================================
-- §5) paint
-- ==========================================================================
local function paint(record, mood: string)
	if record.mood == mood then
		return -- repainting the same mood every tick is wasted work
	end
	record.mood = mood

	local isClaim = mood == "claim"
	for _, gradient in ipairs(record.claimGradients) do
		gradient.Enabled = isClaim
	end
	for _, gradient in ipairs(record.dullGradients) do
		gradient.Enabled = not isClaim
		gradient.Color = mood == "next" and NEXT_RAMP or record.dullBase[gradient]
	end

	-- Only the claimable card is a button. Everything else is inert, so a locked day cannot
	-- eat a tap (and on a phone, cannot eat a steering drag).
	record.button.Active = isClaim

	if record.icon and record.icon:IsA("ImageLabel") then
		record.icon.ImageTransparency = mood == "done" and CLAIMED_ICON_FADE or 0
	end
	if not isClaim then
		record.scale.Scale = 1 -- drop the pulse the moment the card stops being claimable
	end
end

local function setLabel(record, text: string)
	if record.label and record.label:IsA("TextLabel") and record.label.Text ~= text then
		record.label.Text = text
	end
end

-- "5h 12m" / "8m 3s" / "12s". Kid-readable, never a bare number of seconds.
local function formatDuration(seconds: number): string
	local left = math.max(0, math.floor(seconds + 0.5))
	local hours = math.floor(left / 3600)
	local minutes = math.floor(left % 3600 / 60)
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %ds", minutes, left % 60)
	end
	return string.format("%ds", left)
end

-- ==========================================================================
-- §6) render + countdown
-- ==========================================================================
local function secondsLeft(): number
	if not state or state.nextAt <= 0 then
		return 0
	end
	return state.nextAt - Workspace:GetServerTimeNow()
end

--[==[ The ONE card that carries a live countdown. While a reward is waiting to be
	claimed that is the day AFTER it (which is what the kit's own mock draws: "Claim",
	"20h 0m", "Locked"...); otherwise it is the day currently on cooldown. Never a chain of
	40h/60h/80h labels down the row — only ever one, and only when the server gave us a real
	unlock time. ]==]
local function nextUpDay(): number?
	if not state or state.nextAt <= 0 then
		return nil
	end
	if not state.ready then
		return state.day
	end
	local after = state.day + 1
	return after <= #state.rewards and after or nil
end

-- claim > next > done > locked: a finished loop still shows day 1's countdown, because
-- day 1 genuinely IS the next reward once midnight rolls it over.
local function moodFor(day: number): string
	if not state then
		return "locked"
	end
	if state.ready and day == state.day then
		return "claim"
	end
	if day == nextUpDay() then
		return "next"
	end
	if state.claimed[day] then
		return "done"
	end
	return "locked"
end

-- The two things that change with the clock rather than with the state.
local function tickText()
	local left = secondsLeft()

	for _, record in pairs(cards) do
		if record.mood == "next" then
			setLabel(record, left > 0 and formatDuration(left) or TEXT.soon)
		end
	end

	--[==[ Our own countdown just ran out. Ask once, rate-limited, instead of waiting up to a
		full server sweep for the flip. The server still decides; this only prompts it. ]==]
	if remote and state and not state.ready and state.nextAt > 0 and left <= 0 then
		local now = os.clock()
		if now - lastBoundarySync > BOUNDARY_SYNC_GAP then
			lastBoundarySync = now
			remote:FireServer("sync")
		end
	end

	if not nextLabel then
		return
	end
	if not state or state.nextAt <= 0 then
		nextLabel.Text = TEXT.offline
	elseif state.ready then
		nextLabel.Text = TEXT.ready
	else
		nextLabel.Text = string.format(TEXT.next, formatDuration(left))
	end
end

local function renderAll()
	for day, record in pairs(cards) do
		local reward = state and state.rewards[day] or nil

		if record.name and record.name:IsA("TextLabel") then
			record.name.Text = "Day " .. day
		end
		if reward and record.amount and record.amount:IsA("TextLabel") and reward.label ~= "" then
			record.amount.Text = reward.label
		end
		if reward and record.icon and record.icon:IsA("ImageLabel") then
			local image = iconForKind[reward.kind]
			if image then
				record.icon.Image = image
			end
		end

		local mood = moodFor(day)
		paint(record, mood)
		if mood == "claim" then
			setLabel(record, TEXT.claim)
		elseif mood == "done" then
			setLabel(record, TEXT.done)
		elseif mood == "locked" then
			setLabel(record, TEXT.locked)
		end
	end

	tickText()
end

-- ==========================================================================
-- §7) claim + remote
-- ==========================================================================
local function sanitize(raw)
	if type(raw) ~= "table" or type(raw.rewards) ~= "table" or type(raw.claimed) ~= "table" then
		return nil
	end
	local count = #raw.rewards
	if count <= 0 then
		return nil
	end

	local clean = {
		day = math.clamp(math.floor(tonumber(raw.day) or 1), 1, count),
		ready = raw.ready == true,
		nextAt = tonumber(raw.nextAt) or 0,
		claimed = table.create(count),
		rewards = table.create(count),
	}
	for day = 1, count do
		local reward = raw.rewards[day]
		clean.rewards[day] = {
			kind = type(reward) == "table" and tostring(reward.kind) or "money",
			label = type(reward) == "table" and type(reward.label) == "string" and reward.label or "",
		}
		clean.claimed[day] = raw.claimed[day] == true
	end
	return clean
end

function DailyUI._claim(day: number)
	if not ready or not remote then
		return
	end
	-- Defence in depth: the button is only Active on the claimable card, and this refuses
	-- anyway. The server refuses a third time — it is the only opinion that counts.
	if not state or not state.ready or day ~= state.day then
		kit.playSfx("DENY")
		return
	end
	local now = os.clock()
	if now - lastFireAt < CLICK_LOCK then
		return
	end
	lastFireAt = now
	pendingDay = day
	pendingAt = now
	remote:FireServer("claim")
end

local function onState(raw)
	local previous = state
	local incoming = sanitize(raw)
	if not incoming then
		return -- malformed push: keep painting the last state we trust
	end
	state = incoming

	if pendingDay then
		local day = pendingDay
		local landed = state.claimed[day] and not (previous and previous.claimed[day])
		pendingDay = nil
		if landed then
			local reward = state.rewards[day]
			kit.notify("Got " .. ((reward and reward.label ~= "" and reward.label) or "your reward") .. "!", "green")
			kit.playSfx("REWARD")
		elseif state.nextAt <= 0 then
			kit.notify("Still loading — try again", "red")
			kit.playSfx("DENY")
		else
			kit.notify("Reward not ready yet!", "red")
			kit.playSfx("DENY")
		end
	end

	renderAll()
end

-- ==========================================================================
-- §8) motion — one connection, alive only while the window is up
-- ==========================================================================
local function startMotion()
	if motionConn then
		return
	end
	local elapsed, sinceTick = 0, math.huge
	motionConn = RunService.RenderStepped:Connect(function(dt)
		if not panel.Visible then
			return
		end
		elapsed += dt
		sinceTick += dt

		if sinceTick >= TICK_SECONDS then
			sinceTick = 0
			tickText()
		end

		for _, record in pairs(cards) do
			if record.mood == "claim" then
				record.scale.Scale = MathUtil.pulse(elapsed, PULSE_SPEED, 0, PULSE_AMP)
			end
		end

		-- A claim that never got an answer stops waiting rather than mislabelling the next
		-- push (a sweep) as the reply to it.
		if pendingDay and os.clock() - pendingAt > PENDING_TIMEOUT then
			pendingDay = nil
		end
	end)
end

local function stopMotion()
	if motionConn then
		motionConn:Disconnect()
		motionConn = nil
	end
	for _, record in pairs(cards) do
		record.scale.Scale = 1
	end
end

-- ==========================================================================
-- §9) init
-- ==========================================================================
function DailyUI.init(ctx)
	kit = ctx and ctx.kit
	remote = ctx and ctx.net and ctx.net.DailyAction or nil
	if not kit or not ctx.frames then
		warn("DailyUI: no ctx.kit / ctx.frames — daily window disabled")
		return
	end
	if not remote then
		warn("DailyUI: DailyAction remote missing — daily window disabled")
		return
	end

	local source = findKitFrame()
	if not source then
		warn("DailyUI: kit frame " .. KIT_GUI .. ".Frames." .. KIT_FRAME .. " not found — daily window disabled")
		return
	end

	panel = source:Clone()
	panel.Name = FRAME_NAME
	panel.Visible = false
	flattenGradients(panel)
	panel.Parent = ctx.frames

	container = panel:FindFirstChild("Container")
	nextLabel = panel:FindFirstChild("NextReward")
	if not container then
		warn("DailyUI: kit frame has no Container — daily window disabled")
		panel:Destroy()
		panel = nil
		return
	end

	--[[ The kit's SkipAll was a Robux "skip the whole track" product. Config.PRODUCTS has no
		entry for it and every id in the catalog is still 0, so the button is hidden rather
		than wired to an invented id. HANDOFF has the Config entry that turns it back on. ]]
	local header = panel:FindFirstChild("Header")
	local buttons = header and header:FindFirstChild("Buttons")
	local skipAll = buttons and buttons:FindFirstChild("SkipAll")
	if skipAll and skipAll:IsA("GuiObject") then
		skipAll.Visible = false
	end

	harvestIcons()
	for day = 1, 7 do
		local card = container:FindFirstChild(tostring(day))
		if card then
			local record = harvestCard(card, day)
			if record then
				cards[day] = record
			else
				warn("DailyUI: card " .. day .. " has no " .. BUTTON_NAME .. " button")
			end
		end
	end
	if next(cards) == nil then
		warn("DailyUI: no usable cards in the kit frame — daily window disabled")
		panel:Destroy()
		panel = nil
		return
	end

	ready = true
	kit.registerFrame(FRAME_NAME, panel) -- hides it, wires Close, gives it pop in/out

	-- Motion (and the countdown) exist only while the window is actually on screen.
	visibilityConn = panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible then
			startMotion()
			renderAll()
			remote:FireServer("sync") -- opened: repaint against the server, not against memory
		else
			stopMotion()
		end
	end)

	remote.OnClientEvent:Connect(onState)
	renderAll() -- paint the kit into a definite "offline" state before the first push lands
	remote:FireServer("sync")
end

return DailyUI
