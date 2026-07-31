--[[ LobbyUI
	The between-rounds screen: a centred card with the next-race countdown, the racer
	count, and the GARAGE entry point — plus the Lobby -> Match "GO!" flourish.

	READS (this module writes nothing — no remotes fired, no attributes set):
		Match state   MatchState.onPhaseChanged() / timeLeft() / formatClock()
		Players       #Players:GetPlayers() vs MatchState.minPlayers() for the
		              waiting state (MatchService holds the lobby and keeps rolling
		              PhaseEndsAt forward, so the clock never freezes at 0:00)
		Config        Config.ROUND.MIN_PLAYERS, read through MatchState.minPlayers()
		              so the Studio profile is applied once, in one place, for the
		              card and for the server that starts the round

	OWNS
		The ONLY garage entry points: the card's GARAGE button during Lobby and a small
		persistent corner button so a player can browse mid-match. Both call
		kit.openFrame("Garage") — GarageUI registers that frame; a missing registration
		warns once instead of erroring. Both buttons sit in the centre / RIGHT half:
		InputController's SteerZone owns the ENTIRE LEFT HALF, so an Active element there
		would swallow a steering drag on a phone.

	MOTION — one RenderStepped connection, manual sine math (MathUtil.drift / pulse),
	gated behind the card's visibility so it costs nothing while hidden. The GO!
	flourish is a one-shot pop in / pop out.

	SOUND — one beat only: THUD as the lights go green with the GO! word. Both GARAGE
	buttons come from kit.button, so their hover / press feel and their HOVER + CLICK
	sounds are already attached by UIKit.addButtonFeedback; opening the garage plays
	kit.openFrame's own OPEN. The lobby card itself is informational (a countdown a
	player cannot act on) so it gets no hover and no arrival sound — it reappears every
	single round, and a chime there would be the definition of noise.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))

local PHASES = MatchState.PHASES

local player = Players.LocalPlayer

local LobbyUI = {}

-- ==========================================================================
-- §1) constants
-- ==========================================================================
-- Taller than it was: the card now has to name the ruleset as well as the clock,
-- and the mode is the single most important thing a player reads between rounds.
local CARD = Vector2.new(420, 336)
local HEADLINE_Y = 18
local HEADLINE_H = 40
local CLOCK_Y = 62
local CLOCK_H = 100
local SUB_Y = 170
local SUB_H = 26
local MODE_Y = 208
local MODE_H = 30
local BLURB_Y = 240
local BLURB_H = 22

local CLOCK_CAP = 48 -- hero countdown: the one text above the 16-24 body range
local GO_CAP = 120 -- the GO! flourish word
local GO_HOLD = 0.6 -- seconds the flourish sits before popping out

local HEADLINE_DRIFT_FREQ = 1.1
local HEADLINE_DRIFT_AMP = 3
local CLOCK_PULSE_SPEED = 3.2
local CLOCK_PULSE_AMP = 0.028

local CORNER_BTN = Vector2.new(104, 34)
local CORNER_X = 18
local CORNER_Y = 44 -- top-RIGHT corner: the left half is InputController's steer zone

-- CarShopUI, not GarageUI: GarageUI is deliberately absent from Main's ORDER, so
-- "Garage" is never registered and this button opened nothing at all.
local GARAGE_FRAME = "CarShop"

local initialized = false

--[[ Config.ROUND.MIN_PLAYERS with the Studio profile applied -- the same call
	MatchService makes, so this card can no longer read "Waiting for players" while the
	round is already starting. ]]
local function minPlayers(): number
	return MatchState.minPlayers()
end

