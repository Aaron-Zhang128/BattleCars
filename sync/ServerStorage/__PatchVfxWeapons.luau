--[[ __PatchVfxWeapons — a re-runnable patch for the two edits that keep getting
	rolled back by Studio's undo stack: Config (the MORTAR / DUALGUN weapon defs and
	rig art contract) and FxController (the particle-pack wiring plus the two new
	weapons' fx).

	Every edit is ANCHORED and IDEMPOTENT: it looks for a marker first and skips if the
	change is already in place, so `require(this).apply()` can be run any number of
	times and after any partial revert. It writes each file exactly ONCE, so the whole
	patch is a single undo waypoint per script.

	Delete this module once the edits stick. Nothing in the game requires it.
]]

local Patch = {}

local CONFIG_EDITS = {
	{
		marker = '"lob" | "place"',
		anchor = '-- kind: "projectile" | "place" | "hitscan" | "aoe" | "self" | "cone"',
		replacement = '-- kind: "projectile" | "lob" | "place" | "hitscan" | "aoe" | "self" | "cone"',
	},
	{
		marker = "SIX of these are MODELLED",
		anchor = [==[-- FOUR of these are MODELLED weapons: they physically bolt onto the car roof and
-- animate when they fire (GUN, ROCKET, CANNON, FLAME). Their ART contract is]==],
		replacement = [==[-- SIX of these are MODELLED weapons: they physically bolt onto the car roof and
-- animate when they fire (GUN, ROCKET, CANNON, FLAME, MORTAR, DUALGUN). Their ART contract is]==],
	},
	{
		marker = "MORTAR = {",
		anchor = [==[	MINE = {
		id = "MINE",]==],
		replacement = [==[	--[=[ MORTAR (Assets.Weapons.MORTAR). The indirect weapon: the shell LOBS, so it is
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
		id = "MINE",]==],
	},
	{
		marker = "contract for the six",
		anchor = "-- WEAPON_RIGS — the ART contract for the four modelled weapons.",
		replacement = "-- WEAPON_RIGS — the ART contract for the six modelled weapons.",
	},
	{
		marker = "Muzzle2 optional second barrel",
		anchor = [==[--   Muzzle  recoils / spins when it fires. ABSENT on CANNON and ROCKET, where the
--           Turret itself IS the moving barrel — recoilPart names whichever moves.]==],
		replacement = [==[--   Muzzle  recoils / spins when it fires. ABSENT on CANNON and ROCKET, where the
--           Turret itself IS the moving barrel — recoilPart names whichever moves.
--   Muzzle2 optional second barrel (DUALGUN). Poses exactly like Muzzle, so a twin
--           gun needs no new pose code — only `muzzleSpread`, which alternates which
--           barrel a shot leaves from.]==],
	},
	{
		marker = 'model = "MORTAR"',
		anchor = [==[		shake = 0.14, -- the nozzle judders instead
	},
}]==],
		replacement = [==[		shake = 0.14, -- the nozzle judders instead
	},
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
}]==],
	},
	{
		marker = "identical for all six",
		anchor = "-- Shared rig behaviour, identical for all four.",
		replacement = "-- Shared rig behaviour, identical for all six.",
	},
	{
		marker = 'vfx = "GOLD", -- FX.VFX.POP',
		anchor = [==[		spinSpeed = 90,
		color = Color3.fromRGB(255, 205, 110),]==],
		replacement = [==[		spinSpeed = 90,
		color = Color3.fromRGB(255, 205, 110),
		vfx = "GOLD", -- FX.VFX.POP entry the collection pop borrows (FxController)]==],
	},
	{
		marker = '\t\tvfx = "GOLD",\n\t},',
		anchor = [==[		spinSpeed = 170,
		color = Color3.fromRGB(255, 243, 194),]==],
		replacement = [==[		spinSpeed = 170,
		color = Color3.fromRGB(255, 243, 194),
		vfx = "GOLD",]==],
	},
	{
		marker = 'vfx = "CONFETTI"',
		anchor = [==[		spinSpeed = 45,
		color = Color3.fromRGB(46, 158, 255),]==],
		replacement = [==[		spinSpeed = 45,
		color = Color3.fromRGB(46, 158, 255),
		vfx = "CONFETTI", -- a crate is a prize, so it bursts like one]==],
	},
}

