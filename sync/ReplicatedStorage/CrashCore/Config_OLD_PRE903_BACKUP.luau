--[[ Config
	Single source of truth for every tunable in the game. No magic numbers in logic.

	Read by: every server service and client controller.
	Sections:
		ATTR       attribute key names (replicated state contract)
		DATA       DataStore identity + retry policy
		MATCH      round state machine timings
		CHASSIS    arcade vehicle handling baseline
		RAM        body-slam combat math
		ARENA      procedural arena dimensions and features
		CARS       car roster (stats + procedural build recipe + signature powerup)
		POWERUPS   weapon definitions
		PICKUPS    crown / coin / crate spawning
		ECONOMY    payout rates
		UI         palette, fonts, motion (mirrors house DNA)
		PRODUCTS   monetization seams (unpopulated until publish)
		TEST       Studio-only overrides, applied ONLY behind RunService:IsStudio()
]]

local Config = {}

-- Boot diagnostics. Studio-only by default so no print() ever ships to players,
-- while a verifier can still read a clean startup out of the playtest log.
Config.VERBOSE_BOOT = game:GetService("RunService"):IsStudio()

-- ==========================================================================
-- ATTR — replicated state contract. Server SetAttribute, client GetAttributeChangedSignal.
-- ==========================================================================
Config.ATTR = {
	-- on Player
	CROWNS = "Crowns", -- crowns held this round (dropped on death)
	LIVES = "Lives", -- lives left this round
	KILLS = "Kills", -- kills this round
	ALIVE = "Alive", -- boolean: car currently spawned
	POWERUP = "PowerupSlot", -- powerup id held, "" when empty
	POWERUP_AMMO = "PowerupAmmo", -- shots left in slot
	SHIELDED = "Shielded", -- boolean: shield powerup active
	FROZEN = "Frozen", -- boolean: freeze debuff active
	COINS = "Coins", -- persistent soft currency
	GEMS = "Gems", -- persistent hard currency
	EQUIPPED = "EquippedCar", -- car id
	OWNED = "OwnedCars", -- JSON array of car ids
	BEST_CROWNS = "BestCrowns", -- persistent record
	TOTAL_KILLS = "TotalKills", -- persistent lifetime kills
	PROFILE_LOADED = "ProfileLoaded", -- boolean: safe to read/write currency

	-- on ReplicatedStorage.CrashCore (global match state)
	PHASE = "Phase", -- "Lobby" | "Match" | "Results"
	PHASE_ENDS = "PhaseEndsAt", -- workspace:GetServerTimeNow() deadline
	ROUND_ID = "RoundId", -- increments each match
	ALIVE_COUNT = "AliveCount", -- players with a car right now
}

-- ==========================================================================
-- DATA
-- ==========================================================================
Config.DATA = {
	STORE_NAME = "CrashCars_Profiles_v1",
	KEY_PREFIX = "p_",
	RETRY_ATTEMPTS = 5,
	RETRY_BASE_DELAY = 0.2, -- doubles each attempt
	AUTOSAVE_SECONDS = 120,
	RECEIPT_RING_SIZE = 100,
}

-- ==========================================================================
-- MATCH
-- ==========================================================================
Config.MATCH = {
	LOBBY_SECONDS = 30,
	MATCH_SECONDS = 180,
	RESULTS_SECONDS = 10,
	MIN_PLAYERS = 2,
	LIVES = 3,
	RESPAWN_DELAY = 2.0, -- seconds of death screen before respawn is allowed
	SPAWN_PROTECT = 2.0, -- invulnerable seconds after spawning
	CROWN_DROP_FRACTION = 0.5, -- fraction of your crowns the killer steals
	CROWN_SCATTER_FRACTION = 0.5, -- the rest scatter as pickups
}

