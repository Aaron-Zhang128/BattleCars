--[[ ResultsUI
	End-of-round board: a three-high podium, the full standings, and the coin payout
	reveal — the dopamine beat that sends a kid into the next round.

	UI module (see StarterGui.Main.Main for the ctx contract). Everything here is built
	from code into its own ScreenGui at kit.DISPLAY_ORDER.RESULTS — nothing is authored
	into the Studio tree.

	VISIBILITY IS DRIVEN HERE, NOT BY THE FRAME MANAGER. The panel is deliberately NOT
	passed to kit.registerFrame: it has no Close button, it opens from the "results"
	event and it auto-dismisses when the phase leaves Results (Config.ROUND.RESULTS_SECONDS
	is the belt-and-braces fallback). Registering it would also let it fight the garage
	window for the one-frame-at-a-time slot.

	§1) constants
	§2) build (podium + standings + payout), rebuilt per round
	§3) show / dismiss
	§4) wiring + the single RenderStepped tick (drift, shimmer, pulse, rolling counter)

	READS
		MatchEvent (S->C) "results" { board = { {name,userId,crowns,kills,score,team}, ... },
		                              payouts = { [userId] = coins },
		                              teams = { {index,name,color,score}, ... } | nil }
		                  `score` is whatever the round's mode placed on and `teams` is
		                  present only in a team mode — the headline becomes the
		                  scoreline when it is, and the podium counts `score` either way.
		MatchState phase + phaseSeconds (dismiss when it leaves Results), Config.ECONOMY
	WRITES
		nothing: no attributes, no remotes fired, no sibling module's instances

	A second "results" event rebuilds cleanly (the body is destroyed and remade, and a
	version counter kills every pending stagger/scroll/dismiss task) so two panels can
	never stack. Losing never gets scolded: the neutral headline is "Nice race!".

	SOUND + HOVER
		One REWARD per podium placement as it staggers in, rising in volume toward 1st so
		three chimes 0.12s apart read as a BUILD rather than three copies of a fanfare.
		The standings rows are the only hoverable thing here — a kid scans that list for
		their own name, so the row under the pointer lifts and brightens its ring. The
		podium cards are deliberately NOT bound: the winner pulse already drives their
		UIScale every frame and a hover tween would fight it. Making rows Active is safe
		because this panel only exists in the Results phase, never while driving.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))

local player = Players.LocalPlayer
local ECON = Config.ECONOMY
local PHASES = MatchState.PHASES

local ResultsUI = {}

-- ==========================================================================
-- §1) constants
-- ==========================================================================
--[[ Podium accents. Gold and silver come straight from the palette (kit.GOLD and
	RARITY.COMMON); the palette has no warm brown, so BRONZE is the one new constant
	here and it is only ever used for 3rd place. ]]
local BRONZE = Color3.fromRGB(198, 124, 66)
local MONEY_GREEN = Config.UI.GREEN -- house money ramp partner for LIME

local PANEL_W, PANEL_H = 620, 472
local FIT_FLOOR = 0.65 -- house phone floor for fixed-offset cards

local HEAD_H = 46
local PODIUM_TOP, PODIUM_H = 52, 168
local LIST_TOP, LIST_H = 228, 122
local PAY_H = 72

local SLOT_W, SLOT_GAP = 132, 14
local SLOT_H = { 168, 138, 118 } -- 1st tallest, centred; 2nd left, 3rd right
local SLOT_DX = { 0, -(132 + 14), 132 + 14 }
local STAGGER = 0.12 -- reveal gap: 3rd, then 2nd, then 1st
local REVEAL_VOLUME = { 1, 0.78, 0.6 } -- 1st..3rd: the reveal chime builds to the winner

local ROW_H, ROW_PAD = 30, 4
local ROW_HOVER_SCALE = 1.03 -- full-width rows: the house 1.07 would clip on the list edge
local ROLL_TIME = 0.6 -- rolling coin counter duration
local ROLL_DELAY = 0.45 -- let the podium reveal land first
local DRIFT_AMP = 3 -- px of two-sine headline drift
local PULSE_SETTLE = 0.34 -- winner pulse waits out its own pop tween

local function ordinal(n: number): string
	if n == 1 then
		return "1st"
	elseif n == 2 then
		return "2nd"
	elseif n == 3 then
		return "3rd"
	end
	return tostring(n) .. "th"
