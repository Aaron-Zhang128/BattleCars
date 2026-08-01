--[[ Config
	Single source of truth for every tunable in the game. No magic numbers in logic.

	Read by: every server service and client controller.
	Sections:
		ATTR       attribute key names (replicated state contract)
		DATA       DataStore identity + retry policy
		ROUND      THE ROUND CLOCK -- phase lengths, intermission, Studio profile
		MATCH      the rules inside a round (lives, respawn, spawn protection)
		MODES      the round rulesets (Crown Rush ... Bounty ... Elimination)
		BOUNTY     Bounty mode: what a life is worth and how the roller behaves
		CHASSIS    arcade vehicle handling baseline
		RAM        body-slam combat math
		ARENA      procedural arena dimensions and features
		CARS       car roster (stats + procedural build recipe + signature powerup)
		POWERUPS   weapon definitions
		PICKUPS    crown / money / crate spawning
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
	MONEY = "Money", -- persistent soft currency
	GEMS = "Gems", -- persistent hard currency
	EQUIPPED = "EquippedCar", -- car id
	OWNED = "OwnedCars", -- JSON array of car ids
	BEST_CROWNS = "BestCrowns", -- persistent record
	TOTAL_KILLS = "TotalKills", -- persistent lifetime kills
	PROFILE_LOADED = "ProfileLoaded", -- boolean: safe to read/write currency
	TEAM = "Team", -- 1-based team index this round, 0 / nil = no teams
	JUGGERNAUT = "Juggernaut", -- boolean: this player is driving the monster car
	SCORE = "Score", -- the number this mode places on (see Shared.GameModes.scoreOf)
	--[[ BOUNTY MODE. Services/BountyService is the only writer of either.
		BOUNTY_TARGET is the userId of the car this player is contracted to wreck (0 =
		none, and 0 for everybody in every other mode); BOUNTY is what THEY are worth to
		whoever wrecks them, which grows for as long as they stay alive. Both are plain
		Player attributes so every client can draw every car's price with no remote. ]]
	BOUNTY_TARGET = "BountyTarget",
	BOUNTY = "Bounty",

	-- on ReplicatedStorage.CrashCore (global match state)
	PHASE = "Phase", -- "Lobby" | "Match" | "Results"
	PHASE_ENDS = "PhaseEndsAt", -- workspace:GetServerTimeNow() deadline
	ROUND_ID = "RoundId", -- increments each match
	ALIVE_COUNT = "AliveCount", -- players with a car right now
	MAP_ID = "MapId", -- id of the map ArenaService currently has built
	MAP_NAME = "MapName", -- its display name, for the lobby card
	MODE_ID = "ModeId", -- id of the game mode this round is running
	MODE_NAME = "ModeName", -- its display name, for the lobby card and the GO! banner
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
-- ROUND -- THE GLOBAL ROUND CLOCK.
--
-- Every duration the round state machine runs on lives here and nowhere else:
-- how long an intermission lasts, how long a round lasts, how long the results
-- card stays up, and every cadence the driver loop ticks at. MatchService owns
-- the machine; this table owns its clock. Nothing in that service hardcodes a
-- duration any more.
--
-- ONE SOURCE, TWO PROFILES. Studio runs on the STUDIO table below, so a solo test
-- loops in seconds instead of four minutes; a live server runs on the values above
-- it. Nothing else in the game may branch on RunService:IsStudio() for a round
-- time -- read every value through Shared/MatchState (phaseSeconds, minPlayers,
-- roundValue), which is the ONLY thing that picks between the two profiles.
-- MatchService, MapVoteService and LobbyUI each used to keep their own copy of that
-- branch with a comment asking the next person to keep them in sync; they now
-- cannot disagree.
--
-- WHAT IS NOT HERE: what happens INSIDE a round -- lives, respawn delay, spawn
-- protection, drop-in height, crown drops -- is Config.MATCH, just below. The map
-- ballot's timings are Config.MAPVOTE, and its BUILD_LEAD is measured backwards
-- from the end of LOBBY_SECONDS and capped as a fraction of it, so shortening the
-- intermission shortens the ballot with it automatically.
-- ==========================================================================
Config.ROUND = {
	--[[ THE THREE PHASE LENGTHS, in seconds -- the dials this table exists for.
		LOBBY is the intermission: the on-foot hub, the map vote and the next map
		assembling in the valley all happen inside it, so it is the one to cut when
		the game feels slow to come back around. ]]
	LOBBY_SECONDS = 30,
	MATCH_SECONDS = 180,
	RESULTS_SECONDS = 10,

	--[[ Below this many players the intermission HOLDS instead of starting a round,
		and PhaseEndsAt keeps rolling forward so clients show a live "waiting for
		players" countdown instead of a clock frozen at 0:00. ]]
	MIN_PLAYERS = 2,

	--[[ STUDIO -- the same keys again, applied ONLY in Studio and only while
		STUDIO_OVERRIDES is true. Any key left out of this table falls through to the
		live value above, so adding one is all it takes to shorten it in test. Turn
		STUDIO_OVERRIDES off to feel the real pacing in a Studio playtest. ]]
	STUDIO_OVERRIDES = true,
	STUDIO = {
		LOBBY_SECONDS = 5,
		MATCH_SECONDS = 40,
		RESULTS_SECONDS = 6,
		MIN_PLAYERS = 1,
	},

	--[[ DRIVER CADENCE -- how OFTEN the round loop does things, as opposed to how
		long a phase lasts. These were local constants inside MatchService; they live
		here so one table answers "why did that take three seconds". They are read
		ONCE at load because they drive hot loops, unlike the phase lengths above,
		which are re-read at the top of every phase. ]]
	TICK = 0.25, -- driver loop granularity: every timing here quantises to it
	BOARD_INTERVAL = 2.0, -- live leaderboard push during Match
	BOARD_TOP_N = 5, -- entries in one of those pushes
	HOLD_REFRESH = 1.0, -- while holding for players, roll PhaseEndsAt forward this often
	LOBBY_TOPUP = 2.0, -- how often Lobby re-checks that everyone has a hub character
	EARLY_END_GRACE = 3.0, -- ignore the all-eliminated check this long after the drop-in
	ENDLESS_REFRESH = 2.0, -- "/test game": roll the endless match clock forward this often
	--[[ How long an eliminated player keeps looking at their own wreck before being
		walked back up to the hub. Long enough for the death card to land and for them
		to see what hit them; short enough that "out of the round" never turns into
		"out of the game". ]]
	ELIMINATED_TO_LOBBY = 3.0,
	--[[ A mid-Match joiner waits this long for their profile before being spawned
		anyway, so their car is built with the skin they equipped last session. ]]
	JOIN_PROFILE_TIMEOUT = 15,
	JOIN_PROFILE_POLL = 0.25,
}

-- ==========================================================================
-- MATCH -- the rules INSIDE a round. Its CLOCK is Config.ROUND, above.
-- ==========================================================================
Config.MATCH = {
	LIVES = 3,
	RESPAWN_DELAY = 2.0, -- seconds of death screen before respawn is allowed
	SPAWN_PROTECT = 2.0, -- invulnerable seconds after spawning
	--[[ Round start: cars are taken off the mountaintop hub and dropped in from this
		height above the arena spawn ring, so a round OPENS with everyone falling into
		the map. Purely a spawn lift — nothing else reads it. ]]
	DROP_IN_HEIGHT = 170,
	CROWN_DROP_FRACTION = 0.5, -- fraction of your crowns the killer steals
	CROWN_SCATTER_FRACTION = 0.5, -- the rest scatter as pickups
}
-- ==========================================================================
-- MODES — the round rulesets. One is picked per round and replicates as
-- Config.ATTR.MODE_ID / MODE_NAME. Shared/GameModes is the pure logic over this
-- table (both sides read it) and ModeService is the only thing that WRITES the
-- per-round state (team assignment, who the juggernaut is).
--
-- Adding a mode is: an entry in LIST, its id in ROTATION, and -- only if it needs
-- a rule nothing here expresses -- a branch in ModeService. Everything else
-- (lives, crowns on the field, friendly fire, what the standings sort on) is
-- declared right here, so no consumer has to special-case a mode by name.
-- ==========================================================================
Config.MODES = {
	--[[ Straight rotation, not random: every player sees every mode, nobody gets
		three eliminations in a row, and "what is next" is answerable. ]]
	ROTATION = { "crowns", "deathmatch", "teams", "juggernaut", "bounty", "elimination" },

	--[[ POINTS are the generic score bucket ScoreService keeps beside crowns and
		kills. Only a mode with scoreKey == "points" PLACES on them, but they are
		always banked, so the payout can pay for them whatever the mode. ]]
	KILL_POINTS = 1,
	JUGG_KILL_POINTS = 6, -- taking the monster down IS the objective, so it pays like it
	SURVIVOR_POINTS = 8, -- elimination: last car driving

	TEAM_NAMES = { "RED", "BLUE" },
	TEAM_COLORS = { Color3.fromRGB(255, 96, 88), Color3.fromRGB(86, 156, 255) },

	--[[ JUGGERNAUT — the monster car.

		SCALE is GEOMETRY ONLY: CarFactory scales the model, sizes the hull around it
		and stamps every multiplier onto the car model, and ChassisSpec.resolveCar
		re-derives ride height from them on BOTH sides — which is what stops the owning
		client driving a 2x body at a 1x hover height and grinding along the floor.

		HP, MASS and SPEED are separate dials on purpose: twice as wide is the READ,
		four times the health is the FIGHT, and the mass is what makes ramming it feel
		like hitting a wall (ChassisSpec.ramResult still clamps the ratio, so it tilts
		a trade rather than deciding it). Speed comes down a little so a fleeing
		monster is always catchable. ]]
	JUGG = {
		SCALE = 2,
		HP_MULT = 4,
		MASS_MULT = 2.6,
		SPEED_MULT = 0.9,
	},

	LIST = {
		{
			id = "crowns",
			name = "Crown Rush",
			blurb = "Grab crowns. Most crowns wins!",
			crowns = true,
			scoreKey = "crowns",
			scoreNoun = "crowns",
			accent = Color3.fromRGB(255, 199, 64),
		},
		{
			id = "deathmatch",
			name = "Deathmatch",
			blurb = "No crowns. Most wrecks wins!",
			lives = 5,
			crowns = false,
			scoreKey = "kills",
			scoreNoun = "wrecks",
			accent = Color3.fromRGB(255, 118, 92),
		},
		{
			id = "teams",
			name = "Team Battle",
			blurb = "Red vs Blue. Wreck the other side!",
			lives = 5,
			crowns = false,
			teams = true,
			scoreKey = "kills",
			scoreNoun = "wrecks",
			accent = Color3.fromRGB(140, 170, 255),
		},
		{
			id = "juggernaut",
			name = "Juggernaut",
			blurb = "One monster car. Take it down!",
			lives = 5,
			crowns = false,
			juggernaut = true,
			scoreKey = "points",
			scoreNoun = "points",
			accent = Color3.fromRGB(190, 120, 255),
		},
		{
			--[[ Everyone is always hunting exactly one named car and being hunted by
				one, and the longer you live the more you are worth -- so the leader is
				also the biggest prize on the field. Config.BOUNTY is the whole tuning
				surface; Services/BountyService owns the contracts. ]]
			id = "bounty",
			name = "Bounty",
			blurb = "Hunt your mark. Survive to raise your price!",
			lives = 5,
			crowns = false,
			bounty = true,
			scoreKey = "points",
			scoreNoun = "bounty",
			accent = Color3.fromRGB(255, 62, 62),
		},
		{
			id = "elimination",
			name = "Elimination",
			blurb = "One life. Last car driving wins!",
			lives = 1,
			crowns = false,
			lastStanding = true,
			scoreKey = "points",
			scoreNoun = "points",
			accent = Color3.fromRGB(120, 230, 170),
		},
	},
}

-- ==========================================================================
-- BOUNTY — the contract mode. Read by Services/BountyService (the only writer of
-- the two attributes), Shared/GameModes (the colours) and StarterGui's BountyUI.
--
-- The mode in one line: you always have exactly ONE named target, they are worth a
-- price that grows for every second they stay alive, and wrecking them banks it.
-- ==========================================================================
Config.BOUNTY = {
	START = 100, -- what a fresh life is worth
	MAX = 900, -- ...and the ceiling, so a runaway leader is a prize, not a lottery

	--[[ SURVIVAL IS THE MECHANIC: a price is START plus PER_SECOND for every second of
		the CURRENT life, so the car nobody has managed to wreck is visibly the richest
		thing on the field. Quantised to STEP because the number hangs over a car in
		world space -- a price that ticks up in readable jumps beats a counter churning
		every frame. At 6/s a life is worth double after ~40 seconds and caps at ~2:13. ]]
	PER_SECOND = 6,
	STEP = 25,
	--[[ Dying takes you back to START. That is what stops one player snowballing and
		what makes a long life worth defending. Set false and bounties only ever grow. ]]
	RESET_ON_DEATH = true,

	--[[ What the killer banks as points (the mode places on points, so this IS the
		scoreboard). Your CONTRACT pays the full price plus the bonus; anybody else pays
		a quarter, because a shot that lands should never be worth literally nothing --
		but taking the car you were sent after has to be worth several times more. ]]
	CLAIM_FRACTION = 1.0,
	CLAIM_BONUS = 50,
	OFF_TARGET_FRACTION = 0.25,

	--[[ THE ROLLER. The server picks the name the moment it needs one, then HOLDS the
		reveal for ROLL_SECONDS while the reel spins. Same contract as the lucky-block
		reel: both sides key off one workspace:GetServerTimeNow() stamp, so a laggy
		client gets a SHORT spin and never a wrong name. BOUNTY_TARGET is written when
		the reel LANDS, which is what makes the red car appear on the beat instead of
		spoiling the roll a second and a half early. ]]
	ROLL_SECONDS = 1.7,
	REEL_TILES = 14, -- names scrolled past before the winner
	REEL_TAIL = 2, -- ...and left on the strip after it, so the settle never runs off
	REGRAB_DELAY = 1.2, -- beat between losing a target and the next roller opening

	TICK = 0.5, -- how often prices grow and hunters with no target are re-rolled

	--[[ The two colours the whole mode is played on -- the nametag, the through-wall
		highlight and the leaderboard row all read them through GameModes.colorFor.
		RED IS THE ONLY RED ON THE FIELD in this mode: nothing else may wear it, which
		is what makes "that car is mine" a glance rather than a search. ]]
	TARGET_COLOR = Color3.fromRGB(255, 62, 62),
	OTHER_COLOR = Color3.fromRGB(245, 245, 250),
}

-- ==========================================================================
-- MAPVOTE — the lobby ballot. Read by Services/MapVoteService only.
--
-- WHY THE BALLOT CLOSES EARLY: rebuilding the arena DELETES the ground, so it may
-- only happen while no car exists — which is any moment during Lobby, not just the
-- top of it. Closing BUILD_LEAD seconds before Lobby ends is late enough that
-- everyone has voted and early enough that the winning map visibly assembles in the
-- valley below the mountaintop hub while people are still standing on it. That
-- "watch the next map build" beat is what the straight rotation used to give, and it
-- is deliberately kept.
-- ==========================================================================
Config.MAPVOTE = {
	CHOICES = 3, -- maps on the ballot. The one currently built is never among them.
	BUILD_LEAD = 8, -- seconds before Lobby ends that the vote closes and the winner builds
	--[[ ...but never more than this fraction of the lobby. Studio's lobby is 5 seconds
		(Config.ROUND.STUDIO.LOBBY_SECONDS) and a flat 8 would close the ballot before
		it opened. ]]
	MAX_LEAD_FRACTION = 0.4,
	VOTE_GAP = 0.4, -- per-player throttle on casting / changing a vote
	SYNC_GAP = 1.0, -- ...and on asking for the current state. Separate gates on purpose:
	-- a fresh joiner syncs and then votes immediately, and one shared gate would eat it.
}

-- ==========================================================================
-- CHASSIS — baseline handling. Per-car stats multiply these.
-- ==========================================================================
Config.CHASSIS = {
	HULL_SIZE = Vector3.new(6, 2.4, 11), -- default; cars override
	HOVER_HEIGHT = 4.73, -- studs from hull center to ground
	RAY_LENGTH = 12.9, -- ground probe distance
	GROUND_SPRING = 90, -- stiffness pulling to hover height
	GROUND_DAMPER = 18, -- zeta 0.95 against GROUND_SPRING 90. Was 12 (zeta 0.63) = visible bob.

	TOP_SPEED = 193.5, -- studs/s at stat 1.0
	REVERSE_FRACTION = 0.45,
	ACCEL = 150.5, -- studs/s^2 at stat 1.0
	BRAKE = 279.5,
	COAST_DRAG = 47.3, -- deceleration with no throttle
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
	FLIP_STUCK_SPEED = 17.2, -- ramp air always carries speed, so barrel rolls never trip this
	FLIP_STUCK_SECONDS = 1.2,
	FLIP_HOP_SPEED = 64.5,
	FLIP_HOP_COOLDOWN = 1.5,
	-- Drift is INTRINSIC to cornering, not a button. driftAmount = speedTerm * steerTerm,
	-- where each term ramps 0->1 from the minimum below up to full. Below these the car
	-- stays planted and crisp; above them grip collapses and the back steps out by itself.
	-- LOWER these to make the car looser more of the time.
	DRIFT_AUTO_SPEED_MIN = 0.35, -- speed fraction where automatic drift starts
	DRIFT_AUTO_STEER_MIN = 0.45, -- steer magnitude where automatic drift starts
	AIR_CONTROL = 0.25, -- steering authority multiplier while airborne
	-- Fallback only: CarFactory now sizes Steer.MaxTorque from UPRIGHT_ANGULAR_ACCEL and
	-- the hull's real inertia. ChassisController still reads this if a car somehow arrives
	-- with no torque set at all.
	UPRIGHT_TORQUE = 12000,
	--[==[ The angular authority the chassis is tuned around, in rad/s^2: how hard the car
		can rotate toward the heading you are steering, and how briskly it rights itself.
		This replaced a flat torque because TORQUE IS NOT PORTABLE ACROSS CAR MODELS.
		Swapping the old 6 x 2.4 x 11 procedural hulls for the real bodies roughly tripled
		yaw inertia, so the same 12000 left every car at ~1.1 rad/s^2 — over a second to
		reach the yaw rate TURN_RATE asks for. The heading never caught up, so
		ChassisController's YAW_RESYNC_DEG clamp fired every frame and steering read as
		laggy and snatchy. An acceleration stays honest whatever the models become.
		7.6 reaches a full-lock yaw rate in about a quarter of a second.
		LOWER for heavier, more sluggish steering; raise for kart-like snap. ]==]
	UPRIGHT_ANGULAR_ACCEL = 7.6,
	UPRIGHT_POWER = 4000,
	MAX_SLOPE_COS = 0.35, -- surfaces steeper than this are not "ground"
	--[==[ TRUE air gap between the bottom of the Hull box and the ground at rest, and the
		reason the car no longer buzzes. hoverHeight = hull.Y/2 + this, so the hull settles
		exactly this far off the floor.
		It was 0.1 while hull.Y was the car's FULL body height, which parked a COLLIDABLE
		box on the ground: the hover spring commanded upward into a contact that pushed
		back, every frame, for the whole time you were driving. That fight was the
		vibration, and any seam or slope that let the box catch was the sinking.
		The gap is paid for out of hull.Y, NOT out of ride height — every CARS[i].hull is
		authored 2 x this SHORTER than its model, so the body still sits at exactly the
		same height and only the invisible collider floats. Change this and you must
		re-author those ten hull heights with it. ]==]
	GROUND_CLEARANCE = 1.5,
	--[==[ Cosmetic wheel spin. FALSE: every model part welds rigidly to the Hull — the
		known-good car. TRUE: CarFactory adds ONE cylinder per wheel at CARS[i].wheels,
		hides the model's own wheel blocks behind it, and ChassisController frees those
		cylinders from the hull and drives them by CFrame.
		ONE PART PER WHEEL IS LOAD-BEARING. The earlier multi-part hub route failed three
		distinct ways (wheels detaching, then frozen in world space) because
		ChassisController only anchors a freed wheel when it is its own AssemblyRootPart,
		which a hub with welded blocks never is. Do not reintroduce hubs. ]==]
	WHEEL_SPIN = true,
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

	FALL_KILL_Y = -129, -- below this, you die (pits)
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
	MIN_CLOSING_SPEED = 60.2, -- below this a touch does nothing
	-- Retuned after CombatService measured the originals: a Mini Tank rear-ending a
	-- Rocket Car at a routine 60 closing speed dealt 168 dmg into 85 hp (a one-shot),
	-- and every full-speed head-on traded mutual instant kills. Mistakes must be
	-- survivable for a kids' audience, and weight class should tilt a fight, not decide it.
	-- Health is authored in 100-point CHUNKS now (Config.HP_PER_CHUNK) and every car
	-- carries 4x what it used to, so EVERY damage number in this file was multiplied
	-- by 4 with it. Ratios are untouched: the tuning described above still holds,
	-- only the units are bigger. Change one damage number and you break that pairing.
	DAMAGE_PER_SPEED = 2.2, -- damage = closingSpeed * this * massRatio
	MASS_RATIO_CLAMP = 1.6, -- caps heavy-car advantage
	-- Was 55, which produced up to 259 studs/s of knock against a 90 top speed —
	-- enough to hurl a car clean over the 26-stud arena wall.
	KNOCKBACK = 73.1, -- impulse scale applied to the loser
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
	MIN_KNOCK_TO_STAGGER = 25.8,
}

-- ==========================================================================
-- ARENA — rebuilt at 903 studs for the real car models (~24 studs long vs the
-- old ~11). Every length is the original 420-stud layout x2.15, so cars occupy
-- the same fraction of the floor as before and the feel carries over.
-- TILE_STUDS 129 divides SIZE 903 exactly -> a clean 7x7 checker.
--
-- These are the numbers that are the SAME on every map, plus the fallbacks a map def
-- inherits when it does not state one. Per-map look and layout live in CrashCore.Maps;
-- ArenaService builds exactly one map at a time and rotates at the top of Lobby.
--
-- DO NOT move ORIGIN or SIZE into a map. CameraController caches them at module load
-- for its lobby orbit and SpawnService caches ARENA_HALF for its out-of-bounds test,
-- and neither re-reads on a map change — a map that resized the floor would silently
-- desync both. Layout variety is what sits ON the floor, never its footprint.
-- ==========================================================================
Config.ARENA = {
	ORIGIN = Vector3.new(0, 0, 0),
	SIZE = 903, -- square floor, studs
	--[[ Map layouts and ArenaService's own stud constants are authored against this
		reference footprint and multiplied by ARENA.SCALE below, so retuning SIZE moves
		the ramps, pits, margins and scenery with it instead of stranding them. ]]
	REFERENCE_SIZE = 420,
	FLOOR_THICKNESS = 9,
	WALL_THICKNESS = 13,

	SPAWN_COUNT = 16,
	SPAWN_RING_RADIUS = 333,
	SPAWN_HEIGHT = 11,

	PAD_SIZE = Vector3.new(39, 1.3, 56),

	-- ---- inherited defaults: a map only states what makes it different ----
	TILE_STUDS = 129, -- 903 / 129 = 7 exactly. Cosmetic: pits cut to the exact rect.
	FLOOR_COLOR = Color3.fromRGB(238, 240, 245),
	FLOOR_ACCENT = Color3.fromRGB(214, 221, 232),

	--[[ The stock Roblox baseplate grid, laid over every floor tile on every map.
		It is TINTED by the tile's own checker colour (Texture.Color3 multiplies), so a
		map keeps its palette and only gains the grid. FLOOR_TEXTURE = "" on a map def
		leaves that floor plain.

		FLOOR_TEXTURE_STUDS is the TARGET world size of one repeat: the baseplate's own
		8 studs x ARENA.SCALE 2.15, i.e. the default grid seen at this world's scale.
		ArenaService SNAPS it to an EVEN divisor of the map's tile, and that is not
		fussiness -- a Texture tiles outward from the face CENTRE, so an odd number of
		repeats per tile lands the pattern half a period out at every seam and the grid
		visibly breaks along all 90 checker lines. ]]
	FLOOR_TEXTURE = "rbxassetid://6372755229",
	FLOOR_TEXTURE_STUDS = 17.2,
	FLOOR_TEXTURE_TRANSPARENCY = 0,
	GROUND_COLOR = Color3.fromRGB(206, 178, 132), -- apron plane outside the walls

	-- Sloped perimeter berm you can drive up. BANK_HEIGHT = 0 disables it.
	BANK_DEPTH = 77,
	BANK_HEIGHT = 28,
	BANK_SEGMENTS = 1, -- >1 with BANK_COLOR_ALT paints racing kerb stripes
	BANK_COLOR = Color3.fromRGB(216, 186, 138),

	WALL_HEIGHT = 56, -- tall enough that a knocked car cannot clear it
	--[[ An INVISIBLE extension standing on top of every boundary wall, so nothing can
		be knocked out of the arena. Maps inherit it and may override it like WALL_HEIGHT.

		IT DISABLES RING-OUTS. FALL_KILL_Y is the only environmental death in this game —
		being rammed clean over the wall — and sealing the box means it can no longer
		happen. Ramming still kills through damage; what is gone is the knock-them-out
		kill and the credit that came with it. Set this to 0 to hand ring-outs back. ]]
	BARRIER_HEIGHT = 200,
	WALL_COLOR = Color3.fromRGB(190, 158, 110),
	TRIM_COLOR = Color3.fromRGB(240, 220, 178),

	BLOCK_COLOR = Color3.fromRGB(196, 170, 126),
	PAD_COLOR = Color3.fromRGB(255, 221, 51),
	--[[ PLATEAUS. A map's raised decks: solid mesas you drive around, or up and over via
		the wedge skirts ArenaService puts on all four sides. HEIGHT and SKIRT are one
		pair — they set the climb angle (atan(HEIGHT/SKIRT) ~ 25 degrees here), and
		raising the deck without lengthening the skirt turns a ramp into a wall.
		PLATEAU_COLOR defaults to BLOCK_COLOR so a plateau reads as what it is: a very
		large block. ]]
	PLATEAU_HEIGHT = 16,
	PLATEAU_SKIRT = 34,

	-- Empty layout: with no map loaded the arena is still a legal, playable box.
	RAMPS = {},
	PADS = {},
	PLATEAUS = {},
	BLOCKS = {},
	MARKS = {},
	DECOR = {},
}

-- Single source of the reference-to-live stretch. Maps and ArenaService both read it.
Config.ARENA.SCALE = Config.ARENA.SIZE / Config.ARENA.REFERENCE_SIZE


-- ==========================================================================
-- LOBBY — the hub, and it IS one of the rocks. Config.RING below rings the arena with
-- real rock models; at this ORIGIN's bearing that ring skips its gap and swells into a
-- peak, and the terrace is cut into the summit. So the place you wait in is part of the
-- skyline you spend the round inside, and the arena reads as a crater floor.
-- You are ON FOOT up here: LobbyService loads a real Roblox character for the whole
-- Lobby phase, so the hub is walked, not driven. The round starts by destroying that
-- character and dropping a car into the arena (SpawnService.dropInAll). LobbyService
-- builds the geometry ONCE at init and never rebuilds it — people are standing on it.
--
-- THE DECK IS FLAT (DECK_TILT_DEG = 0) BY CHOICE, AND IT COSTS THE VIEW FROM THE BACK.
-- This is the one number up here that was argued over, so the trade is written down.
-- A flat floor 330 studs above the arena only shows you the arena from near its own
-- edge: your eye is ~10 studs up and the arena centre is ~21 degrees below it, so the
-- sight line clears the deck's own edge only within about 25 studs of it. Further back
-- the deck hides the valley and you get the far rim and sky instead. The terrace was
-- raked 19-26 degrees for exactly this reason until 2026-07-30, when a flat floor was
-- chosen over the full view. Three consequences are load-bearing — do not undo them:
--   * THERE IS NO FRONT RAIL. PARAPET_HEIGHT = 0 and LobbyService skips that wall
--     entirely. At the old 13 the rail alone stood above a 2.15x rig's eye and hid the
--     arena from the WHOLE deck, its own edge included; even a 4-stud kerb costs two
--     thirds of the band. The drop is open on purpose. LobbyService's sweep is what
--     catches fallers — no death, back on the deck inside 0.5s — and it always was.
--     EdgeStripe is the only thing marking the edge now.
--   * SPAWN_RING_Z_OFFSET presses the spawn arc up against that edge, so slots sit
--     inside the band that can actually see. The arc is nearly a straight line along
--     the drop on purpose: everyone arrives at the balcony already looking down.
--   * The back two thirds of the plaza is deliberately scenery you can walk on.
-- The band is eye height / tan(depression), so it scales with ORIGIN.Y: 330 -> ~25
-- studs, 200 -> ~42, 120 -> ~68. Lowering the peak widens it but sinks the hub below
-- the rim rocks, which are 190-275 tall. The only way to have a flat floor AND the view
-- from everywhere is to terrace the deck into steps.
-- ==========================================================================
Config.LOBBY = {
	ORIGIN = Vector3.new(0, 330, -880), -- centre of the deck's top surface; sits ON the ring

	-- Sized for walking, not driving: you should be able to cross it inside a Lobby.
	-- Depth is what costs view, so the terrace spends its space on width instead.
	DECK_WIDTH = 500,
	DECK_DEPTH = 260,
	DECK_TILT_DEG = 0, -- FLAT by choice; see above for exactly what that costs
	DECK_THICKNESS = 26,
	TILE_STUDS = 65,
	DECK_COLOR = Color3.fromRGB(230, 232, 236),
	DECK_ACCENT = Color3.fromRGB(208, 212, 220),

	-- Three tall sides and one OPEN one. A zero height means LobbyService builds no
	-- wall there at all, which is the whole reason the flat deck can see anything.
	RIM_HEIGHT = 30,
	RIM_THICKNESS = 12,
	PARAPET_HEIGHT = 0,
	--[[ The invisible wall around the whole summit, terrace and practice field alike. It
		goes up the OPEN front too: that edge is open so you can SEE out of it, never so
		you can walk out of it. This is what makes a railless balcony over a 330-stud drop
		safe, so the two settings belong together — dropping PARAPET_HEIGHT to 0 for the
		view is only reasonable while this is non-zero. 0 disables it. ]]
	BARRIER_HEIGHT = 90,
	RIM_COLOR = Color3.fromRGB(150, 144, 138),
	RIM_CAP_COLOR = Color3.fromRGB(236, 232, 226),
	TRIM_COLOR = Color3.fromRGB(255, 214, 64),

	--[[ THE PEAK — crags cloned from CrashCore.Assets.Rocks and ringed around the
		terrace, so the deck reads as a flat spot cut INTO a summit rather than a slab
		parked on one. Every rock in this game is authored by SUMMIT HEIGHT and WIDTH,
		never by centre or scale factor: what matters is how tall a crag stands next to
		the deck and how much horizon it covers.

		Crags ring the SUMMIT — the terrace PLUS the practice field behind it, derived
		by LobbyService from both — not the terrace alone, so changing Config.PRACTICE
		reshapes the peak on its own without a single crag number being re-tuned.

		The arena-facing arc gets BUTTRESSES instead — the same rock, kept under the
		terrace's own view ray (see PEAK_BUTTRESS_DROP) and set on a wider ellipse so
		they flank the balcony instead of hiding under it. A crag there would be the one thing standing between the
		terrace and what the terrace exists to look at. They also mask the plinth's
		front face, which is the only flat surface left on the mountain. ]]
	PEAK_COUNT = 24,
	PEAK_STANDOFF = 95, -- how far a crag stands outside the summit edge, before pushing
	PEAK_RISE = 70, -- how far the tallest crags stand above the deck
	PEAK_SINK = 50, -- how far the shortest ones fall short of it
	PEAK_WIDTH_MIN = 150,
	PEAK_WIDTH_MAX = 265,
	PEAK_CLEAR_DOT = 0.35, -- a crag pointing this much at the arena becomes a buttress
	PEAK_BUTTRESS_RADIUS_X = 420, -- wider than the crags, to clear the deck edge in plan
	PEAK_BUTTRESS_RADIUS_Z = 190, -- tucked under the balcony, where it masks the plinth
	--[[ A buttress summit is NOT authored against the deck's front edge. A rock below
		that edge but well in front of it still stands HIGHER in the view than the lip
		does — that mistake hid the arena out past its own centre. LobbyService clamps a
		summit to the terrace's own view ray instead, and these two are how far under
		that ray it sits and how much that varies from rock to rock. ]]
	PEAK_BUTTRESS_DROP = 18,
	PEAK_BUTTRESS_SPREAD = 42,
	PEAK_MARGIN = 140, -- plinth overhang past the deck
	PLINTH_THICKNESS = 180, -- the tilted rock cap the terrace is cut into
	FOOT_Y = -8, -- ArenaService's apron sits at about this height
	BURIAL = 22, -- how far a rock's foot is sunk under FOOT_Y, so nothing floats
	ROCK_LOW = Color3.fromRGB(104, 98, 96),
	ROCK_HIGH = Color3.fromRGB(146, 140, 134),

	--[[ A wide, SHALLOW arc rather than a ring, pressed against the open front edge by
		SPAWN_RING_Z_OFFSET — on a flat deck only that band can see the arena, so that
		is where people have to arrive. Z is deliberately tiny: this is a line of ten
		people leaning on a balcony, not a circle. Doubles as the SpawnLocation ring. ]]
	SPAWN_COUNT = 10,
	SPAWN_RING_X = 190,
	SPAWN_RING_Z = 6,
	SPAWN_RING_Z_OFFSET = 115, -- deck-local; the open edge is at DECK_DEPTH * 0.5 = 130
	SPAWN_HEIGHT = 10,

	--[[ CHARACTER — the hub is the one place in this game with humanoids.
		The whole world is Config.ARENA.SCALE (2.15x) oversized because the cars are real
		models ~21 studs long, so a default 5-stud avatar reads as an insect on a 500-stud
		terrace. The rig is scaled to match and its movement scaled with it: WalkSpeed
		linearly (same crossing time), JumpPower by sqrt(scale) (gravity is fixed, so
		clearing a 2.15x step needs only 1.47x the launch speed).
		Set CHARACTER_SCALE = 1 for true default-size avatars. ]]
	CHARACTER_SCALE = 2.15,
	WALK_SPEED = 34,
	JUMP_POWER = 74,
	RESPAWN_SECONDS = 1.5, -- after a hub death; CharacterAutoLoads is off, we own this
	SWEEP_INTERVAL = 0.5, -- how often the hub checks for fallers and missing characters
	-- Below ORIGIN.Y - this, a character has gone over the rail and gets put back.
	CATCH_DROP = 200,

	EMBLEM_RADIUS = 60,
	EMBLEM_WIDTH = 5,

	--[[ Walkable kickers. There are deliberately NO boost pads up here: a pad's effect
		lives on the CAR chassis, so on foot one would be a promise the hub cannot keep.
		Offsets are deck-local (X across, Z downhill toward the arena). ]]
	RAMPS = {
		{ offset = Vector2.new(196, 0), size = Vector3.new(70, 4, 54), rotY = 90, tilt = 13 },
		{ offset = Vector2.new(-196, 0), size = Vector3.new(70, 4, 54), rotY = -90, tilt = 13 },
	},
}

-- ==========================================================================
-- RING — the rock rim around the arena. Real models cloned from Assets.Rocks (65 slate
-- unions), not parts: scaled and scattered into a crater wall that closes the horizon
-- behind the arena's own walls, so a map stops reading as a slab in an empty desert.
--
-- LOBBYSERVICE BUILDS THIS, NOT ARENASERVICE, and that is the whole reason it can be
-- rock at all: the arena is destroyed and rebuilt every Lobby as the map rotates, and
-- cloning ~50 unions on every rotation would be real cost for scenery that never
-- changes. The rim is built ONCE at init, like the hub it carries.
--
-- Radii are live studs from the arena centre. Every rock clears the 903-stud arena
-- footprint by ARENA_MARGIN at its nearest face.
--
-- KNOWN CLASH, NOT YET RESOLVED (2026-07-30). Map DECOR runs from radius ~503 to ~1269,
-- which is the SAME band these rows occupy (~530-1100 once jitter and rock width are
-- counted). Measured on rooftops: 62 of its 150 decor parts intersect a rim rock. Note
-- Maps offsets are ALREADY LIVE STUDS — do not multiply them by ARENA.SCALE; reading
-- them as reference studs is what hid this, and it put decor at a phantom ~1082-2589.
-- Natural kinds (dune, mound, ridge, rock, pine, spike) read fine standing among
-- boulders. The architectural ones (tower, watertower, stand, banner, mast) do not.
-- The fix is a radial push clear of this band in ArenaService.buildDecor, NOT deleting
-- what falls inside it: rooftops' entire prop list is in there (542..1011). Moving these
-- rows instead is not free either, since the hub stands on them and Config.LOBBY's flat
-- deck is derived from where it stands.
-- ==========================================================================
Config.RING = {
	GAP_DEG = 52, -- arc left empty on the lobby bearing, for the peak to fill
	SWELL = 95, -- extra summit height as the ring closes on the peak, so it blends in
	ARENA_MARGIN = 70, -- nearest face of any rock to the arena footprint
	SEED = 20260730, -- fixed: every server gets the same skyline

	ROWS = {
		-- The wall.
		{
			count = 32, radius = 880, jitter = 70, phase = 0, swell = 1,
			topMin = 190, topMax = 275, widthMin = 155, widthMax = 300,
		},
		-- Talus at its foot: low boulders that plug the gaps at a DRIVER's eye height,
		-- which is the one viewpoint the tall row cannot fix.
		{
			count = 18, radius = 700, jitter = 55, phase = 11, swell = 0.3,
			topMin = 70, topMax = 145, widthMin = 120, widthMax = 230,
		},
	},
}

-- ==========================================================================
-- PRACTICE — a flat field with two kickers directly behind the terrace, on the same
-- summit and at the same height, so you walk straight off the back of the lobby into it
-- through a doorway cut in the back rail.
--
-- IT IS SCALED FOR CARS, NOT FOR FEET. The ramps are the arena's own ramp spec (112 x 78
-- live studs at 15 degrees, the same numbers every map uses) and the run-up from the
-- doorway is ~210 studs, because a kicker you cannot reach speed for teaches nothing.
-- Nothing puts a car up here yet — the Lobby is on foot and SpawnService gates spawning
-- on MatchService.canRespawn, which is Match-only. Until that changes this is a field
-- you can run around, and the geometry is already right for the day it does.
--
-- IT MOVES THE PEAK. Config.LOBBY's crags ring the SUMMIT, and the summit is the deck
-- plus this field; LobbyService derives that rect from both. Set DEPTH = 0 and the field
-- disappears, the doorway closes and the peak shrinks back around the terrace by itself.
-- ==========================================================================
Config.PRACTICE = {
	WIDTH = 620, -- wider than the 500 deck on purpose: it opens out as you walk through
	DEPTH = 520,
	THICKNESS = 26, -- matches DECK_THICKNESS, so the two floors are one surface
	TILE_STUDS = 65,
	DOOR_WIDTH = 220, -- opening cut in the terrace's back rail

	WALL_HEIGHT = 34,
	WALL_THICKNESS = 12,
	PEDESTAL_THICKNESS = 180, -- the rock block under it; its top face IS the floor's

	FLOOR_COLOR = Color3.fromRGB(214, 218, 226),
	FLOOR_ACCENT = Color3.fromRGB(196, 202, 212),
	WALL_COLOR = Color3.fromRGB(150, 144, 138),

	--[[ Deck-local: X across, Z back from the terrace (so these are negative). Same
		shape as LOBBY.RAMPS, and like those the size's Y is IGNORED — a ramp's height is
		derived from its length and tilt, which is the only way the slope angle you
		typed is the slope angle you get. ]]
	RAMPS = {
		{ offset = Vector2.new(-150, -380), size = Vector3.new(112, 0, 78), rotY = 0, tilt = 15 },
		{ offset = Vector2.new(150, -380), size = Vector3.new(112, 0, 78), rotY = 0, tilt = 15 },
	},
}

-- ==========================================================================
-- HEALTH — the HUD draws ONE CHUNK per HP_PER_CHUNK points, so car health is
-- authored in whole chunks and never in between: a normal car is 4 chunks (400),
-- heavies 5-6. A hp that is not a multiple of this still renders (the last chunk
-- just comes out narrow), but the bar stops reading at a glance, which is the
-- entire reason it is chunked. Every damage number in this file is at the same scale.
-- ==========================================================================
Config.HP_PER_CHUNK = 100

-- ==========================================================================
-- CARS — the roster. REAL models, cloned from Assets.CarModels by CarFactory.
-- `hull` is MEASURED from each normalised model, never authored by hand: every model
-- was pivot-normalised and rotated so its length runs down -Z (they ship facing +X),
-- then measured. WIDTH and LENGTH are 92% of the model so bodywork never snags. HEIGHT
-- is the model's height MINUS 2 x CHASSIS.GROUND_CLEARANCE: that lifts the collidable box
-- clear of the floor while leaving ride height (hull.Y/2 + clearance) exactly unchanged,
-- so the body sits where it always did. A hull that reaches the ground fights the hover
-- spring and the car buzzes — re-measure a model and you must re-apply that subtraction.
-- `stats` multiply Config.CHASSIS. `special` is the powerup this car
-- pulls more often from crates, which is what makes cars play differently.
-- ==========================================================================
Config.CARS = {
	{
		id = "convertible",
		name = "Convertible",
		rarity = "COMMON",
		price = 0,
		currency = "Money",
		starter = true,
		model = "convertible", -- Assets.CarModels.convertible
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.63, axleY = -1.68, frontZ = -6.04, rearZ = 5.91, radius = 2.36 },
		hull = Vector3.new(12.42, 5.30, 18.95), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.05, accel = 1.05, turn = 1.05, mass = 0.95, hp = 400 },
		special = "GUN",
	},
	{
		id = "pickup",
		name = "Pickup",
		rarity = "COMMON",
		price = 500,
		currency = "Money",
		model = "pickup", -- Assets.CarModels.pickup
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.31, axleY = -2.04, frontZ = -8.14, rearZ = 9.23, radius = 2.98 },
		hull = Vector3.new(11.87, 7.20, 24.10), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 0.95, accel = 0.95, turn = 0.90, mass = 1.35, hp = 500 },
		special = "CANNON",
	},
	{
		id = "bluetruck",
		name = "Blue Truck",
		rarity = "UNCOMMON",
		price = 1500,
		currency = "Money",
		model = "bluetruck", -- Assets.CarModels.bluetruck
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.63, axleY = -1.75, frontZ = -7.56, rearZ = 6.35, radius = 2.69 },
		hull = Vector3.new(11.87, 6.10, 22.26), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.00, accel = 1.00, turn = 0.95, mass = 1.20, hp = 500 },
		special = "GUN",
	},
	{
		id = "blacksuv",
		name = "Black SUV",
		rarity = "UNCOMMON",
		price = 3000,
		currency = "Money",
		model = "blacksuv", -- Assets.CarModels.blacksuv
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.52, axleY = -2.14, frontZ = -7.63, rearZ = 8.30, radius = 3.09 },
		hull = Vector3.new(13.25, 7.70, 22.63), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 0.95, accel = 0.95, turn = 0.90, mass = 1.45, hp = 600 },
		special = "CANNON",
	},
	{
		id = "redvan",
		name = "Red Van",
		rarity = "RARE",
		price = 7500,
		currency = "Money",
		model = "redvan", -- Assets.CarModels.redvan
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.55, axleY = -2.05, frontZ = -7.35, rearZ = 8.30, radius = 3.04 },
		hull = Vector3.new(13.25, 7.40, 22.63), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 0.92, accel = 0.90, turn = 0.88, mass = 1.50, hp = 600 },
		special = "FLAME",
	},
	{
		id = "compact",
		name = "Compact",
		rarity = "RARE",
		price = 12000,
		currency = "Money",
		model = "compact", -- Assets.CarModels.compact
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.45, axleY = -2.02, frontZ = -6.84, rearZ = 6.41, radius = 2.28 },
		hull = Vector3.new(12.14, 5.80, 19.32), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.15, accel = 1.15, turn = 1.20, mass = 0.85, hp = 400 },
		special = "GUN",
	},
	{
		id = "greensuv",
		name = "Green SUV",
		rarity = "EPIC",
		price = 20000,
		currency = "Money",
		model = "greensuv", -- Assets.CarModels.greensuv
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.28, axleY = -2.44, frontZ = -9.42, rearZ = 7.84, radius = 2.00 },
		hull = Vector3.new(11.87, 6.10, 22.26), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.00, accel = 1.00, turn = 0.95, mass = 1.30, hp = 500 },
		special = "FLAME",
	},
	{
		id = "sedan",
		name = "Sedan",
		rarity = "EPIC",
		price = 60,
		currency = "Gems",
		model = "sedan", -- Assets.CarModels.sedan
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.59, axleY = -1.74, frontZ = -8.24, rearZ = 6.78, radius = 2.70 },
		hull = Vector3.new(11.87, 6.10, 22.36), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.20, accel = 1.20, turn = 1.10, mass = 1.00, hp = 400 },
		special = "ROCKET",
	},
	{
		id = "orangevan",
		name = "Orange Van",
		rarity = "LEGENDARY",
		price = 100,
		currency = "Gems",
		model = "orangevan", -- Assets.CarModels.orangevan
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.40, axleY = -2.20, frontZ = -8.13, rearZ = 8.58, radius = 2.24 },
		hull = Vector3.new(11.87, 6.10, 22.54), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.05, accel = 1.00, turn = 0.95, mass = 1.40, hp = 600 },
		special = "SHIELD",
	},
	{
		id = "supercar",
		name = "Supercar",
		rarity = "LEGENDARY",
		price = 150,
		currency = "Gems",
		model = "supercar", -- Assets.CarModels.supercar
		-- Wheel hubs, MEASURED from the model's dark low geometry and then symmetrised
		-- (a car is symmetric, so averaging the four corners repairs lopsided models).
		-- `radius` is NOT measured — a cluster fit swallows arches and skirts and comes back
		-- 40% too big. It is DERIVED as axleY + modelHeight/2, the only value that puts the
		-- tyre on the road the car rides on. Authored radii were all ~0.8 studs short, which
		-- floated every wheel a stud off the ground and over-spun it by the same ratio.
		wheels = { track = 4.75, axleY = -1.93, frontZ = -10.20, rearZ = 8.66, radius = 2.36 },
		hull = Vector3.new(13.06, 5.80, 24.93), -- 92% wide/long; height = body - 2 x GROUND_CLEARANCE (see the header)
		stats = { topSpeed = 1.40, accel = 1.45, turn = 1.15, mass = 0.90, hp = 400 },
		special = "ROCKET",
	},
}