-- ==========================================================================
-- CHASSIS — baseline handling. Per-car stats multiply these.
-- ==========================================================================
Config.CHASSIS = {
	HULL_SIZE = Vector3.new(6, 2.4, 11), -- default; cars override
	HOVER_HEIGHT = 2.2, -- studs from hull center to ground
	RAY_LENGTH = 6.0, -- ground probe distance
	GROUND_SPRING = 90, -- stiffness pulling to hover height
	GROUND_DAMPER = 18, -- zeta 0.95 against GROUND_SPRING 90. Was 12 (zeta 0.63) = visible bob.

	TOP_SPEED = 90, -- studs/s at stat 1.0
	REVERSE_FRACTION = 0.45,
	ACCEL = 70, -- studs/s^2 at stat 1.0
	BRAKE = 130,
	COAST_DRAG = 22, -- deceleration with no throttle
	TURN_RATE = 100, -- deg/s at stat 1.0, full grip (~51 stud radius at top speed)
	TURN_SPEED_FLOOR = 0.45, -- steering authority fraction at a standstill
	-- Grip is an exponential decay RATE on lateral velocity, so time constant = 1/GRIP.
	-- 14 meant 0.07s: lateral died almost instantly and the car was on rails.
	-- Solved for a target slip angle rather than guessed: equilibrium lateral is roughly
	-- (topSpeed * sin(turnRate * boost * dt)) / (1 - exp(-grip * dt)).
	-- These give ~15 deg slip in a normal corner and ~36 deg while drifting — a clear
	-- contrast you can feel, without the car ending up travelling sideways.
	GRIP = 13, -- lateral velocity cancellation strength (tighter default = crisper)
	DRIFT_GRIP = 4, -- lateral grip while drifting (looser = bigger slide)
	-- The mechanic that MAKES it read as drift rather than understeer: while drifting the
	-- car rotates faster than it travels, so the nose swings into the corner while
	-- momentum carries the body wide. Lower grip alone only produces a wide, mushy slide.
	DRIFT_TURN_BOOST = 1.3, -- yaw-rate multiplier while the drift button is held
	-- Slip angle injected INSTANTLY on the frame drift is pressed. Without it the slide
	-- has to build through the grip time constant: measured 583ms to reach 90% of a 23deg
	-- slide, and only 6.9deg after 100ms — far too slow to read as a response to a button.
	-- This snaps most of the slide out immediately, then yaw + grip sustain it.
	DRIFT_ENTRY_KICK_DEG = 14,
	-- Drift reward (mini-turbo). Charge accrues at driftAmount per second while grounded
	-- AND actually sliding, then pays out through the existing pad-boost path, so there is
	-- no second speed system to keep in sync. Tiers differ in DURATION only.
	DRIFT_CHARGE_MIN_AMOUNT = 0.35, -- the tail-loose point; nothing charges below it
	DRIFT_CHARGE_TIER1 = 0.75, -- ~0.77s of full-lock slide
	DRIFT_CHARGE_TIER2 = 1.60, -- ~1.65s; a sweeping corner or a donut
	DRIFT_RELEASE_GRACE = 0.18, -- survives a mid-corner counter-steer correction
	DRIFT_BOOST_FRACTION = { 0.30, 0.60 }, -- x BOOST_SECONDS -> 0.48s / 0.96s
	DRIFT_BOOST_SHAKE = { 0.22, 0.38 },
	DRIFT_BOOST_SHAKE_TIME = 0.18,
	DRIFT_AIR_HOLD_SECONDS = 1.2, -- charge survives this long airborne, pays on landing
	-- Cosmetic wheels.
	WHEEL_STEER_RATE = 12, -- deliberately trails the input's own smoothing rate of 22
	WHEEL_SLIP_RATE = 9,
	WHEEL_SPINUP_EXTRA = 0.6, -- overspin while the throttle is winning
	WHEEL_LOCK_SLIP = 0.15, -- lock-up under braking
	-- Flip unstick. Geometry, not torque, is the only thing that can pin a car: Steer
	-- commands upright every frame and MaxTorque is inertia-scaled with 4x headroom.
	FLIP_UP_DOT = 0.35,
	FLIP_STUCK_SPEED = 8, -- ramp air always carries speed, so barrel rolls never trip this
	FLIP_STUCK_SECONDS = 1.2,
	FLIP_HOP_SPEED = 30,
	FLIP_HOP_COOLDOWN = 1.5,
	-- Drift is INTRINSIC to cornering, not a button. driftAmount = speedTerm * steerTerm,
	-- where each term ramps 0->1 from the minimum below up to full. Below these the car
	-- stays planted and crisp; above them grip collapses and the back steps out by itself.
	-- LOWER these to make the car looser more of the time.
	DRIFT_AUTO_SPEED_MIN = 0.35, -- speed fraction where automatic drift starts
	DRIFT_AUTO_STEER_MIN = 0.45, -- steer magnitude where automatic drift starts
	AIR_CONTROL = 0.25, -- steering authority multiplier while airborne
	UPRIGHT_TORQUE = 12000,
	UPRIGHT_POWER = 4000,
	MAX_SLOPE_COS = 0.35, -- surfaces steeper than this are not "ground"
	-- Ceiling on TOTAL planar speed, as a multiple of the car's current top speed.
	-- Rotating the car turns forward velocity into lateral, but the throttle then tops
	-- forward back up every frame while lateral decays only slowly — so with no cap the
	-- two accumulate and the car ends up sliding far faster than it can drive. Scaling
	-- both components preserves the slip ANGLE while making a slide COST speed, which
	-- is what drifting should feel like.
	MAX_PLANAR_OVERSPEED = 1.05,

	BOOST_MULTIPLIER = 1.6,
	BOOST_ACCEL_MULTIPLIER = 2.2,
	BOOST_SECONDS = 1.6, -- from a boost pad
	FROZEN_SPEED_MULTIPLIER = 0.15,
	FROZEN_SECONDS = 2.0,

	FALL_KILL_Y = -60, -- below this, you die (pits)
	STATE_SEND_HZ = 12, -- client -> server position heartbeat for validation
}

