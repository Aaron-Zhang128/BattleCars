--[[ DeathUI
	The death card: what killed you, what it cost you, and the one button that puts you
	back in the arena. Plus the out-of-lives spectate strip, and the "Jump in!" card for
	anyone who is out of a car during a live match without having died.

	UI module (see StarterGui.Main.Main for the ctx contract). Everything here is built
	from code into its own ScreenGui at kit.DISPLAY_ORDER.DEATH — nothing is authored
	into the Studio tree.

	§1) constants
	§2) build (backdrop + card + pips + respawn button + spectate strip)
	§3) crowns-at-death memory
	§4) respawn button state machine
	§5) show / hide (death card, join card, spectate strip)
	§6) wiring + the single Heartbeat tick

	READS
		CarLifecycle (S->C) "destroyed" { cause, killerName, livesLeft, canRespawnAt }
		                    "spawned"   — the ONLY thing that closes the card
		MatchEvent   (S->C) "kill" { victimName, crowns } — the killer's cut, a last-resort
		                    source for the "Lost N crowns" line
		Player attributes Crowns / Lives / Alive, MatchState phase, Config.MATCH
	FIRES
		RequestRespawn (C->S) — only from the RESPAWN button, at most once per arm
	SOUNDS
		THUD on a death with lives left, IMPACT on the run-ending one, TOGGLE the moment
		the button becomes tappable. THIS module owns the death sound for the whole game:
		HudUI's pip loss is the same instant and is deliberately silent, so one death is
		always exactly one sound. Nothing here is hoverable — every line is a fact about
		what just happened, not a choice — and the RESPAWN button gets its feel from
		kit.button (UIKit.addButtonFeedback).
	WRITES
		nothing: no attributes, no sibling module's instances, no Studio instances

	Only "killed" and "fell" raise the death card. "roundEnd" / "reset" / "left" are not
	the player's fault, so a card there would be noise.

	NOT EVERY CARLESS PLAYER DIED. A mid-match joiner — or anyone whose spawn SpawnService
	silently refused (profile still loading) — gets no "destroyed" event at all, so
	Alive == false during the Match phase is a second, independent trigger: after a short
	grace it offers the same RESPAWN button under a "Jump in!" headline. The grace exists
	because Alive is briefly false for everyone at the Match edge, before spawnAll lands.

	The countdown trusts info.canRespawnAt against workspace:GetServerTimeNow(), never a
	local clock, so a laggy or fiddled client cannot arm the button early. The card closes
	on the next "spawned" event, never optimistically on the click — if the server refuses,
	the card stays and the button re-arms so the player can tap again.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))

local player = Players.LocalPlayer
local ATTR = Config.ATTR
local MATCH = Config.MATCH
local PHASES = MatchState.PHASES

local DeathUI = {}

-- ==========================================================================
-- §1) constants
-- ==========================================================================
-- The only despawn causes that are a real death, mapped to their headline.
local HEADLINE = {
	killed = "Smashed!",
	fell = "You fell off!",
}

local JOIN_HEADLINE = "Jump in!" -- no car, no death: a mid-match joiner or a refused spawn
local JOIN_GRACE = 1.5 -- seconds Alive==false must persist before we offer a spawn

local CARD_W, CARD_H = 360, 318
local STRIP_W, STRIP_H = 300, 84
local BACKDROP_ALPHA = 0.45
local FIT_FLOOR = 0.65 -- house phone floor for fixed-offset cards
local CROWN_MEMORY = 3.0 -- seconds a pre-death Crowns reading stays trustworthy
local REARM_AFTER = 1.6 -- no "spawned" landed: let them tap again (server may have refused)
local PIP = 20 -- lives pip diameter
local DRIFT_AMP = 3 -- px of two-sine headline drift
local TOP_LEFT = Vector2.new(0, 0) -- UIListLayout children must not be centre-anchored

local inited = false