function LobbyUI.init(ctx)
	if initialized then
		return
	end
	initialized = true

	local kit = ctx.kit
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

	-- ==========================================================================
	-- §2) garage entry point
	-- ==========================================================================
	local garageWarned = false
	local function openGarage()
		local ok, err = pcall(kit.openFrame, GARAGE_FRAME)
		if not ok and not garageWarned then
			garageWarned = true
			warn("LobbyUI: garage frame unavailable -> " .. tostring(err))
		end
	end

	-- ==========================================================================
	-- §3) screen + card
	-- ==========================================================================
	-- If StarterGui.Main is ever re-copied (respawn), drop the previous lobby screen
	-- so we never stack two ScreenGuis / two frame loops.
	local playerGui = player:WaitForChild("PlayerGui")
	local stale = playerGui:FindFirstChild("CrashLobby")
	if stale then
		stale:Destroy()
	end

	local gui = kit.screen("CrashLobby", kit.DISPLAY_ORDER.LOBBY)

	local card = kit.card({
		parent = gui,
		name = "LobbyCard",
		size = UDim2.fromOffset(CARD.X, CARD.Y),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		accent = kit.GOLD,
	})
	card.Visible = false

	local headline = textLabel({
		parent = card,
		name = "Headline",
		text = "Next race in",
		size = UDim2.new(1, -40, 0, HEADLINE_H),
		position = UDim2.new(0.5, 0, 0, HEADLINE_Y),
		anchor = Vector2.new(0.5, 0),
		cap = 24,
		ramp = kit.GOLD_RAMP,
		stroke = 3,
	})
	local headlineBase = headline.Position

	local clock = textLabel({
		parent = card,
		name = "Clock",
		text = "0:00",
		size = UDim2.new(1, -40, 0, CLOCK_H),
		position = UDim2.new(0.5, 0, 0, CLOCK_Y),
		anchor = Vector2.new(0.5, 0),
		cap = CLOCK_CAP,
		stroke = 3,
	})
	local clockScale = kit.ensureScale(clock)

	local subLine = textLabel({
		parent = card,
		name = "Racers",
		text = "",
		size = UDim2.new(1, -40, 0, SUB_H),
		position = UDim2.new(0.5, 0, 0, SUB_Y),
		anchor = Vector2.new(0.5, 0),
		cap = 18,
		color = kit.GOLD_LIGHT,
		stroke = 2,
	})

	--[[ §3b) the ruleset. The rotation changes the game every round — one round you are
		collecting crowns, the next you have one life — so the card has to say WHICH
		game before it says when. Name in the mode's own accent, blurb underneath in
		plain words a kid can act on. ]]
	local modeName = textLabel({
		parent = card,
		name = "ModeName",
		text = "",
		size = UDim2.new(1, -40, 0, MODE_H),
		position = UDim2.new(0.5, 0, 0, MODE_Y),
		anchor = Vector2.new(0.5, 0),
		cap = 26,
		stroke = 3,
	})

	local modeBlurb = textLabel({
		parent = card,
		name = "ModeBlurb",
		text = "",
		size = UDim2.new(1, -40, 0, BLURB_H),
		position = UDim2.new(0.5, 0, 0, BLURB_Y),
		anchor = Vector2.new(0.5, 0),
		cap = 16,
		color = kit.PAPER,
		stroke = 2,
	})

	--[[ Repainted from the attribute, not from a remote: ModeService rotates at the top
		of Lobby and onModeChanged also fires once immediately, so a player who joined
		mid-round still reads the right ruleset the moment their UI exists. ]]
	local function paintMode(def)
		def = def or GameModes.current()
		setText(modeName, string.upper(GameModes.displayName()))
		setText(modeBlurb, def.blurb or "")
		modeName.TextColor3 = GameModes.accent(def)
	end
	table.insert(conns, GameModes.onModeChanged(paintMode))

	kit.button({
		parent = card,
		name = "GarageButton",
		text = "GARAGE",
		size = UDim2.fromOffset(200, 48),
		position = UDim2.new(0.5, 0, 1, -22),
		anchor = Vector2.new(0.5, 1),
		accent = kit.GOLD,
		textCap = 18,
		onClick = openGarage,
	})

	-- The persistent corner GARAGE button used to live here. RailUI now clones the kit's
	-- authored rail into that same right edge and its "Cars" button is up in every phase,
	-- so this was a second door to the same room -- and a generated button sitting next to
	-- hand-drawn art. Removed rather than restyled.

	-- ==========================================================================
	-- §4) GO! flourish
	-- ==========================================================================
	local goWord = textLabel({
		parent = gui,
		name = "Go",
		text = "GO!",
		size = UDim2.fromScale(0.7, 0.28),
		position = UDim2.fromScale(0.5, 0.44),
		anchor = Vector2.new(0.5, 0.5),
		cap = GO_CAP,
		ramp = kit.GOLD_RAMP,
		stroke = 3,
	})
	goWord.Visible = false

	--[[ The ruleset, said out loud on the way in. The lobby card is gone by now and the
		next thing a player does is drive, so this is the last chance to tell them what
		they are driving FOR. Rides the same one-shot as the word above it. ]]
	local goMode = textLabel({
		parent = gui,
		name = "GoMode",
		text = "",
		size = UDim2.fromScale(0.8, 0.09),
		position = UDim2.fromScale(0.5, 0.60),
		anchor = Vector2.new(0.5, 0.5),
		cap = 34,
		stroke = 3,
	})
	goMode.Visible = false

	local goToken = 0
	local function flourish()
		goToken += 1
		local token = goToken
		local def = GameModes.current()
		setText(goMode, string.upper(GameModes.displayName()))
		goMode.TextColor3 = GameModes.accent(def)

		kit.playSfx("THUD") -- one drum hit on the lights going green, with the word
		kit.popIn(goWord, 0.6)
		kit.popIn(goMode, 0.6)
		task.delay(GO_HOLD, function()
			if goToken ~= token then
				return
			end
			if goWord.Visible then
				kit.popOut(goWord)
			end
			if goMode.Visible then
				kit.popOut(goMode)
			end
		end)
	end

	-- ==========================================================================
	-- §5) racer count
	-- ==========================================================================
	local racerCount = #Players:GetPlayers()

	table.insert(conns, Players.PlayerAdded:Connect(function()
		racerCount = #Players:GetPlayers()
	end))
	table.insert(conns, Players.PlayerRemoving:Connect(function()
		-- fires BEFORE the player leaves the list
		racerCount = math.max(1, #Players:GetPlayers() - 1)
	end))

	local function racersReadyText(count: number): string
		if count == 1 then
			return "1 racer ready"
		end
		return tostring(count) .. " racers ready"
	end

	local function needMoreText(missing: number): string
		if missing <= 1 then
			return "Need 1 more racer"
		end
		return "Need " .. tostring(missing) .. " more racers"
	end

	-- ==========================================================================
	-- §6) phase visibility
	-- ==========================================================================
	local lastPhase = nil

	table.insert(conns, MatchState.onPhaseChanged(function(phase)
		if phase == PHASES.LOBBY then
			if not card.Visible then
				kit.popIn(card)
			end
		else
			if card.Visible then
				kit.popOut(card)
			end
			if phase == PHASES.MATCH and lastPhase == PHASES.LOBBY then
				flourish()
			end
		end
		lastPhase = phase
	end))

	-- ==========================================================================
	-- §7) the single frame loop — manual sine math only
	-- ==========================================================================
	local t = 0

	table.insert(conns, RunService.RenderStepped:Connect(function(dt)
		if not card.Visible then
			return
		end
		t += dt

		-- idle motion: two-layered drift on the headline, gentle pulse on the clock
		local dy = MathUtil.drift(t, HEADLINE_DRIFT_FREQ, 0.4, HEADLINE_DRIFT_AMP)
		headline.Position = headlineBase + UDim2.fromOffset(0, dy)
		clockScale.Scale = MathUtil.pulse(t, CLOCK_PULSE_SPEED, 0, CLOCK_PULSE_AMP)

		local needed = minPlayers()
		if racerCount < needed then
			-- the server is holding the lobby: there is no live countdown to show
			setText(headline, "Waiting for players")
			setText(clock, tostring(racerCount) .. " / " .. tostring(needed))
			setText(subLine, needMoreText(needed - racerCount))
		else
			setText(headline, "Next race in")
			setText(clock, MatchState.formatClock(MatchState.timeLeft()))
			setText(subLine, racersReadyText(racerCount))
		end
	end))

	gui.Destroying:Connect(function()
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
	end)
end

return LobbyUI