-- ==========================================================================
-- CAMERA — the chase camera's feel knobs. It had no Config section before.
-- ==========================================================================
Config.CAMERA = {
	-- getSpeedFraction() is clamp01'd, so a 1.6x boost left the camera unchanged at
	-- flat out. This overlay is applied AFTER the damp: damping a 6 degree kick would
	-- smear it across most of a second and a 0.48s mini-turbo would expire first.
	FOV_BOOST_EXTRA = 6,
	BOOST_PULL_EXTRA = 3, -- studs further back while boosting
	BOOST_BLEND_RATE = 9,
	OCCLUSION_RETURN_RATE = 4, -- instant pull-in at a wall, eased return when it clears
}

-- ==========================================================================
-- RAM — body-slam combat. The core kill verb.
-- ==========================================================================
Config.RAM = {
	MIN_CLOSING_SPEED = 28, -- below this a touch does nothing
	-- Retuned after CombatService measured the originals: a Mini Tank rear-ending a
	-- Rocket Car at a routine 60 closing speed dealt 168 dmg into 85 hp (a one-shot),
	-- and every full-speed head-on traded mutual instant kills. Mistakes must be
	-- survivable for a kids' audience, and weight class should tilt a fight, not decide it.
	DAMAGE_PER_SPEED = 0.55, -- damage = closingSpeed * this * massRatio
	MASS_RATIO_CLAMP = 1.6, -- caps heavy-car advantage
	-- Was 55, which produced up to 259 studs/s of knock against a 90 top speed —
	-- enough to hurl a car clean over the 26-stud arena wall.
	KNOCKBACK = 34, -- impulse scale applied to the loser
	KNOCKBACK_LIFT = 0.35, -- upward fraction of the knockback
	SELF_DAMAGE_FRACTION = 0.25, -- the rammer takes some too
	COOLDOWN = 0.6, -- per attacker/victim pair
	FRONT_BONUS = 1.5, -- multiplier when hit lands in the victim's rear arc
	FRONT_ARC_COS = 0.25, -- dot threshold defining that arc
	-- After a hit the victim's own client must STOP commanding velocity for this long,
	-- otherwise its LinearVelocity erases the knockback impulse within ~0.1s and rams feel dead.
	STAGGER_SECONDS = 0.35,
	-- If a victim dies environmentally (pit) within this long after being hit, the
	-- last attacker still gets the kill and the crown steal. Without it, shoving
	-- someone into a pit — the most satisfying play available — pays nothing.
	KILL_CREDIT_SECONDS = 6,
	-- Knockback below this does NOT stamp StaggerUntil and does NOT borrow network
	-- ownership. Without the gate, machine-gun fire (knockback 4, one shot every
	-- 0.09s) re-stamped the window every bullet and held the victim undriveable for
	-- the whole ~2.2s burst. Chosen at 12 because it sits clear below the weakest
	-- possible shove that SHOULD move you: weakest ram 21.25, edge-of-blast rocket
	-- ~21, edge-of-blast mine ~27. Bullets chip health; they do not throw cars.
	MIN_KNOCK_TO_STAGGER = 12,
}