function DeathUI.init(ctx)
	if inited then
		return
	end
	inited = true

	local kit = ctx.kit
	local net = ctx.net
	if not net.RequestRespawn or not net.CarLifecycle or not net.MatchEvent then
		warn("DeathUI: missing a pinned remote, death card disabled")
		return
	end

	local DANGER_RAMP = kit.MOOD_RAMPS.red -- house red 3-stop is our danger headline ramp
	local requestRespawn -- forward: the button is built before its state machine

	-- ==========================================================================
	-- §2) build
	-- ==========================================================================
	local gui = kit.screen("CrashDeath", kit.DISPLAY_ORDER.DEATH)

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = kit.INK
	backdrop.BackgroundTransparency = BACKDROP_ALPHA
	backdrop.BorderSizePixel = 0
	backdrop.Active = false -- Active false: never swallows the touch controls underneath
	backdrop.Visible = false
	backdrop.ZIndex = 0
	backdrop.Parent = gui

	-- Holder carries the phone fit scale; the card's own UIScale is the pop tween.
	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.Size = UDim2.fromOffset(CARD_W, CARD_H)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Active = false
	holder.ZIndex = 1
	holder.Parent = gui

	local fit = Instance.new("UIScale")
	fit.Parent = holder

	local card = kit.card({
		parent = holder,
		name = "DeathCard",
		size = UDim2.fromScale(1, 1),
		accent = kit.DANGER,
	})
	card.Visible = false

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -28, 1, -26)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.BackgroundTransparency = 1
	body.Parent = card

	local bodyList = Instance.new("UIListLayout")
	bodyList.FillDirection = Enum.FillDirection.Vertical
	bodyList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bodyList.VerticalAlignment = Enum.VerticalAlignment.Center
	bodyList.SortOrder = Enum.SortOrder.LayoutOrder
	bodyList.Padding = UDim.new(0, 6)
	bodyList.Parent = body

	-- The headline lives in its own slot so the idle drift never fights the list layout.
	local headSlot = Instance.new("Frame")
	headSlot.Name = "HeadlineSlot"
	headSlot.Size = UDim2.new(1, 0, 0, 52)
	headSlot.BackgroundTransparency = 1
	headSlot.AnchorPoint = TOP_LEFT
	headSlot.LayoutOrder = 1
	headSlot.Parent = body

	local headline = kit.label({
		parent = headSlot,
		name = "Headline",
		text = HEADLINE.killed,
		size = UDim2.fromScale(1, 1),
		cap = 24,
		ramp = DANGER_RAMP,
		stroke = 3,
	})

	-- The headline is gradient-painted, so switching mood means repainting its ramp.
	local headGrad = headline:FindFirstChildOfClass("UIGradient")
	local function setHeadRamp(colors: { Color3 })
		if not headGrad or #colors < 2 then
			return
		end
		local keys = {}
		for i, color in ipairs(colors) do
			table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#colors - 1), color))
		end
		headGrad.Color = ColorSequence.new(keys)
	end

	local killerLine = kit.label({
		parent = body,
		name = "KillerLine",
		text = "",
		size = UDim2.new(1, 0, 0, 22),
		anchor = TOP_LEFT,
		font = kit.FONT_BOLD,
		cap = 17,
		stroke = 1.6,
	})
	killerLine.LayoutOrder = 2
	killerLine.Visible = false

	local crownLine = kit.label({
		parent = body,
		name = "CrownLine",
		text = "",
		size = UDim2.new(1, 0, 0, 20),
		anchor = TOP_LEFT,
		font = kit.FONT_BOLD,
		color = kit.GOLD,
		cap = 16,
		stroke = 1.6,
	})
	crownLine.LayoutOrder = 3
	crownLine.Visible = false

	local livesLine = kit.label({
		parent = body,
		name = "LivesLine",
		text = "",
		size = UDim2.new(1, 0, 0, 18),
		anchor = TOP_LEFT,
		font = kit.FONT_BOLD,
		cap = 14,
		stroke = 1.5,
	})
	livesLine.LayoutOrder = 4

	local pipRow = Instance.new("Frame")
	pipRow.Name = "Pips"
	pipRow.Size = UDim2.new(1, 0, 0, PIP)
	pipRow.BackgroundTransparency = 1
	pipRow.AnchorPoint = TOP_LEFT
	pipRow.LayoutOrder = 5
	pipRow.Parent = body

	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pipLayout.Padding = UDim.new(0, 8)
	pipLayout.Parent = pipRow

	local pips = {}
	for i = 1, math.max(1, MATCH.LIVES) do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.Size = UDim2.fromOffset(PIP, PIP)
		pip.BackgroundColor3 = kit.CONFIRM
		pip.BorderSizePixel = 0
		pip.AnchorPoint = TOP_LEFT
		pip.LayoutOrder = i
		pip.Parent = pipRow
		kit.pill(pip)
		kit.stroke(pip, 2, kit.INK)
		pips[i] = pip
	end

	local respawnBtn = kit.button({
		parent = body,
		name = "Respawn",
		text = "RESPAWN",
		size = UDim2.fromOffset(214, 52),
		anchor = TOP_LEFT,
		accent = kit.CONFIRM,
		textCap = 20,
		onClick = function()
			requestRespawn()
		end,
	})
	respawnBtn.LayoutOrder = 6

	-- Disabled veil: dims the button (background AND label) while the countdown runs.
	local veil = Instance.new("Frame")
	veil.Name = "Veil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = kit.INK
	veil.BackgroundTransparency = 0.5
	veil.BorderSizePixel = 0
	veil.Active = false
	veil.ZIndex = 3
	veil.Parent = respawnBtn
	kit.corner(veil, 10)

	-- Out of lives: a slim strip on the left edge, no backdrop, so the orbiting
	-- spectate camera and the arena stay fully visible.
	local strip = kit.card({
		parent = gui,
		name = "SpectateStrip",
		size = UDim2.fromOffset(STRIP_W, STRIP_H),
		position = UDim2.new(0, 18, 0.42, 0),
		anchor = Vector2.new(0, 0.5),
		accent = kit.DANGER,
	})
	strip.Visible = false
	strip.ZIndex = 1

	local stripBody = Instance.new("Frame")
	stripBody.Name = "Body"
	stripBody.Size = UDim2.new(1, -24, 1, -16)
	stripBody.Position = UDim2.fromScale(0.5, 0.5)
	stripBody.AnchorPoint = Vector2.new(0.5, 0.5)
	stripBody.BackgroundTransparency = 1
	stripBody.Parent = strip

	local stripList = Instance.new("UIListLayout")
	stripList.FillDirection = Enum.FillDirection.Vertical
	stripList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stripList.VerticalAlignment = Enum.VerticalAlignment.Center
	stripList.SortOrder = Enum.SortOrder.LayoutOrder
	stripList.Padding = UDim.new(0, 2)
	stripList.Parent = stripBody

	local stripSlot = Instance.new("Frame")
	stripSlot.Name = "HeadlineSlot"
	stripSlot.Size = UDim2.new(1, 0, 0, 30)
	stripSlot.BackgroundTransparency = 1
	stripSlot.AnchorPoint = TOP_LEFT
	stripSlot.LayoutOrder = 1
	stripSlot.Parent = stripBody

	local stripTitle = kit.label({
		parent = stripSlot,
		name = "Title",
		text = "Out of lives!",
		size = UDim2.fromScale(1, 1),
		cap = 20,
		ramp = DANGER_RAMP,
		stroke = 2.5,
	})

	local stripSub = kit.label({
		parent = stripBody,
		name = "Sub",
		text = "Watch the rest",
		size = UDim2.new(1, 0, 0, 20),
		anchor = TOP_LEFT,
		font = kit.FONT_BOLD,
		cap = 14,
		stroke = 1.5,
	})
	stripSub.LayoutOrder = 2

	-- ==========================================================================
	-- §3) crowns-at-death memory
	-- ==========================================================================
	--[[ The server zeroes Crowns the moment you die, so the card cannot just read the
		attribute. We remember the last value it held before it fell, and keep the
		killer's cut from the kill feed as a last resort (stolen = crowns * CROWN_DROP_FRACTION). ]]
	local crownsNow = tonumber(player:GetAttribute(ATTR.CROWNS)) or 0
	local crownsBefore, crownsBeforeAt = 0, 0
	local stolenFromMe, stolenAt = 0, 0

	local function crownsLost(): number
		if crownsNow > 0 then
			return crownsNow -- the drop has not replicated yet: this IS the pile
		end
		local now = os.clock()
		if crownsBefore > 0 and now - crownsBeforeAt <= CROWN_MEMORY then
			return crownsBefore
		end
		local frac = tonumber(MATCH.CROWN_DROP_FRACTION) or 0
		if stolenFromMe > 0 and frac > 0 and now - stolenAt <= CROWN_MEMORY then
			return math.floor(stolenFromMe / frac)
		end
		return 0 -- no trustworthy number: show no line rather than a wrong one
	end

	local function refreshCrownLine()
		local lost = crownsLost()
		crownLine.Visible = lost > 0
		if lost == 1 then
			crownLine.Text = "Lost 1 crown"
		elseif lost > 1 then
			crownLine.Text = "Lost " .. MathUtil.comma(lost) .. " crowns"
		end
	end

	-- ==========================================================================
	-- §4) respawn button state machine  ("counting" -> "ready" -> "sent")
	-- ==========================================================================
	local btnState = "counting"
	local respawnAt = nil
	local shownCount = nil
	local ticket = 0 -- invalidates pending re-arm work when the card changes
	local joinToken = 0 -- invalidates a pending "Jump in!" offer
	local t = 0

	local function setButton(enabled: boolean, text: string)
		respawnBtn.Text = text
		respawnBtn.Active = enabled
		veil.Visible = not enabled
	end

	local function armRespawn()
		if btnState == "ready" then
			return
		end
		btnState = "ready"
		setButton(true, "RESPAWN")
		-- A pop AND a click the instant it becomes tappable. The btnState guard above is
		-- what keeps this to one sound per arm, however often the tick re-enters.
		kit.playSfx("TOGGLE")
		kit.popIn(respawnBtn, 0.85)
	end

	function requestRespawn()
		if btnState ~= "ready" then
			return -- countdown still running, or a request is already in flight
		end
		btnState = "sent"
		setButton(false, "Respawning...") -- disabled the same frame: a double tap cannot spam

		local myTicket = ticket
		net.RequestRespawn:FireServer()

		task.delay(REARM_AFTER, function()
			-- No "spawned" landed: the server refused or the request was dropped.
			if ticket == myTicket and card.Visible and btnState == "sent" then
				armRespawn()
			end
		end)
	end

	-- ==========================================================================
	-- §5) show / hide
	-- ==========================================================================
	local function applyFit()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local scale = math.min(vp.X / (CARD_W + 80), vp.Y / (CARD_H + 100), 1)
		fit.Scale = math.clamp(scale, FIT_FLOOR, 1)
	end
	applyFit()

	local function setPips(livesLeft: number)
		for i, pip in ipairs(pips) do
			local on = i <= livesLeft
			pip.BackgroundColor3 = on and kit.CONFIRM or kit.GLASS
			pip.BackgroundTransparency = on and 0 or 0.25
		end
	end

	local function livesText(lives: number): string
		return lives == 1 and "1 life left" or (lives .. " lives left")
	end

	local function hideAll()
		ticket += 1
		joinToken += 1
		respawnAt = nil
		shownCount = nil
		if card.Visible then
			kit.popOut(card, function()
				backdrop.Visible = false
			end)
		else
			backdrop.Visible = false
		end
		if strip.Visible then
			kit.popOut(strip)
		end
	end

	local function showSpectate(title: string, sub: string)
		ticket += 1
		joinToken += 1
		stripTitle.Text = title
		stripSub.Text = sub
		if card.Visible then
			kit.popOut(card)
		end
		backdrop.Visible = false
		if not strip.Visible then
			kit.popIn(strip)
		end
	end

	local function showDeath(info)
		if type(info) ~= "table" then
			return
		end
		local title = HEADLINE[tostring(info.cause)]
		if not title then
			return -- roundEnd / reset / left: not a death, not the player's fault
		end

		local livesLeft = math.max(0, math.floor(tonumber(info.livesLeft) or 0))

		--[[ ONE sound for the death, escalating: THUD while there are lives left, the
			heavier IMPACT for the run-ending one. It lives HERE and not inside
			showSpectate, because offerJoin() reaches that too and nobody died there. ]]
		if livesLeft <= 0 then
			kit.playSfx("IMPACT")
			showSpectate("Out of lives!", "Heading back to the lobby")
			return
		end
		kit.playSfx("THUD")

		ticket += 1
		joinToken += 1
		setHeadRamp(DANGER_RAMP)
		headline.Text = title

		local killerName = type(info.killerName) == "string" and info.killerName ~= "" and info.killerName or nil
		killerLine.Visible = killerName ~= nil
		if killerName then
			killerLine.Text = killerName .. " got you"
		end

		refreshCrownLine()
		setPips(livesLeft)
		livesLine.Text = livesText(livesLeft)

		-- Trust the server's deadline, never a local timer.
		respawnAt = tonumber(info.canRespawnAt) or (workspace:GetServerTimeNow() + MATCH.RESPAWN_DELAY)
		btnState = "counting"
		shownCount = nil
		setButton(false, "Respawn in " .. math.max(1, math.ceil(respawnAt - workspace:GetServerTimeNow())))

		if strip.Visible then
			kit.popOut(strip)
		end
		applyFit()
		backdrop.Visible = true
		kit.popIn(card)
	end

	--[[ No car, no death: a mid-match joiner or a spawn the server quietly refused.
		Same card, friendly headline, and the button is live immediately — there is no
		death penalty to wait out. If the server still says no, the re-arm makes it a
		retry button rather than a dead end. ]]
	local function showJoin(lives: number)
		ticket += 1
		joinToken += 1
		setHeadRamp(kit.GOLD_RAMP)
		headline.Text = JOIN_HEADLINE
		killerLine.Visible = false
		crownLine.Visible = false
		setPips(lives)
		livesLine.Text = livesText(lives)

		respawnAt = nil
		btnState = "counting"
		shownCount = nil
		armRespawn()

		if strip.Visible then
			kit.popOut(strip)
		end
		applyFit()
		backdrop.Visible = true
		kit.popIn(card)
	end

	local function offerJoin()
		if MatchState.getPhase() ~= PHASES.MATCH then
			return -- lobby and results own the screen; nothing to jump into
		end
		if player:GetAttribute(ATTR.ALIVE) == true then
			return
		end
		if card.Visible or strip.Visible then
			return -- already told them where they stand
		end

		local lives = tonumber(player:GetAttribute(ATTR.LIVES))
		if lives and lives <= 0 then
			showSpectate("Next round soon!", "Waiting in the lobby")
			return
		end
		showJoin(math.max(1, math.floor(lives or MATCH.LIVES)))
	end

	--[[ Alive is false for a beat at the Match edge, before spawnAll lands, so the offer
		waits out a grace period. Any spawn / death / phase change cancels it. ]]
	local function scheduleOffer()
		joinToken += 1
		local myToken = joinToken
		task.delay(JOIN_GRACE, function()
			if joinToken == myToken then
				offerJoin()
			end
		end)
	end

	-- ==========================================================================
	-- §6) wiring + the single Heartbeat tick
	-- ==========================================================================
	local conns = {}

	table.insert(
		conns,
		player:GetAttributeChangedSignal(ATTR.CROWNS):Connect(function()
			local value = tonumber(player:GetAttribute(ATTR.CROWNS)) or 0
			if crownsNow > 0 and value < crownsNow then
				crownsBefore, crownsBeforeAt = crownsNow, os.clock()
			end
			crownsNow = value
			if card.Visible then
				refreshCrownLine()
			end
		end)
	)

	table.insert(
		conns,
		player:GetAttributeChangedSignal(ATTR.ALIVE):Connect(function()
			if player:GetAttribute(ATTR.ALIVE) == true then
				joinToken += 1 -- in a car: nothing to offer
			else
				scheduleOffer() -- covers the deaths that never send a "destroyed"
			end
		end)
	)

	table.insert(
		conns,
		net.CarLifecycle.OnClientEvent:Connect(function(action, _model, info)
			if action == "destroyed" then
				showDeath(info)
			elseif action == "spawned" then
				hideAll() -- the server actually put us back in: only now does the card go
			end
		end)
	)

	table.insert(
		conns,
		net.MatchEvent.OnClientEvent:Connect(function(kind, payload)
			if kind ~= "kill" or type(payload) ~= "table" then
				return
			end
			if payload.victimName ~= player.Name then
				return
			end
			local stolen = tonumber(payload.crowns) or 0
			if stolen > 0 then
				stolenFromMe, stolenAt = stolen, os.clock()
				if card.Visible then
					refreshCrownLine() -- the kill feed may land after the card is already up
				end
			end
		end)
	)

	table.insert(
		conns,
		MatchState.onPhaseChanged(function(phase)
			if phase == PHASES.MATCH then
				scheduleOffer() -- also covers joining straight into a live match
			else
				hideAll()
				crownsBefore, crownsBeforeAt = 0, 0
				stolenFromMe, stolenAt = 0, 0
			end
		end)
	)

	-- ONE tick for the countdown, the pips and the idle drift. No task.wait loops.
	table.insert(
		conns,
		RunService.Heartbeat:Connect(function(dt)
			t += dt
			if card.Visible then
				if btnState == "counting" and respawnAt then
					local left = respawnAt - workspace:GetServerTimeNow()
					if left <= 0.05 then
						armRespawn()
					else
						local whole = math.max(1, math.ceil(left))
						if whole ~= shownCount then
							shownCount = whole
							setButton(false, "Respawn in " .. whole)
						end
					end
				end
				headline.Position = UDim2.new(0.5, 0, 0.5, math.round(MathUtil.drift(t, 2.2, 0.6, DRIFT_AMP)))
			elseif strip.Visible then
				stripTitle.Position = UDim2.new(0.5, 0, 0.5, math.round(MathUtil.drift(t, 1.8, 1.2, DRIFT_AMP - 1)))
			end
		end)
	)

	gui.Destroying:Connect(function()
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		table.clear(conns)
	end)
end

return DeathUI
