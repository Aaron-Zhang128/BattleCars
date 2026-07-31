--[[ FxController — the juice layer. Every visible / audible reaction on the client.

	PURPOSE
		Renders what the SERVER says happened (WeaponFx), decorates server-spawned
		projectiles, and adds the purely local driving feedback that makes the cars
		feel physical: skid marks, boost trails, wind streaks, landing thumps, state
		shells (frozen / shielded / spawn-protected) and world nametags.
		Nothing here is authoritative. No damage, no hit decisions, no state writes.

	DATA FLOW
		WeaponFx (S->C, kind, payload)      -> HANDLERS[kind]                      (§7)
		WeaponFx "HIT" (S->C, one per damage event) -> victim highlight flash + damage pop (§7b)
		WeaponController.predictFire(...)   -> muzzle flash + launch sound, recorded
		                                       so the server echo does not double it (§6)
		Workspace.Projectiles ChildAdded    -> rocket trail / mine glow decoration  (§8)
		Workspace.Cars ChildAdded/Removed   -> nametags + through-wall highlights (§16)
		                                       + state shells (§10)
		ChassisController / InputController  -> per-frame local driving fx           (§9)
		CameraController.shake(...)          <- rams, nearby blasts, hard landings, stagger

	CAR MODEL FACTS THIS FILE DEPENDS ON (CarFactory contract)
		* Hull is Transparency = 1 — a pure physics body. NEVER tint or adorn the Hull:
		  the player would see nothing. All car-hugging visuals size and follow
		  Body/Shell (fallback: any Body part, last resort the Hull).
		* Cosmetics carry a WeldConstraint child named "Weld" and are CanQuery = false.
		  We only READ their Size/CFrame; we never touch the welds.
		* Hulls ARE raycast-queryable, so every ground probe excludes Workspace.Cars
		  and uses RespectCanCollide = true (arena decorations are CanCollide = false
		  but still queryable, and a skid must land on the real floor, not a pad chevron).

	ATTRIBUTES  reads Player: Crowns, Shielded · Car: Hp, MaxHp, CarId, OwnerUserId,
	            BoostUntil, FrozenUntil, Invuln, StaggerUntil. Writes NOTHING.
	REMOTES     WeaponFx (S->C) only.
	FOLDERS     creates Workspace.Fx at runtime. Every fx part is Anchored, CanCollide
	            = false, CanQuery = false, CanTouch = false, Massless, and carries BOTH a
	            sweeper entry AND a task.delay hard-kill, so nothing can leak even if a
	            frame loop dies.
	PERF        every pool is hard-capped (CAPS). Distance culling sits behind
	            FX.CULL_ENABLED and is currently OFF — nothing is dropped, skipped or
	            hidden for range, whatever the DISTANCE tunables say. ALL looped motion is
	            manual sine / lerp math on ONE RenderStepped — no TweenService anywhere.
	PUBLIC      FxController.predictFire(powerupId, origin, dir) — WeaponController's
	            feel-only prediction seam.
	INIT ORDER  last: after InputController, ChassisController, CameraController, WeaponController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local sharedFolder = core:WaitForChild("Shared")
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local PowerupDefs = require(sharedFolder:WaitForChild("PowerupDefs"))
local WeaponRig = require(sharedFolder:WaitForChild("WeaponRig"))
local VfxKit = require(sharedFolder:WaitForChild("VfxKit"))

local UI = Config.UI
local ATTR = Config.ATTR
local CAR = ChassisSpec.ATTR
local POWERUPS = Config.POWERUPS

local player = Players.LocalPlayer

local FxController = {}

-- ==========================================================================
-- § 1) SFX — every sound in one place. Built-in rbxasset only, nothing to upload.
--      pitch = {min,max}; each instance rolls inside the range so repeats never
--      sound robotic. Swap assets HERE and the whole game changes voice.
-- ==========================================================================
local SFX = {
	GUN = { asset = "rbxasset://sounds/metal.ogg", volume = 0.26, pitch = { 1.75, 2.05 }, life = 0.6 },
	LAUNCH = { asset = "rbxasset://sounds/bass.wav", volume = 0.55, pitch = { 0.72, 0.88 }, life = 1.4 },
	WHOOSH = { asset = "rbxasset://sounds/bass.wav", volume = 0.30, pitch = { 1.10, 1.30 }, life = 1.4 },
	FREEZE = { asset = "rbxasset://sounds/snap.mp3", volume = 0.45, pitch = { 0.80, 0.95 }, life = 0.8 },
	MINE_ARM = { asset = "rbxasset://sounds/electronicpingshort.wav", volume = 0.42, pitch = { 0.82, 0.94 }, life = 0.9 },
	ZAP = { asset = "rbxasset://sounds/snap.mp3", volume = 0.60, pitch = { 1.25, 1.55 }, life = 0.8 },
	SHIELD_UP = { asset = "rbxasset://sounds/electronicpingshort.wav", volume = 0.40, pitch = { 1.18, 1.32 }, life = 0.9 },
	SHIELD_POP = { asset = "rbxasset://sounds/snap.mp3", volume = 0.55, pitch = { 0.66, 0.82 }, life = 0.9 },
	IMPACT = { asset = "rbxasset://sounds/collide.mp3", volume = 0.85, pitch = { 0.52, 0.70 }, life = 1.6 },
	RAM = { asset = "rbxasset://sounds/metal.ogg", volume = 0.70, pitch = { 0.58, 0.78 }, life = 1.2 },
	BOOST = { asset = "rbxasset://sounds/bass.wav", volume = 0.45, pitch = { 0.98, 1.12 }, life = 1.4 },
	LAND = { asset = "rbxasset://sounds/collide.mp3", volume = 0.38, pitch = { 0.86, 1.06 }, life = 1.2 },
	CANNON = { asset = "rbxasset://sounds/collide.mp3", volume = 0.95, pitch = { 0.40, 0.52 }, life = 1.8 },
	FLAME = { asset = "rbxasset://sounds/bass.wav", volume = 0.26, pitch = { 1.45, 1.70 }, life = 1.0 },
	-- Pitched under the cannon: the mortar is the heaviest thing on the roof.
	MORTAR = { asset = "rbxasset://sounds/collide.mp3", volume = 0.95, pitch = { 0.30, 0.40 }, life = 2.0 },
	DUALGUN = { asset = "rbxasset://sounds/metal.ogg", volume = 0.22, pitch = { 1.95, 2.30 }, life = 0.5 },
	--[[ The only TWO 2D sounds in this table. Everything else here is a thing that
		happened in the world and is heard from where it happened; these two are a
		message to YOU about a hit YOU landed. A positional ping fired from the car you
		just shot would fade out exactly when you are furthest from it, which is the
		moment you most need telling that the shot connected. ]]
	HIT = { asset = "rbxasset://sounds/electronicpingshort.wav", volume = 0.30, pitch = { 1.55, 1.72 }, life = 0.6 },
	KO = { asset = "rbxasset://sounds/snap.mp3", volume = 0.80, pitch = { 0.60, 0.70 }, life = 1.0 },
	--[[ The plasma beam's hum. LOOPED onto the ray's own host part (see plasmaBeam), so
		it starts with the beam, follows the barrel and dies with the rig — a held weapon
		wants one continuous sound, never fourteen one-shots a second. ]]
	PLASMA = { asset = "rbxasset://sounds/bass.wav", volume = 0.34, pitch = { 1.28, 1.28 }, life = 1.4 },
	--[[ RAILGUN. The charge is LOOPED onto the wind-up rig and its PlaybackSpeed is
		driven per frame from the same 0..1 as the orb, so the pitch climbing IS the
		countdown — the pitch pair here is only its starting value. The shot is pitched
		under the mortar, which was the heaviest thing in the game until now. ]]
	RAIL_CHARGE = { asset = "rbxasset://sounds/bass.wav", volume = 0.42, pitch = { 0.55, 0.55 }, life = 1.4 },
	RAIL_SHOT = { asset = "rbxasset://sounds/collide.mp3", volume = 1.0, pitch = { 0.24, 0.30 }, life = 2.2 },
	RAIL_CRACK = { asset = "rbxasset://sounds/snap.mp3", volume = 0.85, pitch = { 1.05, 1.25 }, life = 0.9 },
}

-- Prediction sound per powerup id (see § 6). Kept beside SFX on purpose.
local PREDICT_SFX = {
	-- GUN is absent on purpose: the beam rig owns a LOOPED hum, so a per-press sound
	-- would rattle fourteen times a second underneath it.
	ROCKET = SFX.LAUNCH,
	FREEZE = SFX.FREEZE,
	MINE = SFX.MINE_ARM,
	ZAP = SFX.ZAP,
	SHIELD = SFX.SHIELD_UP,
	CANNON = SFX.CANNON,
	FLAME = SFX.FLAME,
	MORTAR = SFX.MORTAR,
	DUALGUN = SFX.DUALGUN,
}

--[[ Minimum seconds between sounds for a powerup id, for the HOLD weapons only.
	The flamethrower fires about twelve times a second and one sample per tick is a
	chainsaw; the plasma gun's tick is short and sharp enough to survive untouched.
	Both the local prediction and the server echo route through this same gate, so
	throttling can never let the two of them double up. ]]
local SOUND_GAP = {
	FLAME = 0.22,
	-- Twin guns fire ~14 times a second and the barrels alternate: one report per
	-- PAIR is what makes it read as two barrels rather than as a buzz.
	DUALGUN = 0.11,
}

-- ==========================================================================
-- § 2) CAPS — hard ceilings. Mobile budget: ~10 cars, dozens of pickups on screen.
--      Exceeding a cap destroys that pool's OLDEST member, never the newest event.
-- ==========================================================================
local CAPS = {
	DEFAULT = 16,
	SKID = 48,
	DEBRIS = 40,
	SPARK = 40,
	TRACER = 28, -- travelling plasma bolts, ~4 in the air per firing player
	PLASMA = 24, -- plasma discs: one at the muzzle and one at the impact, per shot
	FLAME = 24,
	BOLT = 24,
	PUFF = 24,
	BOOST = 20,
	WIND = 10,
	RING = 14, -- a blast now draws a shockwave ring on top of the fireball ring
	FLASH = 18, -- the plasma gun alone spends two of these a shot at 11 shots/s
	SOUND = 18,
	SHELL = 16, -- state shells are NOT pooled; this caps how many may exist at once
	TAG = 12,
	-- Roblox stops rendering Highlights past ~31 on screen. A 12-car round is far
	-- under that; this ceiling keeps a runaway spawn from silently crossing it.
	HIGHLIGHT = 16,
	-- Floating damage numbers. Enforced by the pop list itself, not by the tracked-pool
	-- sweeper: a pop has to re-anchor to a moving car every frame, so it owns its host.
	POP = 10,
}

