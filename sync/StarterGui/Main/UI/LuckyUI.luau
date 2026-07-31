--[[ LuckyUI
	The lucky-block weapon roller: a chromeless VERTICAL reel of 3D weapons rolling
	top-to-bottom through the middle of the screen, settling on the one you won.

	Driven ENTIRELY by the server. LuckySpin carries the tile strip, the index the reel
	stops on and an ABSOLUTE server timestamp, and the strip offset is a pure function of
	(GetServerTimeNow() - startedAt). So a client that hitches, or one that receives the
	event late, catches up to where the reel should be instead of drifting — and the
	winner was never a client decision in the first place.

	READS   Remotes (S->C)   LuckySpin
	WRITES  nothing. No remotes fired, no attributes set. WeaponService fills the HUD
	        powerup slot on its own timer, which the server set to land as the reel stops —
	        so the slot popping IS the payoff, and this module never touches it.

	LAYOUT  TOP-CENTRE at DISPLAY_ORDER.LUCKY (12), tucked under HudUI's timer band: above
	        the HUD, below the death and results cards so neither is ever covered. It lives
	        up there because the middle of the screen is where you are DRIVING. Contains NO
	        GuiButton and the root is Active = false, so InputController's steer zone (the
	        whole left half of the screen) and its fire button keep receiving touches while
	        the reel spins. You keep driving through the whole spin — that is the point.

	        NO PANEL. The weapons hang straight over the world with nothing behind them but
	        two marker dashes flanking the winning slot — the reel IS the card. The root
	        frame is still named "LuckyCard" inside a ScreenGui still named "LuckySpin"
	        because HudUI resolves exactly that path and reads its .Visible to keep the
	        powerup slot quiet while the reel is paying off. Renaming either breaks that
	        silently: HudUI just starts double-announcing every spin-granted weapon.

	DEPTH   Off-centre tiles are smaller AND more transparent (TILE_SCALE / TILE_FADE), so
	        the column reads as one thing sliding past a focal point rather than four
	        unrelated icons. Everything more than CULL_STEPS away is Visible = false: a
	        ViewportFrame renders its own little scene every frame, and a 16-tile strip of
	        them is real GPU cost for tiles nobody can see. Exactly 3 are ever live: the
	        winner and the tile above and below it, which is all the reel needs to read.

	ICONS   Two sources, in this order. A MODELLED weapon (Config.WEAPON_RIGS) shows its
	        REAL model straight out of Assets.Weapons, so the thing rolling past the marker
	        is exactly the thing that will be bolted to your roof a second later. Anything
	        else — SHIELD today — still uses the hand-built primitive prop below, keyed off
	        PowerupDefs, each returning a Model centred on the origin for UIKit.viewport to
	        frame. An id with neither falls back to a plain cube in its own colour, so a new
	        powerup can never crash the reel; it just looks generic until it gets art.

	MOTION  Manual RenderStepped math, per the house rule against TweenService for looped
	        motion. Two beats: an ease-out APPROACH that is still genuinely rolling when it
	        reaches the winner, then a KICK over the last third — the strip is thrown a
	        third of a tile past the winner and snapped back onto it, landing on the pop.
	        The kick is ADDITIVE, so the reel still ends on exactly toOffset at u = 1, and
	        Config.LUCKY.REEL_TAIL guarantees there are tiles to throw it into.

	SOUND   TICK per tile that crosses the marker, REWARD as it lands, both from UIKit's
	        verified sound table rather than Sound instances of our own — one table, one
	        place to retune the whole game. playSfx creates a fresh Sound per call, so
	        ticks CAN overlap: hence TICK_MIN_GAP, a real design gap on top of playSfx's
	        0.04s floor. The ease-out does the rest of the work, spacing the last few
	        clicks out by itself. The landing REWARD is the payoff for the weapon this
	        grants, so HudUI stays quiet when its powerup slot fills while this card is up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))
local WeaponRig = require(sharedFolder:WaitForChild("WeaponRig"))

local UI = Config.UI

local LuckyUI = {}