-- ==========================================================================
-- ARENA
-- ==========================================================================
Config.ARENA = {
	ORIGIN = Vector3.new(0, 0, 0),
	SIZE = 420, -- square floor, studs
	FLOOR_THICKNESS = 4,
	WALL_HEIGHT = 26,
	WALL_THICKNESS = 6,
	FLOOR_COLOR = Color3.fromRGB(78, 84, 96),
	FLOOR_ACCENT = Color3.fromRGB(96, 104, 120),
	WALL_COLOR = Color3.fromRGB(44, 46, 56),
	TILE_STUDS = 60, -- checker tile size for the floor pattern

	SPAWN_COUNT = 16,
	SPAWN_RING_RADIUS = 155,
	SPAWN_HEIGHT = 5,

	-- Ramps: {position (XZ offset from origin), size, rotationY degrees, tiltDegrees}
	RAMPS = {
		{ offset = Vector2.new(0, 90), size = Vector3.new(46, 3, 34), rotY = 0, tilt = 16 },
		{ offset = Vector2.new(0, -90), size = Vector3.new(46, 3, 34), rotY = 180, tilt = 16 },
		{ offset = Vector2.new(90, 0), size = Vector3.new(46, 3, 34), rotY = 90, tilt = 16 },
		{ offset = Vector2.new(-90, 0), size = Vector3.new(46, 3, 34), rotY = -90, tilt = 16 },
	},

	-- Boost pads: {offset, size, rotationY}
	PADS = {
		{ offset = Vector2.new(60, 60), rotY = 45 },
		{ offset = Vector2.new(-60, 60), rotY = -45 },
		{ offset = Vector2.new(60, -60), rotY = 135 },
		{ offset = Vector2.new(-60, -60), rotY = -135 },
		{ offset = Vector2.new(0, 0), rotY = 0 },
	},
	PAD_SIZE = Vector3.new(18, 0.6, 26),
	PAD_COLOR = Color3.fromRGB(255, 221, 51),

	-- Pits: holes in the floor that kill. {offset, size (XZ)}
	PITS = {
		{ offset = Vector2.new(120, 120), size = Vector2.new(46, 46) },
		{ offset = Vector2.new(-120, -120), size = Vector2.new(46, 46) },
	},
	PIT_DEPTH = 120,

	-- Obstacle blocks (cover + ram targets)
	BLOCKS = {
		{ offset = Vector2.new(150, -40), size = Vector3.new(16, 14, 40) },
		{ offset = Vector2.new(-150, 40), size = Vector3.new(16, 14, 40) },
		{ offset = Vector2.new(40, 150), size = Vector3.new(40, 14, 16) },
		{ offset = Vector2.new(-40, -150), size = Vector3.new(40, 14, 16) },
	},
	BLOCK_COLOR = Color3.fromRGB(120, 96, 72),
}

-- ==========================================================================
-- CARS — roster. `stats` are multipliers on Config.CHASSIS.
-- `build` is the procedural recipe CarFactory turns into a model (no art assets needed).
-- `special` is the powerup this car pulls more often from crates.
-- ==========================================================================
Config.CARS = {
	{
		id = "rustbucket",
		name = "Rustbucket",
		rarity = "COMMON",
		price = 0,
		currency = "Coins",
		starter = true,
		stats = { topSpeed = 1.0, accel = 1.0, turn = 1.0, mass = 1.0, hp = 100 },
		special = "GUN",
		build = {
			body = Vector3.new(6, 2.2, 11),
			bodyColor = Color3.fromRGB(150, 108, 74),
			roof = Vector3.new(5.2, 2.0, 5),
			roofColor = Color3.fromRGB(128, 90, 60),
			accent = Color3.fromRGB(220, 210, 190),
			wheelRadius = 1.6,
			wheelWidth = 1.2,
		},
	},
	{
		id = "taxi",
		name = "Taxi",
		rarity = "COMMON",
		price = 500,
		currency = "Coins",
		stats = { topSpeed = 1.1, accel = 1.05, turn = 0.95, mass = 1.05, hp = 105 },
		special = "MINE",
		build = {
			body = Vector3.new(6.2, 2.3, 12),
			bodyColor = Color3.fromRGB(255, 196, 40),
			roof = Vector3.new(5.4, 2.1, 5.4),
			roofColor = Color3.fromRGB(245, 178, 24),
			accent = Color3.fromRGB(30, 30, 30),
			wheelRadius = 1.6,
			wheelWidth = 1.2,
		},
	},
	{
		id = "icecream",
		name = "Ice Cream Van",
		rarity = "UNCOMMON",
		price = 1500,
		currency = "Coins",
		stats = { topSpeed = 0.9, accel = 0.9, turn = 0.85, mass = 1.35, hp = 130 },
		special = "FREEZE",
		build = {
			body = Vector3.new(6.6, 3.4, 12.5),
			bodyColor = Color3.fromRGB(245, 245, 250),
			roof = Vector3.new(6.0, 2.6, 8),
			roofColor = Color3.fromRGB(120, 220, 255),
			accent = Color3.fromRGB(255, 130, 190),
			wheelRadius = 1.7,
			wheelWidth = 1.3,
		},
	},
	{
		id = "police",
		name = "Police Car",
		rarity = "UNCOMMON",
		price = 3000,
		currency = "Coins",
		stats = { topSpeed = 1.2, accel = 1.2, turn = 1.1, mass = 1.1, hp = 110 },
		special = "GUN",
		build = {
			body = Vector3.new(6.2, 2.2, 12.5),
			bodyColor = Color3.fromRGB(240, 240, 245),
			roof = Vector3.new(5.4, 2.0, 5.2),
			roofColor = Color3.fromRGB(30, 40, 70),
			accent = Color3.fromRGB(46, 158, 255),
			wheelRadius = 1.6,
			wheelWidth = 1.25,
			siren = true,
		},
	},
	{
		id = "monster",
		name = "Monster Truck",
		rarity = "RARE",
		price = 7500,
		currency = "Coins",
		stats = { topSpeed = 1.0, accel = 0.95, turn = 0.9, mass = 1.7, hp = 160 },
		special = "ZAP",
		build = {
			body = Vector3.new(7, 3, 12),
			bodyColor = Color3.fromRGB(64, 196, 96),
			roof = Vector3.new(5.6, 2.4, 5.6),
			roofColor = Color3.fromRGB(40, 150, 70),
			accent = Color3.fromRGB(255, 182, 24),
			wheelRadius = 2.8,
			wheelWidth = 2.0,
			lift = 1.6,
		},
	},
	{
		id = "minitank",
		name = "Mini Tank",
		rarity = "EPIC",
		price = 15000,
		currency = "Coins",
		stats = { topSpeed = 0.85, accel = 0.85, turn = 0.8, mass = 2.2, hp = 200 },
		special = "ROCKET",
		build = {
			body = Vector3.new(7.4, 2.6, 12.5),
			bodyColor = Color3.fromRGB(96, 104, 72),
			roof = Vector3.new(5, 2.2, 5),
			roofColor = Color3.fromRGB(78, 86, 58),
			accent = Color3.fromRGB(50, 54, 40),
			wheelRadius = 1.5,
			wheelWidth = 2.4,
			barrel = true,
		},
	},
	{
		id = "rocketcar",
		name = "Rocket Car",
		rarity = "EPIC",
		price = 60,
		currency = "Gems",
		stats = { topSpeed = 1.45, accel = 1.5, turn = 1.05, mass = 0.85, hp = 85 },
		special = "ROCKET",
		build = {
			body = Vector3.new(5.4, 1.8, 13),
			bodyColor = Color3.fromRGB(255, 80, 70),
			roof = Vector3.new(3.6, 1.4, 4),
			roofColor = Color3.fromRGB(30, 30, 36),
			accent = Color3.fromRGB(255, 221, 51),
			wheelRadius = 1.5,
			wheelWidth = 1.4,
			fins = true,
		},
	},
	{
		id = "ufo",
		name = "UFO",
		rarity = "LEGENDARY",
		price = 150,
		currency = "Gems",
		stats = { topSpeed = 1.25, accel = 1.3, turn = 1.15, mass = 0.9, hp = 95 },
		special = "ZAP",
		build = {
			body = Vector3.new(11, 1.6, 11),
			bodyColor = Color3.fromRGB(196, 78, 255),
			roof = Vector3.new(5, 3, 5),
			roofColor = Color3.fromRGB(120, 255, 240),
			accent = Color3.fromRGB(255, 255, 255),
			wheelRadius = 0.9,
			wheelWidth = 0.9,
			hover = true,
			saucer = true,
		},
	},
}