-- ==========================================================================
-- § 3) FX — tunables. No magic numbers below this block.
-- ==========================================================================
local FX = {
	FOLDER = "Fx",
	CARS_FOLDER = "Cars",
	PROJECTILE_FOLDER = "Projectiles",

	--[=[ MORTAR. The landing RING is the whole point of the entry: the shell arrives
		from above, so the only warning anyone gets is the ring it paints on the ground
		the moment it leaves the tube. It CLOSES IN over the flight, which reads as
		"incoming" instead of as "something already exploded here". ]=]
	MORTAR = {
		FLASH_RADIUS = 6.5,
		FLASH_LIFE = 0.16,
		LIGHT = 26,
		SMOKE = 7,
		SMOKE_SCALE = 1.8,
		MUZZLE_DISC = 7.5,
		MUZZLE_DISC_LIFE = 0.16,
		SHAKE_RADIUS = 46,
		SHAKE_INTENSITY = 1.15,
		SHAKE_TIME = 0.30,
		MARK_THICKNESS = 0.4,
		MARK_TRANSPARENCY = 0.42,
		MARK_START_SCALE = 1.5, -- the ring starts this much wider and shrinks onto the spot
		MARK_LIFE = 1.3, -- fallback when a payload carries no flight time
	},

	--[=[ VFX — which authored particle pack (ReplicatedStorage.VFXs, wrapped by
		Shared.VfxKit) each event borrows, and how hard.

		SCALE is the dial that matters: every pack was authored as an aura for a
		4-stud pet, and the cars here are 24 studs. RATE multiplies the authored
		emission rate, COUNT multiplies how much a one-shot burst throws, ONLY/SKIP
		pick layers out of a pack by name — which is how the radioactive pack becomes
		plain engine smoke and the diamond aura becomes a ring of sparks.

		A pack that is missing from the folder simply does not draw. Every one of these
		sits ON TOP of hand-built geometry that is still the real effect. ]=]
	VFX = {
		-- events
		FLAME = { PACK = "FIRE", SCALE = 0.9, RATE = 2.4, SPEED = NumberRange.new(70, 115), SPREAD = Vector2.new(11, 11), DRAG = 1.2, LIGHT = 28, BRIGHTNESS = 2.4 },
		BLAST = { PACK = "FIRE", SCALE = 1.0, COUNT = 3.0, SPEED = NumberRange.new(16, 54), SPREAD = Vector2.new(180, 180) },
		RAM = { PACK = "Push", SCALE = 1.6, COUNT = 1.6 },
		ZAP = { PACK = "LIGHTNING", SCALE = 1.4, COUNT = 2.0 },
		PLASMA_HIT = { PACK = "LIGHTNING", SCALE = 0.32, COUNT = 0.5 },
		FREEZE = { PACK = "ICE", SCALE = 1.3, COUNT = 2.0 },
		SHIELD_POP = { PACK = "DiamondAura", SCALE = 0.4, COUNT = 2.4 },
		--[[ The railgun is the DIAMOND weapon. ONLY = Star for the same reason the shield
			uses it: that pack's other layers are 45-53 stud blurs authored for a pet aura,
			and one of those on a car roof fills the screen. ]]
		RAIL_CHARGE = { PACK = "DiamondAura", SCALE = 1.1, RATE = 3.0, ONLY = { "Star" } },
		RAIL_HIT = { PACK = "DiamondAura", SCALE = 0.9, COUNT = 3.5, ONLY = { "Star" } },
		-- pickup / lucky pops, named by the SERVER in payload.vfx (see PickupService)
		POP = {
			GOLD = { PACK = "GOLD", SCALE = 0.3, COUNT = 1.8 },
			CONFETTI = { PACK = "CONFETTI", SCALE = 1.6, COUNT = 1.6 },
			STAR = { PACK = "STAR", SCALE = 1.5, COUNT = 1.6 },
		},
		BLAST_MIN_RADIUS = 10, -- an IMPACT smaller than this is a pickup pop, not a bomb
		-- states, worn by the car itself
		FROST = { PACK = "ICE", SCALE = 2.0, RATE = 0.6, ONLY = { "Snowflake" } },
		SHIELD = { PACK = "DiamondAura", SCALE = 1.4, RATE = 1.0, ONLY = { "Star" } },
		JUGGERNAUT = { PACK = "ADMIN", SCALE = 1.1, RATE = 0.5 },
		BOOST = { PACK = "RainbowAura", SCALE = 0.9, RATE = 1.0, ONLY = { "Star", "Flare" } },
		BURNING = { PACK = "RADIOACTIVE", SCALE = 1.7, RATE = 0.55, ONLY = { "Smoke" } },
		BURNING_HP = 0.34, -- under this fraction of max hp a car trails smoke
		AURA_LIFT = 1.8, -- studs above the body an aura emits from
	},
	SHELL_PART = "Shell", -- CarFactory's main visible body block, under Body/

	-- Master switch for every distance gate below. false = render everything, at any
	-- range: no dropped events, no skipped debris, no distance-hidden shells or tags.
	-- Flip to true to restore the perf culling; the ranges below are kept for that.
	CULL_ENABLED = false,
	CULL_DISTANCE = 420, -- events farther than this from the camera are dropped entirely
	DETAIL_DISTANCE = 190, -- beyond this, skip debris/sparks and keep the readable core
	HARD_KILL_GRACE = 0.75, -- task.delay backstop past an fx's own lifetime
	GRAVITY = Vector3.new(0, -80, 0),
	SOUND_RANGE = 260,
	SOUND_LIFE = 2.0,
	SOUND_HOLDER_SIZE = Vector3.new(0.2, 0.2, 0.2),
	STATE_INTERVAL = 0.1, -- car state (frozen/shield/invuln/hp) sweep, 10 Hz

	FLASH = { START = 0.35, END = 2.0, TRANSPARENCY = 0.15, LIGHT_BRIGHTNESS = 3.2 },
	RING = { THICKNESS = 0.6, START = 0.3, END = 2.4, TRANSPARENCY = 0.25 },

	DEBRIS = {
		CAT = "DEBRIS",
		MATERIAL = Enum.Material.SmoothPlastic,
		SIZE = { 0.45, 1.35 },
		LIFE = { 0.45, 0.85 },
		SPEED = { 14, 44 },
		UP = { 0.35, 1.0 },
		SPREAD = 1.4,
		SPIN = 9,
		LONG = 1.0,
		GRAVITY = true,
	},
	SPARK = {
		CAT = "SPARK",
		MATERIAL = Enum.Material.Neon,
		SIZE = { 0.16, 0.44 },
		LIFE = { 0.10, 0.24 },
		SPEED = { 30, 80 },
		UP = { 0.05, 0.9 },
		SPREAD = 1.0,
		SPIN = 0,
		LONG = 3.0, -- stretched along travel so sparks read as slivers
		GRAVITY = false,
	},
	PUFF = {
		CAT = "PUFF",
		SIZE = { 0.9, 2.1 },
		LIFE = { 0.24, 0.42 },
		SPEED = { 5, 16 },
		GROW = 2.4,
		SPREAD = 1.2,
		TRANSPARENCY = 0.35,
		COLOR = Color3.fromRGB(196, 192, 186),
	},

	--[=[ PLASMA BOLT — the TWIN GUNS' slug. (The plasma GUN itself pours a continuous
		ray now; see BEAM below. Keeping a discrete slug on one and a held ray on the
		other IS the difference between the two plasma weapons.)
		It is HITSCAN — the server decided the hit before any of this draws — so the
		visual is free to travel, and it should: an instant line is unreadable from
		another car, which is what the old hairline tracer was.

		What sells a bolt is not the slug, it is the three things hanging off it. At
		780 studs/s the core covers ~13 studs between frames, so on its own it strobes
		as a dashed line of rods; the TRAIL bridges those gaps into one streak. The
		travelling LIGHT is what makes a shot cross the arena instead of being drawn on
		it. The HALO is the soft bloom a neon part cannot have on its own. SPEED is
		still picked so a max-range shot (220 studs) takes ~0.28s: long enough to
		track, short enough that the impact still feels like a reply to the trigger. ]=]
	BOLT_SHOT = {
		SPEED = 780,
		LENGTH = 13.0, -- about one frame of travel, so the rod never leaves a gap
		WIDTH = 0.85,
		MIN_LIFE = 0.06,
		MAX_LIFE = 0.4,
		TRANSPARENCY = 0.05,
		CORE_WHITE = 0.7, -- the rod is white-hot; the weapon colour lives in the glow
		TRAIL_WIDTH = 1.35, -- x WIDTH — the gap between the trail's two attachments
		TRAIL_LIFE = 0.09,
		HALO_RATE = 34,
		HALO_SIZE = 3.4,
		HALO_LIFE = 0.16,
		LIGHT_RANGE = 16,
		LIGHT_BRIGHTNESS = 2.4,
		MAX_LIGHTS = 8, -- a six-way firefight must not put thirty PointLights on screen
	},
	-- Soft round blur lifted from the authored packs (ReplicatedStorage.VFXs), so it
	-- is an asset this place already loads. Every plasma glow below uses it.
	GLOW_TEXTURE = "rbxassetid://14159634300",

	--[=[ Both plasma weapons draw from this one entry; TWIN_SCALE is the whole
		difference between the gun and the lighter twin guns. The DISCS matter most: a
		slug at 780 studs/s is past a bystander before they can track it, so the flat
		ring punched down the barrel — and the one that splashes back off whatever it
		hits — are what actually say "a shot happened, that way, and it connected". ]=]
	GUN = {
		MUZZLE_RADIUS = 1.9,
		MUZZLE_LIFE = 0.07,
		MUZZLE_LIGHT = 15, -- PointLight range at the barrel
		MUZZLE_DISC = 5.0, -- studs across, facing down the barrel
		MUZZLE_DISC_LIFE = 0.10,
		HIT_SPARKS = 5,
		HIT_FLASH = 2.2,
		HIT_LIFE = 0.09,
		HIT_DISC = 7.5,
		HIT_DISC_LIFE = 0.16,
		CAR_HIT_SCALE = 1.5, -- hitting a CAR must never look like hitting a wall
		CAR_HIT_LIGHT = 14,
		VFX_GAP = 0.14, -- floor between pack bursts; 11 hits a second would mush
		TWIN_SCALE = 0.7,
	},

	--[=[ THE PLASMA BEAM — what the gun draws now that it pours a ray instead of firing
		slugs. It lives BETWEEN the server's ticks exactly like the flamethrower's jet and
		for the same reason: a weapon you HOLD has to be drawn by the client every frame or
		it strobes at the tick rate, and fourteen ticks a second is exactly what you would
		see. HOLD is how long a ray outlives its last tick; FADE is the gutter after that,
		and HOLD must stay comfortably above the weapon's cooldown or a held trigger
		flickers between ticks.

		The widths are all multiplied by one shared wobble, so core, glow and both flares
		breathe together — three layers pulsing out of phase reads as three effects. ]=]
	BEAM = {
		HOLD = 0.16, -- > POWERUPS.GUN.cooldown (0.07), with room for a bad ping
		FADE = 0.12,
		MAX_RIGS = 6, -- one per shooter; past this the oldest ray is dropped
		CORE_WIDTH = 0.62,
		CORE_WHITE = 0.8, -- the rod is white-hot; the weapon colour lives in the glow
		CORE_TRANSPARENCY = 0.05,
		BEAM_WIDTH = 3.4,
		BEAM_TAPER = 0.8, -- narrower where it lands, so the ray reads as focused
		BEAM_TRANSPARENCY = 0.3,
		SEGMENTS = 6,
		TEXTURE_LENGTH = 9,
		TEXTURE_SPEED = 6, -- the SCROLL is what makes it a stream, not a painted line
		FLICKER_HZ = 27,
		FLICKER = 0.14, -- shared width wobble, fraction
		MUZZLE_FLARE = 2.1,
		END_FLARE = 2.4,
		CAR_END_SCALE = 1.6, -- landing on a CAR must never look like landing on a wall
		FLARE_TRANSPARENCY = 0.15,
		MUZZLE_LIGHT = 15,
		END_LIGHT = 12,
		LIGHT_BRIGHTNESS = 2.2,
		--[[ The per-tick contact fx is gated HARD. The end flare carries contact
			continuously, so these are only the sparkle on top; ungated they are a smear. ]]
		IMPACT_GAP = 0.13,
		IMPACT_SCALE = 0.75,
		SPARK_GAP = 0.1,
		SPARKS = 2,
	},

	--[=[ RAILGUN. Two halves that are really one shape: a wind-up that gathers, and a
		ray that leaves. Everything in the wind-up is driven off ONE normalised 0..1
		charge so the orb, the ring, the light and the whine cannot drift apart. ]=]
	RAIL = {
		-- the wind-up
		GRACE = 0.4, -- how far past its duration an orphaned charge survives before dying
		ORB_MIN = 0.7,
		ORB_MAX = 4.6,
		ORB_TRANSPARENCY = 0.08,
		FLICKER_HZ = 34,
		FLICKER = 0.12,
		LIGHT_MIN = 8,
		LIGHT_MAX = 30,
		LIGHT_BRIGHTNESS = 2.6,
		GATHER_MAX = 17, -- the ring starts wide and closes ONTO the muzzle: gathering,
		GATHER_MIN = 2.6, -- not throwing. Reversing these two reads as a weapon firing.
		GATHER_THICKNESS = 0.35,
		GATHER_FORWARD = 3.4,
		GATHER_TRANSPARENCY = 0.25,
		PITCH_MIN = 0.55,
		PITCH_MAX = 2.05,
		VFX_REFRESH = 0.1,
		-- the shot
		LIFE = 0.5, -- the glow rod hangs this long, thinning to nothing
		CORE_LIFE = 0.34,
		CORE_WIDTH = 1.5,
		CORE_WHITE = 0.85,
		GLOW_WIDTH = 5.4,
		GLOW_TRANSPARENCY = 0.42,
		SHOCKS = 4, -- discs punched along the length: what makes a still rod read as MOVED
		SHOCK_SIZE = 12,
		SHOCK_LIFE = 0.4,
		FLASH_LIFE = 0.16,
		DISC_LIFE = 0.22,
		MUZZLE_FLASH = 7,
		MUZZLE_LIGHT = 36,
		MUZZLE_DISC = 16,
		PUFFS = 5,
		PUFF_SCALE = 2.2,
		HIT_FLASH = 8,
		HIT_RING = 16,
		HIT_RING_LIFE = 0.34,
		HIT_SPARKS = 18,
		HIT_LIGHT = 30,
		CAR_HIT_SCALE = 1.5,
		SHAKE_RADIUS = 95, -- the loudest thing in the game; it is felt well past the shot
		SHAKE_INTENSITY = 2.2,
		SHAKE_TIME = 0.4,
	},
	--[=[ The shared LAUNCH — every weapon that spits a projectile (rocket, cannon,
		mortar, freeze) draws this before its own flourish. The DISC is the load-bearing
		part: every weapon in this game fires DEAD AHEAD (Config.WEAPONS.AIM_MAX_YAW_DEG
		is 0, and three separate places agree on it), so a flat ring punched off the
		barrel always points both where the shot is going and where the car is pointing.
		It reads from any angle, which a muzzle sphere never did. ]=]
	LAUNCH = {
		PUFFS = 4,
		FLASH_RADIUS = 4.0,
		FLASH_LIFE = 0.12,
		LIGHT = 18,
		DISC = 6.0,
		DISC_LIFE = 0.12,
		SPARKS = 4,
		SPARK_FOCUS = 0.75, -- 1 = straight down the barrel, 0 = the old even scatter
	},
	MINE = { RING_RADIUS = 7, RING_LIFE = 0.3 },
	ZAP = { SEGMENTS = 6, JITTER = 0.055, WIDTH = 0.3, LIFE = 0.15, TRANSPARENCY = 0.05, END_FLASH = 3.0, SPARKS = 5, RING_LIFE = 0.28 },
	SHIELD = { POP_RADIUS = 8, FLASH_LIFE = 0.16, POP_LIFE = 0.26, POP_SPARKS = 8 },

	IMPACT = {
		DEFAULT_RADIUS = 14,
		MIN_RADIUS = 3,
		MAX_RADIUS = 60,
		FLASH_LIFE = 0.2,
		RING_LIFE = 0.3,
		DEBRIS = 7,
		--[[ An explosion is THREE shapes, not one: the coloured fireball, a white-hot
			core that dies twice as fast (which is what makes the fireball look like it
			is cooling rather than merely fading), and a thin ring travelling out past
			both as the pressure wave. LIGHT_SCALE is the one that was missing — a blast
			that does not light the road it is standing on reads as a decal. ]]
		CORE_SCALE = 0.5, -- white-hot core, as a fraction of the blast radius
		CORE_LIFE = 0.09,
		--[[ PointLight range = radius * this, capped at 60 in the handler. That cap is
			OUR ceiling, not the engine's (measured: Range accepts up to 120) — past
			about 60 studs a blast light stops reading as an explosion and starts
			reading as the sun coming out. Nothing in Config gets near it: the biggest
			blastRadius in the game is the cannon's 22, i.e. a range of 40. ]]
		LIGHT_SCALE = 1.8,
		SHOCK_SCALE = 1.45,
		SHOCK_LIFE = 0.16,
		SHAKE_SCALE = 2.2, -- shake reaches blastRadius * this
		SHAKE_INTENSITY = 1.1,
		SHAKE_TIME = 0.28,
	},
	RAM = {
		FLASH_RADIUS = 3.4,
		FLASH_LIFE = 0.12,
		SPARKS = 10,
		SHAKE_RADIUS = 34, -- past this a crash is someone else's problem
		SHAKE_INTENSITY = 1.0,
		SHAKE_TIME = 0.22,
	},
	STAGGER = { SHAKE_INTENSITY = 0.85, SPARKS = 6 }, -- local car took knockback

	SKID = {
		INTERVAL = 0.08,
		LIFE = 1.8,
		MIN_SPEED_FRACTION = 0.22,
		WIDTH = 1.5,
		THICKNESS = 0.08,
		LENGTH = { 2.4, 13.0 },
		LENGTH_SCALE = 1.35, -- speed * INTERVAL * this = mark length, so marks join up
		SIDE_FRACTION = 0.38, -- of hull width, per rear wheel
		BACK_FRACTION = 0.34, -- of hull length, behind center
		Y_OFFSET = 0.07,
		TRANSPARENCY = 0.32,
		COLOR = Color3.fromRGB(26, 24, 28),
		RAY_LENGTH = 12,
	},
	BOOST = {
		INTERVAL = 0.045,
		LIFE = 0.3,
		SIDE_FRACTION = 0.26,
		BACK_FRACTION = 0.52,
		SIZE = Vector3.new(0.55, 0.55, 3.6),
		GROW = 2.2,
		TRANSPARENCY = 0.15,
		COLORS = { UI.GOLD_LIGHT, UI.GOLD_DEEP, UI.LIME },
	},
	WIND = {
		MIN_FRACTION = 0.72, -- speed fraction before wind streaks appear
		INTERVAL = 0.05,
		LIFE = 0.16,
		AHEAD = 26,
		SIDE = { 7, 15 },
		VERTICAL = 5,
		SIZE = Vector3.new(0.1, 0.1, 7),
		SPEED = 150,
		TRANSPARENCY = 0.78, -- deliberately faint: never obscure the road
	},
	LAND = {
		MIN_AIRTIME = 0.35,
		MAX_AIRTIME = 1.4,
		PUFFS = 5,
		PUFF_SCALE = 1.6,
		SHAKE_INTENSITY = 0.9,
		SHAKE_TIME = 0.2,
	},

	SHELL = {
		MATCH_RADIUS = 22, -- how close a SHIELD fx origin must be to claim a car
		DISTANCE = 260, -- do not build shells for cars this far from the camera
		BOX_SCALE = 1.08,
		FROST = {
			SHAPE = "Box",
			COLOR = Color3.fromRGB(150, 226, 255),
			BASE = 0.55,
			AMPLITUDE = 0.12,
			SPEED = 6,
			MATERIAL = Enum.Material.Ice,
		},
		INVULN = {
			SHAPE = "Box",
			COLOR = UI.PAPER,
			BASE = 0.72,
			AMPLITUDE = 0.22,
			SPEED = 11, -- fast flash: "your ram did nothing on purpose"
			SCALE = 1.14,
			MATERIAL = Enum.Material.Neon,
		},
		SHIELD = {
			SHAPE = "Ball",
			COLOR = UI.CONFIRM,
			BASE = 0.74,
			AMPLITUDE = 0.1,
			SPEED = 3.5,
			SCALE = 1.15, -- of the car's extents
			MATERIAL = Enum.Material.ForceField,
		},
		HURT = {
			SHAPE = "Box",
			COLOR = UI.DANGER,
			BASE = 0.45,
			AMPLITUDE = 0,
			SPEED = 0,
			SCALE = 1.11,
			LIFE = 0.16, -- one-shot damage flash on the local car
			MATERIAL = Enum.Material.Neon,
		},
	},

	PROJECTILE = {
		MAX_DECORATED = 14,
		HINT_WINDOW = 0.6,
		HINT_RADIUS = 40,
		HINT_MAX = 8,
		TRAIL_LIFETIME = 0.32,
		TRAIL_WIDTH = 1.6,
		LIGHT_RANGE = 14,
		LIGHT_BRIGHTNESS = 2.4,
		--[[ The flying shell itself. A trail alone is a streak with nothing at the head
			of it; GLOW is what puts something there, and every flyer gets it. Only the
			ROCKET has a motor, so only the rocket gets an EXHAUST cone out of the tail
			— and the two lobbed shells trail SMOKE, which is what makes an arc readable
			against the sky. ]]
		GLOW_RATE = 26,
		GLOW_SIZE = 2.8,
		GLOW_LIFE = 0.22,
		EXHAUST_RATE = 55,
		EXHAUST_SIZE = 3.2,
		EXHAUST_LIFE = 0.26,
		EXHAUST_SPEED = 30, -- studs/s, thrown BACKWARDS out of the tail
		EXHAUST_COLOR = Color3.fromRGB(255, 190, 90),
		SMOKE_RATE = 16,
		SMOKE_SIZE = 5.0,
		SMOKE_LIFE = 0.85,
		SMOKE_COLOR = Color3.fromRGB(122, 120, 118),
		MINE_PULSE_SPEED = 4.2,
		MINE_LIGHT_RANGE = 11,
		MINE_LIGHT_MIN = 0.4,
		MINE_LIGHT_MAX = 2.6,
		MINE_EMIT_RATE = 5,
		MINE_EMIT_SIZE = 0.7,
		MINE_EMIT_LIFE = 0.45,
	},

	--[[ The flamethrower jet. Redrawn on EVERY tick, so everything here stays cheap:
		a few Neon balls swelling and fading down the aim line. The visible jet is
		deliberately SHORTER than the hitbox (LENGTH_FRACTION) — a jet that looks like
		it reaches you but does not burn reads as broken, the other way round does not. ]]
	FLAME = {
		SEGMENTS = 3,
		LENGTH_FRACTION = 0.62, -- of def.range
		START_WIDTH = 1.8,
		END_WIDTH = 7.5,
		GROW = 1.6,
		DRIFT = 42, -- studs/s the puffs carry on down the jet as they fade
		LIFE = 0.17,
		TRANSPARENCY = 0.32,
		LIGHT = 16, -- rides the FIRST puff only, so a held jet is still one light
		DISC = 4.6, -- nozzle flare: the jet lives between ticks, the muzzle still pops
		DISC_LIFE = 0.13,
		DISC_GAP = 0.16, -- twelve nozzle flares a second is a strobe, not a flame
	},

	CANNON = {
		FLASH_RADIUS = 5.5,
		FLASH_LIFE = 0.10,
		LIGHT = 30, -- the heaviest muzzle flash in the game deserves the brightest
		SMOKE = 6,
		SMOKE_SCALE = 2.1,
		SPARKS = 7,
		MUZZLE_DISC = 10.0, -- the widest muzzle ring in the game; it is the big gun
		MUZZLE_DISC_LIFE = 0.14,
		SPARK_FOCUS = 0.82, -- cannon sparks blow straight down the barrel
		SHAKE_RADIUS = 34, -- the shooter feels their own cannon; that IS the weapon
		SHAKE_INTENSITY = 1.1,
		SHAKE_TIME = 0.16,
	},

	PREDICT = {
		WINDOW = 0.45, -- how long a local prediction suppresses the server echo's sound
		RADIUS = 16, -- and how far the echo may land from where we predicted
		MAX = 8,
		FLASH_RADIUS = 2.2,
		FLASH_LIFE = 0.07,
		SPARKS = 3,
		SPARK_FORWARD = 1.5,
	},

	TAG = {
		NAME = "CrashNametag",
		WIDTH = 9,
		HEIGHT = 1.5,
		-- Studs above the ROOFLINE (Hull.WeaponMount), not above the adornee. Was 7.6
		-- when it was measured off a trim part and landed somewhere different on
		-- every car.
		OFFSET = 3.2,
		MAX_DISTANCE = 250,
		STROKE = 2,
		NAME_HEIGHT = 0.5,
		CROWN_HEIGHT = 0.24,
		BAR_WIDTH = 0.66,
		--[[ The bar fills the band left under the score line (name 0..0.50, score
			0.50..0.74, bar bottom-anchored). 0.17 left a dead 0.09 gap there and drew a
			23:1 ribbon that thinned out to nothing at range; 0.21 closes the gap and
			still clears the score line at the peak of a hit punch (1 - 0.21 * 1.18 =
			0.752 against the score line's 0.74). Raising it further needs PUNCH_SCALE
			to come down with it -- the two share that gap. ]]
		BAR_HEIGHT = 0.21,
		-- Chunk dividers are sized in SCALE, never offset: a BillboardGui shrinks on
		-- screen with distance but its children's pixel offsets do not, so an offset
		-- divider would swell into a solid block on a car across the arena.
		CHUNK_WIDTH = 0.022,
		CHUNK_MAX = 12,
		--[[ YOUR OWN car gets a tag too, which is how Crash of Cars reads: the bar you
			care about most floats where you are already looking, instead of only at the
			edge of the screen. It is STRIPPED though — no name, no crowns. You know who
			you are, the HUD already carries your score, and a full-height tag over your
			own roof is the one thing guaranteed to sit between you and the road ahead.
			SELF_ENABLED = false goes back to rivals-only. ]]
		SELF_ENABLED = true,
		SELF_WIDTH = 6.2, -- shorter than a rival tag because there is no text to hold
		SELF_HEIGHT = 0.62,
		SELF_OFFSET = 2.2, -- lower too, so it hugs the roof rather than floating over it
		SELF_BAR_WIDTH = 0.94, -- the bar IS the tag here, so it fills it
		SELF_BAR_HEIGHT = 0.5,
		--[[ Damage read-out. The FILL never tweens: a ram can take a third of a car,
			and a bar that eases toward the real number is lying at exactly the moment
			someone is deciding whether to chase. What animates is the GHOST behind it,
			which holds the old value for GHOST_HOLD and then drains at GHOST_DRAIN of
			the bar per second -- that white sliver IS the hit you just landed. ]]
		HIT_COLOR = UI.PAPER,
		HEAL_COLOR = UI.LIME,
		GHOST_HOLD = 0.20,
		GHOST_DRAIN = 0.9, -- bar-widths per second
		GHOST_TRANSPARENCY = 0.15,
		HIT_FLASH = 0.16, -- how long the fill carries the white (or green) hit tint
		PUNCH_SCALE = 0.18, -- extra bar size at the peak of a hit
		PUNCH_TIME = 0.20,
		--[[ Under this the bar BREATHES -- a sine, never a blink, because a blinking
			bar reads as a broken bar. Matched to the smoke tell (FX.VFX.BURNING_HP) on
			purpose: the trail you see from behind and the bar you see from in front
			have to start at the same moment or they read as two different states. ]]
		LOW_FRACTION = 0.34,
		LOW_PULSE_HZ = 2.4,
		LOW_PULSE_DEPTH = 0.3, -- how far toward PAPER the fill lifts at the peak
		LOW_STROKE_COLOR = UI.DANGER,
		POP_TIME = 0.24, -- spawn pop, so a tag ARRIVES instead of appearing
		POP_SCALE = 0.55,
		GLOSS_LOW = 0.72, -- bottom stop of the fill's multiply gradient
		FALLBACK_NAME = "Driver",
		RESOLVE_TIMEOUT = 5,
		RESOLVE_POLL = 0.1,
	},

	HL = {
		NAME = "CrashCarHighlight",
		SELF_COLOR = UI.CONFIRM,
		RIVAL_COLOR = UI.DANGER,
		-- Fill stays near-transparent so each car's own paint still reads through it;
		-- the opaque outline is what carries the silhouette at arena distance.
		FILL_TRANSPARENCY = 0.78,
		OUTLINE_TRANSPARENCY = 0,
		--[[ THE HIT FLASH. Every car already wears this Highlight, so it is the cheapest
			surface in the game to say "that one just took a hit": two property writes, no
			new instance, no cap to blow, and it reads through walls at arena distance
			exactly like the silhouette it is already drawing.
			STRENGTH is the damage as a fraction of the victim's max hp, floored so that a
			machine-gun chip still ticks and capped so that a cannon cannot do more than
			white out the car. KILL is its own longer, gold flash: the last thing you ever
			see of a car you destroyed. ]]
		HIT_COLOR = UI.PAPER,
		HIT_FILL = 0.1, -- fill transparency at full strength (FILL_TRANSPARENCY is the base)
		HIT_TIME = 0.26,
		HIT_MIN_STRENGTH = 0.4,
		HIT_FULL_FRACTION = 0.22, -- damage / maxHp that reads as a full-strength flash
		KILL_COLOR = UI.GOLD_LIGHT,
		KILL_TIME = 0.45,
	},

	--[=[ HIT — damage feedback, and the one fx kind that draws something DIFFERENT for
		each of the three people watching it:
		  EVERYONE  the victim's highlight flashes (see HL above). This is the pack-
		            readability half: from across a 903-stud arena, through a plateau,
		            you can see which car is being worked on.
		  ATTACKER  a marker, a 2D ping, sparks — the confirmation that a shot fired at a
		            car 200 studs away actually connected.
		  VICTIM    the same number in DANGER red. The HURT shell (§14) already flashes
		            the bodywork off the local hp drop, so nothing here repeats it.
		Third-party damage draws NO number on purpose: twelve cars trading fire would
		bury the arena in other people's arithmetic. ]=]
	HIT = {
		HOST_SIZE = Vector3.new(0.2, 0.2, 0.2),
		--[[ Billboard CENTRE, above the body centre. The nametag's own top edge sits at
			bodyY/2 + OFFSET + HEIGHT/2 (~12.4 on a normal body), and this billboard is
			POP_TOTAL_HEIGHT tall around its centre, so 15 is what puts the number's
			bottom edge clear of the tag on the FIRST frame rather than a tenth of a
			second into its climb. Move one of the two and re-derive the other. ]]
		POP_HEIGHT = 15,
		POP_RISE = 7,
		POP_WIDTH = 7,
		POP_TOTAL_HEIGHT = 3.2, -- studs; the billboard scales as one unit for the punch
		POP_TEXT_HEIGHT = 0.62, -- fraction of the billboard
		POP_MARK_WIDTH = 0.3,
		POP_MARK_HEIGHT = 0.34,
		MARK_BAR_LENGTH = 0.9, -- of the marker box, per bar
		MARK_BAR_THICKNESS = 0.2,
		POP_LIFE = 0.85,
		POP_FADE_AT = 0.55, -- fraction of life before the fade starts
		POP_PUNCH = 0.34, -- extra scale on every fresh hit, eased out
		POP_KILL_PUNCH = 0.75,
		POP_PUNCH_TIME = 0.16,
		MERGE_TIME = 0.55, -- a second hit inside this climbs the SAME number
		STROKE = 2,
		SPARKS = 5,
		SPARK_GAP = 0.09, -- the hold weapons land 8+ hits a second even after coalescing
		PING_GAP = 0.07,
		KILL_SHAKE = 1.2,
		KILL_SHAKE_TIME = 0.22,
		DEALT_COLOR = UI.PAPER, -- damage you dealt
		SELF_COLOR = UI.DANGER, -- damage you took
		KILL_TEXT_COLOR = UI.GOLD,
	},
}

-- ==========================================================================
-- § 4) State
-- ==========================================================================
local rng = Random.new()

local ctxRef = nil
local warned = {}

local pools = {} -- category -> array of tracked entries (oldest first)
local shells = {} -- car -> { kind -> entry }
local shellCount = 0
local pulses = {} -- decorated mines awaiting their sine pulse
local decorated = 0
local projHints = {} -- recent launch events used to classify server projectiles
local predictions = {} -- local prediction receipts, consumed by the server echo
local tags = {} -- car -> nametag entry
local tagCount = 0
local highlights = {} -- car -> { hl, base colour, hit envelope }; EVERY car, your own included
local highlightCount = 0
local beams = {} -- shooter userId -> live plasma ray rig; ONE per shooter
local rails = {} -- shooter userId -> live railgun wind-up rig; ONE per shooter
local beamCount = 0
local pops = {} -- floating damage numbers, oldest first; this list owns their hosts
local popByCar = {} -- car -> the live pop a fresh hit on that car climbs into
local lastHitSparkAt = 0
local lastHitPingAt = 0
local specCache = {} -- ChassisSpec.specKey -> resolved spec (id AND body modifiers)
local visualCache = {} -- car -> Body/Shell (or fallback) BasePart
local boundFolders = {}

local fxFolderRef = nil
local stateAccum = 0

local drive = {
	lastSkidAt = 0,
	lastBoostAt = 0,
	lastWindAt = 0,
	wasBoosting = false,
	wasGrounded = true,
	wasStaggered = false,
	airtime = 0,
	lastHp = nil,
	lastCar = nil,
}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("FxController: " .. message)
end

--[[ Lazy, crash-proof sibling call. Siblings are written by other passes; a missing
	or throwing controller must never take the fx loop down. ]]
local function safeCall(controllerName: string, fnName: string, default: any, ...): any
	local ctrl = ctxRef and ctxRef.ctrl and ctxRef.ctrl[controllerName]
	local fn = ctrl and ctrl[fnName]
	if type(fn) ~= "function" then
		warnOnce(controllerName .. "." .. fnName, controllerName .. "." .. fnName .. " unavailable")
		return default
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warnOnce("err:" .. controllerName .. "." .. fnName, controllerName .. "." .. fnName .. " errored -> " .. tostring(result))
		return default
	end
	if result == nil then
		return default
	end
	return result
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function cameraPos(): Vector3?
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position or nil
end

-- Distance gate. With no camera yet we render (better one wasted fx than a silent game).
local function isNear(position: Vector3, maxDistance: number): boolean
	if not FX.CULL_ENABLED then
		return true -- culling disabled: everything is "near"
	end
	local from = cameraPos()
	if not from then
		return true
	end
	return (position - from).Magnitude <= maxDistance
end

-- CFrame for a part whose Z axis spans a->b. Safe when the segment is vertical.
local function segmentCFrame(a: Vector3, b: Vector3): CFrame
	local delta = b - a
	if delta.Magnitude < 1e-4 then
		return CFrame.new(a)
	end
	local up = math.abs(delta.Unit.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
	return CFrame.lookAt(a + delta * 0.5, b, up)
end

local function pickColor(payload: any, fallback: Color3): Color3
	if typeof(payload.color) == "Color3" then
		return payload.color
	end
	return fallback
end

local function pickRadius(payload: any, fallback: number): number
	if type(payload.radius) == "number" and payload.radius == payload.radius then
		return math.clamp(payload.radius, FX.IMPACT.MIN_RADIUS, FX.IMPACT.MAX_RADIUS)
	end
	return fallback
end

-- ==========================================================================
-- § 5) Fx folder, part factory, tracked pools, sweeper.
--      Two independent destroy paths per part: the sweeper AND a task.delay
--      backstop, so a dead frame loop still cannot leak parts.
-- ==========================================================================
local function fxFolder(): Folder
	if fxFolderRef and fxFolderRef.Parent then
		return fxFolderRef
	end
	local existing = workspace:FindFirstChild(FX.FOLDER)
	if existing and existing:IsA("Folder") then
		fxFolderRef = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FX.FOLDER
	folder.Parent = workspace
	fxFolderRef = folder
	return folder
end

local function newPart(cat: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local part = Instance.new("Part")
	part.Name = cat
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- must never appear in anyone's ground probe
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = fxFolder()
	return part
end

local function track(inst: Instance, cat: string, life: number, opts: any?)
	local pool = pools[cat]
	if not pool then
		pool = {}
		pools[cat] = pool
	end
	local cap = CAPS[cat] or CAPS.DEFAULT
	while #pool >= cap do
		local oldest = table.remove(pool, 1)
		if oldest and oldest.inst then
			oldest.inst:Destroy()
		end
	end

	local entry = { inst = inst, born = os.clock(), life = math.max(life, 0.01) }
	if opts then
		for key, value in pairs(opts) do
			entry[key] = value
		end
	end
	table.insert(pool, entry)

	task.delay(entry.life + FX.HARD_KILL_GRACE, function()
		if inst.Parent then
			inst:Destroy()
		end
	end)
	return entry
end

-- Manual lerp/fade/drift for every tracked part. One pass, no tweens.
local function sweep(dt: number)
	local now = os.clock()
	for _, pool in pairs(pools) do
		for i = #pool, 1, -1 do
			local entry = pool[i]
			local inst = entry.inst
			if not inst or not inst.Parent then
				table.remove(pool, i)
			else
				local k = math.clamp((now - entry.born) / entry.life, 0, 1)
				if entry.fade0 then
					inst.Transparency = entry.fade0 + (entry.fade1 - entry.fade0) * k
				end
				if entry.size0 then
					inst.Size = entry.size0:Lerp(entry.size1, k)
				end
				if entry.vel then
					if entry.gravity then
						entry.vel = entry.vel + FX.GRAVITY * dt
					end
					inst.CFrame = inst.CFrame + entry.vel * dt
					if entry.spin then
						inst.CFrame = inst.CFrame * CFrame.fromEulerAnglesXYZ(entry.spin.X * dt, entry.spin.Y * dt, entry.spin.Z * dt)
					end
				end
				if k >= 1 then
					table.remove(pool, i)
					inst:Destroy()
				end
			end
		end
	end
end

-- ==========================================================================
-- § 6) Sound. 3D sounds ride a tiny invisible holder at the event position so
--      they attenuate; every sound is destroyed on Ended and on a hard timer.
-- ==========================================================================
local function configureSound(spec: any, volumeScale: number?): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = spec.asset
	sound.Volume = spec.volume * (volumeScale or 1)
	sound.PlaybackSpeed = rng:NextNumber(spec.pitch[1], spec.pitch[2])
	sound.RollOffMaxDistance = FX.SOUND_RANGE
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	return sound
end

local function playSound(spec: any, position: Vector3?, volumeScale: number?): Sound?
	if not spec then
		return nil
	end
	if position and not isNear(position, FX.CULL_DISTANCE) then
		return nil
	end

	local life = spec.life or FX.SOUND_LIFE
	local sound = configureSound(spec, volumeScale)

	if position then
		local holder = newPart("SOUND", FX.SOUND_HOLDER_SIZE, CFrame.new(position), UI.PAPER, Enum.Material.SmoothPlastic, 1)
		track(holder, "SOUND", life)
		sound.Parent = holder
	else
		sound.Parent = SoundService -- 2D
		task.delay(life + FX.HARD_KILL_GRACE, function()
			if sound.Parent then
				sound:Destroy()
			end
		end)
	end

	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	return sound
end

--[[ Sound that rides a server-spawned part (rocket whoosh). Dies with its host,
	so there is no cleanup to own here. ]]
-- Rate-limited sound for the hold weapons; see SOUND_GAP. Unknown ids pass through.
local lastKindSoundAt = {}
local function playGatedSound(kind: string, spec: any, position: Vector3?)
	local gap = SOUND_GAP[kind]
	if not gap then
		playSound(spec, position)
		return
	end
	local now = os.clock()
	if now - (lastKindSoundAt[kind] or 0) < gap then
		return
	end
	lastKindSoundAt[kind] = now
	playSound(spec, position)
end

local function attachSound(spec: any, host: BasePart, looped: boolean): Sound?
	if not spec or not host.Parent then
		return nil
	end
	local sound = configureSound(spec, nil)
	sound.Looped = looped
	sound.Parent = host
	if not looped then
		sound.Ended:Once(function()
			sound:Destroy()
		end)
	end
	sound:Play()
	return sound
end

-- ==========================================================================
-- § 7) Primitives
-- ==========================================================================
--[[ `lightRange` is optional and defaults to no light at all, so every existing
	caller is untouched. A PointLight parented to the flash part dies with it, which is
	why this needs no bookkeeping of its own. ]]
local function flash(position: Vector3, color: Color3, radius: number, life: number, lightRange: number?)
	local part = newPart("FLASH", Vector3.one * radius * FX.FLASH.START, CFrame.new(position), color, Enum.Material.Neon, FX.FLASH.TRANSPARENCY)
	part.Shape = Enum.PartType.Ball
	if lightRange and lightRange > 0 then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = lightRange
		light.Brightness = FX.FLASH.LIGHT_BRIGHTNESS
		light.Shadows = false
		light.Parent = part
	end
	track(part, "FLASH", life, {
		fade0 = FX.FLASH.TRANSPARENCY,
		fade1 = 1,
		size0 = part.Size,
		size1 = Vector3.one * radius * FX.FLASH.END,
	})
end

-- Flat expanding disc. The single most readable "something happened here" shape.
local function ring(position: Vector3, color: Color3, radius: number, life: number)
	local start = radius * FX.RING.START
	local part = newPart(
		"RING",
		Vector3.new(FX.RING.THICKNESS, start, start),
		CFrame.new(position) * CFrame.fromEulerAnglesYXZ(0, 0, math.rad(90)),
		color,
		Enum.Material.Neon,
		FX.RING.TRANSPARENCY
	)
	part.Shape = Enum.PartType.Cylinder
	local finish = radius * FX.RING.END
	track(part, "RING", life, {
		fade0 = FX.RING.TRANSPARENCY,
		fade1 = 1,
		size0 = part.Size,
		size1 = Vector3.new(FX.RING.THICKNESS, finish, finish),
	})
end

--[[ Shared debris / spark emitter. cfg is FX.DEBRIS or FX.SPARK. `axis`/`focus` bias
	the throw toward one direction (focus 1 = straight along it, 0 = the old even
	scatter), which is what lets plasma sparks spray back off a surface along the
	shot instead of puffing out of it in every direction. ]]
local function burst(position: Vector3, color: Color3, count: number, cfg: any, axis: Vector3?, focus: number?)
	if count <= 0 or not isNear(position, FX.DETAIL_DISTANCE) then
		return
	end
	local bias = (axis and axis.Magnitude > 1e-3) and axis.Unit or nil
	local weight = math.clamp(focus or 0.6, 0, 1)
	for _ = 1, count do
		local s = rng:NextNumber(cfg.SIZE[1], cfg.SIZE[2])
		local dir = Vector3.new(
			rng:NextNumber(-1, 1) * cfg.SPREAD,
			rng:NextNumber(cfg.UP[1], cfg.UP[2]),
			rng:NextNumber(-1, 1) * cfg.SPREAD
		)
		if dir.Magnitude < 1e-3 then
			dir = Vector3.yAxis
		end
		dir = dir.Unit
		if bias then
			local blended = bias * weight + dir * (1 - weight)
			dir = blended.Magnitude > 1e-3 and blended.Unit or bias
		end

		local part = newPart(cfg.CAT, Vector3.new(s, s, s * cfg.LONG), segmentCFrame(position, position + dir), color, cfg.MATERIAL, 0)
		track(part, cfg.CAT, rng:NextNumber(cfg.LIFE[1], cfg.LIFE[2]), {
			fade0 = 0,
			fade1 = 1,
			vel = dir * rng:NextNumber(cfg.SPEED[1], cfg.SPEED[2]),
			gravity = cfg.GRAVITY,
			spin = cfg.SPIN > 0
					and Vector3.new(rng:NextNumber(-cfg.SPIN, cfg.SPIN), rng:NextNumber(-cfg.SPIN, cfg.SPIN), rng:NextNumber(-cfg.SPIN, cfg.SPIN))
				or nil,
		})
	end
end

local function puffBurst(position: Vector3, color: Color3, count: number, scale: number?)
	local cfg = FX.PUFF
	if count <= 0 or not isNear(position, FX.DETAIL_DISTANCE) then
		return
	end
	for _ = 1, count do
		local s = rng:NextNumber(cfg.SIZE[1], cfg.SIZE[2]) * (scale or 1)
		local offset = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0, 0.6), rng:NextNumber(-1, 1)) * cfg.SPREAD
		local part = newPart(cfg.CAT, Vector3.one * s, CFrame.new(position + offset), color, Enum.Material.SmoothPlastic, cfg.TRANSPARENCY)
		part.Shape = Enum.PartType.Ball
		local dir = Vector3.new(offset.X, math.abs(offset.Y) + 0.4, offset.Z)
		track(part, cfg.CAT, rng:NextNumber(cfg.LIFE[1], cfg.LIFE[2]), {
			fade0 = cfg.TRANSPARENCY,
			fade1 = 1,
			size0 = part.Size,
			size1 = part.Size * cfg.GROW,
			vel = (dir.Magnitude > 1e-3 and dir.Unit or Vector3.yAxis) * rng:NextNumber(cfg.SPEED[1], cfg.SPEED[2]),
		})
	end