-- ==========================================================================
-- LAYOUT CONSTANTS — pixel geometry, plus the presentation timings that are purely
-- local (how long the prize holds, how fast the reel is allowed to click). The SPIN
-- timings the server and client must agree on still live in Config.LUCKY.
-- ==========================================================================

--[[ REEL_H is ~2.1 STEPs on purpose: the winner sits in the middle with the tile above and
	the tile below it CROPPED by the window edge, which is what sells the column as endless.
	Whole tiles with nothing bleeding off the edges read as a list, not a reel. ]]
local REEL_W, REEL_H = 158, 200
local TILE_W, TILE_H = 84, 84
local TILE_GAP = 12
local STEP = TILE_H + TILE_GAP -- centre-to-centre distance between tiles

local PRIZE_GAP, PRIZE_H = 4, 26
local CARD_H = REEL_H + PRIZE_GAP + PRIZE_H

--[[ TOP-CENTRE, not screen-centre: the middle of the screen is where you are DRIVING, and the
	reel owns it for the whole SPIN_SECONDS. 44 is the Roblox topbar inset, the same one
	HudUI uses for its lives row — and HudUI's own top band is gone now, so nothing is
	under this but the arena. ]]
local TOP_MARGIN = 44

local ICON_INSET = 7 -- the viewport sits inside the tile so the badge has room
local AMMO_Y = 0.88 -- badge centre, as a fraction of tile height: it overlaps the icon
local AMMO_W, AMMO_H = 58, 26

local PIP_W, PIP_H = 20, 5 -- the two dashes that flank the winning slot
local PIP_EDGE = 3 -- inset from the window's left/right edge

--[[ Depth falloff, in STEPs away from the centre. A tile one step out is already well
	under half opacity — the reference this was built to match reads as ONE bright weapon
	with ghosts above and below it, not a list of four. ]]
local TILE_SCALE = { centre = 1.0, edge = 0.56 }
local TILE_FADE = { centre = 0, edge = 0.88 }
local FADE_STEPS = 1.15 -- distance (in STEPs) at which a tile is fully faded out
--[[ Only the winner and its two neighbours are ever drawn. REEL_H is 2.1 STEPs, so a tile
	two steps out is entirely outside the window anyway — culling it can never pop — and the
	column reads as ONE weapon with a ghost above and below it. ]]
local CULL_STEPS = 1.6

local LAND_HOLD = 1.25 -- seconds the prize stays up after the reel stops
local WINNER_SPIN_DPS = 95 -- the winner turns on the spot once it lands
local TICK_MIN_GAP = 0.07 -- ~14 clicks/s max: the opening whip reads as a whirr, not a buzz
local TICK_VOLUME_SCALE = 0.9

--[[ THE KICK. One ease-out quint had the reel crawling by 70% of the spin and arriving with no
	impact. The approach is now a shallower ease — still genuinely rolling into the finish —
	and the last KICK_WINDOW of the spin adds a pulse that throws the strip past the winner
	and snaps it back onto it. The pulse is ADDITIVE to the base curve, so the reel still
	lands on exactly toOffset at u = 1 no matter how these are tuned. ]]
local APPROACH_POWER = 2.6 -- ease-out exponent; lower carries more speed into the finish
local KICK_WINDOW = 0.4 -- last fraction of the spin the kick owns
local KICK_PEAK = 0.5 -- where inside that window the throw is furthest out
--[[ Pulse height in tiles. The BASE curve is still ~0.2 tiles short of the winner when the
	pulse peaks, so the throw you actually see past the winner is about half this — 0.45
	here reads as a quarter-tile overshoot. Measured, not guessed: raising it past ~0.5
	makes the strip visibly RE-ACCELERATE at the kick, which reads as a hitch, not a whip. ]]
local OVERSHOOT_STEPS = 0.45

--[[ Tiles are anchored at their CENTRE and stacked UPWARD (tile 2 sits one STEP above
	tile 1), so advancing through the strip means the offset grows and the whole column
	slides DOWN the screen. That direction is the entire ask: the reel rolls top to bottom. ]]