Config.STARTER_CAR = "rustbucket"

-- ==========================================================================
-- POWERUPS — one slot at a time, like the original.
-- kind: "projectile" | "place" | "hitscan" | "aoe" | "self"
-- ==========================================================================
Config.POWERUPS = {
	ROCKET = {
		id = "ROCKET",
		name = "Rocket",
		kind = "projectile",
		ammo = 1,
		cooldown = 0.6,
		damage = 55,
		speed = 220,
		life = 3.0,
		blastRadius = 16,
		knockback = 70,
		size = Vector3.new(1.2, 1.2, 4),
		color = Color3.fromRGB(255, 80, 70),
		weight = 22, -- crate roll weight
	},
	GUN = {
		id = "GUN",
		name = "Machine Gun",
		kind = "hitscan",
		ammo = 24,
		cooldown = 0.09,
		damage = 6,
		range = 220,
		spread = 1.6, -- degrees
		knockback = 4,
		color = Color3.fromRGB(255, 221, 51),
		weight = 26,
	},
	MINE = {
		id = "MINE",
		name = "Mine",
		kind = "place",
		ammo = 2,
		cooldown = 0.5,
		damage = 65,
		armTime = 0.8,
		life = 22,
		triggerRadius = 7,
		blastRadius = 14,
		knockback = 90,
		dropBehind = 9, -- studs behind the car
		color = Color3.fromRGB(255, 120, 40),
		weight = 20,
	},
	FREEZE = {
		id = "FREEZE",
		name = "Freeze Ray",
		kind = "projectile",
		ammo = 1,
		cooldown = 0.6,
		damage = 10,
		speed = 160,
		life = 2.5,
		blastRadius = 14,
		freezeSeconds = 2.0,
		size = Vector3.new(2, 2, 2),
		color = Color3.fromRGB(120, 220, 255),
		weight = 14,
	},
	ZAP = {
		id = "ZAP",
		name = "Zap",
		kind = "aoe",
		ammo = 1,
		cooldown = 0.8,
		damage = 40,
		radius = 46,
		maxTargets = 3,
		knockback = 45,
		color = Color3.fromRGB(196, 78, 255),
		weight = 10,
	},
	SHIELD = {
		id = "SHIELD",
		name = "Shield",
		kind = "self",
		ammo = 1,
		cooldown = 0.5,
		duration = 6.0,
		color = Color3.fromRGB(126, 217, 87),
		weight = 8,
	},
}