end

-- Lerp toward white. A plasma core only reads hot if it is brighter than its own glow.
local function hot(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

--[[ Flat disc facing `dir`, expanding as it fades — the shape that reads as an energy
	discharge instead of a puff of smoke. A Cylinder's flat faces are its +/-X, so the
	part is aimed by rotating a lookAt a quarter turn about Y. ]]
local function disc(position: Vector3, dir: Vector3, color: Color3, size: number, life: number)
	local aim = dir.Magnitude > 1e-3 and dir.Unit or Vector3.yAxis
	local start = size * 0.3
	local part = newPart(
		"PLASMA",
		Vector3.new(FX.RING.THICKNESS, start, start),
		CFrame.lookAt(position, position + aim) * CFrame.Angles(0, math.pi * 0.5, 0),
		color,
		Enum.Material.Neon,
		FX.RING.TRANSPARENCY
	)
	part.Shape = Enum.PartType.Cylinder
	track(part, "PLASMA", life, {
		fade0 = FX.RING.TRANSPARENCY,
		fade1 = 1,
		size0 = part.Size,
		size1 = Vector3.new(FX.RING.THICKNESS, size, size),
	})
end

-- Bolts are capped by the TRACER pool, but the PointLight is the one part of a bolt
-- the GPU actually cares about, so lights are counted separately and cheaply.
local liveBoltLights = 0

--[[ A plasma slug flying muzzle -> impact. Returns its flight time so the caller can
	hold the impact fx back until it actually lands: sparks that fire before the bolt
	arrives are worse than no bolt at all.

	The tracked part is only the CORE — a white-hot rod, round in section (a Cylinder,
	so there is no flat facet to catch the light wrong side-on). Everything else hangs
	off it as CHILDREN, which is why a bolt still costs exactly one pooled part and
	needs no cleanup of its own: destroying the rod takes the trail, the halo and the
	light with it. `scale` thins the whole thing down for the twin guns — but never the
	LENGTH, which is set by frame travel and is the same for any plasma weapon. ]]
local function boltShot(from: Vector3, to: Vector3, color: Color3, scale: number?): number
	local delta = to - from
	local dist = delta.Magnitude
	if dist < 0.1 then
		return 0
	end
	local dir = delta / dist
	local cfg = FX.BOLT_SHOT
	local s = scale or 1
	local life = math.clamp(dist / cfg.SPEED, cfg.MIN_LIFE, cfg.MAX_LIFE)
	local core = hot(color, cfg.CORE_WHITE)
	local width = cfg.WIDTH * s

	local part = newPart(
		"TRACER",
		Vector3.new(cfg.LENGTH, width, width),
		CFrame.lookAt(from, from + dir) * CFrame.Angles(0, math.pi * 0.5, 0),
		core,
		Enum.Material.Neon,
		cfg.TRANSPARENCY
	)
	part.Shape = Enum.PartType.Cylinder

	-- Both trail attachments sit at the TAIL, split across the rod, so the ribbon is
	-- as wide as the slug and streams straight out behind it.
	local half = width * cfg.TRAIL_WIDTH * 0.5
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(-cfg.LENGTH * 0.5, 0, half)
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(-cfg.LENGTH * 0.5, 0, -half)
	a1.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Texture = FX.GLOW_TEXTURE
	trail.TextureMode = Enum.TextureMode.Stretch
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Lifetime = cfg.TRAIL_LIFE
	trail.MinLength = 0
	trail.Color = ColorSequence.new(core, color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent = part

	-- Speed 0 and unlocked from the part: the halo is SHED along the flight path and
	-- left hanging there, which is what gives the bolt a soft edge and a wake.
	local halo = Instance.new("ParticleEmitter")
	halo.Texture = FX.GLOW_TEXTURE
	halo.Color = ColorSequence.new(color)
	halo.LightEmission = 1
	halo.LightInfluence = 0
	halo.Rate = cfg.HALO_RATE
	halo.Lifetime = NumberRange.new(cfg.HALO_LIFE * 0.6, cfg.HALO_LIFE)
	halo.Speed = NumberRange.new(0)
	halo.Rotation = NumberRange.new(0, 360)
	halo.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, cfg.HALO_SIZE * s),
		NumberSequenceKeypoint.new(1, 0),
	})
	halo.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	halo.Parent = part

	if liveBoltLights < cfg.MAX_LIGHTS then
		liveBoltLights += 1
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = cfg.LIGHT_RANGE * s
		light.Brightness = cfg.LIGHT_BRIGHTNESS
		light.Shadows = false
		light.Parent = part
		task.delay(life, function()
			liveBoltLights -= 1
		end)
	end

	track(part, "TRACER", life, {
		fade0 = cfg.TRANSPARENCY,
		fade1 = 0.55, -- still bright when it lands; the impact fx takes over from there
		vel = dir * (dist / life), -- reaches `to` exactly as it expires
	})
	return life
end

local function bolt(from: Vector3, to: Vector3, color: Color3)
	local total = to - from
	local dist = total.Magnitude
	if dist < 0.1 then
		return
	end

	local axis = total.Unit
	local side = axis:Cross(Vector3.yAxis)
	side = side.Magnitude < 1e-3 and Vector3.xAxis or side.Unit
	local up = axis:Cross(side).Unit

	local prev = from
	for i = 1, FX.ZAP.SEGMENTS do
		local t = i / FX.ZAP.SEGMENTS
		local point
		if i == FX.ZAP.SEGMENTS then
			point = to
		else
			local jitter = FX.ZAP.JITTER * dist * math.sin(t * math.pi) -- zero at both ends
			point = from
				+ total * t
				+ side * rng:NextNumber(-jitter, jitter)
				+ up * rng:NextNumber(-jitter, jitter)
		end
		local len = (point - prev).Magnitude
		if len > 1e-3 then
			local part = newPart("BOLT", Vector3.new(FX.ZAP.WIDTH, FX.ZAP.WIDTH, len), segmentCFrame(prev, point), color, Enum.Material.Neon, FX.ZAP.TRANSPARENCY)
			track(part, "BOLT", FX.ZAP.LIFE, { fade0 = FX.ZAP.TRANSPARENCY, fade1 = 1 })
		end
		prev = point
	end
end

--[=[ Pack helpers. Every VfxKit call in this file goes through one of these three, so
	an FX.VFX entry is the only thing that ever has to change to repaint an effect. ]=]
local function vfxBurst(cfg: any, position: Vector3, scale: number?, color: Color3?)
	if not cfg or not cfg.PACK then
		return
	end
	VfxKit.burst(cfg.PACK, position, {
		scale = (cfg.SCALE or 1) * (scale or 1),
		count = cfg.COUNT,
		color = color,
		only = cfg.ONLY,
		skip = cfg.SKIP,
		motion = cfg.SPEED and { speed = cfg.SPEED, spread = cfg.SPREAD, drag = cfg.DRAG } or nil,
	})
end

local function vfxAura(car: Model, key: string, cfg: any, host: BasePart?, color: Color3?)
	if not cfg or not cfg.PACK then
		return
	end
	VfxKit.aura(car, key, cfg.PACK, {
		host = host,
		offset = Vector3.new(0, FX.VFX.AURA_LIFT, 0),
		scale = cfg.SCALE,
		rate = cfg.RATE,
		only = cfg.ONLY,
		skip = cfg.SKIP,
		color = color,
	})
end

--[=[ The flamethrower's jet: ONE rig per shooter, re-aimed by every tick and guttering
	out on its own once the ticks stop. Keyed on the shooter's userId so the local
	prediction and the server echo drive the same rig and can never draw two jets.

	It follows that shooter's LIVE turret muzzle rather than the payload origin: ticks
	arrive at 12 Hz and the car under the barrel is doing 190 studs/s, so hanging fire
	on the payload would leave the flame trailing the nozzle by a car length. ]=]
local function flameJet(userId: number, origin: Vector3, dir: Vector3, color: Color3)
	local cfg = FX.VFX.FLAME
	return VfxKit.jet(userId, cfg.PACK, origin, dir, {
		scale = cfg.SCALE,
		rate = cfg.RATE,
		-- Only the stationary flame sheets are pushed down the barrel; the pack's own
		-- embers keep the wide authored spray that makes the base of the jet read.
		motion = { speed = cfg.SPEED, spread = cfg.SPREAD, drag = cfg.DRAG, direction = Enum.NormalId.Front },
		light = { color = color, range = cfg.LIGHT, brightness = cfg.BRIGHTNESS },
		getPosition = function()
			return safeCall("TurretController", "getMuzzleWorldFor", nil, userId, "FLAME")
		end,
	})