Config.STARTER_CAR = "convertible"

-- ==========================================================================
-- POWERUPS — one slot at a time, like the original.
-- kind: "projectile" | "lob" | "place" | "hitscan" | "aoe" | "self" | "cone"
--
-- SEVEN of these are MODELLED weapons: they physically bolt onto the car roof and
-- animate when they fire (GUN, DUALGUN, CANNON, MORTAR, ROCKET, FLAME, RAILGUN).
-- Their ART contract is Config.WEAPON_RIGS below and the rig is assembled
-- client-side by TurretController; the numbers HERE stay the single source of balance.
--
-- MINE / FREEZE / ZAP are still fully defined and still work, but they are out of
-- PowerupDefs.ORDER, so nothing rolls them: they have no turret model, and a
-- weapon you cannot see on your own roof reads as a bug beside seven you can.
-- Put an id back in ORDER to bring it back — nothing else has to change.
-- ==========================================================================
Config.POWERUPS = {
	--[[ MISSILE POD (Assets.Weapons.ROCKET). GUIDED, which is what earns the pod its
		name: the shell steers toward the nearest car ahead of it, while the cannon
		below fires dead straight. Six shots, so each one hits softer than the old
		one-shot rocket and the pod plays as a salvo you spend rather than a single
		verdict. At 0.75s cooldown that is ~3.8s of held fire. ]]
	ROCKET = {
		id = "ROCKET",
		name = "Missiles",
		kind = "projectile",
		ammo = 6,
		cooldown = 0.75,
		damage = 190, -- 1.9 chunks
		speed = 200,
		life = 3.2,
		blastRadius = 16,
		knockback = 70,
		-- Homing. A shell only ever locks a target already inside seekCone of its own
		-- heading, so it can never whip around and chase someone behind it.
		homing = true,
		seekRange = 260,
		seekCone = 55, -- degrees off the shell's heading
		turnRate = 150, -- degrees/s of steering authority
		size = Vector3.new(1.2, 1.2, 4), -- collision proxy; the client skins it with Assets.Weapons.ROCKET.Ammo
		color = Color3.fromRGB(255, 80, 70),
		weight = 22, -- crate roll weight
	},
	--[=[ PLASMA GUN (Assets.Weapons.GUN) — the BEAM WEAPON. It pours a continuous ray
		that chips: no travel, no spread, no slug, and no single hit worth flinching at.

		Still kind = "hitscan" because that IS what a beam is on the server — a cast down
		the aim line, re-run every tick, damaging the first car it finds. What changed is
		the RHYTHM. AMMO COUNTS TICKS, exactly like the flamethrower, so the numbers below
		are a duration and a damage-per-second in disguise:
		    0.07s cooldown x 45 ammo = ~3.1 seconds of held beam
		    11 damage x 14 ticks/s   = ~157 dps, so ~2.5s of perfect tracking per car
		It out-damages nothing in a single hit and beats everything that cannot hold its
		aim, which is the trade the weapon is for.

		SPREAD IS 0 AND MUST STAY 0. The ray is drawn as one straight line between the
		barrel and whatever the server says it hit; a couple of degrees of scatter that
		nobody could see on a slug makes a continuous beam visibly twitch every tick.

		KNOCKBACK IS HALVED (4 -> 2) because it now lands 14 times a second instead of 11
		and is still deliberately below Config.RAM.MIN_KNOCK_TO_STAGGER: the beam nudges,
		it does not shove. Raising it past that line would paralyse anyone it touches.

		The three numbers below are ONE unit. Halving the cooldown without halving the
		damage doubles the dps. ]=]
	GUN = {
		id = "GUN",
		name = "Plasma Gun",
		kind = "hitscan",
		ammo = 45, -- TICKS of beam, not shots: ~3.1s of continuous fire
		cooldown = 0.07,
		damage = 11, -- ~157 dps; a 400 hp car takes ~2.5s of held beam
		range = 220,
		spread = 0, -- a ray does not scatter; see the note above
		knockback = 2,
		color = Color3.fromRGB(170, 100, 255),
		weight = 26,
	},
	--[=[ RAILGUN (Assets.Weapons.RAILGUN) — the execution weapon, and the only one that
		does not fire when you pull the trigger. kind = "charged": the press starts a
		wind-up and spends the round, and WeaponService.stepCharges resolves the shot
		chargeTime later, re-aimed from the car's CURRENT heading (you STEER a charged
		shot onto its target — see HANDLERS.charged).

		ONE ROUND, and it is meant to delete a car:
		    damage 500 vs the hp roster (400 normal / 500 mid / 600 heavy)
		    -> one-shots every normal and mid car outright
		    -> leaves the three 600 hp heavies (blacksuv, redvan, orangevan) on 100
		That last line is the balance, not an accident: the heaviest bodies are the ONLY
		thing in the game that survives a railgun, which is what they are for. Raising
		damage to 600 deletes that distinction; lowering it to 400 makes the mid cars
		safe and the weapon pointless.

		The wind-up is the counterplay. CHARGE_TIME is long enough to see the orb, hear
		the whine climb and get off the line, and every client draws that tell on the
		firing car's own barrel, so it is public information the moment it starts. ]=]
	RAILGUN = {
		id = "RAILGUN",
		name = "Railgun",
		kind = "charged",
		ammo = 1, -- one round, ever. The slot clears itself on the press.
		cooldown = 2.6, -- academic at ammo 1; it is the anti-spam floor if that changes
		chargeTime = 1.15,
		damage = 500,
		range = 640, -- the longest reach in the game: 2/3 of the way across the arena
		knockback = 95, -- well over RAM.MIN_KNOCK_TO_STAGGER: survivors get thrown
		color = Color3.fromRGB(150, 235, 255),
		weight = 6, -- the rarest roll in the crate pool by a factor of four
	},
	--[=[ CANNON (Assets.Weapons.CANNON). The heavy — now a TRIPLE: one press throws
		three balls in a narrow fan that skip along the floor and swat other shells out
		of the air. It still does not steer.

		DAMAGE WAS SPLIT, NOT TRIPLED, AND THE SPLIT IS TIGHTER THAN IT LOOKS. At the
		old 320 a volley would have been 960 — more than the health of any car, an
		instant delete from any range. But 150 each (450 a volley) was still a one-shot
		on the four 400 hp cars, because THE FAN DOES NOT ACTUALLY SEPARATE THE HITS:
		at 5 degrees the outer balls are only 8.7 studs off centre at 100 studs, well
		inside a blast radius, so all three land on the same car out to ~170 studs and
		the spread costs the shooter nothing. Measured, not assumed.

		So the volley is priced as ONE shell: 3 x 110 = 330, within a few points of the
		320 it replaced. What the player gains is the skipping, the flak, and three
		chances to clip a car they half-missed — not a bigger number. Blast came down
		to 12 with it: three overlapping 22-stud blasts covered a quarter of the
		crossing.

		SPREAD is the whole weapon. The three go out at -SPREAD_DEG / 0 / +SPREAD_DEG
		about the aim, and the FAN PLANE rolls at random every shot, so a volley is
		sometimes side-by-side and sometimes stacked — that is the "sway", and it is
		what stops three balls reading as one fat one.

		GRAVITY is what makes "bounces off the floor" mean anything: without it a flat
		shot never meets the ground and the bounce code would never run. At 60 with a
		260-stud/s ball the first touchdown is ~105 studs out, and each bounce keeps
		BOUNCE_RESTITUTION of the reflected velocity, so it skips along the arena floor
		at roughly hull height instead of arcing over everyone like the mortar.

		INTERCEPT: a ball detonates any other player's shell it comes within
		interceptRadius of, and goes up with it. It cannot touch its own volley (same
		owner), which is the only reason three balls flying side by side survive the
		muzzle. ]=]
	CANNON = {
		id = "CANNON",
		name = "Cannon",
		kind = "projectile",
		ammo = 1,
		cooldown = 1.1,
		damage = 110, -- x3 = 330 a volley, against the single 320 shell it replaces
		speed = 260,
		life = 2.6,
		blastRadius = 12,
		knockback = 45, -- per ball; x3 lands near the 130 one shell used to carry
		size = Vector3.new(2.2, 2.2, 2.2), -- a ball, and the hitbox the client draws around
		color = Color3.fromRGB(255, 221, 51),
		weight = 16,

		pellets = 3,
		spreadDeg = 5, -- the fan half-angle: 0 for the middle ball, 5 for the outer two
		gravity = 60, -- studs/s^2. See above: this is what puts the ball on the floor.
		bounces = 3,
		bounceRestitution = 0.78, -- of the reflected velocity kept per skip
		hitsProjectiles = true,
		interceptRadius = 7,
	},
	--[[ FLAMETHROWER (Assets.Weapons.FLAME). Hold to fire. Every tick burns every car
		inside a short cone, so it is the one weapon that punishes tailgating instead
		of rewarding aim. Range is deliberately short: it must never trade with the
		plasma gun at distance. `ammo` counts TICKS, not shots. ]]
	FLAME = {
		id = "FLAME",
		name = "Flamethrower",
		kind = "cone",
		ammo = 70, -- ~5.6 seconds of held fire
		cooldown = 0.08,
		damage = 26, -- per tick per car; ~3.3 chunks/sec on one target
		range = 62,
		coneDeg = 26, -- half-angle off the aim direction
		maxTargets = 3,
		knockback = 6,
		color = Color3.fromRGB(255, 120, 30),
		weight = 20,
	},
	--[=[ MORTAR (Assets.Weapons.MORTAR). The indirect weapon: the shell LOBS, so it is
		the only thing in the game that can reach a car sitting behind a plateau. The
		server casts your aim to find the SPOT you are pointing at and then solves the
		launch velocity that puts the shell on that spot in exactly arcTime seconds —
		so where it lands is what you aimed at, and the only thing you have to learn is
		how far ahead of a moving car to place it. ]=]
	MORTAR = {
		id = "MORTAR",
		name = "Mortar",
		kind = "lob",
		ammo = 3,
		cooldown = 1.4,
		damage = 300, -- 3 chunks, all of it blast: a direct hit is not a special case
		blastRadius = 30, -- the widest in the game; it is aimed at ground, not at cars
		knockback = 110,
		arcTime = 1.35, -- muzzle to landing, whatever the distance
		gravity = 260, -- studs/s^2 on the shell; with arcTime this sets how high it climbs
		range = 320, -- how far along your aim the landing spot may be
		minRange = 34, -- nearer than this it lands here, so you cannot blast your own bumper
		life = 6, -- despawn backstop; the arc always lands well inside it
		size = Vector3.new(2.2, 2.2, 2.2),
		color = Color3.fromRGB(150, 225, 120),
		weight = 14,
	},
	--[=[ TWIN GUNS (Assets.Weapons.DUALGUN). Hold to fire like the plasma gun, but the
		two barrels alternate, each hit is lighter and the cone is wider: this is the gun
		for holding a lane at close range, where the plasma gun is the gun for picking a
		target across the arena. ]=]
	DUALGUN = {
		id = "DUALGUN",
		name = "Twin Guns",
		kind = "hitscan",
		ammo = 36,
		cooldown = 0.07,
		damage = 17, -- ~6 hits per chunk; DPS lands just under the plasma gun's
		range = 190,
		spread = 3.4, -- degrees — wider than GUN, so distance is where it loses
		knockback = 3,
		color = Color3.fromRGB(90, 240, 190),
		weight = 22,
	},
	MINE = {
		id = "MINE",
		name = "Mine",
		kind = "place",
		ammo = 2,
		cooldown = 0.5,
		damage = 260, -- 2.6 chunks
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
		damage = 40, -- chip damage; the freeze is the point
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
		damage = 160, -- 1.6 chunks, split across up to maxTargets
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
-- WEAPON_RIGS — the ART contract for the seven modelled weapons.
--
-- Assets.Weapons.<model> is PRE-NORMALISED (built once from ServerStorage.WeaponSource):
-- the Base's bottom face sits at the rig origin, the rig is centred in X/Z, and the
-- barrel points along -Z — the same direction a car drives and the same direction
-- Hull.WeaponMount looks. So mounting is literally
--     partWorld = mountWorldCFrame * partLocalCFrame
-- with no per-car and no per-weapon correction anywhere. If a model is re-exported,
-- re-run the normaliser rather than adding a fudge angle here.
--
-- ROLES inside each model:
--   Base    bolted to the roof, never moves
--   Turret  yaws to follow your aim
--   Muzzle  recoils / spins when it fires. ABSENT on CANNON and ROCKET, where the
--           Turret itself IS the moving barrel — recoilPart names whichever moves.
--   Muzzle2 optional SECOND barrel (DUALGUN). Poses exactly like Muzzle, so a twin
--           gun needs no new pose code — only `muzzleSpread`, which alternates which
--           barrel a shot leaves from.
--   Ammo    ROCKET only: the missile mesh the client skins the flying shell with.
--
-- `muzzle` is rig-space and is where a shot visually leaves: fx origin, muzzle
-- flash and WeaponController's local prediction all read this one vector.
-- ==========================================================================
Config.WEAPON_RIGS = {
	GUN = {
		model = "GUN",
		muzzle = Vector3.new(0, 3.46, -7.50),
		yawSpeed = 480, -- deg/s the turret tracks your aim
		yawLimit = 105, -- deg either side of the car's nose
		recoilPart = "Muzzle",
		recoilStuds = 0.55,
		recoilPitch = 2.5, -- deg the barrel kicks up
		recoilReturn = 0.10, -- seconds (time constant) back to rest
		spinSpeed = 1100, -- deg/s barrel roll while the trigger is held
		spinDecay = 3.5, -- how fast that roll dies once you stop
		shake = 0.06,
	},
	--[[ RAILGUN. Normalised from Workspace.Railgun (now archived in
		ServerStorage.WeaponSource) by the same pass as the others: base bottom on the
		rig origin, centred in X/Z, barrel down -Z, scale 3.4 BAKED IN — the model ships
		2.98 studs long and a mounted weapon on a 24-stud car wants ten. The muzzle
		below is the measured tip of that barrel, not a guess. ]]
	RAILGUN = {
		model = "RAILGUN",
		muzzle = Vector3.new(0, 2.93, -7.04),
		yawSpeed = 170, -- the slowest swing in the game; it is a sniper, not a turret
		yawLimit = 95,
		recoilPart = "Muzzle",
		recoilStuds = 2.4, -- the hardest kick here, and it earns it once per round
		recoilPitch = 7.0,
		recoilReturn = 0.55,
		spinSpeed = 0,
		spinDecay = 0,
		shake = 0.55,
	},
	CANNON = {
		model = "CANNON",
		muzzle = Vector3.new(0, 4.39, -4.10),
		yawSpeed = 260, -- heavy: it swings slowly, and that is half its character
		yawLimit = 95,
		recoilPart = "Turret", -- no separate muzzle part; the whole barrel kicks
		recoilStuds = 1.15, -- + ~0.70 more from recoilPitch about the rig origin
		recoilPitch = 9.0,
		recoilReturn = 0.34,
		spinSpeed = 0,
		spinDecay = 0,
		shake = 0.16,
	},
	--[[ THE POD CARRIES AN EXTRA 270 DEGREES, BAKED INTO THE ASSET. The normaliser gave
		all four originals the same +90 yaw on the assumption they were laid out facing
		+X; the missile pod was not, so it sat a quarter turn off on the roof while its
		own missile flew straight. It was first corrected +90 (2026-07-31, on sight: "the
		rocket launcher should be tilted 90 degrees counter-clockwise"), which squared it
		up but left it pointing BACKWARDS -- so a further +180 landed on the same day
		("faced 180 degree the opposite way"). Total baked yaw is 270.

		Both passes rotated Base and Turret about Y ABOUT THE RIG ORIGIN, so the pod spins
		in place rather than orbiting the mount, and `Assets.Weapons.ROCKET` carries the
		attribute PodYawFix = 270 to record the running total.

		A RE-EXPORT WILL UNDO THIS. Re-run the normaliser and then re-apply the extra
		270, or the pod comes back sideways. The Ammo mesh was deliberately NOT rotated
		with it -- that is the flying missile, not part of the pod, and its nose is
		already verified against the direction of travel.

		`muzzle` stays as authored: it is a RIG-space point (-Z is forward, where the
		shot goes), not a point on the model, and the pod is square enough in plan that
		the top of it is the top of it either way. ]]
	ROCKET = {
		model = "ROCKET",
		muzzle = Vector3.new(0, 6.00, -0.60), -- missiles leave the TOP of the pod
		yawSpeed = 340,
		yawLimit = 100,
		recoilPart = "Turret",
		recoilStuds = 0.30, -- + ~0.80 more from recoilPitch about the rig origin
		recoilPitch = 14.0, -- the pod rears back rather than kicking straight
		recoilReturn = 0.26,
		spinSpeed = 0,
		spinDecay = 0,
		shake = 0.10,
	},
	FLAME = {
		model = "FLAME",
		muzzle = Vector3.new(0, 3.03, -4.90),
		yawSpeed = 520, -- lightest head, so the snappiest track
		yawLimit = 110,
		recoilPart = "Muzzle",
		recoilStuds = 0.22, -- barely a kick: it is a continuous jet, not a shot
		recoilPitch = 1.2,
		recoilReturn = 0.09,
		spinSpeed = 0,
		spinDecay = 0,
		shake = 0.14, -- the nozzle judders instead
	},
	--[[ MORTAR. Muzzle tip measured at z = -2.21; the point below sits a little ahead
		of it so the launch flash blooms off the mouth of the tube rather than inside
		it. The tube is short and stubby, which is why it is the ONE weapon whose shot
		leaves nearly over the mount. ]]
	MORTAR = {
		model = "MORTAR",
		muzzle = Vector3.new(0, 3.30, -2.60),
		yawSpeed = 230, -- the slowest traverse in the game: siege kit, not a turret
		yawLimit = 90,
		recoilPart = "Turret", -- the tube rears back and the muzzle rides with it
		recoilStuds = 0.85, -- + ~1.0 more from recoilPitch about the rig origin
		recoilPitch = 13.0,
		recoilReturn = 0.40, -- the slowest settle: you watch it reload itself
		spinSpeed = 0,
		spinDecay = 0,
		shake = 0.18,
	},
	--[[ TWIN GUNS. The only rig with a Muzzle2, and `muzzleSpread` is not a guess: the
		two barrels are modelled at x = -0.31 and +0.31, so a shot's flash, tracer and
		claimed origin all land on the barrel that actually kicked. ]]
	DUALGUN = {
		model = "DUALGUN",
		muzzle = Vector3.new(0, 2.43, -3.10),
		muzzleSpread = 0.31, -- barrels sit this far either side of centre; shots alternate
		yawSpeed = 500,
		yawLimit = 110,
		recoilPart = "Muzzle", -- both barrels kick; the housing holds still
		recoilStuds = 0.45,
		recoilPitch = 1.8,
		recoilReturn = 0.08, -- snappy: it has to be back before the next shot
		spinSpeed = 0, -- hex barrels, not a minigun: they buck, they do not roll
		spinDecay = 0,
		shake = 0.09,
	},
}

-- Shared rig behaviour, identical for all seven.
Config.WEAPON_RIG = {
	MOUNT_LIFT = 0.05, -- studs above Hull.WeaponMount, so the base never z-fights the roof
	FIRE_HOLD = 0.22, -- seconds a shot counts as "still firing" (drives spin + shake)
	MAX_RIGS = 12, -- one per car in a full round; a hard ceiling on client cost

	--[[ MOUNTING. A weapon does not appear, it ARRIVES: the whole rig scales up from
		nothing with the house back-out overshoot (the same curve every card in the UI
		pops on), and scales away again when the slot empties. It is the one moment the
		player is told "you have a weapon now" while their eyes are on the road, and a
		model that simply blinks into existence reads as a replication glitch.

		The rig scales about the MOUNT, so a growing gun rises out of the roof rather
		than inflating through it. OVERSHOOT is the fraction past full size the pop
		reaches; 0 makes it a plain ease. START is where it begins -- not 0, because a
		zero-size MeshPart is clamped by the engine and pops visibly at the first
		frame. ]]
	MOUNT_GROW_TIME = 0.34,
	MOUNT_OVERSHOOT = 0.16,
	MOUNT_START_SCALE = 0.06,
	--[[ Faster than the grow on purpose: arriving is an event worth watching, leaving
		is just tidying up, and the slot is usually emptying because you FIRED the last
		shot -- the shot is what should hold the eye, not the disappearing barrel. ]]
	MOUNT_SHRINK_TIME = 0.18,
}

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
	--[[ THE forward-fire dial, and the single source of truth for it. Weapons fire
		STRAIGHT AHEAD: 0 means a shot always leaves along the car's own heading, so you
		steer to aim and nobody can shoot sideways or backwards out of a car.

		STEERING IS AIMING. At 0 — the shipped value — the aim a client sends is not
		read at all: WeaponService.sanitizeAim returns the car's own flat heading and
		WeaponService.shotOrigin drops the shot to hull-centre height so it can hit the
		cars in front of it. Those two are ONE change and must never be split; see the
		comment on shotOrigin for why a flat shot from a roof turret otherwise flies
		over everybody.

		FOUR places obey this one number, and they must never disagree, or a barrel
		points somewhere the bullet does not go:
		  WeaponService.sanitizeAim        the authoritative direction of every shot
		  WeaponRig.setAim                 how far a turret model may swivel
		  WeaponController.firingAxis      the client's prediction and its wire value
		  TurretController.aimFor          which pose a live turret tracks
		Raise it to 25 or 30 to hand aiming back: the turrets swivel again, the cursor
		starts contributing yaw, and AIM_MAX_PITCH_DEG below starts applying. At 0 that
		pitch key is not read. ]]
	AIM_MAX_YAW_DEG = 0,
	BLAST_EDGE_FRACTION = 0.30, -- explosion damage at blastRadius, tapering from 1.0 at centre

	--[[ A shot is DRAWN leaving the barrel and TRAVELS from hull-centre height, and
		the client's only contribution to either is cosmetic: it sends the barrel it
		fired from so every machine's muzzle flash blooms on the gun rather than the
		bonnet. MAX_MUZZLE_OFFSET clamps that claim to somewhere on the sender's own
		car — the worst a forged packet can do is move its own flash.

		AIM_MAX_PITCH_DEG only applies when the yaw cone above is non-zero, i.e. when
		players can aim at all. Damage, ammo, cooldown and every hit are server-decided
		either way: the client contributes a flash position, never an outcome. ]]
	AIM_MAX_PITCH_DEG = 50,
	MAX_MUZZLE_OFFSET = 30, -- studs a claimed muzzle may sit from its own hull centre
	--[[ There WAS a touch/gamepad aim assist here (ASSIST_CONE_DEG / ASSIST_RANGE /
		ASSIST_CONVERGE): with shots leaving a roof barrel on a flat line, a phone
		player could not have hit anything without one. It is deleted rather than
		disabled, because forward-only fire plus a hull-height origin gives every input
		device the same shot — you steer, and what is in front of you is what you hit.
		Nothing reads those keys any more; git history has them if a cone ever returns. ]]

}

-- ==========================================================================
-- AIM — THE TARGETING RETICLE drawn on the ground in front of YOUR car: two rails
-- framing where the weapon you are holding actually reaches, and a bracket that snaps
-- onto whatever is standing in them.
--
-- WHY IT EXISTS. Config.WEAPONS.AIM_MAX_YAW_DEG is 0: every weapon fires straight
-- down the car's nose and STEERING IS AIMING. That rule is only fair if "ahead" is
-- something you can SEE, and a roof turret that never swivels tells you nothing.
--
-- THE SHAPE IS THE TUTORIAL. Each weapon gets its own footprint, so you learn a
-- weapon by looking at the floor rather than by reading its stats: the railgun is a
-- razor line to the far wall, the flamethrower a stubby wedge you have to be on top
-- of, the missiles a wide flare that says "you do not have to be precise". Widths are
-- authored against the thing they describe (a blast diameter, a cone half-angle, a
-- beam that does not scatter) — the derivation is on each entry.
--
-- ==========================================================================
-- WHY EVERY LINE IS DRAWN TWICE — the one non-obvious thing in this table.
--
-- This started as flat Neon slabs and read as raw, and the reason turned out to be
-- the FLOOR. ARENA.FLOOR_COLOR is 238,240,245 — very nearly white — so a glowing
-- line (LightEmission 1) blows out to white and DISAPPEARS on it. Measured by
-- rendering five treatments of the same line against the real floor colour and grid
-- texture: a thin glowing line was invisible, a thin flat one was weak, and the only
-- treatment that read cleanly was a DARK WIDER HALO with a FLAT SATURATED CORE on
-- top. That pairing also survives the dark plateaus and the sand apron, which a
-- single-colour line never can, because one of the two layers always contrasts.
--
-- So: every structural line is two Beams. LightEmission stays 0 on both — do not
-- "make it glow", that is the exact change that broke it.
-- ==========================================================================
--
-- ENTIRELY LOCAL AND ENTIRELY COSMETIC. Controllers/AimController draws it on ONE
-- client for ONE car out of Beams on a single anchored, CanQuery=false host part. It
-- never fires, never damages, and the server is never told it exists.
-- Set ENABLED = false to remove it.
--
-- THESE LENGTHS ARE READABILITY, NOT RANGE. A railgun reaches 640 studs; a 640-stud
-- reticle would cover a third of the arena and read as noise. Each `length` is the
-- shortest run that still tells the truth about the weapon's REACH RELATIVE TO THE
-- OTHERS, so the ordering (flame < cannon < gun < railgun) is what is load-bearing,
-- not the absolute numbers. The LOCK is what tells you a shot connects.
-- ==========================================================================
Config.AIM = {
	ENABLED = true,
	FOLDER = "AimFx", -- workspace folder; created on demand
	HOST = "AimRoot", -- the ONE part every Attachment hangs off, parked at the origin
	-- with an identity CFrame, so an Attachment's CFrame IS its world CFrame.
	CARS_FOLDER = "Cars", -- SpawnService's; scanned for the lock

	-- ======================================================================
	-- geometry
	-- ======================================================================
	--[[ Ground samples down the lane, and the ONLY raycasts this controller does: one
		per station, shared by both rails AND the centre line, with tick positions
		interpolated between them for free. Six is enough to follow a plateau skirt
		without the rails visibly faceting. ]]
	STATIONS = 6,
	NOSE_FRACTION = 0.62, -- fraction of hull LENGTH ahead of centre the reticle starts
	--[[ The core sits a hair above the halo so the two coplanar ribbons cannot fight
		for depth order — without the bias they strobe against each other as you drive. ]]
	LIFT = 0.14,
	CORE_LIFT_BIAS = 0.04,
	PROBE_UP = 26, -- ray starts this far above the sample, so a crest cannot be missed
	PROBE_DOWN = 240,

	-- ======================================================================
	-- the line primitive — see the header for why there are two layers
	-- ======================================================================
	RAIL_WIDTH = 1.5,
	RAIL_HALO_WIDTH = 3.6,
	HALO_DARKEN = 0.16, -- core colour x this = halo colour, so the halo is the weapon's
	-- own hue at near-black rather than a neutral grey that muddies it
	THIN_WIDTH = 0.85, -- ticks, centre dots, corner turns: secondary marks, no halo

	--[[ Idle is a hint you can see past; LOCK is a car standing in the reticle. The
		contrast between the two IS the feature, so these are authored as pairs. ]]
	CORE_TRANSPARENCY = 0.10,
	LOCK_CORE_TRANSPARENCY = 0.0,
	HALO_TRANSPARENCY = 0.46,
	LOCK_HALO_TRANSPARENCY = 0.30,
	THIN_TRANSPARENCY = 0.38,
	LOCK_THIN_TRANSPARENCY = 0.14,

	--[[ Lerp of the core colour toward white while locked. DELIBERATELY SMALL: the
		colour IS the weapon's name, and at 0.5 a locked railgun and a locked cannon
		were the same pale wash. The lock is read off the opacity jump, the pulse rate
		and the bracket — the brighten is a top note, not the signal. ]]
	LOCK_BRIGHTEN = 0.28,

	-- ======================================================================
	-- the dissolve — there is NO cap bar at the far end
	-- ======================================================================
	--[[ Rails hold full opacity to this fraction and then ramp to nothing, so the
		reticle ends by running out rather than by hitting a wall. The hard bar the
		first version drew was the single most "decal" thing about it. RANGE_MARK sits
		exactly here: it is the last solid thing you see, so it reads as the effective
		range without needing a line across the mouth. ]]
	FADE_START = 0.58,

	-- ======================================================================
	-- instrument marks — sparse on purpose. A targeting display is mostly empty.
	-- ======================================================================
	TICKS = { 0.30 }, -- lane fractions carrying a short inward tick off each rail
	TICK_LENGTH = 0.30, -- ...as a fraction of the local HALF-width
	RANGE_MARK_LENGTH = 0.55, -- the longer pair at FADE_START
	CORNER_LENGTH = 0.42, -- the inward turn at the near end, fraction of near half-width
	CENTRE_DOTS = 4, -- dotted centre line: where the shot itself goes
	CENTRE_DOT_FRACTION = 0.42, -- fraction of each dot's slot that is dot, rest is gap

	-- ======================================================================
	-- the target bracket — four corners that snap around a locked car
	-- ======================================================================
	BRACKET_PAD = 3.0, -- studs outside the target's hull footprint
	BRACKET_ARM = 0.34, -- fraction of each half-extent one arm of the L covers
	BRACKET_WIDTH = 1.6,
	BRACKET_HALO_WIDTH = 3.4,
	--[[ The corners start this much further out and cinch in as the lock lands. It is
		the whole difference between a bracket that APPEARS and one that ACQUIRES. ]]
	BRACKET_POP = 1.9,
	ACQUIRE_RATE = 16,

	-- ======================================================================
	-- motion — all manual exp damping, no TweenService (house rule)
	-- ======================================================================
	FADE_RATE = 14, -- picking a weapon up / running it dry
	LOCK_RATE = 22, -- faster: a lock has to land on the beat you line the shot up
	FLASH_DECAY = 5.5, -- the one-shot tick flash when a lock is first acquired
	FLASH_BOOST = 0.5, -- how much opacity that flash adds at full

	-- One sine at two speeds. The change of RATE is what you read, not the amplitude.
	IDLE_PULSE_HZ = 1.1,
	IDLE_PULSE = 0.06,
	LOCK_PULSE_HZ = 5.5,
	LOCK_PULSE = 0.1,

	-- ======================================================================
	-- the lock test
	-- ======================================================================
	--[[ Point-in-shape against every other car's hull centre, padded by roughly half a
		car so a target straddling the edge still counts — the reticle is a promise
		about a SHOT, and a shot has a body to hit. ]]
	LOCK_PAD = 5,
	MAX_CARS_SCANNED = 16, -- a full round is 12; this is the runaway-spawn backstop

	--[[ Hard ceilings on instances. A full lane is 24 rail + 2 tick + 2 range + 2
		corner + 4 centre = 34, plus 16 for the bracket = 50. Past the cap a line is
		simply skipped, which is a far better failure than allocating every frame. ]]
	MAX_BEAMS = 64,
	RING_STATIONS = 12, -- for a `ring` shape, which has no lane to divide

	--[[ Anything held that is not listed below still gets a reticle. A weapon with no
		footprint would read as broken next to five that have one. ]]
	DEFAULT = { length = 130, near = 12, far = 20 },

	SHAPES = {
		--[[ PLASMA GUN. `spread` is 0 and must stay 0 (see POWERUPS.GUN), so the rails
			run parallel and barely wider than a car — a beam that does not scatter
			either hits what is between them or misses. ]]
		GUN = { length = 150, near = 10, far = 10 },

		--[[ RAILGUN. The longest run in the game and the narrowest: it reaches 640 and
			deletes whatever it finds, so this is a sight line, not an area. You line a
			car up between the rails during the 1.15s wind-up — that IS the weapon. ]]
		RAILGUN = { length = 280, near = 6, far = 6 },

		--[[ CANNON. The rails splay out to its own blast: `far` is 2 x blastRadius (22),
			so the mouth is literally the crater the shell makes. Being a car-width off
			still hits, and the flare is what says so. ]]
		CANNON = { length = 130, near = 14, far = 44 },

		--[[ MISSILES. The widest flare by far, and deliberately: the shell HOMES inside
			a 55-degree cone, so precision is not what this weapon asks for. Rails that
			obviously cover more than you could aim at are the honest picture of that. ]]
		ROCKET = { length = 170, near = 18, far = 78 },

		--[[ FLAMETHROWER. The one shape drawn to true scale, because its whole character
			is that it is SHORT: length is the def's range (62) exactly, and `far` is
			2 x range x tan(coneDeg 26) = ~60, the real mouth of the cone. It looks like
			a weapon you have to tailgate with, which is what it is. ]]
		FLAME = { length = 62, near = 10, far = 60 },

		--[[ TWIN GUNS. The plasma gun's lane, shorter and splayed: `far` is
			2 x length x tan(spread 3.4 deg) = ~17, so the mouth is the real scatter at
			the far end of the drawn run. It reads as "the same gun, but you have to be
			closer", which is exactly the trade. ]]
		DUALGUN = { length = 140, near = 10, far = 24 },

		--[[ MORTAR. Out-reaches the cannon and lands in a bigger hole, so it is drawn
			longer and wider than the cannon on both counts: `far` is 2 x blastRadius
			(30) — the crater, again — and the length says "further than the cannon,
			nowhere near the railgun". The shell ARCS onto the spot, so the rails are a
			statement of reach, not of the flight path; the ring FxController paints on
			the landing spot is what tells you where it actually comes down. ]]
		MORTAR = { length = 190, near = 14, far = 60 },

		--[[ The three defined-but-unrolled powerups (see PowerupDefs.ORDER). They cost
			nothing while nothing rolls them, and putting an id back in that list must
			never leave a weapon as the only one with no reticle. ]]
		MINE = { length = 30, near = 16, far = 16, behind = true }, -- it drops out the BACK
		FREEZE = { length = 120, near = 12, far = 28 }, -- far = 2 x blastRadius 14
		ZAP = { ring = 46 }, -- an aoe centred on you: a ring, not a lane
	},
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
	--[[ The ground pickup is a floating BANKNOTE, not a coin: PickupService skins a thin
		panel with the same cash-bundle art the shop and the HUD counter use, so what you
		drive over and what ticks up on the rail are visibly the one currency. `color` is
		the edge/glow tint behind that art, which is why it is cash green rather than the
		crown's gold — the two pickups must never be mistaken for each other mid-drive. ]]
	MONEY = {
		value = 12,
		maxActive = 14,
		spawnInterval = 2.5,
		radius = 5.5,
		bobHeight = 0.7,
		bobSpeed = 3.0,
		spinSpeed = 170,
		color = Color3.fromRGB(88, 204, 108),
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
	SPAWN_INSET = 64.5, -- keep pickups this far from the walls
	MIN_SEPARATION = 30.1,
	FLOAT_HEIGHT = 6.45, -- studs from ground to pickup centre, before bobbing
	-- Idle bob/spin is server-driven, so it replicates. These bound that cost on mobile.
	ANIM_HZ = 20, -- idle animation update rate (not the render rate)
	ANIM_RADIUS = 559, -- skip animating pickups with no player car within this many studs
}

-- ==========================================================================
-- ECONOMY
-- ==========================================================================
Config.ECONOMY = {
	MONEY_PER_CROWN = 6,
	MONEY_PER_KILL = 25,
	MONEY_PER_PLACEMENT = { 300, 180, 120, 80 }, -- 1st..4th
	MONEY_PARTICIPATION = 40,
	GEM_DROP_CHANCE = 0.05, -- per crown banked
	GEM_DROP_AMOUNT = 1,
	--[[ Modes that place on POINTS (juggernaut, elimination) bank no crowns at all,
		so without this their whole payout would be kills + placement. Priced between
		a crown and a kill: a juggernaut takedown (6 points) is worth about a kill. ]]
	MONEY_PER_POINT = 18,
}

-- ==========================================================================
-- DAILY — the 7-day login track. Boundaries are UTC days, not a rolling 24h
-- cooldown: a cooldown drifts later every day until the reward walks out of the
-- player's play window, and "daily" already means a calendar day to a kid.
-- ==========================================================================
Config.DAILY = {
	MISS_GRACE_DAYS = 1, -- a gap of 1 or 2 UTC days keeps the streak; 3+ restarts at day 1
	SPIN_MONEY = 400, -- what one banked spin pays while MonetizationService.addSpins is absent
	CAR_OWNED_GEMS = 20, -- day 7 payout once that car is already owned
	REWARDS = {
		{ day = 1, kind = "money", amount = 250, label = "+250 Money" },
		{ day = 2, kind = "money", amount = 500, label = "+500 Money" },
		{ day = 3, kind = "gems", amount = 5, label = "+5 Gems" },
		{ day = 4, kind = "money", amount = 1000, label = "+1,000 Money" },
		{ day = 5, kind = "spins", amount = 3, label = "+3 Spins" },
		{ day = 6, kind = "gems", amount = 15, label = "+15 Gems" },
		{ day = 7, kind = "car", carId = "blacksuv", label = "Black SUV" },
	},
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
	DISPLAY_ORDER = { HUD = 5, LOBBY = 6, LUCKY = 12, BOUNTY = 13, DEATH = 20, RESULTS = 30, GARAGE = 40, NOTIF = 10000 },
}

--[[ ART — image ids that more than one place has to agree on.

	MONEY especially: the rail counter, the wallet chips, the shop packs, the daily card
	and the thing you drive over on the arena floor are ONE currency, and a player only
	learns that if they are literally one drawing. Every id here is already in the place
	(they ship with the Alternate kit's cash rows), so nothing new has to be uploaded or
	moderated. Anything used in exactly one module still belongs in that module. ]]
Config.ART = {
	MONEY = "rbxassetid://76420323803161", -- banded cash bundle: THE currency mark
	--[[ The three pack tiers, in the SAME order the kit's own Store.Cash columns draw them
		(column1.1 / column1.2 / column2.1). Keeping catalog art and authored art identical
		is why the shop can restore the kit's rows instead of regenerating them. ]]
	MONEY_WALLET = "rbxassetid://84369068204476", -- small pack
	MONEY_BAG = "rbxassetid://107981444977206", -- medium pack
	MONEY_PILE = "rbxassetid://123388541068357", -- large pack
	MONEY_BUNDLE = "rbxassetid://100008386147111", -- outline-free bundle, the 2x Money pass
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
	    score and selling score makes the leaderboard pay-to-win. Money is progression and
	    is safe to multiply. Please do not "complete the set" by adding one.
]]
Config.MONETIZATION = {
	VIP_MONEY_MULTIPLIER = 1.5,
	DOUBLE_MONEY_MULTIPLIER = 2,
	PREMIUM_MONEY_MULTIPLIER = 1.25, -- Roblox Premium, stacks on top
	MAX_TOTAL_MONEY_MULTIPLIER = 6, -- ceiling so stacked perks cannot break the economy
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

	--[[ The three money packs each have their OWN kit art (wallet -> bag -> pile), so the
		ladder is legible before a single number is read. The `icon` names map to
		ShopUI.ICONS; a pack that reused one image for all three would make the tiers look
		identical at a glance and put all the work on the price. ]]
	MONEY_S = { id = 0, name = "Wallet of Money", grant = "money", amount = 2500, robux = 29, icon = "moneyWallet" },
	MONEY_M = { id = 0, name = "Bag of Money", grant = "money", amount = 12000, robux = 99, icon = "moneyBag" },
	MONEY_L = { id = 0, name = "Pile of Money", grant = "money", amount = 40000, robux = 249, icon = "moneyPile", tag = "BEST VALUE" },

	SPINS_5 = { id = 0, name = "5 Lucky Spins", grant = "spins", amount = 5, robux = 49, icon = "spin" },
	SPINS_25 = { id = 0, name = "25 Lucky Spins", grant = "spins", amount = 25, robux = 199, icon = "spin" },

	EXTRA_LIFE = { id = 0, name = "Extra Life", grant = "extraLife", amount = 1, robux = 19, icon = "heart" },
}

Config.PASSES = {
	DOUBLE_MONEY = { id = 0, name = "2x Money", perk = "doubleMoney", robux = 199, icon = "money",
		blurb = "Earn double money forever!" },
	VIP = { id = 0, name = "VIP", perk = "vip", robux = 399, icon = "crown",
		blurb = "1.5x money, an extra life, VIP car." },
	STARTER_PACK = { id = 0, name = "Starter Pack", perk = "starterPack", robux = 99, icon = "gift",
		blurb = "10,000 money and the Police Car.", onceOnly = true,
		grantMoney = 10000, grantCar = "police" },
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
		{ key = "MONEY", label = "Money", source = "PRODUCTS", filter = "money" },
		{ key = "PASSES", label = "Perks", source = "PASSES" },
		{ key = "CARS", label = "Cars", source = "CARS" },
		{ key = "LIMITED", label = "Limited", source = "LIMITED" },
	},
	LIMITED_ROTATION_SECONDS = 86400,
	LIMITED_POOL = { "GEMS_M", "MONEY_M", "SPINS_25", "STARTER_PACK" },
	LIMITED_DISCOUNT = 0.25,
}


-- ==========================================================================
-- TEST — Studio-only. Consumers MUST gate on RunService:IsStudio() at point of use.
-- ==========================================================================
Config.TEST = {
	--[[ The round timings used to live here (MIN_PLAYERS / SHORT_LOBBY / SHORT_MATCH).
		They are Config.ROUND.STUDIO now, so the live pacing and the Studio pacing sit
		side by side in one table and MatchState is the only thing that picks between
		them -- there is no second place to keep in sync. ]]
	GRANT_ALL_CARS = false,
	START_MONEY = 0,

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

	--[[ Pin the map rotation to one id from CrashCore.Maps ("sandbowl", "frostbite",
		"rooftops", "speedway") so a layout can be iterated on without waiting for the
		rotation to come back round. nil = rotate normally. Read by ArenaService only,
		behind RunService:IsStudio(). ]]
	FORCE_MAP = nil,
	--[[ Pin the game mode to one id from Config.MODES.ROTATION ("crowns",
		"deathmatch", "teams", "juggernaut", "elimination") so one ruleset can be
		iterated on without waiting for the rotation. nil = rotate normally.
		Read by ModeService only, behind RunService:IsStudio(). ]]
	FORCE_MODE = nil,

	--[[ "/test" — the weapon carousel (Services/WeaponTestService). Cycles you through
		every modelled weapon on this timer with its ammo kept topped up, so each turret
		can be watched mount, swivel and recoil inside one round. The command itself is
		gated on Studio-or-place-owner, NOT on this key.
		AUTOSTART is the fallback for TextChatService setups that never deliver
		Player.Chatted to the server: flip it and the carousel runs with no command at
		all. Studio only, and read behind RunService:IsStudio() at the point of use. ]]
	WEAPON_CYCLE_SECONDS = 10,
	WEAPON_CYCLE_AUTOSTART = false,

	--[[ "/test game" — the endless round (MatchService.setEndless, commanded through
		WeaponTestService). A round starts at once and never finishes: the lobby stops
		waiting for players, the match clock stops running out, and nobody is ever out
		of lives. This key is the same Chatted fallback WEAPON_CYCLE_AUTOSTART is — flip
		it and the server opens straight into an endless round with no command typed.
		Studio only, read behind RunService:IsStudio() at the point of use. ]]
	ENDLESS_ROUND = false,
}

-- Convenience: id -> car def
Config.CARS_BY_ID = {}
for _, car in ipairs(Config.CARS) do
	Config.CARS_BY_ID[car.id] = car
end

return Config