Config.SPECIAL_WEIGHT_BONUS = 40 -- added to a car's signature powerup weight in crate rolls

-- ==========================================================================
-- LUCKY BLOCKS — drive through one, a reel spins, you get a weapon.
-- Rarer and much further apart than crates: a lucky block is a destination you
-- steer for, not litter you sweep up. The roll itself is PowerupDefs.roll, the
-- SAME call crates use, so lucky blocks add theatre and a reason to cross the
-- arena without quietly changing weapon balance.
-- ==========================================================================
Config.LUCKY = {
	MAX_ACTIVE = 5,
	SPAWN_INTERVAL = 5.0, -- seconds between top-up attempts
	RESPAWN_DELAY = 12, -- a taken block holds its slot this long, so the field genuinely thins
	SPAWN_INSET = 40, -- keep blocks this far from the walls
	MIN_SEPARATION = 55, -- XZ spacing, far wider than crates so each block is its own detour
	FLOAT_HEIGHT = 4.6, -- ground to block centre, before bobbing
	BLOCK_SIZE = 5.4,
	TRIGGER_RADIUS = 7.5, -- collection ball; wider than the cube so a car at top speed cannot tunnel
	BOB_HEIGHT = 0.9,
	BOB_SPEED = 1.3,
	SPIN_SPEED = 60, -- degrees/s of idle yaw
	ANIM_HZ = 20, -- idle animation rate; server-driven motion replicates, so it is capped
	ANIM_RADIUS = 300, -- skip animating blocks with no car within this many studs
	MARK_HEIGHT = 5.2, -- the "?" billboard, studs above block centre
	MARK_DISTANCE = 250,
	COLOR = Color3.fromRGB(255, 205, 110),
	ACCENT = Color3.fromRGB(255, 243, 194),
	FX_RADIUS = 6,

	-- The reveal. Server rolls the winner on touch and hands the powerup over when
	-- the reel lands, so the HUD slot fills on exactly the beat the reel stops.
	SPIN_SECONDS = 2.4,
	REEL_TILES = 16, -- tiles scrolled past before the winner
	REEL_TAIL = 2, -- tiles AFTER the winner, so the strip never runs out mid-settle
	BUSY_TAIL = 1.8, -- extra ineligible seconds after a reel lands; must outlive LuckyUI's land hold
}

-- ==========================================================================
-- WEAPONS — firing discipline and blast shaping. Server-enforced.
-- ==========================================================================
Config.WEAPONS = {
	MAX_LIVE_PROJECTILES = 60, -- hard cap; past it a shot is refused and the ammo is KEPT
	COOLDOWN_TOLERANCE = 0.9, -- fraction of the real cooldown accepted, absorbs client jitter
	HARD_MIN_FIRE_GAP = 0.05, -- floor beneath every cooldown, so no client can outrun the rate
	AIM_MAX_YAW_DEG = 75, -- client aim is a hint; it is clamped into this forward cone
	BLAST_EDGE_FRACTION = 0.30, -- explosion damage at blastRadius, tapering from 1.0 at centre
}

-- ==========================================================================
-- PICKUPS
-- ==========================================================================
Config.PICKUPS = {
	CROWN = {
		value = 1,
		maxActive = 22,
		spawnInterval = 1.2,
		radius = 6,
		bobHeight = 1.2,
		bobSpeed = 2.4,
		spinSpeed = 90,
		color = Color3.fromRGB(255, 205, 110),
		respawnDelay = 0,
	},
	COIN = {
		value = 12,
		maxActive = 14,
		spawnInterval = 2.5,
		radius = 5.5,
		bobHeight = 0.7,
		bobSpeed = 3.0,
		spinSpeed = 170,
		color = Color3.fromRGB(255, 243, 194),
	},
	CRATE = {
		maxActive = 10,
		spawnInterval = 3.0,
		radius = 7,
		respawnDelay = 6,
		bobHeight = 0.5,
		bobSpeed = 1.6,
		spinSpeed = 45,
		color = Color3.fromRGB(46, 158, 255),
	},
	SPAWN_INSET = 30, -- keep pickups this far from the walls
	MIN_SEPARATION = 14,
	FLOAT_HEIGHT = 3.0, -- studs from ground to pickup centre, before bobbing
	-- Idle bob/spin is server-driven, so it replicates. These bound that cost on mobile.
	ANIM_HZ = 20, -- idle animation update rate (not the render rate)
	ANIM_RADIUS = 260, -- skip animating pickups with no player car within this many studs
}