end

-- ==========================================================================
-- § 8) Car helpers. Visuals hug Body/Shell — the Hull is invisible.
-- ==========================================================================
local function carsFolder(): Instance?
	return workspace:FindFirstChild(FX.CARS_FOLDER)
end

local function localCar(): Model?
	local car = safeCall("ChassisController", "getCar", nil)
	if typeof(car) == "Instance" and car:IsA("Model") and car.Parent then
		return car
	end
	-- Fallback so fx still work if ChassisController is unavailable.
	local folder = carsFolder()
	local found = folder and folder:FindFirstChild("Car_" .. tostring(player.UserId))
	if found and found:IsA("Model") then
		return found
	end
	return nil
end

local function localHull(): BasePart?
	local car = localCar()
	if not car then
		return nil
	end
	local hull = ChassisSpec.getHull(car)
	return (hull and hull.Parent) and hull or nil
end

--[=[ The part every car-hugging visual follows: the state shells, the particle auras,
	the nametag, the floating damage numbers and the stagger sparks all take their
	position from this one part.

	It used to be Body/Shell -- CarFactory's single visible block back when the cars were
	PROCEDURAL. That contract died when the cars became the user's own models: Body is
	now a folder of 190-235 loose mesh parts with no Shell among them, so the old
	"first BasePart in Body" fallback silently handed every visual a random piece of
	TRIM. Measured on the shipped cars: a wing mirror 6.56 studs off the centreline
	(blacksuv), a tail light 12.83 studs behind centre (pickup), and a 0.1 x 0.4 x 0.9
	part whose Size then became the size of the frost shell. That is what put the
	nametag out to one side of the car.

	The HULL is the right answer and not the compromise it looks like: cosmeticise
	re-centres the bodywork's measured AABB on the hull's centre, so hull centre IS the
	car's visual centre. Only the HEIGHT differs -- carDef.hull is authored
	2 x GROUND_CLEARANCE shorter than the body -- so anything needing the real bodywork
	EXTENT measures car:GetExtentsSize() rather than taking ref.Size, and anything
	needing the ROOFLINE reads Hull.WeaponMount. ]=]
--[[ The live car a userId is driving. Cars carry OwnerUserId and CarFactory also names
	them Car_<userId>, so the fallback still resolves a model whose attributes have not
	replicated yet. Twelve cars at most and a handful of lookups a second: a scan beats a
	cache that would have to be invalidated on every respawn. ]]
local function carForUser(userId: number?): Model?
	if type(userId) ~= "number" then
		return nil
	end
	local folder = carsFolder()
	if not folder then
		return nil
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") then
			local owner = child:GetAttribute(CAR.OWNER) or tonumber(string.match(child.Name, "^Car_(%d+)$"))
			if owner == userId then
				return child
			end
		end
	end
	return nil
end

local function visualRef(car: Model): BasePart?
	local cached = visualCache[car]
	if cached and cached.Parent then
		return cached
	end

	-- Body/Shell is still checked first so a procedural car would still use its own
	-- visible block; no shipped car has one.
	local body = car:FindFirstChild(ChassisSpec.BODY)
	local shell = body and body:FindFirstChild(FX.SHELL_PART)
	local found = (shell and shell:IsA("BasePart")) and shell or ChassisSpec.getHull(car)
	visualCache[car] = found
	return found
end

--[[ Cached on ChassisSpec.specKey, NOT on the car id: a mode can hand out a modified
	body (the Juggernaut's is 2x) and two cars sharing an id no longer share a spec.
	Keying on the id alone would serve a 2x car the stock car's hover height, and this
	spec is what the skid rays and the landing puffs measure the ground with. ]]
local function resolvedSpec(car: Model)
	local key = ChassisSpec.specKey(car)
	local spec = specCache[key]
	if not spec then
		spec = ChassisSpec.resolveCar(car)
		specCache[key] = spec
	end
	return spec
end

local function nearestCar(position: Vector3, maxDistance: number): Model?
	local folder = carsFolder()
	if not folder then
		return nil
	end
	local best, bestDist = nil, maxDistance
	for _, car in ipairs(folder:GetChildren()) do
		if car:IsA("Model") then
			local hull = ChassisSpec.getHull(car)
			if hull then
				local dist = (hull.Position - position).Magnitude
				if dist <= bestDist then
					best, bestDist = car, dist
				end
			end
		end
	end
	return best
end

--[[ Ground probe for skids and dust.
	RespectCanCollide = true because ArenaService's pads, chevrons, block caps and pit
	shafts are CanCollide = false but still queryable — without it a skid mark would
	float on a pad decoration instead of the floor. Cars are excluded because Hulls ARE
	queryable (only the cosmetics are CanQuery = false), and our own fx never are. ]]
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = true

local function groundHit(from: Vector3, length: number): RaycastResult?
	local filter = { fxFolder() }
	local cars = carsFolder()
	if cars then
		table.insert(filter, cars)
	end
	groundParams.FilterDescendantsInstances = filter
	return workspace:Raycast(from, Vector3.new(0, -length, 0), groundParams)
end

--[[ Distance-scaled screen shake. Falloff is squared so a crash across the arena
	does not shake your screen while the one under your bumper does. ]]
local function shakeIfNear(position: Vector3, radius: number, intensity: number, duration: number)
	local hull = localHull()
	local reference = hull and hull.Position or cameraPos()
	if not reference or radius <= 0 then
		return
	end
	local dist = (position - reference).Magnitude
	if dist > radius then
		return
	end
	local falloff = 1 - dist / radius
	safeCall("CameraController", "shake", nil, intensity * falloff * falloff, duration)
end

-- ==========================================================================
-- § 9) State shells — frozen / shielded / spawn-protected / hurt.
--      Own parts in Workspace.Fx that FOLLOW Body/Shell every frame; we never
--      recolour the car's own parts (they are the server's, and the Hull is invisible).
-- ==========================================================================
local function releaseShell(car: Model, kind: string)
	local perCar = shells[car]
	local entry = perCar and perCar[kind]
	if not entry then
		return
	end
	perCar[kind] = nil
	shellCount = math.max(0, shellCount - 1)
	if entry.part then
		entry.part:Destroy()
	end
	if next(perCar) == nil then
		shells[car] = nil
	end
end

local function releaseAllShells(car: Model)
	local perCar = shells[car]
	if not perCar then
		return
	end
	for kind in pairs(perCar) do
		releaseShell(car, kind)
	end
end

local function ensureShell(car: Model, kind: string, colorOverride: Color3?)
	local cfg = FX.SHELL[kind]
	local perCar = shells[car]
	local existing = perCar and perCar[kind]
	if existing then
		-- One-shot shells (the damage flash) restart on a fresh hit.
		if cfg and cfg.LIFE then
			existing.expiresAt = os.clock() + cfg.LIFE
		end
		return existing
	end
	local ref = visualRef(car)
	if not cfg or not ref or not ref.Parent then
		return nil
	end
	if shellCount >= CAPS.SHELL or not isNear(ref.Position, FX.SHELL.DISTANCE) then
		return nil
	end

	--[[ BOTH shapes measure the MODEL, never ref.Size. ref is the hull, and the hull is
		authored 2 x GROUND_CLEARANCE shorter than the bodywork, so a box taken from it
		sits ~3 studs short and clips through the roof. The car's PrimaryPart IS the
		Hull, so GetExtentsSize is already in hull space -- no yawed-pivot surprise. ]]
	local extents = car:GetExtentsSize()
	local size
	if cfg.SHAPE == "Ball" then
		size = Vector3.one * (math.max(extents.X, extents.Z) * (cfg.SCALE or FX.SHELL.BOX_SCALE))
	else
		size = extents * (cfg.SCALE or FX.SHELL.BOX_SCALE)
	end

	local part = newPart("SHELL_" .. kind, size, ref.CFrame, colorOverride or cfg.COLOR, cfg.MATERIAL, cfg.BASE)
	if cfg.SHAPE == "Ball" then
		part.Shape = Enum.PartType.Ball
	end

	local entry = {
		part = part,
		ref = ref,
		car = car,
		cfg = cfg,
		phase = rng:NextNumber(0, math.pi * 2),
		expiresAt = cfg.LIFE and (os.clock() + cfg.LIFE) or nil,
		-- A ball bubble is centred on the car, not on the shell block.
		centerOnCar = cfg.SHAPE == "Ball",
	}

	perCar = perCar or {}
	perCar[kind] = entry
	shells[car] = perCar
	shellCount += 1
	return entry
end

local function updateShells(now: number)
	for car, perCar in pairs(shells) do
		for kind, entry in pairs(perCar) do
			local ref = entry.ref
			if not car.Parent or not ref or not ref.Parent or not entry.part.Parent then
				releaseShell(car, kind)
			elseif entry.expiresAt and now >= entry.expiresAt then
				releaseShell(car, kind)
			else
				local cfg = entry.cfg
				if entry.centerOnCar then
					local hull = ChassisSpec.getHull(car)
					entry.part.CFrame = CFrame.new((hull or ref).Position)
				else
					entry.part.CFrame = ref.CFrame
				end
				if cfg.AMPLITUDE > 0 then
					entry.part.Transparency = math.clamp(cfg.BASE + math.sin(now * cfg.SPEED + entry.phase) * cfg.AMPLITUDE, 0, 1)
				end
			end
		end
	end
end

-- ==========================================================================
-- § 10) Local prediction receipts (see WeaponController). A receipt suppresses the
--       SOUND of the matching server echo so one shot is never heard twice.
-- ==========================================================================
local function recordPrediction(kind: string, position: Vector3)
	table.insert(predictions, { kind = kind, pos = position, t = os.clock() })
	while #predictions > FX.PREDICT.MAX do
		table.remove(predictions, 1)
	end
end

local function consumePrediction(kind: string, position: Vector3): boolean
	local now = os.clock()
	for i = #predictions, 1, -1 do
		local entry = predictions[i]
		if now - entry.t > FX.PREDICT.WINDOW then
			table.remove(predictions, i)
		elseif entry.kind == kind and (entry.pos - position).Magnitude <= FX.PREDICT.RADIUS then
			table.remove(predictions, i)
			return true
		end
	end
	return false
end

-- ==========================================================================
-- § 11) Server projectile decoration. The projectile PART is server-spawned in
--       Workspace.Projectiles, so we attach a trail/glow/whoosh to it instead of
--       drawing our own path. Classification: name, then attribute, then the most
--       recent matching launch hint (WeaponFx arrives with the spawn).
-- ==========================================================================
local function expectProjectile(kind: string, color: Color3, origin: Vector3)
	table.insert(projHints, { kind = kind, color = color, pos = origin, t = os.clock() })
	while #projHints > FX.PROJECTILE.HINT_MAX do
		table.remove(projHints, 1)
	end
end

local function classifyProjectile(host: Instance, part: BasePart): (string?, Color3?)
	local upper = string.upper(host.Name)
	for id, def in pairs(POWERUPS) do
		if string.find(upper, id, 1, true) then
			return id, def.color
		end
	end

	local attr = host:GetAttribute("PowerupId") or host:GetAttribute("Powerup") or host:GetAttribute("Kind")
	if type(attr) == "string" then
		local def = PowerupDefs.get(string.upper(attr))
		if def then
			return def.id, def.color
		end
	end

	local now = os.clock()
	for i = #projHints, 1, -1 do
		local hint = projHints[i]
		if now - hint.t > FX.PROJECTILE.HINT_WINDOW then
			table.remove(projHints, i)
		elseif (hint.pos - part.Position).Magnitude <= FX.PROJECTILE.HINT_RADIUS then
			table.remove(projHints, i)
			return hint.kind, hint.color
		end
	end
	return nil, nil
end

--[[ Some weapons ship a real mesh for their shell (Assets.Weapons.<id>.Ammo — today
	only the missile). The SERVER's part is left exactly as it is, because that is the
	thing the server steps and everyone agrees on; we only hide it and weld the mesh
	on. So a missing asset degrades to the neon proxy you always had, never to an
	invisible rocket. The mesh is authored nose-along--Z and the shell's CFrame is
	built with CFrame.lookAt, so they already agree — no correction here. ]]
local function skinFlyer(part: BasePart, kind: string?): boolean
	if not kind then
		return false
	end
	local mesh = WeaponRig.ammoClone(kind)
	if not mesh then
		return false
	end
	mesh.Name = "FxSkin"
	-- NOT anchored: a WeldConstraint to the anchored shell makes it ride every
	-- server CFrame write for free, with nothing to update per frame.
	mesh.Anchored = false
	mesh.Massless = true
	mesh.CanCollide = false
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.CastShadow = false
	mesh.CFrame = part.CFrame
	mesh.Parent = part

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part
	weld.Part1 = mesh
	weld.Parent = mesh

	part.Transparency = 1 -- local only; the server never writes this again
	return true
end

--[[ `kind` is what separates a missile from a thrown rock: it is the only thing here
	that knows whether this shell has a motor behind it. Unknown kinds still get the
	trail, the light and the glow, so a new weapon is never invisible. ]]
local function decorateFlyer(part: BasePart, color: Color3, kind: string?)
	local cfg = FX.PROJECTILE
	local half = math.max(part.Size.X, part.Size.Y) * 0.5
	local a0 = Instance.new("Attachment")
	a0.Name = "FxTrailA"
	a0.Position = Vector3.new(-half, 0, 0)
	a0.Parent = part

	local a1 = Instance.new("Attachment")
	a1.Name = "FxTrailB"
	a1.Position = Vector3.new(half, 0, 0)
	a1.Parent = part

	local trail = Instance.new("Trail")
	trail.Name = "FxTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = cfg.TRAIL_LIFETIME
	trail.MinLength = 0
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Texture = FX.GLOW_TEXTURE
	trail.TextureMode = Enum.TextureMode.Stretch
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, cfg.TRAIL_WIDTH),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Color = ColorSequence.new(hot(color, 0.5), color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = part

	local light = Instance.new("PointLight")
	light.Name = "FxLight"
	light.Color = color
	light.Range = cfg.LIGHT_RANGE
	light.Brightness = cfg.LIGHT_BRIGHTNESS
	light.Shadows = false
	light.Parent = part

	-- The shell's own bloom, one emitter. Speed 0 and unlocked from the part, so it is
	-- SHED along the path rather than dragged with it.
	local glowAtt = Instance.new("Attachment")
	glowAtt.Name = "FxGlowAtt"
	glowAtt.Parent = part

	local glow = Instance.new("ParticleEmitter")
	glow.Name = "FxGlow"
	glow.Texture = FX.GLOW_TEXTURE
	glow.Color = ColorSequence.new(color)
	glow.LightEmission = 1
	glow.LightInfluence = 0
	glow.Rate = cfg.GLOW_RATE
	glow.Lifetime = NumberRange.new(cfg.GLOW_LIFE * 0.6, cfg.GLOW_LIFE)
	glow.Speed = NumberRange.new(0)
	glow.Rotation = NumberRange.new(0, 360)
	glow.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, cfg.GLOW_SIZE),
		NumberSequenceKeypoint.new(1, 0),
	})
	glow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	glow.Parent = glowAtt

	--[[ The shell is built with CFrame.lookAt and the ammo meshes are authored
		nose-along--Z, so the TAIL is +Z: EmissionDirection.Back throws the exhaust the
		right way with no maths of our own, and it keeps pointing right through every
		steering correction a homing missile makes. ]]
	if kind == "ROCKET" or kind == "MORTAR" then
		local tail = Instance.new("Attachment")
		tail.Name = "FxTailAtt"
		tail.Position = Vector3.new(0, 0, part.Size.Z * 0.5)
		tail.Parent = part

		if kind == "ROCKET" then
			local exhaust = Instance.new("ParticleEmitter")
			exhaust.Name = "FxExhaust"
			exhaust.Texture = FX.GLOW_TEXTURE
			exhaust.Color = ColorSequence.new(cfg.EXHAUST_COLOR, color)
			exhaust.LightEmission = 1
			exhaust.LightInfluence = 0
			exhaust.Rate = cfg.EXHAUST_RATE
			exhaust.Lifetime = NumberRange.new(cfg.EXHAUST_LIFE * 0.5, cfg.EXHAUST_LIFE)
			exhaust.Speed = NumberRange.new(cfg.EXHAUST_SPEED * 0.6, cfg.EXHAUST_SPEED)
			exhaust.SpreadAngle = Vector2.new(13, 13)
			exhaust.EmissionDirection = Enum.NormalId.Back
			exhaust.Rotation = NumberRange.new(0, 360)
			exhaust.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, cfg.EXHAUST_SIZE),
				NumberSequenceKeypoint.new(1, 0),
			})
			exhaust.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			})
			exhaust.Parent = tail
		end

		-- Smoke is LightEmission 0 on purpose: it is the one part of a shell that must
		-- read as matter rather than as light, or the whole arc glows like neon.
		local smoke = Instance.new("ParticleEmitter")
		smoke.Name = "FxSmoke"
		smoke.Texture = FX.GLOW_TEXTURE
		smoke.Color = ColorSequence.new(cfg.SMOKE_COLOR)
		smoke.LightEmission = 0
		smoke.LightInfluence = 0.4
		smoke.Rate = cfg.SMOKE_RATE
		smoke.Lifetime = NumberRange.new(cfg.SMOKE_LIFE * 0.6, cfg.SMOKE_LIFE)
		smoke.Speed = NumberRange.new(0, 3)
		smoke.SpreadAngle = Vector2.new(25, 25)
		smoke.Rotation = NumberRange.new(0, 360)
		smoke.RotSpeed = NumberRange.new(-40, 40)
		smoke.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, cfg.SMOKE_SIZE * 0.35),
			NumberSequenceKeypoint.new(1, cfg.SMOKE_SIZE),
		})
		smoke.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		smoke.Parent = tail
	end

	attachSound(SFX.WHOOSH, part, true) -- rides the projectile, dies with it
end

local function decorateMine(part: BasePart, color: Color3)
	local light = Instance.new("PointLight")
	light.Name = "FxLight"
	light.Color = color
	light.Range = FX.PROJECTILE.MINE_LIGHT_RANGE
	light.Brightness = FX.PROJECTILE.MINE_LIGHT_MIN
	light.Shadows = false
	light.Parent = part

	-- One tiny emitter beats a per-frame part for something that lives ~22s.
	local attachment = Instance.new("Attachment")
	attachment.Name = "FxMineAtt"
	attachment.Parent = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "FxMineGlow"
	emitter.Rate = FX.PROJECTILE.MINE_EMIT_RATE
	emitter.Lifetime = NumberRange.new(FX.PROJECTILE.MINE_EMIT_LIFE)
	emitter.Speed = NumberRange.new(0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, FX.PROJECTILE.MINE_EMIT_SIZE),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = attachment

	table.insert(pulses, { host = part, light = light, phase = rng:NextNumber(0, math.pi * 2) })
end

-- Mine glow pulse. Decorations are children of the server part, so they die with it.
local function updatePulses(now: number)
	for i = #pulses, 1, -1 do
		local entry = pulses[i]
		if not entry.host.Parent or not entry.light.Parent then
			table.remove(pulses, i)
			decorated = math.max(0, decorated - 1)
		else
			local k = (math.sin(now * FX.PROJECTILE.MINE_PULSE_SPEED + entry.phase) + 1) * 0.5
			entry.light.Brightness = MathUtil.lerp(FX.PROJECTILE.MINE_LIGHT_MIN, FX.PROJECTILE.MINE_LIGHT_MAX, k)
		end
	end
end

-- WeaponService may spawn a projectile as a bare Part or as a Model; resolve the
-- part we can actually attach a trail to, and classify from the spawned host.
local function projectilePart(child: Instance): BasePart?
	if child:IsA("BasePart") then
		return child
	end
	if child:IsA("Model") then
		if child.PrimaryPart then
			return child.PrimaryPart
		end
		for _, descendant in ipairs(child:GetChildren()) do
			if descendant:IsA("BasePart") then
				return descendant
			end
		end
	end
	return nil
end

local function onProjectileAdded(child: Instance)
	if not (child:IsA("BasePart") or child:IsA("Model")) then
		return
	end
	-- Deferred so the server's CFrame/attributes/parts have landed before we classify.
	task.defer(function()
		if not child.Parent or decorated >= FX.PROJECTILE.MAX_DECORATED then
			return
		end
		local part = projectilePart(child)
		if not part then
			return
		end
		local kind, color = classifyProjectile(child, part)
		color = color or UI.PAPER
		decorated += 1
		if kind == "MINE" then
			decorateMine(part, color)
		else
			skinFlyer(part, kind)
			decorateFlyer(part, color, kind)
			-- Flyers are short-lived; release the budget when the part goes.
			child.Destroying:Once(function()
				decorated = math.max(0, decorated - 1)
			end)
		end
	end)
end

-- ==========================================================================
-- § 12) WeaponFx renderer — one handler per pinned kind, dispatched from a table.
-- ==========================================================================
local HANDLERS = {}

--[=[ The plasma DISCHARGE, shared by both plasma weapons. A white-hot core, a light,
	and a disc punched down the barrel: the disc is what tells a bystander which way
	the shot went, since the slug is past them before they can track it. ]=]