end

local inited = false

function ResultsUI.init(ctx)
	if inited then
		return
	end
	inited = true

	local kit = ctx.kit
	local net = ctx.net
	if not net.MatchEvent then
		warn("ResultsUI: MatchEvent missing, results panel disabled")
		return
	end

	local PLACE = {
		{ label = "1st", accent = kit.GOLD },
		{ label = "2nd", accent = kit.RARITY.COMMON }, -- silver
		{ label = "3rd", accent = BRONZE },
	}
	local MONEY_RAMP = { kit.LIME, MONEY_GREEN, MONEY_GREEN:Lerp(kit.INK, 0.4) }

	-- ==========================================================================
	-- shell (built once)
	-- ==========================================================================
	local gui = kit.screen("CrashResults", kit.DISPLAY_ORDER.RESULTS)

	-- Holder carries the phone fit scale; the panel's own UIScale is the pop tween.
	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Active = false -- never swallows the touch controls underneath
	holder.Parent = gui

	local fit = Instance.new("UIScale")
	fit.Parent = holder

	local panel = kit.card({
		parent = holder,
		name = "ResultsPanel",
		size = UDim2.fromScale(1, 1),
		accent = kit.GOLD,
	})
	panel.Visible = false

	-- per-round state
	local body = nil
	local headline, headGrad, coinLabel, winnerScale = nil, nil, nil, nil
	local version = 0
	local t = 0
	local pulseFrom = math.huge
	local coinTarget, coinShown, rollT, rollWait = 0, -1, 0, 0

	local function applyFit()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local scale = math.min(vp.X / (PANEL_W + 60), vp.Y / (PANEL_H + 80), 1)
		fit.Scale = math.clamp(scale, FIT_FLOOR, 1)
	end
	applyFit()

	-- ==========================================================================
	-- §2) build
	-- ==========================================================================
	local function addRow(parent: Instance, place: number, row, isMe: boolean)
		local frame = Instance.new("Frame")
		frame.Name = "Row" .. place
		frame.Size = UDim2.new(1, -8, 0, ROW_H)
		frame.BackgroundColor3 = isMe and kit.CONFIRM:Lerp(kit.GLASS, 0.7) or kit.GLASS
		frame.BackgroundTransparency = isMe and 0.05 or 0.3
		frame.BorderSizePixel = 0
		frame.LayoutOrder = place
		frame.Parent = parent
		kit.corner(frame, 8)
		local rowStroke =
			kit.stroke(frame, isMe and 3 or 1.5, isMe and kit.CONFIRM or kit.INK, isMe and 0 or 0.25)

		-- Lift the row and brighten its ring under the pointer. Active is fine inside the
		-- ScrollingFrame: the garage grid already scrolls with GuiButtons in its cells.
		kit.bindHover(frame, { scale = ROW_HOVER_SCALE, stroke = rowStroke })

		kit.label({
			parent = frame,
			name = "Rank",
			text = tostring(place),
			size = UDim2.new(0, 40, 1, 0),
			position = UDim2.new(0, 8, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			cap = 15,
			stroke = 2,
			align = Enum.TextXAlignment.Left,
		})
		kit.label({
			parent = frame,
			name = "PlayerName",
			text = tostring(row.name or "?"),
			size = UDim2.new(1, -296, 1, 0),
			position = UDim2.new(0, 50, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			font = kit.FONT_BOLD,
			cap = 15,
			stroke = 1.6,
			align = Enum.TextXAlignment.Left,
		})
		kit.label({
			parent = frame,
			name = "Score",
			-- The mode's own number and its own noun: "12 wrecks", "8 points", "5 crowns".
			text = MathUtil.comma(tonumber(row.score or row.crowns) or 0) .. " " .. GameModes.scoreNoun(),
			size = UDim2.new(0, 120, 1, 0),
			position = UDim2.new(1, -246, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			cap = 14,
			ramp = kit.GOLD_RAMP,
			stroke = 2,
			align = Enum.TextXAlignment.Right,
		})
		kit.label({
			parent = frame,
			name = "Kills",
			text = MathUtil.comma(tonumber(row.kills) or 0) .. " kills",
			size = UDim2.new(0, 110, 1, 0),
			position = UDim2.new(1, -118, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			font = kit.FONT_BOLD,
			cap = 13,
			stroke = 1.6,
			align = Enum.TextXAlignment.Right,
		})
	end

	local function addPodiumSlot(parent: Instance, place: number, row, isMe: boolean, myVersion: number)
		local def = PLACE[place]

		-- The slot owns the pop tween; the card inside owns the winner pulse. Two
		-- UIScales so the reveal and the idle motion never fight.
		local slot = Instance.new("Frame")
		slot.Name = "Slot" .. place
		slot.Size = UDim2.fromOffset(SLOT_W, SLOT_H[place])
		slot.Position = UDim2.new(0.5, SLOT_DX[place], 1, 0)
		slot.AnchorPoint = Vector2.new(0.5, 1)
		slot.BackgroundTransparency = 1
		slot.Visible = false
		slot.Parent = parent

		local pcard = kit.card({
			parent = slot,
			name = "Card",
			size = UDim2.fromScale(1, 1),
			accent = def.accent,
		})

		if isMe then
			local outline = pcard:FindFirstChildOfClass("UIStroke")
			if outline then
				outline.Color = kit.CONFIRM -- house selection state
				outline.Thickness = 3
			end
		end

		local badge = Instance.new("Frame")
		badge.Name = "Badge"
		badge.Size = UDim2.fromOffset(52, 24)
		badge.Position = UDim2.new(0.5, 0, 0, 10)
		badge.AnchorPoint = Vector2.new(0.5, 0)
		badge.BackgroundColor3 = def.accent
		badge.BorderSizePixel = 0
		badge.Parent = pcard
		kit.pill(badge)
		kit.stroke(badge, 2, kit.INK)
		kit.gradient(badge, { def.accent:Lerp(kit.PAPER, 0.35), def.accent, def.accent:Lerp(kit.INK, 0.25) })

		kit.label({
			parent = badge,
			name = "Place",
			text = def.label,
			size = UDim2.new(1, -8, 1, -6),
			cap = 14,
			stroke = 2,
		})
		kit.label({
			parent = pcard,
			name = "PlayerName",
			text = tostring(row.name or "?"),
			size = UDim2.new(1, -12, 0, 20),
			position = UDim2.new(0.5, 0, 0, 40),
			anchor = Vector2.new(0.5, 0),
			font = kit.FONT_BOLD,
			cap = 15,
			stroke = 1.6,
		})
		kit.label({
			parent = pcard,
			name = "Score",
			text = MathUtil.comma(tonumber(row.score or row.crowns) or 0),
			size = UDim2.new(1, -12, 0, 34),
			position = UDim2.new(0.5, 0, 0, 62),
			anchor = Vector2.new(0.5, 0),
			cap = 24,
			ramp = kit.GOLD_RAMP,
			stroke = 2.5,
		})
		kit.label({
			parent = pcard,
			name = "Caption",
			text = GameModes.scoreNoun(),
			size = UDim2.new(1, -12, 0, 14),
			position = UDim2.new(0.5, 0, 0, 96),
			anchor = Vector2.new(0.5, 0),
			font = kit.FONT_BOLD,
			cap = 12,
			stroke = 1.4,
		})

		-- Staggered reveal: 3rd, 2nd, 1st.
		task.delay((3 - place) * STAGGER, function()
			if version ~= myVersion or not panel.Visible then
				return
			end
			kit.popIn(slot)
			-- One REWARD per placement, rising: 3rd lands quietest, 1st loudest.
			kit.playSfx("REWARD", REVEAL_VOLUME[place] or 1)
			if place == 1 then
				winnerScale = kit.ensureScale(pcard)
				pulseFrom = t + PULSE_SETTLE
			end
		end)
	end

	local function build(payload)
		if body then
			body:Destroy()
			body = nil
		end
		headline, headGrad, coinLabel, winnerScale = nil, nil, nil, nil
		pulseFrom = math.huge
		coinTarget, coinShown, rollT, rollWait = 0, -1, 0, ROLL_DELAY

		version += 1
		local myVersion = version

		local board = type(payload.board) == "table" and payload.board or {}
		local payouts = type(payload.payouts) == "table" and payload.payouts or {}

		local myPlace = nil
		for place, row in ipairs(board) do
			if tonumber(row.userId) == player.UserId then
				myPlace = place
				break
			end
		end

		body = Instance.new("Frame")
		body.Name = "Body"
		body.Size = UDim2.new(1, -28, 1, -24)
		body.Position = UDim2.fromScale(0.5, 0.5)
		body.AnchorPoint = Vector2.new(0.5, 0.5)
		body.BackgroundTransparency = 1
		body.Parent = panel

		--[[ headline: gold + shimmer for a win, warm and neutral for everyone else.

			In a TEAM mode the round was not won by a PERSON, so the headline stops being
			about placement and becomes the scoreline — and `won` (which drives the gold
			ramp and the shimmer in the frame loop) follows your SIDE instead of your own
			rank. Somebody who came fourth on the winning team should still be told they
			won; that is the whole difference between a team mode and a free-for-all. ]]
		local teams = type(payload.teams) == "table" and payload.teams or nil
		local top = teams and teams[1] or nil
		local runnerUp = teams and teams[2] or nil

		local won = myPlace == 1
		local headText = won and "You won!" or "Nice race!"
		local headColor = nil

		if top then
			local otherScore = runnerUp and runnerUp.score or 0
			local drawn = runnerUp ~= nil and otherScore == top.score
			won = not drawn and GameModes.teamOf(player) == top.index
			if drawn then
				headText = string.format("Draw! %d — %d", top.score, otherScore)
			else
				headText = string.format("%s wins! %d — %d", top.name, top.score, otherScore)
			end
			-- The losing side still gets told WHO won, in that side's own colour.
			headColor = (not won) and top.color or nil
		end

		headline = kit.label({
			parent = body,
			name = "Headline",
			text = headText,
			size = UDim2.new(1, 0, 0, HEAD_H),
			position = UDim2.new(0.5, 0, 0, 0),
			anchor = Vector2.new(0.5, 0),
			cap = 24,
			ramp = won and kit.GOLD_RAMP or nil,
			color = not won and (headColor or kit.PAPER) or nil,
			stroke = 3,
		})
		headGrad = won and headline:FindFirstChildOfClass("UIGradient") or nil

		local podium = Instance.new("Frame")
		podium.Name = "Podium"
		podium.Size = UDim2.new(1, 0, 0, PODIUM_H)
		podium.Position = UDim2.new(0.5, 0, 0, PODIUM_TOP)
		podium.AnchorPoint = Vector2.new(0.5, 0)
		podium.BackgroundTransparency = 1
		podium.Parent = body

		if #board == 0 then
			kit.label({
				parent = podium,
				name = "Empty",
				text = "Round over!",
				size = UDim2.new(1, 0, 0, 40),
				cap = 20,
				font = kit.FONT_BOLD,
				stroke = 2.5,
			})
		end

		for place = 1, math.min(3, #board) do
			addPodiumSlot(podium, place, board[place], myPlace == place, myVersion)
		end

		-- standings, ranks 4+
		local list = Instance.new("ScrollingFrame")
		list.Name = "Standings"
		list.Size = UDim2.new(1, 0, 0, LIST_H)
		list.Position = UDim2.new(0.5, 0, 0, LIST_TOP)
		list.AnchorPoint = Vector2.new(0.5, 0)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ClipsDescendants = true
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.ScrollBarThickness = 4
		list.ScrollBarImageColor3 = kit.PAPER
		list.ScrollBarImageTransparency = 0.5
		list.Visible = #board > 3
		list.Parent = body

		local listLayout = Instance.new("UIListLayout")
		listLayout.FillDirection = Enum.FillDirection.Vertical
		listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Padding = UDim.new(0, ROW_PAD)
		listLayout.Parent = list

		for place = 4, #board do
			addRow(list, place, board[place], myPlace == place)
		end

		--[[ Outside the top 3: make sure their own row is on screen. Runs after the
			layout has measured itself, and again a beat later in case the automatic
			canvas size had not settled. ]]
		if myPlace and myPlace > 3 then
			local function scrollToMe()
				if version ~= myVersion or not list.Parent then
					return
				end
				local y = (myPlace - 4) * (ROW_H + ROW_PAD)
				list.CanvasPosition = Vector2.new(0, math.max(0, y - (list.AbsoluteSize.Y - ROW_H) * 0.5))
			end
			task.defer(scrollToMe)
			task.delay(0.15, scrollToMe)
		end

		-- payout reveal
		local pay = Instance.new("Frame")
		pay.Name = "Payout"
		pay.Size = UDim2.new(1, 0, 0, PAY_H)
		pay.Position = UDim2.new(0.5, 0, 1, 0)
		pay.AnchorPoint = Vector2.new(0.5, 1)
		pay.BackgroundTransparency = 1
		pay.Parent = body

		local coins = math.max(0, math.floor(tonumber(payouts[player.UserId]) or 0))
		coinLabel = kit.label({
			parent = pay,
			name = "Coins",
			text = coins > 0 and "+0 coins!" or "Next round soon!",
			size = UDim2.new(1, 0, 0, 44),
			position = UDim2.new(0.5, 0, 0, 0),
			anchor = Vector2.new(0.5, 0),
			cap = 24,
			ramp = MONEY_RAMP,
			stroke = 3,
		})
		coinTarget = coins

		local bonusText = ""
		if coins > 0 and myPlace and ECON.COINS_PER_PLACEMENT[myPlace] then
			bonusText = ordinal(myPlace) .. " place bonus!"
		end
		local bonus = kit.label({
			parent = pay,
			name = "Bonus",
			text = bonusText,
			size = UDim2.new(1, 0, 0, 20),
			position = UDim2.new(0.5, 0, 1, 0),
			anchor = Vector2.new(0.5, 1),
			font = kit.FONT_BOLD,
			color = kit.GOLD,
			cap = 14,
			stroke = 1.6,
		})
		bonus.Visible = bonusText ~= ""
	end

	-- ==========================================================================
	-- §3) show / dismiss
	-- ==========================================================================
	local function dismiss()
		version += 1 -- kills pending stagger / scroll / fallback work
		if not panel.Visible then
			return
		end
		kit.popOut(panel)
	end

	local function show(payload)
		--[[ The garage sits above us at DISPLAY_ORDER 40 — deliberately, it has to clear the
			HUD and the death card — and we are not in the frame manager, so a garage window
			left open would bury the standings and the payout. Closing it is the fix, never
			reordering. pcall because GarageUI may not have loaded; closeFrame no-ops when the
			frame is unregistered or already hidden. ]]
		pcall(function()
			kit.closeFrame("Garage")
		end)

		build(payload)
		t = 0
		applyFit()
		kit.popIn(panel)

		local myVersion = version
		-- Fallback only: the phase watcher below is what normally closes the panel.
		task.delay(MatchState.phaseSeconds(PHASES.RESULTS) + 1, function()
			if version == myVersion then
				dismiss()
			end
		end)
	end

	-- ==========================================================================
	-- §4) wiring + the single RenderStepped tick
	-- ==========================================================================
	local conns = {}

	table.insert(
		conns,
		net.MatchEvent.OnClientEvent:Connect(function(kind, payload)
			if kind ~= "results" or type(payload) ~= "table" then
				return
			end
			show(payload) -- a second event rebuilds; it never stacks a second panel
		end)
	)

	table.insert(
		conns,
		MatchState.onPhaseChanged(function(phase)
			if phase ~= PHASES.RESULTS then
				dismiss()
			end
		end)
	)

	-- ONE binding for every looped motion here: drift, shimmer, pulse, rolling counter.
	table.insert(
		conns,
		RunService.RenderStepped:Connect(function(dt)
			if not panel.Visible then
				return
			end
			t += dt

			if headline then
				headline.Position = UDim2.new(0.5, 0, 0, math.round(MathUtil.drift(t, 2.0, 0.4, DRIFT_AMP)))
			end
			if headGrad then
				headGrad.Offset = Vector2.new(0, math.sin(t * 1.6) * 0.22) -- winner shimmer
			end
			if winnerScale and t >= pulseFrom then
				winnerScale.Scale = MathUtil.pulse(t, 3.0, 0, 0.025)
			end

			if coinLabel and coinTarget > 0 and rollT < ROLL_TIME then
				if rollWait > 0 then
					rollWait -= dt
				else
					rollT = math.min(ROLL_TIME, rollT + dt)
					local eased = 1 - (1 - rollT / ROLL_TIME) ^ 3
					local shown = math.floor(coinTarget * eased + 0.5)
					if shown ~= coinShown then
						coinShown = shown
						coinLabel.Text = "+" .. MathUtil.comma(shown) .. " coins!"
					end
				end
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

return ResultsUI