-- ==========================================================================
-- ECONOMY
-- ==========================================================================
Config.ECONOMY = {
	COINS_PER_CROWN = 6,
	COINS_PER_KILL = 25,
	COINS_PER_PLACEMENT = { 300, 180, 120, 80 }, -- 1st..4th
	COINS_PARTICIPATION = 40,
	GEM_DROP_CHANCE = 0.05, -- per crown banked
	GEM_DROP_AMOUNT = 1,
}

-- ==========================================================================
-- UI — mirrors the house visual DNA. UIKit reads these.
-- ==========================================================================
Config.UI = {
	INK = Color3.fromRGB(15, 15, 15),
	PAPER = Color3.fromRGB(255, 255, 255),
	GLASS = Color3.fromRGB(26, 22, 32),
	GOLD_LIGHT = Color3.fromRGB(255, 243, 194),
	GOLD = Color3.fromRGB(255, 205, 110),
	GOLD_DEEP = Color3.fromRGB(255, 170, 60),
	LIME = Color3.fromRGB(212, 251, 121),
	GREEN = Color3.fromRGB(0, 249, 0),
	CONFIRM = Color3.fromRGB(126, 217, 87),
	DANGER = Color3.fromRGB(255, 80, 70),
	RARITY = {
		COMMON = Color3.fromRGB(205, 212, 222),
		UNCOMMON = Color3.fromRGB(58, 224, 104),
		RARE = Color3.fromRGB(46, 158, 255),
		EPIC = Color3.fromRGB(196, 78, 255),
		LEGENDARY = Color3.fromRGB(255, 182, 24),
	},
	POP_IN = { time = 0.32, from = 0.7 },
	POP_OUT = { time = 0.12, to = 0.75 },
	HOVER_SCALE = 1.07,
	PRESS_SCALE = 0.92,
	HOVER_TIME = 0.12,
	PRESS_TIME = 0.06,
	NOTIF_LIFETIME = 4,
	NOTIF_MAX = 5,
	CARD_CORNER = 12,
	BUTTON_CORNER = 10,
	STROKE = 2.5,
	DISPLAY_ORDER = { HUD = 5, LOBBY = 6, LUCKY = 12, DEATH = 20, RESULTS = 30, GARAGE = 40, NOTIF = 10000 },
}

-- ==========================================================================
-- PRODUCTS / PASSES — monetization seams. Fill IDs at publish time.
-- TODO(monetization): populate ids, then MonetizationService reads these.
-- ==========================================================================
--[[ MONETIZATION.

	EVERY id below is 0 = PLACEHOLDER. Create the product/pass in the Creator Hub, paste the
	id here, and it goes live — nothing else changes. MonetizationService SKIPS any entry whose
	id is 0, so an unfilled catalog is inert rather than broken and the shop just omits it.

	Honest-design rules this catalog follows on purpose, because the audience is kids:
	  * No lying. The LIMITED countdown is derived from the same clock that actually rotates
	    the offer, so it cannot claim urgency that isn't real. No "only 2 left!" theatre.
	  * Gacha odds shown are the odds rolled — Config.LUCKY / CARS rarity weights are the one
	    source, so display can never drift from behaviour.
	  * Nothing here is needed to play or to win a round. Boosts affect EARN RATE, never
	    lives, damage or in-match car stats.
	  * FAIRNESS FLAG: there is deliberately NO crown multiplier. Crowns are the competitive
	    score and selling score makes the leaderboard pay-to-win. Coins are progression and
	    are safe to multiply. Please do not "complete the set" by adding one.
]]
Config.MONETIZATION = {
	VIP_COIN_MULTIPLIER = 1.5,
	DOUBLE_COIN_MULTIPLIER = 2,
	PREMIUM_COIN_MULTIPLIER = 1.25, -- Roblox Premium, stacks on top
	MAX_TOTAL_COIN_MULTIPLIER = 6, -- ceiling so stacked perks cannot break the economy
	VIP_EXTRA_LIFE = 1, -- the one non-cosmetic perk, kept deliberately small
	FREE_GEMS_GROUP = 25, -- one-time, for joining the group
	FREE_SPINS_FAVOURITE = 3, -- one-time, for favouriting the game
	RECEIPT_RING_SIZE = 100, -- ProcessReceipt dedup ring; re-delivery is idempotent
}