local function plasmaMuzzle(origin: Vector3, dir: Vector3?, color: Color3, scale: number)
	local cfg = FX.GUN
	flash(origin, hot(color, 0.55), cfg.MUZZLE_RADIUS * scale, cfg.MUZZLE_LIFE, cfg.MUZZLE_LIGHT * scale)
	if dir then
		disc(origin + dir * 0.7, dir, color, cfg.MUZZLE_DISC * scale, cfg.MUZZLE_DISC_LIFE)
	end
end

-- Pack bursts are rate-limited: a held trigger on one target lands eleven hits a
-- second and eleven lightning bursts a second is a smear, not a hit.
local lastPlasmaVfxAt = 0

--[=[ The impact. A hit on a CAR gets the full splash — a bigger disc, its own light
	and a lightning burst — where a hit on the ground gets a scuff. "Did I connect?"
	is the only question the shooter is asking, and at this fire rate the fx is the
	only thing fast enough to answer it. ]=]
local function plasmaImpact(at: Vector3, dir: Vector3?, color: Color3, scale: number, hitCar: boolean)
	local cfg = FX.GUN
	local back = dir and -dir or Vector3.yAxis
	local size = scale * (hitCar and cfg.CAR_HIT_SCALE or 1)

	flash(at, hot(color, 0.5), cfg.HIT_FLASH * size, cfg.HIT_LIFE, hitCar and cfg.CAR_HIT_LIGHT or nil)
	disc(at + back * 0.4, back, color, cfg.HIT_DISC * size, cfg.HIT_DISC_LIFE)
	burst(at, hot(color, 0.25), math.max(2, math.floor(cfg.HIT_SPARKS * size)), FX.SPARK, back, 0.55)

	if hitCar then
		local now = os.clock()
		if now - lastPlasmaVfxAt >= cfg.VFX_GAP then
			lastPlasmaVfxAt = now
			vfxBurst(FX.VFX.PLASMA_HIT, at, size, color)
		end
	end
end

-- Both plasma weapons want the same two facts out of a payload: where the bolt ended
-- up, and which way it was travelling when it got there.
local function plasmaShot(payload: any, origin: Vector3, def: any): (Vector3?, Vector3?)
	local dir = nil
	if typeof(payload.dir) == "Vector3" and payload.dir.Magnitude > 1e-3 then
		dir = payload.dir.Unit
	end
	local target = typeof(payload.target) == "Vector3" and payload.target or nil
	if not target and dir then
		target = origin + dir * (def.range or 0)
	end
	if target and not dir then
		local delta = target - origin
		dir = delta.Magnitude > 1e-3 and delta.Unit or nil
	end
	return target, dir
end

--[=[ THE PLASMA RAY. One rig per shooter, keyed on userId, so the local prediction and
	the server echo drive the SAME instance and can never draw two rays. Everything hangs
	off the host part as CHILDREN, which is why a ray costs one Destroy to clean up: the
	glow beam, the core, both lights, the end flare and the looped hum all go with it.

	IT IS RE-DERIVED FROM THE CAR EVERY FRAME. The aim is stored in the HULL's object
	space and rebuilt into world space each frame, so between two ticks 70ms apart a car
	doing 190 studs/s swings the whole ray with it. Store the world direction instead and
	the beam visibly detaches from the barrel every time you turn.

	Three layers, because one neon rod reads as a plastic stick:
	  CORE  a thin white-hot Cylinder, round in section so no flat facet catches the light
	        wrong side-on. This is the thing the eye actually tracks.
	  BEAM  a camera-facing Beam with the packs' own soft blur SCROLLING along it. The
	        scroll is what makes it a stream rather than a painted line, and being
	        camera-facing it never thins to nothing when you look down the barrel.
	  ENDS  a flare and a light at the muzzle, another where it lands. The end flare is
	        what says "I am connecting" CONTINUOUSLY, which is what lets the per-tick
	        contact fx be gated as hard as it is. ]=]
local function dropBeam(userId: any)
	local rig = beams[userId]
	if not rig then
		return
	end
	beams[userId] = nil
	beamCount = math.max(0, beamCount - 1)
	if rig.host then
		rig.host:Destroy() -- takes the beam, core, tip, lights and hum with it
	end
end

local function plasmaBeam(userId: number, origin: Vector3, target: Vector3, dir: Vector3, color: Color3, hitCar: boolean)
	local cfg = FX.BEAM
	local now = os.clock()
	local rig = beams[userId]
	if rig and not rig.host.Parent then
		dropBeam(userId)
		rig = nil
	end

	if not rig then
		-- Oldest ray goes first when six people are holding the trigger at once.
		while beamCount >= cfg.MAX_RIGS do
			local oldestId, oldestAt = nil, math.huge
			for id, other in pairs(beams) do
				if other.born < oldestAt then
					oldestId, oldestAt = id, other.born
				end
			end
			if not oldestId then
				break
			end
			dropBeam(oldestId)
		end

		local host = newPart("BEAM", Vector3.one * cfg.MUZZLE_FLARE, CFrame.new(origin), hot(color, 0.5), Enum.Material.Neon, cfg.FLARE_TRANSPARENCY)
		host.Shape = Enum.PartType.Ball

		local a0 = Instance.new("Attachment")
		a0.Parent = host
		local a1 = Instance.new("Attachment")
		a1.Parent = host

		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Texture = FX.GLOW_TEXTURE
		beam.TextureMode = Enum.TextureMode.Wrap
		beam.TextureLength = cfg.TEXTURE_LENGTH
		beam.TextureSpeed = cfg.TEXTURE_SPEED
		beam.FaceCamera = true
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Segments = cfg.SEGMENTS
		beam.Color = ColorSequence.new(color)
		beam.Transparency = NumberSequence.new(cfg.BEAM_TRANSPARENCY)
		beam.Parent = host

		local core = newPart("BEAM", Vector3.one, CFrame.new(origin), hot(color, cfg.CORE_WHITE), Enum.Material.Neon, cfg.CORE_TRANSPARENCY)
		core.Shape = Enum.PartType.Cylinder
		core.Parent = host

		local tip = newPart("BEAM", Vector3.one * cfg.END_FLARE, CFrame.new(target), hot(color, 0.4), Enum.Material.Neon, cfg.FLARE_TRANSPARENCY)
		tip.Shape = Enum.PartType.Ball
		tip.Parent = host

		local muzzleLight = Instance.new("PointLight")
		muzzleLight.Color = color
		muzzleLight.Range = cfg.MUZZLE_LIGHT
		muzzleLight.Brightness = cfg.LIGHT_BRIGHTNESS
		muzzleLight.Shadows = false
		muzzleLight.Parent = host

		local tipLight = Instance.new("PointLight")
		tipLight.Color = color
		tipLight.Range = cfg.END_LIGHT
		tipLight.Brightness = cfg.LIGHT_BRIGHTNESS
		tipLight.Shadows = false
		tipLight.Parent = tip

		rig = {
			host = host,
			beam = beam,
			core = core,
			tip = tip,
			a1 = a1,
			muzzleLight = muzzleLight,
			tipLight = tipLight,
			born = now,
			phase = rng:NextNumber(0, math.pi * 2),
			lastK = -1,
		}
		rig.sound = attachSound(SFX.PLASMA, host, true)
		rig.soundVolume = SFX.PLASMA.volume
		beams[userId] = rig
		beamCount += 1
	end

	rig.origin = origin
	rig.dir = dir
	rig.length = math.max((target - origin).Magnitude, 1)
	rig.hitCar = hitCar
	rig.expiresAt = now + cfg.HOLD

	--[[ Object space, not world space: this is the whole reason the ray stays welded to a
		barrel that is moving 13 studs between ticks. ]]
	local car = carForUser(userId)
	local hull = car and ChassisSpec.getHull(car) or nil
	rig.hull = hull
	rig.localDir = hull and hull.CFrame:VectorToObjectSpace(dir) or nil
end

local function updateBeams(now: number)
	local cfg = FX.BEAM
	for userId, rig in pairs(beams) do
		if not rig.host.Parent then
			dropBeam(userId)
		else
			local left = rig.expiresAt - now
			if left <= -cfg.FADE then
				dropBeam(userId)
			else
				-- 1 while the trigger is down, ramping to 0 through the gutter.
				local k = left >= 0 and 1 or (1 + left / cfg.FADE)

				local from = safeCall("TurretController", "getMuzzleWorldFor", nil, userId, "GUN")
				if typeof(from) ~= "Vector3" then
					from = rig.origin
				end
				local dir = rig.dir
				if rig.localDir and rig.hull and rig.hull.Parent then
					local world = rig.hull.CFrame:VectorToWorldSpace(rig.localDir)
					if world.Magnitude > 1e-3 then
						dir = world.Unit
					end
				end

				local dist = rig.length
				local to = from + dir * dist
				local aim = CFrame.lookAt(from, to)
				local wobble = (1 + math.sin(now * cfg.FLICKER_HZ + rig.phase) * cfg.FLICKER) * k
				local coreWidth = cfg.CORE_WIDTH * wobble

				rig.host.CFrame = aim
				rig.host.Size = Vector3.one * cfg.MUZZLE_FLARE * wobble
				rig.a1.Position = Vector3.new(0, 0, -dist)
				rig.beam.Width0 = cfg.BEAM_WIDTH * wobble
				rig.beam.Width1 = cfg.BEAM_WIDTH * wobble * cfg.BEAM_TAPER
				-- A Cylinder's length runs along its X axis, so the segment frame is yawed 90.
				rig.core.Size = Vector3.new(dist, coreWidth, coreWidth)
				rig.core.CFrame = aim * CFrame.new(0, 0, -dist * 0.5) * CFrame.Angles(0, math.rad(90), 0)
				rig.tip.CFrame = CFrame.new(to)
				rig.tip.Size = Vector3.one * cfg.END_FLARE * (rig.hitCar and cfg.CAR_END_SCALE or 1) * wobble

				--[[ Transparency, volume and light only move while the ray is GUTTERING, so a
					held beam is not rebuilding a NumberSequence sixty times a second. ]]
				if math.abs(k - rig.lastK) > 0.01 then
					rig.lastK = k
					local t = 1 - k
					rig.beam.Transparency = NumberSequence.new(MathUtil.lerp(cfg.BEAM_TRANSPARENCY, 1, t))
					rig.core.Transparency = MathUtil.lerp(cfg.CORE_TRANSPARENCY, 1, t)
					rig.host.Transparency = MathUtil.lerp(cfg.FLARE_TRANSPARENCY, 1, t)
					rig.tip.Transparency = rig.host.Transparency
					rig.muzzleLight.Brightness = cfg.LIGHT_BRIGHTNESS * k
					rig.tipLight.Brightness = cfg.LIGHT_BRIGHTNESS * k
					if rig.sound then
						rig.sound.Volume = rig.soundVolume * k
					end
				end
			end
		end
	end
end

--[[ Where the LOCAL prediction stops drawing. Length only — it never decides a hit, and
	nothing downstream may read it. RespectCanCollide keeps the ray from stopping dead on
	a non-collidable arena decoration, and the local car is excluded so the beam does not
	terminate inside your own bonnet. ]]
local beamParams = nil
local function beamEnd(from: Vector3, dir: Vector3, range: number): (Vector3, boolean)
	if range <= 0 then
		return from + dir, false
	end
	if not beamParams then
		beamParams = RaycastParams.new()
		beamParams.FilterType = Enum.RaycastFilterType.Exclude
		beamParams.RespectCanCollide = true
	end
	local ignore = { fxFolder() }
	local mine = localCar()
	if mine then
		table.insert(ignore, mine)
	end
	local projectiles = workspace:FindFirstChild(FX.PROJECTILE_FOLDER)
	if projectiles then
		table.insert(ignore, projectiles)
	end
	beamParams.FilterDescendantsInstances = ignore

	local result = workspace:Raycast(from, dir * range, beamParams)
	if not result then
		return from + dir * range, false
	end
	local cars = carsFolder()
	return result.Position, cars ~= nil and result.Instance:IsDescendantOf(cars)
end

--[=[ PLASMA GUN. The server casts once per tick; this refreshes ONE continuous ray, and
	the tick rate is invisible because updateBeams draws it every frame in between.

	The contact fx is GATED hard — the ray lands fourteen times a second and fourteen
	splashes a second is a smear, not a hit. The rig's own end flare is what carries
	contact continuously; these are the sparkle on top. Both gates are GLOBAL rather than
	per shooter on purpose: they exist to protect the screen, and the screen does not care
	which of six beams is drawing the splash. ]=]
local lastBeamHitAt = 0
local lastBeamSparkAt = 0

--[=[ THE RAILGUN WIND-UP. One rig per shooter keyed on userId, exactly like the plasma
	ray: the local prediction lights it on the press frame and the server's RAILCHARGE
	echo refreshes the same instance, so nobody ever sees two — and the echo deliberately
	does NOT restart the clock, or your own charge would visibly stutter one ping in.

	This is the weapon's ONLY counterplay, so the tell is built to be read from across the
	arena: the orb swells, the ring closes IN, the diamond sparkle thickens and the whine
	climbs, all four driven off the SAME normalised 0..1 charge so they cannot drift apart.

	It expires GRACE seconds past its own duration. The shot event is what normally kills
	it; that fallback is what stops one dropped packet leaving an orb burning on somebody's
	roof for the rest of the round. ]=]
local function dropRailCharge(userId: any)
	local rig = rails[userId]
	if not rig then
		return
	end
	rails[userId] = nil
	VfxKit.stopJet(rig.jetKey)
	if rig.host then
		rig.host:Destroy() -- takes the ring, the light and the whine with it
	end
end

local function railCharge(userId: number, origin: Vector3, dir: Vector3, color: Color3, duration: number)
	local cfg = FX.RAIL
	local now = os.clock()
	local rig = rails[userId]
	if rig and not rig.host.Parent then
		dropRailCharge(userId)
		rig = nil
	end

	if not rig then
		local host = newPart("RAIL", Vector3.one * cfg.ORB_MIN, CFrame.new(origin), hot(color, 0.45), Enum.Material.Neon, cfg.ORB_TRANSPARENCY)
		host.Shape = Enum.PartType.Ball

		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = cfg.LIGHT_MIN
		light.Brightness = cfg.LIGHT_BRIGHTNESS
		light.Shadows = false
		light.Parent = host

		local ring = newPart("RAIL", Vector3.new(cfg.GATHER_THICKNESS, cfg.GATHER_MAX, cfg.GATHER_MAX), CFrame.new(origin), color, Enum.Material.Neon, cfg.GATHER_TRANSPARENCY)
		ring.Shape = Enum.PartType.Cylinder
		ring.Parent = host

		rig = {
			host = host,
			ring = ring,
			light = light,
			jetKey = "rail" .. tostring(userId),
			startedAt = now, -- set ONCE; the echo must not restart it
			lastJetAt = 0,
			muzzle = origin,
		}
		-- One stable closure, so a 60 Hz updater is not allocating a new one per frame.
		rig.getPosition = function()
			return rig.muzzle
		end
		rig.sound = attachSound(SFX.RAIL_CHARGE, host, true)
		rails[userId] = rig
	end

	rig.origin = origin
	rig.dir = dir
	rig.duration = math.max(duration, 0.05)

	-- Object space, so the orb rides a barrel that is moving 13 studs between packets.
	local car = carForUser(userId)
	local hull = car and ChassisSpec.getHull(car) or nil
	rig.hull = hull
	rig.localDir = hull and hull.CFrame:VectorToObjectSpace(dir) or nil
end

local function updateRailCharges(now: number)
	local cfg = FX.RAIL
	for userId, rig in pairs(rails) do
		if not rig.host.Parent then
			dropRailCharge(userId)
		elseif now - rig.startedAt > rig.duration + cfg.GRACE then
			dropRailCharge(userId)
		else
			local k = MathUtil.clamp01((now - rig.startedAt) / rig.duration)

			local from = safeCall("TurretController", "getMuzzleWorldFor", nil, userId, "RAILGUN")
			if typeof(from) ~= "Vector3" then
				from = rig.origin
			end
			local dir = rig.dir
			if rig.localDir and rig.hull and rig.hull.Parent then
				local world = rig.hull.CFrame:VectorToWorldSpace(rig.localDir)
				if world.Magnitude > 1e-3 then
					dir = world.Unit
				end
			end
			rig.muzzle = from

			-- Squared ease on the orb: a slow gather, then a rush into the shot.
			local wobble = 1 + math.sin(now * cfg.FLICKER_HZ) * cfg.FLICKER * k
			rig.host.CFrame = CFrame.new(from)
			rig.host.Size = Vector3.one * MathUtil.lerp(cfg.ORB_MIN, cfg.ORB_MAX, k * k) * wobble
			rig.light.Range = MathUtil.lerp(cfg.LIGHT_MIN, cfg.LIGHT_MAX, k)
			rig.light.Brightness = cfg.LIGHT_BRIGHTNESS * (0.35 + k)

			-- A Cylinder's flat faces are its X ends, so the disc is yawed onto the aim.
			local radius = MathUtil.lerp(cfg.GATHER_MAX, cfg.GATHER_MIN, k)
			rig.ring.Size = Vector3.new(cfg.GATHER_THICKNESS, radius, radius)
			rig.ring.CFrame = CFrame.lookAt(from + dir * cfg.GATHER_FORWARD, from + dir * (cfg.GATHER_FORWARD + 1)) * CFrame.Angles(0, math.rad(90), 0)
			rig.ring.Transparency = MathUtil.lerp(cfg.GATHER_TRANSPARENCY, 1, k * k)

			if rig.sound then
				rig.sound.PlaybackSpeed = MathUtil.lerp(cfg.PITCH_MIN, cfg.PITCH_MAX, k)
			end

			--[[ The diamond sparkle. Refreshed on a timer, not every frame: a jet only needs
				keeping alive, and VfxKit re-places it off getPosition on its own step. ]]
			if now - rig.lastJetAt >= cfg.VFX_REFRESH then
				rig.lastJetAt = now
				local vcfg = FX.VFX.RAIL_CHARGE
				VfxKit.jet(rig.jetKey, vcfg.PACK, from, dir, {
					scale = vcfg.SCALE,
					rate = vcfg.RATE,
					only = vcfg.ONLY,
					getPosition = rig.getPosition,
				})
			end
		end
	end
end

--[=[ THE RAY. A railgun shot is over before it can be drawn, so what sells it is what
	it LEAVES BEHIND: a rod hanging in the air for half a second and thinning to nothing,
	shock discs punched along its length, and a crater at each end. Both rods are ordinary
	tracked pool parts — the sweeper already does fade-and-thin on a fixed curve, which is
	exactly the curve this wants, and it costs no frame loop of its own. ]=]
local function railRay(from: Vector3, to: Vector3, color: Color3, hitCar: boolean)
	local cfg = FX.RAIL
	local delta = to - from
	local dist = delta.Magnitude
	if dist < 1 then
		return
	end
	local dir = delta / dist
	local back = -dir
	local axis = segmentCFrame(from, to) * CFrame.Angles(0, math.rad(90), 0)

	local glow = newPart("BOLT", Vector3.new(dist, cfg.GLOW_WIDTH, cfg.GLOW_WIDTH), axis, color, Enum.Material.Neon, cfg.GLOW_TRANSPARENCY)
	glow.Shape = Enum.PartType.Cylinder
	track(glow, "BOLT", cfg.LIFE, {
		fade0 = cfg.GLOW_TRANSPARENCY,
		fade1 = 1,
		size0 = glow.Size,
		size1 = Vector3.new(dist, cfg.GLOW_WIDTH * 0.08, cfg.GLOW_WIDTH * 0.08),
	})

	local core = newPart("BOLT", Vector3.new(dist, cfg.CORE_WIDTH, cfg.CORE_WIDTH), axis, hot(color, cfg.CORE_WHITE), Enum.Material.Neon, 0)
	core.Shape = Enum.PartType.Cylinder
	track(core, "BOLT", cfg.CORE_LIFE, {
		fade0 = 0,
		fade1 = 1,
		size0 = core.Size,
		size1 = Vector3.new(dist, cfg.CORE_WIDTH * 0.05, cfg.CORE_WIDTH * 0.05),
	})

	for i = 1, cfg.SHOCKS do
		disc(from + dir * (dist * (i / (cfg.SHOCKS + 1))), dir, color, cfg.SHOCK_SIZE, cfg.SHOCK_LIFE)
	end

	-- The barrel end.
	flash(from, hot(color, 0.6), cfg.MUZZLE_FLASH, cfg.FLASH_LIFE, cfg.MUZZLE_LIGHT)
	disc(from + dir * 1.5, dir, color, cfg.MUZZLE_DISC, cfg.DISC_LIFE)
	puffBurst(from, FX.PUFF.COLOR, cfg.PUFFS, cfg.PUFF_SCALE)

	-- The landing end.
	flash(to, hot(color, 0.5), cfg.HIT_FLASH * (hitCar and cfg.CAR_HIT_SCALE or 1), cfg.FLASH_LIFE, cfg.HIT_LIGHT)
	ring(to, color, cfg.HIT_RING, cfg.HIT_RING_LIFE)
	disc(to + back * 1.2, back, color, cfg.MUZZLE_DISC, cfg.DISC_LIFE)
	burst(to, hot(color, 0.3), cfg.HIT_SPARKS, FX.SPARK, back, 0.6)
	vfxBurst(FX.VFX.RAIL_HIT, to, hitCar and 1.4 or 1, color)

	playSound(SFX.RAIL_SHOT, from)
	playSound(SFX.RAIL_CRACK, to)
	shakeIfNear(from, cfg.SHAKE_RADIUS, cfg.SHAKE_INTENSITY, cfg.SHAKE_TIME)
	shakeIfNear(to, cfg.SHAKE_RADIUS, cfg.SHAKE_INTENSITY * 0.7, cfg.SHAKE_TIME)