local function offsetFor(index: number): number
	return REEL_H * 0.5 + (index - 1) * STEP
end

-- Which strip index is currently under the marker, given a strip offset.
local function centredIndex(offset: number): number
	return math.floor((offset - REEL_H * 0.5) / STEP + 0.5) + 1
end

-- ==========================================================================
-- WEAPON PROPS — one low-poly model per powerup, built once at init
-- ==========================================================================

local function newProp(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- A Cylinder's axis is its LOCAL X, so standing one upright is a 90 degree roll.
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

--[[ Each builder gets the powerup's own colour and returns the part that becomes the
	model's PrimaryPart. Everything is authored around the origin because UIKit.viewport
	pivots the clone to CFrame.new() and then frames its bounding box. ]]
local PROP_BUILDERS = {
	ROCKET = function(model, color, ink, paper)
		local body = newProp(model, "Body", Vector3.new(3.4, 1.15, 1.15), UPRIGHT, color, Enum.PartType.Cylinder)
		newProp(model, "Nose", Vector3.new(1.15, 1.15, 1.15), CFrame.new(0, 1.75, 0), paper, Enum.PartType.Ball)
		newProp(model, "Band", Vector3.new(0.34, 1.24, 1.24), CFrame.new(0, 0.25, 0) * UPRIGHT, ink, Enum.PartType.Cylinder)
		for i, ang in ipairs({ 0, 120, 240 }) do
			local yaw = CFrame.Angles(0, math.rad(ang), 0)
			newProp(model, "Fin" .. i, Vector3.new(0.22, 1.0, 1.05), yaw * CFrame.new(0, -1.5, 0.62), ink)
		end
		return body
	end,

	GUN = function(model, color, ink, paper)
		local body = newProp(model, "Body", Vector3.new(1.7, 1.0, 0.78), CFrame.new(), color)
		newProp(model, "Barrel", Vector3.new(2.5, 0.46, 0.46), CFrame.new(1.75, 0.16, 0) * UPRIGHT * CFrame.Angles(0, 0, math.rad(90)), ink, Enum.PartType.Cylinder)
		newProp(model, "Muzzle", Vector3.new(0.4, 0.62, 0.62), CFrame.new(2.95, 0.16, 0) * CFrame.Angles(0, 0, math.rad(90)), paper, Enum.PartType.Cylinder)
		newProp(model, "Mag", Vector3.new(0.62, 1.2, 0.66), CFrame.new(-0.15, -1.0, 0), ink)
		newProp(model, "Grip", Vector3.new(0.55, 1.0, 0.6), CFrame.new(-0.85, -0.85, 0) * CFrame.Angles(0, 0, math.rad(14)), ink)
		return body
	end,

	MINE = function(model, color, ink, paper)
		local body = newProp(model, "Core", Vector3.new(2.5, 2.5, 2.5), CFrame.new(), color, Enum.PartType.Ball)
		newProp(model, "Band", Vector3.new(0.3, 2.62, 2.62), UPRIGHT, ink, Enum.PartType.Cylinder)
		local spikes = {
			CFrame.new(0, 1.55, 0),
			CFrame.new(0, -1.55, 0),
			CFrame.new(1.55, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
			CFrame.new(-1.55, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
			CFrame.new(0, 0, 1.55) * CFrame.Angles(math.rad(90), 0, 0),
			CFrame.new(0, 0, -1.55) * CFrame.Angles(math.rad(90), 0, 0),
		}
		for i, cf in ipairs(spikes) do
			newProp(model, "Spike" .. i, Vector3.new(1.0, 0.42, 0.42), cf * UPRIGHT, i == 1 and paper or ink, Enum.PartType.Cylinder)
		end
		return body
	end,

	FREEZE = function(model, color, ink, paper)
		-- A tapering stack, each slab yawed off the one below: chunky ice, not a cone.
		local body = newProp(model, "Base", Vector3.new(1.75, 1.5, 1.75), CFrame.new(0, -0.85, 0) * CFrame.Angles(0, math.rad(45), 0), color)
		newProp(model, "Mid", Vector3.new(1.3, 1.35, 1.3), CFrame.new(0, 0.35, 0) * CFrame.Angles(0, math.rad(18), 0), color:Lerp(paper, 0.35))
		newProp(model, "Tip", Vector3.new(0.72, 1.15, 0.72), CFrame.new(0, 1.5, 0) * CFrame.Angles(0, math.rad(52), 0), paper)
		newProp(model, "Shard", Vector3.new(0.5, 0.95, 0.5), CFrame.new(0.95, -0.35, 0.2) * CFrame.Angles(0, math.rad(30), math.rad(22)), color:Lerp(ink, 0.15))
		return body
	end,

	ZAP = function(model, color, ink, paper)
		-- Three slabs zig-zagged into a bolt; the middle one is the bright one.
		local body = newProp(model, "Top", Vector3.new(0.85, 1.5, 0.5), CFrame.new(0.42, 1.25, 0) * CFrame.Angles(0, 0, math.rad(26)), color)
		newProp(model, "Mid", Vector3.new(0.95, 1.7, 0.5), CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.rad(-30)), paper)
		newProp(model, "Bottom", Vector3.new(0.8, 1.5, 0.5), CFrame.new(-0.42, -1.25, 0) * CFrame.Angles(0, 0, math.rad(26)), color)
		newProp(model, "Spark", Vector3.new(0.55, 0.55, 0.55), CFrame.new(-0.85, -2.05, 0) * CFrame.Angles(0, 0, math.rad(45)), ink)
		return body
	end,

	SHIELD = function(model, color, ink, paper)
		-- Cylinder rolled onto Z so the disc FACES the viewport camera instead of edging it.
		local face = CFrame.Angles(0, math.rad(90), 0) * UPRIGHT
		local body = newProp(model, "Plate", Vector3.new(0.45, 3.0, 3.0), CFrame.new(0, 0, 0.16) * face, color, Enum.PartType.Cylinder)
		newProp(model, "Rim", Vector3.new(0.4, 3.45, 3.45), CFrame.new(0, 0, -0.1) * face, ink, Enum.PartType.Cylinder)
		newProp(model, "Boss", Vector3.new(1.0, 1.0, 1.0), CFrame.new(0, 0, 0.5), paper, Enum.PartType.Ball)
		newProp(model, "BarA", Vector3.new(0.34, 2.2, 0.34), CFrame.new(0, 0, 0.44) * CFrame.Angles(0, 0, math.rad(38)), paper)
		newProp(model, "BarB", Vector3.new(0.34, 2.2, 0.34), CFrame.new(0, 0, 0.44) * CFrame.Angles(0, 0, math.rad(-38)), paper)
		return body
	end,
}

--[[ Fallback for an id nobody has drawn yet: a plain chunky cube in the powerup's own
	colour. A new entry in Config.POWERUPS therefore shows up in the reel immediately and
	just looks generic, instead of erroring inside the render loop. ]]
local function buildFallback(model, color, ink, paper)
	local body = newProp(model, "Cube", Vector3.new(2.4, 2.4, 2.4), CFrame.Angles(0, math.rad(20), 0), color)
	newProp(model, "Cap", Vector3.new(2.5, 0.3, 2.5), CFrame.new(0, 1.2, 0) * CFrame.Angles(0, math.rad(20), 0), color:Lerp(paper, 0.35))
	newProp(model, "Base", Vector3.new(2.5, 0.3, 2.5), CFrame.new(0, -1.2, 0) * CFrame.Angles(0, math.rad(20), 0), color:Lerp(ink, 0.3))
	return body
end

--[[ Built ONCE and held in this table, unparented — a Lua reference is enough to keep
	them alive, and UIKit.viewport clones whatever it is handed. Rebuilding six models per
	tile per spin would be pure waste. ]]
local props: { [string]: Model } = {}

--[[ The real weapon, assembled from Assets.Weapons for the reel. The rig parts are
	authored standing on the origin, which is exactly the pose UIKit.viewport wants, so
	nothing is repositioned — this only strips the parts out of the source model and
	makes them safe to hold unparented. Returns nil for any id with no model. ]]
local function buildFromAsset(def)
	local source = WeaponRig.source(def.id)
	if not source then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = def.id
	for _, role in ipairs({ WeaponRig.BASE, WeaponRig.TURRET, WeaponRig.MUZZLE }) do
		local part = source:FindFirstChild(role)
		if part and part:IsA("BasePart") then
			local clone = part:Clone()
			clone.Anchored = true
			clone.CanCollide = false
			clone.CanQuery = false
			clone.CanTouch = false
			clone.CastShadow = false
			clone.Parent = model
			if role == WeaponRig.BASE then
				model.PrimaryPart = clone
			end
		end
	end
	if not model.PrimaryPart then
		model:Destroy()
		return nil
	end
	return model
end

local function buildProps(kit)
	for _, def in ipairs(PowerupDefs.list()) do
		local real = buildFromAsset(def)
		if real then
			props[def.id] = real
			continue
		end

		local model = Instance.new("Model")
		model.Name = def.id
		local builder = PROP_BUILDERS[def.id] or buildFallback
		local ok, body = pcall(builder, model, def.color, kit.INK, kit.PAPER)
		if not ok or not body then
			warn("LuckyUI: prop builder failed for " .. tostring(def.id) .. " — using a cube")
			model:ClearAllChildren()
			body = buildFallback(model, def.color, kit.INK, kit.PAPER)
		end
		model.PrimaryPart = body
		props[def.id] = model
	end
end

-- ==========================================================================
-- STATE
-- ==========================================================================

local card, window, strip, prizeLabel = nil, nil, nil, nil
local tiles: { { frame: Frame, scale: UIScale, viewport: ViewportFrame, ammo: TextLabel, ammoStroke: UIStroke } } = {}
local winnerSpin: RBXScriptConnection? = nil

local spin = {
	playing = false,
	token = 0, -- bumped per spin, so an old spin's hide never closes a newer card
	startedAt = 0,
	duration = 0,
	fromOffset = 0,
	toOffset = 0,
	lastTick = 0,
	lastTickAt = 0, -- os.clock() of the last click, enforcing TICK_MIN_GAP
	landIndex = 1,
	overshoot = 0, -- px the strip is thrown past the winner at the peak of the kick
	winner = nil,
}

local function stopWinnerSpin()
	if winnerSpin then
		winnerSpin:Disconnect()
		winnerSpin = nil
	end
end

-- ==========================================================================
-- BUILD
-- ==========================================================================

--[[ One slot: the 3D weapon over nothing, with its ammo count stamped across the bottom
	of the icon. No plate, no frame — the depth falloff is what separates the tiles. ]]
local function buildTile(kit, def, index: number)
	local tile = Instance.new("Frame")
	tile.Name = "Tile" .. index
	tile.Size = UDim2.fromOffset(TILE_W, TILE_H)
	tile.Position = UDim2.new(0.5, 0, 0, -(index - 1) * STEP)
	tile.AnchorPoint = Vector2.new(0.5, 0.5) -- centre-anchored so UIScale grows about the middle
	tile.BackgroundTransparency = 1
	tile.Active = false
	tile.Parent = strip

	local vp = kit.viewport({
		parent = tile,
		name = "Icon",
		model = props[def.id],
		size = UDim2.new(1, -ICON_INSET * 2, 1, -ICON_INSET * 2),
	})
	vp.ZIndex = 2

	local ammo = kit.label({
		parent = tile,
		name = "Ammo",
		text = "x" .. tostring(def.ammo or 1),
		size = UDim2.fromOffset(AMMO_W, AMMO_H),
		position = UDim2.new(0.5, 0, AMMO_Y, 0),
		cap = 20,
		stroke = 4,
	})
	ammo.ZIndex = 3

	table.insert(tiles, {
		frame = tile,
		scale = kit.ensureScale(tile),
		viewport = vp,
		ammo = ammo,
		ammoStroke = ammo:FindFirstChildOfClass("UIStroke"),
	})
end

local function build(kit)
	local gui = kit.screen("LuckySpin", UI.DISPLAY_ORDER.LUCKY)

	--[[ Named LuckyCard even though it is no longer a card: HudUI resolves
		PlayerGui.LuckySpin.LuckyCard and reads .Visible to keep its powerup slot quiet
		while the reel is paying off. Pinned contract — see the header. ]]
	card = Instance.new("Frame")
	card.Name = "LuckyCard"
	card.Size = UDim2.fromOffset(REEL_W, CARD_H)
	card.Position = UDim2.new(0.5, 0, 0, TOP_MARGIN)
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.BackgroundTransparency = 1
	card.Active = false
	card.Visible = false
	card.Parent = gui

	window = Instance.new("Frame")
	window.Name = "Reel"
	window.Size = UDim2.fromOffset(REEL_W, REEL_H)
	window.Position = UDim2.new(0.5, 0, 0, 0)
	window.AnchorPoint = Vector2.new(0.5, 0)
	window.BackgroundTransparency = 1
	window.ClipsDescendants = true -- the mask that makes a column of frames read as a reel
	window.Active = false
	window.Parent = card

	--[[ Zero-height on purpose: the strip is only a moving origin. Clipping is the
		window's job, so tiles positioned outside the strip's own rect still draw. ]]
	strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.Size = UDim2.fromOffset(TILE_W, 0)
	strip.Position = UDim2.new(0.5, 0, 0, offsetFor(1))
	strip.AnchorPoint = Vector2.new(0.5, 0)
	strip.BackgroundTransparency = 1
	strip.Active = false
	strip.Parent = window

	--[[ The marker is two dashes at the window's edges, not a line across it: a bar drawn
		over the winning weapon would obscure the one thing the player is waiting to read. ]]
	for _, side in ipairs({ { "PipLeft", 0, 0 }, { "PipRight", 1, 1 } }) do
		local pip = Instance.new("Frame")
		pip.Name = side[1]
		pip.Size = UDim2.fromOffset(PIP_W, PIP_H)
		pip.Position = UDim2.new(side[2], (side[2] == 0) and PIP_EDGE or -PIP_EDGE, 0.5, 0)
		pip.AnchorPoint = Vector2.new(side[3], 0.5)
		pip.BackgroundColor3 = kit.PAPER
		pip.BorderSizePixel = 0
		pip.ZIndex = 6
		pip.Active = false
		pip.Parent = window
		kit.corner(pip, 4)
		kit.stroke(pip, 2, kit.INK)
	end

	--[[ Hidden for the whole spin. The reference layout this matches has no text at all
		while the reel is moving; the name is the STAMP on landing, not reel chrome. ]]
	prizeLabel = kit.label({
		parent = card,
		name = "Prize",
		text = "",
		size = UDim2.new(1, 0, 0, PRIZE_H),
		position = UDim2.new(0.5, 0, 1, 0),
		anchor = Vector2.new(0.5, 1),
		cap = 19,
		stroke = 4,
	})
	prizeLabel.Visible = false
end

-- ==========================================================================
-- SPIN
-- ==========================================================================

--[[ Depth pass. Runs every frame while the reel is up, over every tile: distance from the
	marker sets scale, opacity and whether the tile is drawn at all. This is the only thing
	that makes the centre slot read as THE slot, so it also runs once on landing. ]]
local function applyDepth(offset: number)
	local centre = REEL_H * 0.5
	for index, tile in ipairs(tiles) do
		-- Tile centres sit at offset - (index-1)*STEP inside the window.
		local dy = math.abs((offset - (index - 1) * STEP) - centre)
		local steps = dy / STEP

		if steps > CULL_STEPS then
			if tile.frame.Visible then
				tile.frame.Visible = false
			end
		else
			tile.frame.Visible = true
			local t = math.clamp(steps / FADE_STEPS, 0, 1)
			tile.scale.Scale = MathUtil.lerp(TILE_SCALE.centre, TILE_SCALE.edge, t)
			local fade = MathUtil.lerp(TILE_FADE.centre, TILE_FADE.edge, t)
			tile.viewport.ImageTransparency = fade
			tile.ammo.TextTransparency = fade
			if tile.ammoStroke then
				tile.ammoStroke.Transparency = fade
			end
		end
	end
end

--[[ Strip offset at u (0..1 through the spin): the approach ease plus the end kick. A pure
	function of u, so a client that hitches still catches up to where the reel should be
	instead of drifting, and it returns exactly toOffset at u = 1. ]]
local function reelOffset(u: number): number
	local eased = 1 - (1 - u) ^ APPROACH_POWER
	local offset = MathUtil.lerp(spin.fromOffset, spin.toOffset, eased)

	if spin.overshoot > 0 and u > 1 - KICK_WINDOW then
		local s = (u - (1 - KICK_WINDOW)) / KICK_WINDOW
		local pulse
		if s < KICK_PEAK then
			local t = s / KICK_PEAK
			pulse = t * t * (3 - 2 * t) -- smoothstep out past the winner: blends in, no lurch
		else
			local t = (s - KICK_PEAK) / (1 - KICK_PEAK)
			pulse = (1 - t) ^ 2 -- and snapped back onto it, settling as it arrives
		end
		offset += spin.overshoot * pulse
	end

	return offset
end

local function land(kit)
	spin.playing = false
	strip.Position = UDim2.new(0.5, 0, 0, spin.toOffset) -- exact, never a frame's rounding off
	applyDepth(spin.toOffset)

	local def = PowerupDefs.get(spin.winner)
	if def then
		prizeLabel.Text = string.upper(def.name)
		prizeLabel.TextColor3 = def.color
		prizeLabel.Visible = true
		kit.popIn(prizeLabel, 1.45)
	end

	--[[ The punch, on the same beat the kick snaps the strip back onto the winner: it pops
		hard and then keeps turning on the spot, so the landing has a scale beat AND a
		motion beat. One viewport spinning, not sixteen. ]]
	local winnerTile = tiles[spin.landIndex]
	if winnerTile then
		kit.popIn(winnerTile.frame, 1.6)
		winnerTile.scale.Scale = TILE_SCALE.centre
		stopWinnerSpin()
		winnerSpin = kit.spinViewport(winnerTile.viewport, WINNER_SPIN_DPS)
	end

	kit.playSfx("REWARD") -- the payoff; HudUI keeps its powerup slot quiet for this beat

	local token = spin.token
	task.delay(LAND_HOLD, function()
		if spin.token ~= token or spin.playing then
			return -- a newer spin owns the reel now
		end
		stopWinnerSpin()
		kit.popOut(card)
	end)
end

local function stepReel(kit)
	if not spin.playing then
		return
	end

	--[[ Re-assert visibility every frame while spinning. A popOut from the PREVIOUS spin can
		still be in flight when a new reel starts — its Completed callback lives inside UIKit
		and cannot be cancelled from here — and if it fires it would hide a live card. One
		property read per frame makes that race structurally impossible to see. ]]
	if not card.Visible then
		card.Visible = true
	end

	local elapsed = Workspace:GetServerTimeNow() - spin.startedAt
	local u = math.clamp(elapsed / math.max(spin.duration, 0.01), 0, 1)
	local offset = reelOffset(u)
	strip.Position = UDim2.new(0.5, 0, 0, offset)
	applyDepth(offset)

	-- One tick per tile that crosses the marker, at most one per frame.
	local centred = centredIndex(offset)
	if centred ~= spin.lastTick then
		spin.lastTick = centred
		local now = os.clock()
		if now - spin.lastTickAt >= TICK_MIN_GAP then
			spin.lastTickAt = now
			kit.playSfx("TICK", TICK_VOLUME_SCALE)
		end
	end

	if u >= 1 then
		land(kit)
	end
end

--[[ Rejects a malformed payload rather than erroring inside the render loop. The client
	trusts the server about WHAT it won; it still checks the shape it was handed. ]]
local function payloadOk(payload): boolean
	if type(payload) ~= "table" then
		return false
	end
	if type(payload.reel) ~= "table" or #payload.reel == 0 then
		return false
	end
	local landIndex = payload.landIndex
	if type(landIndex) ~= "number" or landIndex < 1 or landIndex > #payload.reel then
		return false
	end
	if type(payload.startedAt) ~= "number" or type(payload.duration) ~= "number" or payload.duration <= 0 then
		return false
	end
	if not PowerupDefs.exists(payload.winner) then
		return false
	end
	return PowerupDefs.exists(payload.reel[landIndex])
end

local function onSpin(kit, payload)
	if not payloadOk(payload) then
		warn("LuckyUI: ignoring malformed LuckySpin payload")
		return
	end

	spin.token += 1
	spin.playing = false -- stop the loop while the strip is rebuilt under it
	stopWinnerSpin()

	strip:ClearAllChildren()
	table.clear(tiles)
	for index, id in ipairs(payload.reel) do
		local def = PowerupDefs.get(id)
		if def then
			buildTile(kit, def, index)
		end
	end

	spin.startedAt = payload.startedAt
	spin.duration = payload.duration
	spin.winner = payload.winner
	spin.landIndex = payload.landIndex
	spin.fromOffset = offsetFor(1)
	spin.toOffset = offsetFor(payload.landIndex)
	--[[ No tile past the winner means nothing to throw the strip INTO, so the kick is dropped
		and the reel lands flat. Config.LUCKY.REEL_TAIL (2) means that never happens in
		practice — this is here so a hand-built payload can never expose the end of the strip. ]]
	spin.overshoot = (payload.landIndex < #tiles) and (OVERSHOOT_STEPS * STEP) or 0
	spin.lastTick = 0
	spin.lastTickAt = 0

	strip.Position = UDim2.new(0.5, 0, 0, spin.fromOffset)
	applyDepth(spin.fromOffset)
	prizeLabel.Visible = false

	kit.popIn(card)
	spin.playing = true
end

-- ==========================================================================
-- INIT
-- ==========================================================================

function LuckyUI.init(ctx)
	local kit = ctx.kit
	buildProps(kit)
	build(kit)

	--[[ Studio only: press Config.TEST.LUCKY_KEY to play a template reel on demand, so the
		roller can be tuned without hunting for a block inside a 40-second test match. Bound
		BEFORE the remote check on purpose — a missing remote is exactly when you want this.
		Draw only: it never grants a weapon, because only the server can do that. ]]
	if RunService:IsStudio() and type(Config.TEST.LUCKY_KEY) == "string" then
		local okKey, keyCode = pcall(function()
			return Enum.KeyCode[Config.TEST.LUCKY_KEY]
		end)
		if okKey and typeof(keyCode) == "EnumItem" then
			game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
				if processed or input.KeyCode ~= keyCode then
					return
				end
				local defs = PowerupDefs.list()
				if #defs == 0 then
					return
				end
				-- Every weapon in order so the template reel shows the whole set.
				local reel = {}
				for i = 1, 16 do
					table.insert(reel, defs[(i - 1) % #defs + 1].id)
				end
				local landIndex = #reel - 2
				onSpin(kit, {
					reel = reel,
					winner = reel[landIndex],
					landIndex = landIndex,
					startedAt = Workspace:GetServerTimeNow(),
					duration = Config.LUCKY.SPIN_SECONDS,
				})
			end)
		else
			warn("LuckyUI: Config.TEST.LUCKY_KEY '" .. tostring(Config.TEST.LUCKY_KEY) .. "' is not a KeyCode name")
		end
	end

	local spinRemote = ctx.net.LuckySpin
	if not spinRemote then
		warn("LuckyUI: LuckySpin remote missing — no reel will ever play")
		return
	end

	spinRemote.OnClientEvent:Connect(function(payload)
		onSpin(kit, payload)
	end)

	-- ONE loop, early-out when idle: cheaper than reconnecting per spin and it cannot leak.
	RunService.RenderStepped:Connect(function()
		stepReel(kit)
	end)
end

return LuckyUI