Config.PRODUCTS = {
	GEMS_S = { id = 0, name = "Handful of Gems", grant = "gems", amount = 80, robux = 39, icon = "gem" },
	GEMS_M = { id = 0, name = "Bag of Gems", grant = "gems", amount = 250, robux = 99, icon = "gem", tag = "POPULAR" },
	GEMS_L = { id = 0, name = "Crate of Gems", grant = "gems", amount = 700, robux = 249, icon = "gem" },
	GEMS_XL = { id = 0, name = "Truck of Gems", grant = "gems", amount = 1800, robux = 599, icon = "gem", tag = "BEST VALUE" },
	GEMS_XXL = { id = 0, name = "Mountain of Gems", grant = "gems", amount = 5000, robux = 1499, icon = "gem" },

	COINS_S = { id = 0, name = "Coin Pouch", grant = "coins", amount = 2500, robux = 29, icon = "coin" },
	COINS_M = { id = 0, name = "Coin Chest", grant = "coins", amount = 12000, robux = 99, icon = "coin" },
	COINS_L = { id = 0, name = "Coin Vault", grant = "coins", amount = 40000, robux = 249, icon = "coin", tag = "BEST VALUE" },

	SPINS_5 = { id = 0, name = "5 Lucky Spins", grant = "spins", amount = 5, robux = 49, icon = "spin" },
	SPINS_25 = { id = 0, name = "25 Lucky Spins", grant = "spins", amount = 25, robux = 199, icon = "spin" },

	EXTRA_LIFE = { id = 0, name = "Extra Life", grant = "extraLife", amount = 1, robux = 19, icon = "heart" },
}

Config.PASSES = {
	DOUBLE_COINS = { id = 0, name = "2x Coins", perk = "doubleCoins", robux = 199, icon = "coin",
		blurb = "Earn double coins forever!" },
	VIP = { id = 0, name = "VIP", perk = "vip", robux = 399, icon = "crown",
		blurb = "1.5x coins, an extra life, VIP car." },
	STARTER_PACK = { id = 0, name = "Starter Pack", perk = "starterPack", robux = 99, icon = "gift",
		blurb = "10,000 coins and the Police Car.", onceOnly = true,
		grantCoins = 10000, grantCar = "police" },
	CROWN_MAGNET = { id = 0, name = "Crown Magnet", perk = "magnet", robux = 149, icon = "magnet",
		blurb = "Crowns fly to you from further away." },
	GOLDEN_CAR = { id = 0, name = "Golden Car", perk = "goldenCar", robux = 299, icon = "car",
		blurb = "A shiny gold ride, pass holders only.", grantCar = "rocketcar" },
}

--[[ SHOP LAYOUT — what the shop renders, in order. `source` says where rows come from, so the
	UI never hardcodes a catalog and cannot drift from what is actually purchasable. ]]
Config.SHOP = {
	TABS = {
		{ key = "GEMS", label = "Gems", source = "PRODUCTS", filter = "gems" },
		{ key = "COINS", label = "Coins", source = "PRODUCTS", filter = "coins" },
		{ key = "PASSES", label = "Perks", source = "PASSES" },
		{ key = "CARS", label = "Cars", source = "CARS" },
		{ key = "LIMITED", label = "Limited", source = "LIMITED" },
	},
	LIMITED_ROTATION_SECONDS = 86400,
	LIMITED_POOL = { "GEMS_M", "COINS_M", "SPINS_25", "STARTER_PACK" },
	LIMITED_DISCOUNT = 0.25,
}


-- ==========================================================================
-- TEST — Studio-only. Consumers MUST gate on RunService:IsStudio() at point of use.
-- ==========================================================================
Config.TEST = {
	MIN_PLAYERS = 1,
	SHORT_LOBBY = 5,
	SHORT_MATCH = 40, -- shorter matches so a solo Studio test loops fast
	GRANT_ALL_CARS = false,
	START_COINS = 0,

	--[[ Lucky blocks are deliberately rare in production: 5 blocks, 55 studs apart, in a
		420-stud arena. Across a 40-second solo Studio match that is very nearly impossible to
		drive into, which presents as "the roller is broken" when the roller is fine and the
		field is just sparse. Studio therefore gets a dense field. Read via
		LuckyBlockService.maxActive()/minSeparation(), both gated on RunService:IsStudio(). ]]
	LUCKY_MAX_ACTIVE = 14,
	LUCKY_MIN_SEPARATION = 26,
	-- Press this key in a Studio playtest to preview the reel without finding a block.
	-- Client-side draw only: it never grants a weapon, because only the server can.
	LUCKY_KEY = "L",
}

-- Convenience: id -> car def
Config.CARS_BY_ID = {}
for _, car in ipairs(Config.CARS) do
	Config.CARS_BY_ID[car.id] = car
end

return Config