end

-- The wind-up, broadcast to everyone the moment the trigger goes down.
HANDLERS.RAILCHARGE = function(payload: any, origin: Vector3)
	local def = POWERUPS.RAILGUN
	local color = pickColor(payload, def and def.color or UI.PAPER)
	if typeof(payload.dir) ~= "Vector3" or payload.dir.Magnitude < 1e-3 then
		return
	end
	local userId = type(payload.userId) == "number" and payload.userId or 0
	railCharge(userId, origin, payload.dir.Unit, color, tonumber(payload.duration) or (def and def.chargeTime) or 1)
end

HANDLERS.RAILGUN = function(payload: any, origin: Vector3)
	local def = POWERUPS.RAILGUN
	local color = pickColor(payload, def.color)
	local userId = type(payload.userId) == "number" and payload.userId or 0
	dropRailCharge(userId) -- the orb BECOMES the shot; it must never outlive it
	local target, dir = plasmaShot(payload, origin, def)
	if not target or not dir then
		return
	end
	railRay(origin, target, color, payload.hitCar == true)
end

HANDLERS.GUN = function(payload: any, origin: Vector3)
	local def = POWERUPS.GUN
	local color = pickColor(payload, def.color)
	local target, dir = plasmaShot(payload, origin, def)
	if not target or not dir then
		return
	end

	local cfg = FX.BEAM
	local userId = type(payload.userId) == "number" and payload.userId or 0
	local hitCar = payload.hitCar == true
	plasmaBeam(userId, origin, target, dir, color, hitCar)

	local now = os.clock()
	if hitCar then
		if now - lastBeamHitAt >= cfg.IMPACT_GAP then
			lastBeamHitAt = now
			plasmaImpact(target, dir, color, cfg.IMPACT_SCALE, true)
		end
	elseif now - lastBeamSparkAt >= cfg.SPARK_GAP then
		lastBeamSparkAt = now
		burst(target, hot(color, 0.25), cfg.SPARKS, FX.SPARK, -dir, 0.55)
	end
	-- No sound here and no prediction receipt to burn: the rig owns a looped hum.
end