local FX_EDITS = {
	{
		marker = "VfxKit = require",
		anchor = 'local WeaponRig = require(sharedFolder:WaitForChild("WeaponRig"))',
		replacement = 'local WeaponRig = require(sharedFolder:WaitForChild("WeaponRig"))\nlocal VfxKit = require(sharedFolder:WaitForChild("VfxKit"))',
	},
	{
		marker = "MORTAR = { asset",
		anchor = [==[	FLAME = { asset = "rbxasset://sounds/bass.wav", volume = 0.26, pitch = { 1.45, 1.70 }, life = 1.0 },
}]==],
		replacement = [==[	FLAME = { asset = "rbxasset://sounds/bass.wav", volume = 0.26, pitch = { 1.45, 1.70 }, life = 1.0 },
	-- Pitched under the cannon: the mortar is the heaviest thing on the roof.
	MORTAR = { asset = "rbxasset://sounds/collide.mp3", volume = 0.95, pitch = { 0.30, 0.40 }, life = 2.0 },
	DUALGUN = { asset = "rbxasset://sounds/metal.ogg", volume = 0.22, pitch = { 1.95, 2.30 }, life = 0.5 },
}]==],
	},
	{
		marker = "MORTAR = SFX.MORTAR,",
		anchor = [==[	FLAME = SFX.FLAME,
}]==],
		replacement = [==[	FLAME = SFX.FLAME,
	MORTAR = SFX.MORTAR,
	DUALGUN = SFX.DUALGUN,
}]==],
	},
	{
		marker = "DUALGUN = 0.11,",
		anchor = [==[local SOUND_GAP = {
	FLAME = 0.22,
}]==],
		replacement = [==[local SOUND_GAP = {
	FLAME = 0.22,
	-- Twin guns fire ~14 times a second and the barrels alternate: one report per
	-- PAIR is what makes it read as two barrels rather than as a buzz.
	DUALGUN = 0.11,
}]==],
	},
	{
		marker = "VFX = {\n\t\t-- events",
		anchor = '	PROJECTILE_FOLDER = "Projectiles",',
		replacement = [==[	PROJECTILE_FOLDER = "Projectiles",

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
		FREEZE = { PACK = "ICE", SCALE = 1.3, COUNT = 2.0 },
		SHIELD_POP = { PACK = "DiamondAura", SCALE = 0.4, COUNT = 2.4 },
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
	},]==],
	},
	{
		marker = "local function flameJet(",
		anchor = [==[-- ==========================================================================
-- § 8) Car helpers.]==],
		replacement = [==[--[=[ Pack helpers. Every VfxKit call in this file goes through one of these three, so
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
-- § 8) Car helpers.]==],
	},
	{
		marker = "HANDLERS.DUALGUN = function",
		anchor = "local function launchFx(kind: string, payload: any, origin: Vector3, spec: any)",
		replacement = [==[--[=[ TWIN GUNS. The plasma gun's draw with a lighter touch: a smaller flash and a
	thinner slug, fired about twice as often. The barrels alternate, and because the
	origin in this payload IS the barrel that fired (WeaponRig.muzzleWorld reads the
	shot's own parity), the bolts genuinely leave alternate sides. ]=]
HANDLERS.DUALGUN = function(payload: any, origin: Vector3)
	local def = POWERUPS.DUALGUN
	local color = pickColor(payload, def.color)

	local target = typeof(payload.target) == "Vector3" and payload.target or nil
	if not target and typeof(payload.dir) == "Vector3" and payload.dir.Magnitude > 1e-3 then
		target = origin + payload.dir.Unit * def.range
	end

	flash(origin, color, FX.GUN.MUZZLE_RADIUS * 0.7, FX.GUN.MUZZLE_LIFE, (FX.GUN.MUZZLE_LIGHT or 0) * 0.6)
	if target then
		local flight = boltShot(origin, target, color)
		local hit = target
		task.delay(flight, function()
			burst(hit, color, math.max(2, FX.GUN.HIT_SPARKS - 2), FX.SPARK)
			flash(hit, color, (FX.GUN.HIT_FLASH or 2) * 0.75, FX.GUN.HIT_LIFE)
		end)
	end
	if not consumePrediction("DUALGUN", origin) then
		playGatedSound("DUALGUN", SFX.DUALGUN, origin)
	end
end

local function launchFx(kind: string, payload: any, origin: Vector3, spec: any)]==],
	},
	{
		marker = "HANDLERS.MORTAR = function",
		anchor = "--[[ CANNON. The shared launch fx plus the weight the shot deserves: extra sparks",
		replacement = [==[--[=[ MORTAR. The launch reads like the cannon; what makes it the mortar is the RING
	it paints on the landing spot the instant the shell leaves, sized to the blast and
	closing in over exactly the flight time. Everyone sees it, including whoever is
	parked on it — a weapon that arrives from above has to be dodgeable to be fair. ]=]
HANDLERS.MORTAR = function(payload: any, origin: Vector3)
	local def = POWERUPS.MORTAR
	local color = pickColor(payload, def.color)
	local cfg = FX.MORTAR

	launchFx("MORTAR", payload, origin, SFX.MORTAR)
	flash(origin, color, cfg.FLASH_RADIUS, cfg.FLASH_LIFE, cfg.LIGHT)
	puffBurst(origin, FX.PUFF.COLOR, cfg.SMOKE, cfg.SMOKE_SCALE)
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

--[[ CANNON. The shared launch fx plus the weight the shot deserves: extra sparks]==],
	},
	{
		marker = "local named = type(payload.vfx)",
		anchor = "	burst(origin, color, FX.IMPACT.DEBRIS, FX.SPARK)",
		replacement = [==[	burst(origin, color, FX.IMPACT.DEBRIS, FX.SPARK)
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
	end]==],
	},
	{
		marker = "vfxBurst(FX.VFX.RAM, origin)",
		anchor = "	burst(origin, color, FX.RAM.SPARKS, FX.SPARK)",
		replacement = [==[	burst(origin, color, FX.RAM.SPARKS, FX.SPARK)
	vfxBurst(FX.VFX.RAM, origin) -- the shove puff, at the contact point between the two cars]==],
	},
	{
		marker = "vfxBurst(FX.VFX.ZAP, target",
		anchor = "		burst(target, color, FX.ZAP.SPARKS, FX.SPARK)",
		replacement = [==[		burst(target, color, FX.ZAP.SPARKS, FX.SPARK)
		vfxBurst(FX.VFX.ZAP, target, 1, color)]==],
	},
	{
		marker = "vfxBurst(FX.VFX.FREEZE, origin)",
		anchor = [==[HANDLERS.FREEZE = function(payload: any, origin: Vector3)
	launchFx("FREEZE", payload, origin, SFX.FREEZE)
end]==],
		replacement = [==[HANDLERS.FREEZE = function(payload: any, origin: Vector3)
	launchFx("FREEZE", payload, origin, SFX.FREEZE)
	vfxBurst(FX.VFX.FREEZE, origin)
end]==],
	},
	{
		marker = "vfxBurst(FX.VFX.SHIELD_POP",
		anchor = "	burst(origin, color, FX.SHIELD.POP_SPARKS, FX.SPARK)",
		replacement = [==[	burst(origin, color, FX.SHIELD.POP_SPARKS, FX.SPARK)
	vfxBurst(FX.VFX.SHIELD_POP, origin, 1, color)]==],
	},
	{
		marker = "flameJet(player.UserId, origin",
		anchor = [==[	playGatedSound(def.id, PREDICT_SFX[def.id], origin)
	recordPrediction(def.id, origin) -- so the server echo stays silent]==],
		replacement = [==[	--[=[ The flamethrower is a HELD weapon, so its jet is the one prediction worth more
		than a flash: light it locally on the press frame. The server echo re-aims this
		same rig (both are keyed on your userId), so there is never a second jet. ]=]
	if def.id == "FLAME" and typeof(dir) == "Vector3" and dir.Magnitude > 1e-3 then
		flameJet(player.UserId, origin, dir.Unit, color)
	end

	playGatedSound(def.id, PREDICT_SFX[def.id], origin)
	recordPrediction(def.id, origin) -- so the server echo stays silent]==],
	},
	{
		marker = "local function updateCarAuras(",
		anchor = "local function updateCarStates()",
		replacement = [==[--[=[ Particle auras for the car states. Two of these already had a shell and now have
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

local function updateCarStates()]==],
	},
	{
		marker = "updateCarAuras(car, ref, driver, sNow)",
		anchor = [==[				if driver and driver:GetAttribute(ATTR.SHIELDED) == true then
					ensureShell(car, "SHIELD")
				elseif driver then
					releaseShell(car, "SHIELD")
				end]==],
		replacement = [==[				if driver and driver:GetAttribute(ATTR.SHIELDED) == true then
					ensureShell(car, "SHIELD")
				elseif driver then
					releaseShell(car, "SHIELD")
				end

				updateCarAuras(car, ref, driver, sNow)]==],
	},
	{
		marker = "VfxKit.clearAuras(car)",
		anchor = "	releaseAllShells(car)",
		replacement = [==[	releaseAllShells(car)
	VfxKit.clearAuras(car) -- the attachments died with the car; this drops the bookkeeping]==],
	},
	{
		marker = "VfxKit.step(dt)",
		anchor = "	updatePulses(now)",
		replacement = [==[	updatePulses(now)
	VfxKit.step(dt) -- pack bursts age out; live flame jets follow their shooters' muzzles]==],
	},
}

--[[ The flamethrower handler is REPLACED WHOLE rather than spliced, because its body
	is the thing being rewritten. Bounded by the doc comment above it and the first
	column-zero `end` below it — every `end` inside the function is indented. ]]
local FLAME_HEAD = "--[[ FLAMETHROWER. No projectile and no impact event:"
local FLAME_BODY = [==[--[=[ FLAMETHROWER. No projectile and no impact event: the server burns a cone every
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
]==]

--[[ Signature weapons. Three cars all pulled GUN, which wasted the whole point of
	`special` (Config.SPECIAL_WEIGHT_BONUS makes a car roll its own weapon far more
	often, and that is what makes cars feel different). The two new guns take two of
	those slots: the light compact gets the twin guns, the truck gets the mortar. ]]
local CAR_SPECIALS = {
	{ car = "compact", special = "DUALGUN" },
	{ car = "bluetruck", special = "MORTAR" },
}

-- Swaps the id inside the FIRST `special = "..."` after a car's id line, leaving any
-- trailing comment alone, and does nothing if it already reads that way.
local function retarget(src: string, carId: string, newSpecial: string, log): string
	local at = string.find(src, ('id = "%s",'):format(carId), 1, true)
	if not at then
		table.insert(log, "Config  !! no car " .. carId)
		return src
	end
	local blockEnd = string.find(src, "\n\t},", at, true) or #src
	local have = string.find(src, ('special = "%s",'):format(newSpecial), at, true)
	if have and have < blockEnd then
		table.insert(log, ("Config  =  %s special"):format(carId))
		return src
	end
	local s = string.find(src, 'special = "', at, true)
	if not s or s > blockEnd then
		table.insert(log, "Config  !! no special in " .. carId)
		return src
	end
	local qs = s + 11 -- past `special = "`
	local qe = string.find(src, '"', qs, true)
	table.insert(log, ("Config  +  %s -> %s"):format(carId, newSpecial))
	return string.sub(src, 1, qs - 1) .. newSpecial .. string.sub(src, qe)
end

local function escape(s: string): string
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function applyEdits(module: LuaSourceContainer, edits, log)
	local src = module.Source
	local changed = false
	for _, e in ipairs(edits) do
		if string.find(src, e.marker, 1, true) then
			table.insert(log, ("%s  =  %s"):format(module.Name, e.marker:sub(1, 30)))
		else
			local count = select(2, string.gsub(src, escape(e.anchor), ""))
			if count ~= 1 then
				table.insert(log, ("%s  !! anchor x%d for %s"):format(module.Name, count, e.marker:sub(1, 30)))
			else
				local at = string.find(src, e.anchor, 1, true)
				src = string.sub(src, 1, at - 1) .. e.replacement .. string.sub(src, at + #e.anchor)
				changed = true
				table.insert(log, ("%s  +  %s"):format(module.Name, e.marker:sub(1, 30)))
			end
		end
	end
	return src, changed
end

function Patch.apply()
	local log = {}
	local RS = game:GetService("ReplicatedStorage")
	local config = RS.CrashCore.Config
	local fxc = game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.FxController

	local cfgSrc, cfgChanged = applyEdits(config, CONFIG_EDITS, log)
	for _, entry in ipairs(CAR_SPECIALS) do
		local before = cfgSrc
		cfgSrc = retarget(cfgSrc, entry.car, entry.special, log)
		cfgChanged = cfgChanged or (cfgSrc ~= before)
	end
	if cfgChanged then
		config.Source = cfgSrc -- ONE write = one undo waypoint for the whole patch
	end

	local fxSrc, fxChanged = applyEdits(fxc, FX_EDITS, log)

	-- flamethrower: whole-handler replacement
	if not string.find(fxSrc, "flameJet(userId, origin, dir, color)", 1, true) then
		local s0 = string.find(fxSrc, FLAME_HEAD, 1, true)
		local s1 = s0 and string.find(fxSrc, "\nend\n", s0, true)
		if s0 and s1 then
			-- s1..s1+4 IS the closing "\nend\n"; step past all of it or the old end is
			-- left behind and the file gains a stray one.
			fxSrc = string.sub(fxSrc, 1, s0 - 1) .. FLAME_BODY .. string.sub(fxSrc, s1 + 5)
			fxChanged = true
			table.insert(log, "FxController  +  FLAME jet handler")
		else
			table.insert(log, "FxController  !! FLAME handler not found")
		end
	else
		table.insert(log, "FxController  =  FLAME jet handler")
	end

	if fxChanged then
		fxc.Source = fxSrc
	end

	-- verdict
	local missing = {}
	for _, key in ipairs({ "MORTAR = {", 'model = "MORTAR"', 'vfx = "CONFETTI"' }) do
		if not string.find(config.Source, key, 1, true) then
			table.insert(missing, "Config:" .. key)
		end
	end
	for _, key in ipairs({ "VfxKit = require", "local function flameJet(", "HANDLERS.DUALGUN", "HANDLERS.MORTAR", "updateCarAuras(car, ref", "VfxKit.step(dt)" }) do
		if not string.find(fxc.Source, key, 1, true) then
			table.insert(missing, "Fx:" .. key)
		end
	end
	table.insert(log, #missing == 0 and "VERDICT complete" or ("VERDICT MISSING " .. table.concat(missing, ", ")))
	return table.concat(log, "\n")
end

return Patch