--[=[ TWIN GUNS. The plasma gun's draw at two thirds the size, fired about twice as
	often. The barrels alternate, and because the origin in this payload IS the barrel
	that fired (WeaponRig.muzzleWorld reads the shot's own parity), the bolts genuinely
	leave alternate sides. ]=]
HANDLERS.DUALGUN = function(payload: any, origin: Vector3)
	local def = POWERUPS.DUALGUN
	local color = pickColor(payload, def.color)
	local target, dir = plasmaShot(payload, origin, def)
	local scale = FX.GUN.TWIN_SCALE

	plasmaMuzzle(origin, dir, color, scale)
	if target then
		local flight = boltShot(origin, target, color, scale)
		local at, aim, hitCar = target, dir, payload.hitCar == true
		task.delay(flight, function()
			plasmaImpact(at, aim, color, scale, hitCar)
		end)
	end
	if not consumePrediction("DUALGUN", origin) then
		playGatedSound("DUALGUN", SFX.DUALGUN, origin)
	end
end

--[[ The shared launch, drawn by every weapon that spits a projectile.

	The DISC is the part that matters and it is not decoration: with the aim cone
	pinned to zero degrees, a car's bonnet IS its barrel, so a flat ring punched off
	the muzzle tells everyone both who fired and which way it went — from any angle,
	which the muzzle sphere on its own never managed. Sparks are focused down the same
	line for the same reason. ]]
local function launchFx(kind: string, payload: any, origin: Vector3, spec: any)
	local def = POWERUPS[kind]
	local color = pickColor(payload, def and def.color or UI.PAPER)
	local cfg = FX.LAUNCH
	local dir = nil
	if typeof(payload.dir) == "Vector3" and payload.dir.Magnitude > 1e-3 then
		dir = payload.dir.Unit
	end

	puffBurst(origin, FX.PUFF.COLOR, cfg.PUFFS)
	flash(origin, hot(color, 0.5), cfg.FLASH_RADIUS, cfg.FLASH_LIFE, cfg.LIGHT)
	if dir then
		disc(origin + dir * 0.8, dir, color, cfg.DISC, cfg.DISC_LIFE)
		burst(origin + dir * 1.4, hot(color, 0.3), cfg.SPARKS, FX.SPARK, dir, cfg.SPARK_FOCUS)
	end
	if not consumePrediction(kind, origin) then
		playSound(spec, origin)
	end
	expectProjectile(kind, color, origin)
end

HANDLERS.ROCKET = function(payload: any, origin: Vector3)
	launchFx("ROCKET", payload, origin, SFX.LAUNCH)
end

HANDLERS.FREEZE = function(payload: any, origin: Vector3)
	launchFx("FREEZE", payload, origin, SFX.FREEZE)
	vfxBurst(FX.VFX.FREEZE, origin)
end

--[=[ MORTAR. The launch reads like the cannon; what makes it the mortar is the RING
	it paints on the landing spot the instant the shell leaves, sized to the blast and
	closing in over exactly the flight time. Everyone sees it, including whoever is
	parked on it — a weapon that arrives from above has to be dodgeable to be fair. ]=]
HANDLERS.MORTAR = function(payload: any, origin: Vector3)
	local def = POWERUPS.MORTAR
	local color = pickColor(payload, def.color)
	local cfg = FX.MORTAR

	launchFx("MORTAR", payload, origin, SFX.MORTAR)
	flash(origin, hot(color, 0.45), cfg.FLASH_RADIUS, cfg.FLASH_LIFE, cfg.LIGHT)
	puffBurst(origin, FX.PUFF.COLOR, cfg.SMOKE, cfg.SMOKE_SCALE)
	-- Its own ring over the shared one: the tube throws harder than a rocket does.
	if typeof(payload.dir) == "Vector3" and payload.dir.Magnitude > 1e-3 then
		local aim = payload.dir.Unit
		disc(origin + aim, aim, color, cfg.MUZZLE_DISC, cfg.MUZZLE_DISC_LIFE)
	end
	shakeIfNear(origin, cfg.SHAKE_RADIUS, cfg.SHAKE_INTENSITY, cfg.SHAKE_TIME)

	local target = typeof(payload.target) == "Vector3" and payload.target or nil
	if not target then
		return
	end
	local diameter = pickRadius(payload, def.blastRadius) * 2
	local life = tonumber(payload.flight) or cfg.MARK_LIFE
	-- Cylinder parts lie along X, so stand it up flat exactly as a mine disc does.
	local mark = newPart("RING", Vector3.new(cfg.MARK_THICKNESS, diameter * cfg.MARK_START_SCALE, diameter * cfg.MARK_START_SCALE),
		CFrame.new(target + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		color, Enum.Material.Neon, cfg.MARK_TRANSPARENCY)
	mark.Shape = Enum.PartType.Cylinder
	track(mark, "RING", life, {
		fade0 = cfg.MARK_TRANSPARENCY,
		fade1 = cfg.MARK_TRANSPARENCY * 0.4, -- it gets STRONGER as it closes, then is gone
		size0 = mark.Size,
		size1 = Vector3.new(cfg.MARK_THICKNESS, diameter, diameter),
	})
end

--[[ CANNON. The shared launch fx plus the weight the shot deserves: extra sparks
	and a shake with no distance test, because the person who feels a cannon most is
	the one who fired it. ]]
HANDLERS.CANNON = function(payload: any, origin: Vector3)
	local color = pickColor(payload, POWERUPS.CANNON.color)
	local cfg = FX.CANNON
	local dir = nil
	if typeof(payload.dir) == "Vector3" and payload.dir.Magnitude > 1e-3 then
		dir = payload.dir.Unit
	end

	launchFx("CANNON", payload, origin, SFX.CANNON)
	-- A second, bigger flash over the shared launch one: this is the heaviest shot in
	-- the game and it should be the brightest thing on screen for a tenth of a second.
	flash(origin, hot(color, 0.45), cfg.FLASH_RADIUS, cfg.FLASH_LIFE, cfg.LIGHT)
	puffBurst(origin, FX.PUFF.COLOR, cfg.SMOKE, cfg.SMOKE_SCALE)
	--[[ And its own muzzle ring over the shared one, half again as wide, because the
		big gun should be legible from across the arena. `dir` goes nil only if the
		server ever stops sending it, and then every directional draw here degrades to
		the old omnidirectional one rather than vanishing. ]]
	if dir then
		disc(origin + dir, dir, color, cfg.MUZZLE_DISC, cfg.MUZZLE_DISC_LIFE)
	end
	burst(origin, hot(color, 0.3), cfg.SPARKS, FX.SPARK, dir, cfg.SPARK_FOCUS)
	shakeIfNear(origin, cfg.SHAKE_RADIUS, cfg.SHAKE_INTENSITY, cfg.SHAKE_TIME)
end

--[=[ FLAMETHROWER. No projectile and no impact event: the server burns a cone every
	tick, so this fires about twelve times a second and the jet has to live BETWEEN
	those ticks rather than be redrawn by each one.

	The jet is the authored FIRE pack (VfxKit.jet): the first tick builds it, every
	later tick re-aims it, and it gutters out on its own when the trigger comes up. If
	the pack is missing the old neon balls below still draw, so the weapon can never
	become invisible — they are the fallback, not the effect. ]=]
HANDLERS.FLAME = function(payload: any, origin: Vector3)
	local def = POWERUPS.FLAME
	local color = pickColor(payload, def.color)
	if typeof(payload.dir) ~= "Vector3" or payload.dir.Magnitude < 1e-3 then
		return
	end
	local dir = payload.dir.Unit

	local userId = type(payload.userId) == "number" and payload.userId or 0
	local jet = flameJet(userId, origin, dir, color)

	--[[ The jet itself lives BETWEEN ticks (VfxKit.jet), but the nozzle should still
		flare, or the one weapon you hold down is the one with no muzzle. Gated on a
		single shared clock exactly like playGatedSound: twelve flares a second is a
		strobe, and at that rate nobody can tell whose nozzle they are looking at. ]]
	local nowFlame = os.clock()
	if nowFlame - lastFlameDiscAt >= FX.FLAME.DISC_GAP then
		lastFlameDiscAt = nowFlame
		disc(origin + dir * 0.8, dir, hot(color, 0.25), FX.FLAME.DISC, FX.FLAME.DISC_LIFE)
	end

	if not jet then
		local cfg = FX.FLAME
		local reach = pickRadius(payload, def.range) * cfg.LENGTH_FRACTION
		for i = 1, cfg.SEGMENTS do
			local k = (i - 0.5) / cfg.SEGMENTS
			local width = MathUtil.lerp(cfg.START_WIDTH, cfg.END_WIDTH, k)
			local part = newPart("FLAME", Vector3.one * width, CFrame.new(origin + dir * (reach * k)), color, Enum.Material.Neon, cfg.TRANSPARENCY)
			part.Shape = Enum.PartType.Ball
			if i == 1 and (cfg.LIGHT or 0) > 0 then
				local light = Instance.new("PointLight")
				light.Color = color
				light.Range = cfg.LIGHT
				light.Brightness = FX.FLASH.LIGHT_BRIGHTNESS
				light.Shadows = false
				light.Parent = part -- dies with the puff, so a held jet never stacks lights
			end
			track(part, "FLAME", cfg.LIFE, {
				fade0 = cfg.TRANSPARENCY,
				fade1 = 1,
				size0 = part.Size,
				size1 = part.Size * cfg.GROW,
				vel = dir * cfg.DRIFT,
			})
		end
	end

	if not consumePrediction("FLAME", origin) then
		playGatedSound("FLAME", SFX.FLAME, origin)
	end
end

HANDLERS.MINE = function(payload: any, origin: Vector3)
	local color = pickColor(payload, POWERUPS.MINE.color)
	ring(origin, color, FX.MINE.RING_RADIUS, FX.MINE.RING_LIFE)
	if not consumePrediction("MINE", origin) then
		playSound(SFX.MINE_ARM, origin)
	end
	expectProjectile("MINE", color, origin)
end

HANDLERS.ZAP = function(payload: any, origin: Vector3)
	local color = pickColor(payload, POWERUPS.ZAP.color)
	local target = typeof(payload.target) == "Vector3" and payload.target or nil

	flash(origin, color, FX.ZAP.END_FLASH, FX.ZAP.LIFE)
	if target then
		bolt(origin, target, color)
		flash(target, color, FX.ZAP.END_FLASH, FX.ZAP.LIFE)
		burst(target, color, FX.ZAP.SPARKS, FX.SPARK)
		vfxBurst(FX.VFX.ZAP, target, 1, color)
	else
		-- No target: draw the aoe footprint so the radius still reads.
		ring(origin, color, pickRadius(payload, POWERUPS.ZAP.radius), FX.ZAP.RING_LIFE)
	end
	if not consumePrediction("ZAP", origin) then
		playSound(SFX.ZAP, origin)
	end
end

HANDLERS.SHIELD = function(payload: any, origin: Vector3)
	local color = pickColor(payload, POWERUPS.SHIELD.color)
	local car = nearestCar(origin, FX.SHELL.MATCH_RADIUS)
	if car then
		ensureShell(car, "SHIELD", color)
	end
	flash(origin, color, FX.SHIELD.POP_RADIUS, FX.SHIELD.FLASH_LIFE)
	if not consumePrediction("SHIELD", origin) then
		playSound(SFX.SHIELD_UP, origin)
	end
end

HANDLERS.SHIELD_POP = function(payload: any, origin: Vector3)
	local color = pickColor(payload, POWERUPS.SHIELD.color)
	local car = nearestCar(origin, FX.SHELL.MATCH_RADIUS)
	if car then
		releaseShell(car, "SHIELD")
	end
	flash(origin, color, FX.SHIELD.POP_RADIUS, FX.SHIELD.POP_LIFE)
	ring(origin, color, FX.SHIELD.POP_RADIUS, FX.SHIELD.POP_LIFE)
	burst(origin, color, FX.SHIELD.POP_SPARKS, FX.SPARK)
	vfxBurst(FX.VFX.SHIELD_POP, origin, 1, color)
	playSound(SFX.SHIELD_POP, origin)
end

-- The workhorse: every explosion, blast and pickup pop routes through here.
HANDLERS.IMPACT = function(payload: any, origin: Vector3)
	local color = pickColor(payload, UI.GOLD)
	local radius = pickRadius(payload, FX.IMPACT.DEFAULT_RADIUS)
	local scale = radius / FX.IMPACT.DEFAULT_RADIUS

	--[[ Three shapes, in the order the eye reads them: the coloured fireball with the
		light on it, a white-hot core that dies twice as fast, and a thin ring running
		out past both as the pressure wave. The light is capped at 60 studs of range by
		choice, not by the engine — see FX.IMPACT.LIGHT_SCALE. ]]
	local cfg = FX.IMPACT
	flash(origin, color, radius, cfg.FLASH_LIFE, math.clamp(radius * cfg.LIGHT_SCALE, 0, 60))
	flash(origin, hot(color, 0.75), radius * cfg.CORE_SCALE, cfg.CORE_LIFE)
	ring(origin, color, radius, cfg.RING_LIFE)
	ring(origin, hot(color, 0.55), radius * cfg.SHOCK_SCALE, cfg.SHOCK_LIFE)
	burst(origin, color, cfg.DEBRIS, FX.DEBRIS)
	burst(origin, hot(color, 0.2), cfg.DEBRIS, FX.SPARK)
	--[=[ The particles that make an explosion read as fire rather than as sparks. This
		one kind carries both bombs and pickup pops (PickupService and LuckyBlockService
		both reuse it), so the pack is whatever the server named in payload.vfx, and
		failing that it is chosen by radius. ]=]
	local named = type(payload.vfx) == "string" and FX.VFX.POP[payload.vfx] or nil
	if named then
		vfxBurst(named, origin, 1, color)
	elseif radius >= FX.VFX.BLAST_MIN_RADIUS then
		vfxBurst(FX.VFX.BLAST, origin, scale)
	else
		vfxBurst(FX.VFX.POP.GOLD, origin, 1, color)
	end
	playSound(SFX.IMPACT, origin, math.clamp(scale, 0.7, 1.4))
	shakeIfNear(origin, radius * FX.IMPACT.SHAKE_SCALE, FX.IMPACT.SHAKE_INTENSITY, FX.IMPACT.SHAKE_TIME)
end

-- ==========================================================================
-- § 7b) Hit feedback. One fx kind ("HIT") carries every damage event out of
--       CombatService's single funnel, so a ram, a rocket, a mortar shell and one
--       tick of flame all announce themselves the same way.
-- ==========================================================================

--[[ Drive the victim's highlight away from its base colour and let it fall back.

	The envelope is an INSTANT attack and a SQUARED decay: it lands on the frame of the
	hit and is most of the way home a tenth of a second later. Anything with a rise on it
	reads as a pulsing light rather than as an impact.

	A fresh hit never DIMS one still fading — the residual of the old flash is measured
	and the larger of the two wins, so a machine-gun chip landing on the tail of a cannon
	hit cannot black the cannon out. ]]
local function flashHighlight(car: Model?, strength: number, killed: boolean?)
	local entry = car and highlights[car]
	if not entry or not entry.hl.Parent then
		return
	end
	local cfg = FX.HL
	local now = os.clock()

	local residual = 0
	if entry.hitAt then
		residual = (entry.strength or 0) * (1 - MathUtil.clamp01((now - entry.hitAt) / (entry.hitTime or cfg.HIT_TIME)))
	end

	entry.hitAt = now
	entry.hitTime = killed and cfg.KILL_TIME or cfg.HIT_TIME
	entry.hitColor = killed and cfg.KILL_COLOR or cfg.HIT_COLOR
	entry.strength = math.max(killed and 1 or strength, residual)
end

local function updateHighlights(now: number)
	local cfg = FX.HL
	for _, entry in pairs(highlights) do
		if entry.hitAt then
			local hl = entry.hl
			if not hl.Parent then
				entry.hitAt = nil
			else
				local k = 1 - MathUtil.clamp01((now - entry.hitAt) / entry.hitTime)
				if k <= 0 then
					-- Home: back to whatever colour bindHighlight chose (mode / self / rival).
					entry.hitAt = nil
					entry.strength = 0
					hl.FillColor = entry.color
					hl.OutlineColor = entry.color
					hl.FillTransparency = cfg.FILL_TRANSPARENCY
					hl.OutlineTransparency = cfg.OUTLINE_TRANSPARENCY
				else
					local s = MathUtil.clamp01(entry.strength * k * k)
					hl.FillColor = entry.color:Lerp(entry.hitColor, s)
					hl.OutlineColor = hl.FillColor
					hl.FillTransparency = MathUtil.lerp(cfg.FILL_TRANSPARENCY, cfg.HIT_FILL, s)
				end
			end
		end
	end
end

--[[ THE DAMAGE POP — the number, and the cross over a car you just hit.

	It rides its own anchored host in Workspace.Fx rather than the victim's bodywork, for
	one reason: the pop that matters most is the one on the KILLING blow, and a billboard
	parented to that car dies with it in the same frame. The host follows the car for as
	long as the car exists and then holds the last position it saw.

	The marker is two rotated Frames rather than a glyph, so it can never come out as a
	tofu box in a font with no multiplication sign, and it recolours to gold on a kill. ]]
local function stylePop(entry: any)
	local cfg = FX.HIT
	local color = entry.dealt and (entry.killed and cfg.KILL_TEXT_COLOR or cfg.DEALT_COLOR) or cfg.SELF_COLOR
	entry.label.Text = "-" .. tostring(math.floor(entry.amount + 0.5))
	entry.label.TextColor3 = color
	for _, bar in ipairs(entry.markBars) do
		bar.BackgroundColor3 = color
	end
	entry.punchAt = os.clock()
	entry.punch = entry.killed and cfg.POP_KILL_PUNCH or cfg.POP_PUNCH
end

-- The list owns the host, but a dead frame loop must never leak one. Re-armed on every
-- merge; an earlier backstop finds the pop younger than its life and does nothing.
local function armPop(entry: any)
	task.delay(entry.life + FX.HARD_KILL_GRACE, function()
		if entry.host.Parent and (os.clock() - entry.born) >= entry.life then
			entry.host:Destroy()
		end
	end)
end

local function hitPop(car: Model?, position: Vector3, amount: number, dealt: boolean, killed: boolean)
	local cfg = FX.HIT
	local now = os.clock()

	--[[ MERGE into the number already floating over this victim. The hold weapons land
		eight or more separate hits a second even after the server coalesces them, and one
		number climbing 12 -> 25 -> 37 reads as a burst where eight stacked 3s read as
		noise. Past MERGE_TIME it is a NEW engagement and gets its own number. ]]
	local live = car and popByCar[car]
	if live and live.host.Parent and (now - live.born) <= cfg.MERGE_TIME then
		live.amount += amount
		live.born = now -- a fresh hit buys the whole number a fresh life
		live.killed = live.killed or killed
		live.dealt = live.dealt or dealt
		stylePop(live)
		armPop(live)
		return
	end

	while #pops >= CAPS.POP do
		local oldest = table.remove(pops, 1)
		if oldest then
			if oldest.car and popByCar[oldest.car] == oldest then
				popByCar[oldest.car] = nil
			end
			oldest.host:Destroy()
		end
	end

	local host = newPart("POP", cfg.HOST_SIZE, CFrame.new(position + Vector3.new(0, cfg.POP_HEIGHT, 0)), UI.PAPER, Enum.Material.SmoothPlastic, 1)

	local gui = Instance.new("BillboardGui")
	gui.Name = "CrashHitPop"
	gui.Size = UDim2.fromScale(cfg.POP_WIDTH, cfg.POP_TOTAL_HEIGHT)
	gui.AlwaysOnTop = true
	gui.MaxDistance = math.huge -- the confirmation is worth MORE the further away it is
	gui.LightInfluence = 0
	gui.Adornee = host
	gui.Parent = host

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromScale(0.5, 1)
	label.Size = UDim2.fromScale(1, cfg.POP_TEXT_HEIGHT)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = ""
	label.Parent = gui

	local strokes = {}
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Color = UI.INK
	labelStroke.Thickness = cfg.STROKE
	labelStroke.Parent = label
	table.insert(strokes, labelStroke)

	--[[ The marker belongs to the ATTACKER alone: a number over a car is information,
		a cross over it is a claim. ]]
	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.BackgroundTransparency = 1
	mark.AnchorPoint = Vector2.new(0.5, 0)
	mark.Position = UDim2.fromScale(0.5, 0)
	mark.Size = UDim2.fromScale(cfg.POP_MARK_WIDTH, cfg.POP_MARK_HEIGHT)
	mark.Visible = dealt
	mark.Parent = gui

	local markBars = {}
	for _, rotation in ipairs({ 45, -45 }) do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.fromScale(cfg.MARK_BAR_LENGTH, cfg.MARK_BAR_THICKNESS)
		bar.Rotation = rotation
		bar.BorderSizePixel = 0
		bar.Parent = mark
		local barStroke = Instance.new("UIStroke")
		barStroke.Color = UI.INK
		barStroke.Thickness = cfg.STROKE
		barStroke.Parent = bar
		table.insert(markBars, bar)
		table.insert(strokes, barStroke)
	end

	local entry = {
		host = host,
		gui = gui,
		label = label,
		strokes = strokes,
		markBars = markBars,
		car = car,
		anchor = position,
		amount = amount,
		dealt = dealt,
		killed = killed,
		born = now,
		life = cfg.POP_LIFE,
	}
	stylePop(entry)
	table.insert(pops, entry)
	if car then
		popByCar[car] = entry
	end
	armPop(entry)
end

local function updatePops(now: number)
	local cfg = FX.HIT
	for i = #pops, 1, -1 do
		local entry = pops[i]
		local age = now - entry.born
		if not entry.host.Parent or age >= entry.life then
			table.remove(pops, i)
			if entry.car and popByCar[entry.car] == entry then
				popByCar[entry.car] = nil
			end
			entry.host:Destroy()
		else
			local k = age / entry.life
			--[[ Follow the car while it lives, then hold: a car doing 190 studs a second
				leaves a world-anchored number behind instantly, and a number parented to the
				car vanishes on the one hit you most wanted to see land. ]]
			local ref = entry.car and entry.car.Parent and visualRef(entry.car) or nil
			if ref and ref.Parent then
				entry.anchor = ref.Position
			end
			entry.host.CFrame = CFrame.new(entry.anchor + Vector3.new(0, cfg.POP_HEIGHT + cfg.POP_RISE * k, 0))

			-- Scale punch on every fresh hit: eased-out overshoot, no tween.
			local punchAge = now - entry.punchAt
			local scale = 1
			if punchAge < cfg.POP_PUNCH_TIME then
				local p = 1 - (punchAge / cfg.POP_PUNCH_TIME)
				scale += entry.punch * p * p
			end
			entry.gui.Size = UDim2.fromScale(cfg.POP_WIDTH * scale, cfg.POP_TOTAL_HEIGHT * scale)

			local fade = 0
			if k > cfg.POP_FADE_AT then
				fade = MathUtil.clamp01((k - cfg.POP_FADE_AT) / (1 - cfg.POP_FADE_AT))
			end
			entry.label.TextTransparency = fade
			for _, stroke in ipairs(entry.strokes) do
				stroke.Transparency = fade
			end
			for _, bar in ipairs(entry.markBars) do
				bar.BackgroundTransparency = fade
			end
		end
	end
end

--[[ HIT — every damage event, from the ONE funnel in CombatService, coalesced there
	per attacker/victim pair so a flamethrower does not send fourteen of these a second.
	payload: victimId, attackerId, amount, hp, maxHp, killed. The origin is the victim's
	hull, NOT a muzzle — this is the one kind that names a victim rather than a shooter,
	which is also why it does not reuse the userId field every other kind fills with the
	SHOOTER (TurretController reads that one, and would kick the wrong car's turret). ]]
HANDLERS.HIT = function(payload: any, origin: Vector3)
	local victimId = type(payload.victimId) == "number" and payload.victimId or nil
	if not victimId then
		return
	end
	local cfg = FX.HIT
	local amount = tonumber(payload.amount) or 0
	local killed = payload.killed == true
	local maxHp = tonumber(payload.maxHp) or ((Config.HP_PER_CHUNK or 100) * 4)
	local car = carForUser(victimId)

	-- Everyone sees this half, including the two cars' bystanders.
	local strength = math.max(
		FX.HL.HIT_MIN_STRENGTH,
		MathUtil.clamp01(amount / math.max(maxHp * FX.HL.HIT_FULL_FRACTION, 1))
	)
	flashHighlight(car, strength, killed)

	local attackerId = type(payload.attackerId) == "number" and payload.attackerId or nil
	local dealt = attackerId == player.UserId and victimId ~= player.UserId
	local onMe = victimId == player.UserId
	if amount <= 0 or (not dealt and not onMe) then
		return -- somebody else's fender bender
	end

	hitPop(car, origin, amount, dealt, killed)
	if not dealt then
		return
	end

	local now = os.clock()
	if now - lastHitSparkAt >= cfg.SPARK_GAP then
		lastHitSparkAt = now
		burst(origin, cfg.DEALT_COLOR, cfg.SPARKS, FX.SPARK)
	end
	if killed then
		playSound(SFX.KO) -- 2D: this one is about you, not about where the wreck is
		safeCall("CameraController", "shake", nil, cfg.KILL_SHAKE, cfg.KILL_SHAKE_TIME)
	elseif now - lastHitPingAt >= cfg.PING_GAP then
		lastHitPingAt = now
		playSound(SFX.HIT)
	end
end

HANDLERS.RAM = function(payload: any, origin: Vector3)
	local color = pickColor(payload, UI.PAPER)
	flash(origin, color, FX.RAM.FLASH_RADIUS, FX.RAM.FLASH_LIFE)
	burst(origin, color, FX.RAM.SPARKS, FX.SPARK)
	vfxBurst(FX.VFX.RAM, origin) -- the shove puff, at the contact point between the two cars
	playSound(SFX.RAM, origin)
	--[[ Proximity shake: the contact point sits between the two cars, so being within
		FX.RAM.SHAKE_RADIUS means you were in the crash (as attacker or victim).
		Squared falloff keeps other people's fender-benders off your screen. ]]
	shakeIfNear(origin, FX.RAM.SHAKE_RADIUS, FX.RAM.SHAKE_INTENSITY, FX.RAM.SHAKE_TIME)
end

local function onWeaponFx(kind: any, payload: any)
	if type(kind) ~= "string" then
		return
	end
	local handler = HANDLERS[kind]
	if not handler then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	local origin = payload.origin
	if typeof(origin) ~= "Vector3" then
		return
	end
	if not isNear(origin, FX.CULL_DISTANCE) then
		return -- far side of the arena: no parts, no sound, no cost
	end

	--[[ payload.origin IS the firing car's barrel: WeaponService takes it from the
		client that fired, which is the only side that knows where its turret points.
		So the flash, the tracer's near end and the flame jet all start on the gun with
		nothing to re-derive here — and MINE (dropped BEHIND the car), ZAP, SHIELD and
		the IMPACT / RAM events keep the car-centred origins they always had. ]]
	local ok, err = pcall(handler, payload, origin)
	if not ok then
		warnOnce("fx:" .. kind, "WeaponFx '" .. kind .. "' handler errored -> " .. tostring(err))
	end
end

-- ==========================================================================
-- § 13) Local prediction seam — called by WeaponController on the press frame.
--       Muzzle flash + launch sound ONLY. Never damage, hits or ammo.
-- ==========================================================================
function FxController.predictFire(powerupId: any, origin: any, dir: any)
	local def = PowerupDefs.get(type(powerupId) == "string" and powerupId or nil)
	if not def or typeof(origin) ~= "Vector3" then
		return
	end

	local color = def.color or UI.PAPER

	--[=[ The plasma gun is a HELD ray, so its prediction IS the ray: light the same rig
		the server echo drives (both keyed on your userId) and skip the per-press flash,
		spark and sound entirely — at fourteen presses a second those three are a strobe
		and a rattle over something meant to read as one continuous beam. The local cast
		decides where to stop DRAWING and nothing else; the server still owns every hit. ]=]
	if def.id == "GUN" and typeof(dir) == "Vector3" and dir.Magnitude > 1e-3 then
		local aim = dir.Unit
		local to, hitCar = beamEnd(origin, aim, def.range or 0)
		plasmaBeam(player.UserId, origin, to, aim, color, hitCar)
		return
	end

	--[=[ The railgun's press does not fire anything — it starts a wind-up the server
		resolves a second later — so the prediction is the CHARGE, lit on the press frame.
		The server's own RAILCHARGE echo refreshes this same rig without restarting its
		clock, so the orb you see is yours from the first frame and still in step with the
		shot everyone else sees. ]=]
	if def.id == "RAILGUN" and typeof(dir) == "Vector3" and dir.Magnitude > 1e-3 then
		railCharge(player.UserId, origin, dir.Unit, color, def.chargeTime or 1)
		return
	end

	flash(origin, color, FX.PREDICT.FLASH_RADIUS, FX.PREDICT.FLASH_LIFE)
	if typeof(dir) == "Vector3" and dir.Magnitude > 1e-3 then
		burst(origin + dir.Unit * FX.PREDICT.SPARK_FORWARD, color, FX.PREDICT.SPARKS, FX.SPARK)
	end
	--[=[ The flamethrower is a HELD weapon, so its jet is the one prediction worth more
		than a flash: light it locally on the press frame. The server echo re-aims this
		same rig (both are keyed on your userId), so there is never a second jet. ]=]
	if def.id == "FLAME" and typeof(dir) == "Vector3" and dir.Magnitude > 1e-3 then
		flameJet(player.UserId, origin, dir.Unit, color)
	end

	playGatedSound(def.id, PREDICT_SFX[def.id], origin)
	recordPrediction(def.id, origin) -- so the server echo stays silent
end

-- ==========================================================================
-- § 14) Local driving fx — skids, boost, wind, landing, hit response.
--       All manual math on the one RenderStepped.
-- ==========================================================================
local function laySkids(car: Model, hull: BasePart, speed: number)
	local spec = resolvedSpec(car)
	local hit = groundHit(hull.Position, spec.hoverHeight + FX.SKID.RAY_LENGTH)
	if not hit then
		return -- airborne or over a pit: nothing to mark
	end

	local cf = hull.CFrame
	local _, yaw = cf:ToOrientation()
	local length = math.clamp(speed * FX.SKID.INTERVAL * FX.SKID.LENGTH_SCALE, FX.SKID.LENGTH[1], FX.SKID.LENGTH[2])
	local size = Vector3.new(FX.SKID.WIDTH, FX.SKID.THICKNESS, length)

	for _, side in ipairs({ -1, 1 }) do
		local local_ = Vector3.new(side * hull.Size.X * FX.SKID.SIDE_FRACTION, 0, hull.Size.Z * FX.SKID.BACK_FRACTION)
		local world = cf:PointToWorldSpace(local_)
		local at = Vector3.new(world.X, hit.Position.Y + FX.SKID.Y_OFFSET, world.Z)
		local part = newPart("SKID", size, CFrame.new(at) * CFrame.fromEulerAnglesYXZ(0, yaw, 0), FX.SKID.COLOR, Enum.Material.SmoothPlastic, FX.SKID.TRANSPARENCY)
		track(part, "SKID", FX.SKID.LIFE, { fade0 = FX.SKID.TRANSPARENCY, fade1 = 1 })
	end
end

local function layBoostStreaks(hull: BasePart)
	local cf = hull.CFrame
	for _, side in ipairs({ -1, 1 }) do
		local at = cf:PointToWorldSpace(Vector3.new(side * hull.Size.X * FX.BOOST.SIDE_FRACTION, 0, hull.Size.Z * FX.BOOST.BACK_FRACTION))
		local color = FX.BOOST.COLORS[rng:NextInteger(1, #FX.BOOST.COLORS)]
		local part = newPart("BOOST", FX.BOOST.SIZE, CFrame.new(at, at + cf.LookVector), color, Enum.Material.Neon, FX.BOOST.TRANSPARENCY)
		track(part, "BOOST", FX.BOOST.LIFE, {
			fade0 = FX.BOOST.TRANSPARENCY,
			fade1 = 1,
			size0 = part.Size,
			size1 = part.Size * FX.BOOST.GROW,
		})
	end
end

local function layWindStreak()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local cf = cam.CFrame
	local side = rng:NextInteger(0, 1) == 0 and -1 or 1
	local at = cf:PointToWorldSpace(Vector3.new(
		side * rng:NextNumber(FX.WIND.SIDE[1], FX.WIND.SIDE[2]),
		rng:NextNumber(-FX.WIND.VERTICAL, FX.WIND.VERTICAL),
		-FX.WIND.AHEAD
	))
	local part = newPart("WIND", FX.WIND.SIZE, CFrame.new(at, at + cf.LookVector), UI.PAPER, Enum.Material.Neon, FX.WIND.TRANSPARENCY)
	track(part, "WIND", FX.WIND.LIFE, {
		fade0 = FX.WIND.TRANSPARENCY,
		fade1 = 1,
		vel = -cf.LookVector * FX.WIND.SPEED,
	})
end

local function updateDriving(dt: number, now: number)
	local car = localCar()
	if not car then
		drive.airtime = 0
		drive.wasBoosting = false
		drive.wasStaggered = false
		return
	end
	local hull = ChassisSpec.getHull(car)
	if not hull or not hull.Parent then
		return
	end

	local sNow = serverNow()
	local speed = safeCall("ChassisController", "getSpeed", 0)
	local fraction = safeCall("ChassisController", "getSpeedFraction", 0)
	local grounded = safeCall("ChassisController", "isGrounded", true)
	local drifting = safeCall("ChassisController", "isDrifting", false)
	local staggered = ChassisSpec.isStaggered(car, sNow)

	-- Skid marks: the single biggest "this feels like Crash of Cars" detail.
	if drifting and grounded and fraction >= FX.SKID.MIN_SPEED_FRACTION and now - drive.lastSkidAt >= FX.SKID.INTERVAL then
		drive.lastSkidAt = now
		laySkids(car, hull, speed)
	end

	-- Boost trail + one whoosh on the rising edge.
	-- Read the CONTROLLER, not the server attribute: pad boosts and the mini-turbo are
	-- predicted locally, so the attribute alone leaves them with no trail and no whoosh.
	local boosting = safeCall("ChassisController", "isBoosting", false)
	if boosting then
		if not drive.wasBoosting then
			playSound(SFX.BOOST, hull.Position)
		end
		if now - drive.lastBoostAt >= FX.BOOST.INTERVAL then
			drive.lastBoostAt = now
			layBoostStreaks(hull)
		end
	end
	drive.wasBoosting = boosting

	--[[ Wind streaks at speed. Suppressed while staggered: right after a hit the
		car is being shoved, and streaks on top of the shake reads as noise. ]]
	if fraction >= FX.WIND.MIN_FRACTION and not staggered and now - drive.lastWindAt >= FX.WIND.INTERVAL then
		drive.lastWindAt = now
		layWindStreak()
	end

	-- Landing thump after meaningful airtime.
	if grounded then
		if not drive.wasGrounded and drive.airtime >= FX.LAND.MIN_AIRTIME then
			local k = MathUtil.clamp01(drive.airtime / FX.LAND.MAX_AIRTIME)
			local hit = groundHit(hull.Position, resolvedSpec(car).hoverHeight + FX.SKID.RAY_LENGTH)
			local at = hit and hit.Position or (hull.Position - Vector3.new(0, resolvedSpec(car).hoverHeight, 0))
			puffBurst(at, FX.PUFF.COLOR, FX.LAND.PUFFS, FX.LAND.PUFF_SCALE)
			playSound(SFX.LAND, at, 0.7 + k * 0.6)
			safeCall("CameraController", "shake", nil, FX.LAND.SHAKE_INTENSITY * k, FX.LAND.SHAKE_TIME)
		end
		drive.airtime = 0
	else
		drive.airtime += dt
	end
	drive.wasGrounded = grounded

	--[[ Stagger is the server telling us THIS car just took knockback — the one
		signal that is guaranteed to be about us, so it drives the "I got hit" shake. ]]
	if staggered and not drive.wasStaggered then
		local ref = visualRef(car) or hull
		burst(ref.Position, UI.PAPER, FX.STAGGER.SPARKS, FX.SPARK)
		safeCall("CameraController", "shake", nil, FX.STAGGER.SHAKE_INTENSITY, Config.RAM.STAGGER_SECONDS)
	end
	drive.wasStaggered = staggered

	-- Damage flash on the visible bodywork (never the invisible Hull).
	local hp = car:GetAttribute(CAR.HP)
	if drive.lastCar ~= car then
		drive.lastCar = car
		drive.lastHp = hp
	elseif type(hp) == "number" and type(drive.lastHp) == "number" and hp < drive.lastHp then
		ensureShell(car, "HURT")
	end
	if type(hp) == "number" then
		drive.lastHp = hp
	end
end

-- ==========================================================================
-- § 15) Car state pass (10 Hz) — frozen / shielded / spawn-protected shells on
--       EVERY car, so you can read at a glance why a ram did nothing.
-- ==========================================================================
--[=[ Particle auras for the car states. Two of these already had a shell and now have
	a texture as well; two never had any tell at all:

	  BURN  a car under a third of its health trails smoke. The only readout a rival's
	        health had was the bar on its nametag, and you cannot read a bar while you
	        are steering — smoke you can see out of the corner of your eye.
	  JUGG  the monster wears the mode's own colour, so "that one is the juggernaut"
	        survives being seen from behind, at distance, mid-pack.

	Auras are Attachments parented INTO the car's own body part, so they follow it for
	free and die with it. VfxKit.aura is idempotent, which is what lets a 10 Hz pass
	call it blindly with no bookkeeping here. ]=]
local function updateCarAuras(car: Model, ref: BasePart, driver: Player?, sNow: number)
	local V = FX.VFX

	if ChassisSpec.isFrozen(car, sNow) then
		vfxAura(car, "FROST", V.FROST, ref)
	else
		VfxKit.clearAura(car, "FROST")
	end

	if driver and driver:GetAttribute(ATTR.SHIELDED) == true then
		vfxAura(car, "SHIELD", V.SHIELD, ref)
	else
		VfxKit.clearAura(car, "SHIELD")
	end

	if driver and driver:GetAttribute(ATTR.JUGGERNAUT) == true then
		vfxAura(car, "JUGG", V.JUGGERNAUT, ref, GameModes.colorFor(driver))
	else
		VfxKit.clearAura(car, "JUGG")
	end

	if ChassisSpec.isBoosting(car, sNow) then
		vfxAura(car, "BOOST", V.BOOST, ref)
	else
		VfxKit.clearAura(car, "BOOST")
	end

	local hp = tonumber(car:GetAttribute(CAR.HP))
	local maxHp = tonumber(car:GetAttribute(CAR.MAX_HP))
	if hp and maxHp and maxHp > 0 and hp > 0 and (hp / maxHp) <= V.BURNING_HP then
		vfxAura(car, "BURN", V.BURNING, ref)
	else
		VfxKit.clearAura(car, "BURN")
	end
end

local function updateCarStates()
	local folder = carsFolder()
	if not folder then
		return
	end
	local sNow = serverNow()

	for _, car in ipairs(folder:GetChildren()) do
		if car:IsA("Model") then
			local ref = visualRef(car)
			if ref then
				if ChassisSpec.isFrozen(car, sNow) then
					ensureShell(car, "FROST")
				else
					releaseShell(car, "FROST")
				end

				if ChassisSpec.isInvulnerable(car, sNow) then
					ensureShell(car, "INVULN")
				else
					releaseShell(car, "INVULN")
				end

				local owner = car:GetAttribute(CAR.OWNER)
				local driver = type(owner) == "number" and Players:GetPlayerByUserId(owner) or nil
				if driver and driver:GetAttribute(ATTR.SHIELDED) == true then
					ensureShell(car, "SHIELD")
				elseif driver then
					releaseShell(car, "SHIELD")
				end

				updateCarAuras(car, ref, driver, sNow)
			end
		end
	end
end

-- ==========================================================================
-- § 16) Nametags — name + crowns + HP bar on every RIVAL car, and a bare HP bar on
--       your own. Knowing who is nearly dead is what makes players chase, so the bar
--       is built to be read in a glance off a moving car: the fill is always the
--       truth, a white ghost drains behind it to show what the last hit cost, and
--       under a third it breathes.
-- ==========================================================================
local function hpColor(fraction: number): Color3
	if fraction >= 0.5 then
		return UI.GOLD:Lerp(UI.CONFIRM, MathUtil.clamp01((fraction - 0.5) * 2))
	end
	return UI.DANGER:Lerp(UI.GOLD, MathUtil.clamp01(fraction * 2))
end

local function inkStroke(parent: Instance, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = UI.INK
	stroke.Parent = parent
	return stroke
end

--[[ The MODE's score, which is not always crowns: Deathmatch counts wrecks and
	Juggernaut counts points, and a tag reading "0 CROWNS" for a whole round is worse
	than no line at all. ScoreService keeps Config.ATTR.SCORE in step with whichever
	number the mode places on, so this reads ONE attribute and never branches on the
	mode itself — only the noun does. ]]
local function refreshScore(entry: any)
	local count = entry.player and entry.player:GetAttribute(ATTR.SCORE) or 0
	if type(count) ~= "number" then
		count = 0
	end
	-- Never on your own tag: the HUD already carries your score, and yours is a bar.
	entry.crowns.Visible = not entry.isSelf and count > 0
	entry.crowns.Text = MathUtil.comma(count) .. " " .. string.upper(GameModes.scoreNoun())
end

--[[ Chunk dividers — one boundary every Config.HP_PER_CHUNK points, matching the
	HUD's segmented bar, so "two chunks left" means the same thing on the car you are
	chasing as it does on your own. Boundaries are placed at ABSOLUTE health, not at
	even fractions, so a car whose max is not a whole multiple still shows real chunks
	plus a short remainder. Rebuilt only when MaxHp changes (a car swap), never per hit. ]]
local function rebuildChunks(entry: any, maxHp: number)
	entry.chunkMax = maxHp
	for _, divider in ipairs(entry.chunks) do
		divider:Destroy()
	end
	table.clear(entry.chunks)

	local perChunk = Config.HP_PER_CHUNK or 100
	local count = math.min(math.ceil(maxHp / perChunk), FX.TAG.CHUNK_MAX)
	for i = 1, count - 1 do
		local divider = Instance.new("Frame")
		divider.Name = "Chunk" .. i
		divider.AnchorPoint = Vector2.new(0.5, 0.5)
		divider.Position = UDim2.fromScale(math.clamp((i * perChunk) / maxHp, 0, 1), 0.5)
		divider.Size = UDim2.fromScale(FX.TAG.CHUNK_WIDTH, 1)
		divider.BackgroundColor3 = UI.INK
		divider.BorderSizePixel = 0
		divider.ZIndex = 5 -- above the fill (3) and the damage ghost (2)
		divider.Parent = entry.bar
		table.insert(entry.chunks, divider)
	end
end

local function refreshHp(entry: any)
	local hp = entry.car:GetAttribute(CAR.HP)
	local maxHp = entry.car:GetAttribute(CAR.MAX_HP)
	if type(hp) ~= "number" or type(maxHp) ~= "number" or maxHp <= 0 then
		return
	end
	if entry.chunkMax ~= maxHp then
		rebuildChunks(entry, maxHp)
	end

	local fraction = MathUtil.clamp01(hp / maxHp)
	local previous = entry.fraction
	entry.fraction = fraction
	entry.baseColor = hpColor(fraction)
	entry.fill.Size = UDim2.fromScale(fraction, 1)
	entry.fill.BackgroundColor3 = entry.baseColor
	entry.tinted = false

	if previous == nil then
		-- First read of a fresh car: level the ghost, or spawning flashes a phantom hit.
		entry.ghostFraction = fraction
		entry.ghost.Size = UDim2.fromScale(fraction, 1)
		return
	end
	if fraction < previous then
		--[[ The ghost KEEPS the old value. Repeat hits inside the hold pool into ONE
			sliver (math.max), so a burst reads as one big bite rather than as several
			small ones racing each other down the bar. ]]
		entry.ghostFraction = math.max(entry.ghostFraction or previous, previous)
		entry.ghostHold = FX.TAG.GHOST_HOLD
		entry.flashUntil = os.clock() + FX.TAG.HIT_FLASH
		entry.flashColor = FX.TAG.HIT_COLOR
		entry.punch = 1
	elseif fraction > previous then
		-- Healing has nothing to trail: the ghost jumps forward with the fill.
		entry.ghostFraction = fraction
		entry.ghost.Size = UDim2.fromScale(fraction, 1)
		entry.ghostHold = 0
		entry.flashUntil = os.clock() + FX.TAG.HIT_FLASH
		entry.flashColor = FX.TAG.HEAL_COLOR
	end
end

--[[ One frame of tag motion. Four things move, each skipped when it has nothing to
	do, so a full grid of idle tags costs a handful of comparisons:

	  GHOST  holds, then drains to meet the fill.
	  FLASH  the fill whitens on damage / greens on a heal, and decays out.
	  PULSE  a nearly-dead bar breathes (see FX.TAG.LOW_FRACTION).
	  SCALE  the BILLBOARD pops on spawn, the BAR punches on damage -- two different
	         objects on purpose: the arrival should carry the name with it, the punch
	         should not shove the name around every time someone lands a shot.

	Manual lerp math on the one RenderStepped, per this module's no-TweenService rule. ]]
local function updateTag(entry: any, dt: number, now: number)
	local T = FX.TAG
	local fraction = entry.fraction or 1

	if entry.ghostFraction and entry.ghostFraction > fraction then
		if entry.ghostHold > 0 then
			entry.ghostHold -= dt
		else
			entry.ghostFraction = math.max(fraction, entry.ghostFraction - T.GHOST_DRAIN * dt)
			entry.ghost.Size = UDim2.fromScale(entry.ghostFraction, 1)
		end
	end

	local flashing = entry.flashUntil > now
	local low = fraction > 0 and fraction <= T.LOW_FRACTION
	if flashing or low then
		local color = entry.baseColor or UI.CONFIRM
		local wave = low and (0.5 + 0.5 * math.sin(now * math.pi * 2 * T.LOW_PULSE_HZ)) or 0
		if flashing then
			color = color:Lerp(entry.flashColor, (entry.flashUntil - now) / T.HIT_FLASH)
		elseif low then
			color = color:Lerp(UI.PAPER, wave * T.LOW_PULSE_DEPTH)
		end
		entry.fill.BackgroundColor3 = color
		--[[ The alarm is the OUTLINE, not the fill. Pulsing a red bar toward white
			de-saturates the one colour that means danger -- measured on the probe, the
			peak read PALER and therefore calmer than the base. Running the stroke from
			INK to DANGER instead keeps the fill hot and puts the motion on the edge,
			which is also the part still legible on a car across the arena. ]]
		if low then
			entry.stroke.Color = UI.INK:Lerp(T.LOW_STROKE_COLOR, wave)
		end
		entry.tinted = true
	elseif entry.tinted then
		entry.fill.BackgroundColor3 = entry.baseColor or UI.CONFIRM
		entry.stroke.Color = UI.INK
		entry.tinted = false
	end

	if entry.popT < 1 then
		entry.popT = math.min(1, entry.popT + dt / T.POP_TIME)
		-- back-out ease: it overshoots 1 near the end, which is what makes it a POP
		local k = entry.popT - 1
		local eased = 1 + 2.70158 * k * k * k + 1.70158 * k * k
		local s = T.POP_SCALE + (1 - T.POP_SCALE) * eased
		entry.gui.Size = UDim2.fromScale(entry.guiW * s, entry.guiH * s)
	end

	if entry.punch > 0 then
		entry.punch = math.max(0, entry.punch - dt / T.PUNCH_TIME)
		local s = 1 + T.PUNCH_SCALE * entry.punch
		entry.bar.Size = UDim2.fromScale(entry.barW * s, entry.barH * s)
	end
end

local function updateTags(dt: number, now: number)
	for _, entry in pairs(tags) do
		updateTag(entry, dt, now)
	end
end

local function buildTag(car: Model, adornee: BasePart, driver: Player?, isSelf: boolean?)
	local gui = Instance.new("BillboardGui")
	gui.Name = FX.TAG.NAME
	local guiW = isSelf and FX.TAG.SELF_WIDTH or FX.TAG.WIDTH
	local guiH = isSelf and FX.TAG.SELF_HEIGHT or FX.TAG.HEIGHT
	-- Built at the popped-DOWN size; updateTag eases it up over POP_TIME.
	gui.Size = UDim2.fromScale(guiW * FX.TAG.POP_SCALE, guiH * FX.TAG.POP_SCALE)
	--[[ Height is measured from Hull.WeaponMount -- the pinned "top of the bodywork, on
		the centreline" point CarFactory stamps on every car (ChassisSpec.mountOffset).
		`adornee.Size.Y * 0.5` only ever meant anything while the adornee was the one
		Shell block: on the trim part it used to pick it meant nothing at all, which is
		why the tag sat 0.83 studs INSIDE the pickup and 1.57 above the blacksuv's roof.
		OFFSET / SELF_OFFSET are therefore now studs above the ROOFLINE, and they are
		the same distance on every car. ]]
	local hullRef = ChassisSpec.getHull(car)
	local mount = hullRef and hullRef:FindFirstChild(ChassisSpec.MOUNT_ATT)
	local roof = mount and mount.Position.Y or adornee.Size.Y * 0.5
	gui.StudsOffsetWorldSpace =
		Vector3.new(0, roof + (isSelf and FX.TAG.SELF_OFFSET or FX.TAG.OFFSET), 0)
	gui.AlwaysOnTop = true
	-- Distance culling is for the pack. Your own tag is never the one worth culling.
	gui.MaxDistance = (isSelf or not FX.CULL_ENABLED) and math.huge or FX.TAG.MAX_DISTANCE
	gui.LightInfluence = 0
	gui.Adornee = adornee
	gui.Parent = adornee -- dies with the car, no cleanup race

	local name = Instance.new("TextLabel")
	name.Name = "DriverName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, FX.TAG.NAME_HEIGHT)
	name.Position = UDim2.fromScale(0, 0)
	name.Font = Enum.Font.GothamBlack
	name.TextScaled = true
	name.TextColor3 = UI.PAPER
	name.Text = driver and driver.DisplayName or FX.TAG.FALLBACK_NAME
	--[[ Tinted by the MODE where it has an opinion: a team-mate's name is their side's
		colour and the juggernaut's is its own, because "red = rival" stops being a safe
		read the moment the game has sides. Every other mode keeps the plain PAPER name. ]]
	local modeTint = driver and GameModes.colorFor(driver) or nil
	if modeTint then
		name.TextColor3 = modeTint
	end
	name.Visible = not isSelf
	name.Parent = gui
	inkStroke(name, FX.TAG.STROKE)

	local crowns = Instance.new("TextLabel")
	crowns.Name = "Crowns"
	crowns.BackgroundTransparency = 1
	crowns.Size = UDim2.fromScale(1, FX.TAG.CROWN_HEIGHT)
	crowns.Position = UDim2.fromScale(0, FX.TAG.NAME_HEIGHT)
	crowns.Font = Enum.Font.GothamBlack
	crowns.TextScaled = true
	crowns.TextColor3 = UI.GOLD
	crowns.Text = ""
	crowns.Visible = false
	crowns.Parent = gui
	inkStroke(crowns, FX.TAG.STROKE)

	local bar = Instance.new("Frame")
	bar.Name = "HpBar"
	--[[ With both labels gone a self tag has nothing to sit under, so its bar is centred
		rather than pinned to the bottom of an otherwise empty billboard. ]]
	bar.AnchorPoint = Vector2.new(0.5, isSelf and 0.5 or 1)
	bar.Position = UDim2.fromScale(0.5, isSelf and 0.5 or 1)
	local barW = isSelf and FX.TAG.SELF_BAR_WIDTH or FX.TAG.BAR_WIDTH
	local barH = isSelf and FX.TAG.SELF_BAR_HEIGHT or FX.TAG.BAR_HEIGHT
	bar.Size = UDim2.fromScale(barW, barH)
	bar.BackgroundColor3 = UI.INK
	bar.BorderSizePixel = 0
	bar.Parent = gui
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0.5, 0)
	barCorner.Parent = bar
	local barStroke = inkStroke(bar, FX.TAG.STROKE)

	--[[ Damage ghost. It sits BEHIND the fill and is the same shape, so while the two
		agree it is invisible with no visibility bookkeeping at all -- it only ever
		shows as the sliver between the old health and the new. ]]
	local ghost = Instance.new("Frame")
	ghost.Name = "Ghost"
	ghost.Size = UDim2.fromScale(1, 1)
	ghost.BackgroundColor3 = FX.TAG.HIT_COLOR
	ghost.BackgroundTransparency = FX.TAG.GHOST_TRANSPARENCY
	ghost.BorderSizePixel = 0
	ghost.ZIndex = 2
	ghost.Parent = bar
	local ghostCorner = Instance.new("UICorner")
	ghostCorner.CornerRadius = UDim.new(0.5, 0)
	ghostCorner.Parent = ghost

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UI.CONFIRM
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = bar
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill
	--[[ A UIGradient MULTIPLIES the background, so the bar gains the house gloss while
		hpColor still owns the hue on its own -- no second colour to keep in step. ]]
	local fillGloss = Instance.new("UIGradient")
	fillGloss.Rotation = 90
	local low = FX.TAG.GLOSS_LOW
	fillGloss.Color = ColorSequence.new(UI.PAPER, Color3.new(low, low, low))
	fillGloss.Parent = fill

	local entry = {
		gui = gui,
		car = car,
		player = driver,
		name = name,
		crowns = crowns,
		bar = bar,
		fill = fill,
		ghost = ghost,
		stroke = barStroke,
		chunks = {},
		chunkMax = -1,
		conns = {},
		isSelf = isSelf or false,
		-- Animation state, advanced by updateTag on the one frame loop. fraction and
		-- ghostFraction stay nil until the refreshHp below takes the first reading.
		guiW = guiW,
		guiH = guiH,
		barW = barW,
		barH = barH,
		baseColor = UI.CONFIRM,
		ghostHold = 0,
		flashUntil = 0,
		flashColor = FX.TAG.HIT_COLOR,
		punch = 0,
		popT = 0,
		tinted = false,
	}
	tags[car] = entry
	tagCount += 1

	table.insert(entry.conns, car:GetAttributeChangedSignal(CAR.HP):Connect(function()
		refreshHp(entry)
	end))
	table.insert(entry.conns, car:GetAttributeChangedSignal(CAR.MAX_HP):Connect(function()
		refreshHp(entry)
	end))
	if driver then
		table.insert(entry.conns, driver:GetAttributeChangedSignal(ATTR.SCORE):Connect(function()
			refreshScore(entry)
		end))
	end

	refreshHp(entry)
	refreshScore(entry)
	return entry
end

local function dropTag(car: Model)
	local entry = tags[car]
	if not entry then
		return
	end
	tags[car] = nil
	tagCount = math.max(0, tagCount - 1)
	for _, conn in ipairs(entry.conns) do
		conn:Disconnect()
	end
	if entry.gui then
		entry.gui:Destroy()
	end
end

--[[ Through-wall car highlights -- the pass that makes a 903-stud arena readable.
	Every car wears a Highlight in AlwaysOnTop depth mode, so you keep tracking the pack
	through walls, ramp backs and the pit lip instead of losing a rival the moment
	geometry gets between you.

	Adornee is the car MODEL on purpose, and that is safe ONLY because Highlight skips
	Transparency = 1 parts: the invisible Hull contributes nothing and the silhouette
	hugs the real bodywork (verified in the viewport against a hull-sized box). This is
	the one car-hugging visual in this file exempt from the "never adorn the Hull" rule,
	because it never actually lands on it.

	Colour is the whole signal: yours green, every rival red. Deliberately NOT distance
	culled the way nametags are -- seeing the far car through the map IS the feature. ]]
local function bindHighlight(car: Model, owner: number?)
	if highlights[car] or highlightCount >= CAPS.HIGHLIGHT then
		return
	end
	local mine = owner ~= nil and owner == player.UserId

	--[[ The MODE gets first say on the colour. The juggernaut wears its own purple to
		EVERYONE (including itself — you want to see what you have become), and in Team
		Battle a car wears its side, because green-is-me / red-is-everyone-else stops
		being useful the moment half the reds are friends.

		Bound once and never refreshed, deliberately: every event that could change this
		answer — teams being dealt at the round start, the crown changing hands mid-round
		— rebuilds the car, and the new model arrives back here for a fresh highlight. ]]
	local driver = type(owner) == "number" and Players:GetPlayerByUserId(owner) or nil
	local modeColor = driver and GameModes.colorFor(driver) or nil

	local hl = Instance.new("Highlight")
	hl.Name = FX.HL.NAME
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	local color = modeColor or (mine and FX.HL.SELF_COLOR or FX.HL.RIVAL_COLOR)
	hl.FillColor = color
	hl.OutlineColor = color
	hl.FillTransparency = FX.HL.FILL_TRANSPARENCY
	hl.OutlineTransparency = FX.HL.OUTLINE_TRANSPARENCY
	hl.Adornee = car
	hl.Parent = car -- dies with the car, no cleanup race

	--[[ The ENTRY is what lives in this table, not the Highlight: the hit flash drives
		colour and fill transparency away from these two base values every time this car
		is damaged, and needs somewhere to remember what to put back. ]]
	highlights[car] = { hl = hl, color = color, strength = 0 }
	highlightCount += 1
end

local function dropHighlight(car: Instance)
	local entry = highlights[car]
	if not entry then
		return
	end
	highlights[car] = nil
	highlightCount = math.max(0, highlightCount - 1)
	entry.hl:Destroy()
end

--[[ Cars arrive from CarFactory possibly before their Hull/attributes replicate, so
	resolve with a bounded poll and re-check the car still exists after every yield. ]]
local function onCarAdded(car: Instance)
	if not car:IsA("Model") or tags[car] then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + FX.TAG.RESOLVE_TIMEOUT
		local adornee, owner
		while os.clock() < deadline do
			if not car.Parent then
				return
			end
			adornee = visualRef(car)
			owner = car:GetAttribute(CAR.OWNER) or tonumber(string.match(car.Name, "^Car_(%d+)$"))
			if adornee and owner then
				break
			end
			task.wait(FX.TAG.RESOLVE_POLL)
		end

		if not car.Parent or tags[car] then
			return
		end

		-- EVERY car, your own included. This runs ahead of the two returns below,
		-- which skip the NAMETAG only -- the highlight is not a nametag decoration.
		bindHighlight(car, owner)

		if not adornee then
			return
		end
		--[[ Your own car is tagged FIRST and OUTSIDE the CAPS.TAG budget: it is a single
			tag, it is the one you look at most, and a crowded arena must never be the
			reason your own health stops rendering. ]]
		if owner == player.UserId then
			if FX.TAG.SELF_ENABLED then
				buildTag(car, adornee, player, true)
			end
			return
		end
		if tagCount >= CAPS.TAG then
			return
		end
		buildTag(car, adornee, type(owner) == "number" and Players:GetPlayerByUserId(owner) or nil)
	end)
end

local function onCarRemoved(car: Instance)
	if not car:IsA("Model") then
		return
	end
	dropTag(car)
	dropHighlight(car)
	releaseAllShells(car)
	VfxKit.clearAuras(car) -- the attachments died with the car; this drops the bookkeeping
	visualCache[car] = nil
	if drive.lastCar == car then
		drive.lastCar = nil
		drive.lastHp = nil
	end
end

-- ==========================================================================
-- § 17) Folder watching. Server folders may not exist yet, and may be rebuilt.
-- ==========================================================================
local function watchFolder(name: string, onAdd: (Instance) -> (), onRemove: ((Instance) -> ())?)
	local function bind(folder: Instance)
		if boundFolders[folder] then
			return
		end
		boundFolders[folder] = true
		for _, child in ipairs(folder:GetChildren()) do
			onAdd(child)
		end
		folder.ChildAdded:Connect(onAdd)
		if onRemove then
			folder.ChildRemoved:Connect(onRemove)
		end
	end

	local existing = workspace:FindFirstChild(name)
	if existing then
		bind(existing)
	end
	-- Stays connected: a folder rebuilt mid-session is re-bound (bind is idempotent).
	workspace.ChildAdded:Connect(function(child)
		if child.Name == name then
			bind(child)
		end
	end)
end

-- ==========================================================================
-- § 18) init
-- ==========================================================================
local function step(dt: number)
	local now = os.clock()
	sweep(dt)
	updateShells(now)
	updatePulses(now)
	updateHighlights(now)
	updatePops(now)
	updateBeams(now)
	updateRailCharges(now)
	VfxKit.step(dt) -- pack bursts age out; live flame jets follow their shooters' muzzles
	updateDriving(dt, now)
	updateTags(dt, now) -- ghost drain, hit flash, low-hp pulse, spawn pop

	stateAccum += dt
	if stateAccum >= FX.STATE_INTERVAL then
		stateAccum = 0
		updateCarStates()
	end
end

function FxController.init(ctx)
	ctxRef = ctx
	fxFolder()

	local remote = ctx.net and ctx.net.WeaponFx
	if remote then
		remote.OnClientEvent:Connect(onWeaponFx)
	else
		warnOnce("net.WeaponFx", "WeaponFx remote missing — server fx will not render")
	end

	watchFolder(FX.CARS_FOLDER, onCarAdded, onCarRemoved)
	watchFolder(FX.PROJECTILE_FOLDER, onProjectileAdded, nil)

	Players.PlayerRemoving:Connect(function(leaving)
		for car, entry in pairs(tags) do
			if entry.player == leaving then
				dropTag(car)
			end
		end
	end)

	-- ONE frame loop for the whole juice layer. pcall keeps a bad frame from
	-- spamming output or stranding fx parts mid-fade.
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warnOnce("step", "render step errored -> " .. tostring(err))
		end
	end)
end

return FxController
