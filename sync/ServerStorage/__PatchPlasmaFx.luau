--[[ __PatchPlasmaFx — one IDEMPOTENT pass that rebuilds the plasma gun's fx.

	Run with:  print(require(game.ServerStorage.__PatchPlasmaFx).apply())

	Every edit is guarded by a marker unique to its own new text, so re-running (or a
	timed-out call the plugin silently retries) is a no-op rather than a double-apply.
	Each script is written exactly once, so the whole patch is a single undo step. ]]

local ScriptEditorService = game:GetService("ScriptEditorService")
local PLACE_ID = 140293260341399

local NL = string.char(10)
local M = {}

-- ==========================================================================
-- Payloads
-- ==========================================================================
local FX_TUNABLES = [===[
	--[=[ PLASMA BOLT. The gun is HITSCAN — the server decided the hit before any of
		this draws — so the visual is free to travel, and it should: an instant line is
		unreadable from another car, which is what the old hairline tracer was.

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
]===]

local FX_BOLT = [===[
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

]===]

local FX_BURST = [===[
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

]===]

local FX_HANDLERS = [===[
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

HANDLERS.GUN = function(payload: any, origin: Vector3)
	local def = POWERUPS.GUN
	local color = pickColor(payload, def.color)
	local target, dir = plasmaShot(payload, origin, def)

	plasmaMuzzle(origin, dir, color, 1)
	if target then
		--[[ Hold the impact back until the bolt actually gets there. Sparks that fire
			before the slug arrives read as two unrelated events; delayed by the flight
			time they read as one shot crossing the arena. ]]
		local flight = boltShot(origin, target, color, 1)
		local at, aim, hitCar = target, dir, payload.hitCar == true
		task.delay(flight, function()
			plasmaImpact(at, aim, color, 1, hitCar)
		end)
	end
	if not consumePrediction("GUN", origin) then
		playSound(SFX.GUN, origin)
	end
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

]===]

local WS_HITSCAN = [===[
HANDLERS.hitscan = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean
	local direction = applySpread(aim, def.spread or 0)
	local range = def.range or 0

	local result = castIgnoringPickups(origin, direction * range, rayParams(car))
	local target = origin + direction * range
	--[[ Whether the bolt landed on a CAR rides along in the fx payload: the client
		draws a full plasma splash on a car and a scuff on the ground, which is the one
		question a shooter is actually asking at eleven shots a second. Purely
		cosmetic — the damage was decided right here — so no client may act on it. ]]
	local hitCar = false
	if result then
		target = result.Position
		local victimCar = carModelFrom(result.Instance)
		hitCar = victimCar ~= nil
		local victim = victimCar and svcCall("SpawnService", "playerFromCar", victimCar) or nil
		if isPlayer(victim) and victim ~= player and victimCar.Parent ~= nil then
			if hurt(victim, victimCar, def.damage or 0, player, def.id) then
				knock(victim, pushDirection(origin, target), def.knockback or 0)
			end
		end
	end

	fx(def.id, { origin = origin, dir = direction, target = target, color = def.color, userId = player.UserId, hitCar = hitCar })
	return true
end

]===]

-- ==========================================================================
-- Splice primitives. Every one verifies its anchor matched EXACTLY once.
-- ==========================================================================
local function insertAfter(src: string, anchor: string, text: string): (string?, string?)
	local s0, e0 = string.find(src, anchor, 1, true)
	if not s0 then
		return nil, "anchor missing"
	end
	if string.find(src, anchor, e0 + 1, true) then
		return nil, "anchor matched more than once"
	end
	return string.sub(src, 1, e0) .. text .. string.sub(src, e0 + 1), nil
end

local function exactReplace(src: string, old: string, new: string): (string?, string?)
	local s0, e0 = string.find(src, old, 1, true)
	if not s0 then
		return nil, "text missing"
	end
	if string.find(src, old, e0 + 1, true) then
		return nil, "text matched more than once"
	end
	return string.sub(src, 1, s0 - 1) .. new .. string.sub(src, e0 + 1), nil
end

-- Replaces everything from the start of `anchor` up to (not including) `stop`.
local function spanReplace(src: string, anchor: string, stop: string, text: string): (string?, string?)
	local s0, e0 = string.find(src, anchor, 1, true)
	if not s0 then
		return nil, "anchor missing"
	end
	if string.find(src, anchor, e0 + 1, true) then
		return nil, "anchor matched more than once"
	end
	local s1 = string.find(src, stop, e0 + 1, true)
	if not s1 then
		return nil, "stop anchor missing"
	end
	return string.sub(src, 1, s0 - 1) .. text .. string.sub(src, s1), nil
end

local EDITS = {
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "CAPS.PLASMA",
		marker = "PLASMA = 24",
		op = "insert",
		anchor = [[	TRACER = 28, -- travelling plasma bolts, ~4 in the air per firing player
]],
		text = [[	PLASMA = 24, -- plasma discs: one at the muzzle and one at the impact, per shot
]],
	},
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "CAPS.FLASH raise",
		marker = "FLASH = 18",
		op = "exact",
		anchor = [[	FLASH = 12,]],
		text = [[	FLASH = 18, -- the plasma gun alone spends two of these a shot at 11 shots/s]],
	},
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "FX.VFX.PLASMA_HIT",
		marker = "PLASMA_HIT",
		op = "insert",
		anchor = [[		ZAP = { PACK = "LIGHTNING", SCALE = 1.4, COUNT = 2.0 },
]],
		text = [[		PLASMA_HIT = { PACK = "LIGHTNING", SCALE = 0.32, COUNT = 0.5 },
]],
	},
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "FX.BOLT_SHOT / FX.GUN tunables",
		marker = "MUZZLE_DISC",
		op = "span",
		anchor = [[	--[[ The plasma bolt. The gun is HITSCAN]],
		stop = [[	LAUNCH = { PUFFS = 4,]],
		text = FX_TUNABLES,
	},
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "boltShot + hot/disc helpers",
		marker = "liveBoltLights",
		op = "span",
		anchor = "--[[ A plasma slug flying muzzle -> impact.",
		stop = "local function bolt(from: Vector3, to: Vector3, color: Color3)",
		text = FX_BOLT,
	},
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "burst() directional bias",
		marker = "axis: Vector3?, focus: number?",
		op = "span",
		anchor = "-- Shared debris / spark emitter. cfg is FX.DEBRIS or FX.SPARK.",
		stop = [[		local part = newPart(cfg.CAT, Vector3.new(s, s, s * cfg.LONG)]],
		text = FX_BURST,
	},
	{
		path = "StarterPlayer.StarterPlayerScripts.Controllers.FxController",
		name = "GUN / DUALGUN handlers",
		marker = "plasmaMuzzle",
		op = "span",
		anchor = "local HANDLERS = {}",
		stop = "local function launchFx(kind: string, payload: any, origin: Vector3, spec: any)",
		text = FX_HANDLERS,
	},
	{
		path = "ServerScriptService.Services.WeaponService",
		name = "hitscan payload.hitCar",
		marker = "hitCar = hitCar",
		op = "span",
		anchor = "HANDLERS.hitscan = function(player: Instance, car: Model, hull: BasePart, def, aim: Vector3, origin: Vector3, trusted: boolean): boolean",
		stop = "HANDLERS.projectile = function(",
		text = WS_HITSCAN,
	},
}

local function resolve(path: string): Instance?
	local node: Instance? = game
	for piece in string.gmatch(path, "[^%.]+") do
		node = node and node:FindFirstChild(piece)
		if not node then
			return nil
		end
	end
	return node
end

function M.apply(): string
	local report = {}
	local function note(line: string)
		table.insert(report, line)
	end

	if game.PlaceId ~= PLACE_ID then
		return string.format("ABORT — wrong place (%d, expected %d)", game.PlaceId, PLACE_ID)
	end

	-- Group by script so each file is written exactly once (one undo waypoint).
	local order, staged = {}, {}
	for _, edit in ipairs(EDITS) do
		if not staged[edit.path] then
			local inst = resolve(edit.path)
			if not inst or not inst:IsA("LuaSourceContainer") then
				note("ABORT — cannot resolve " .. edit.path)
				return table.concat(report, NL)
			end
			staged[edit.path] = { inst = inst, src = inst.Source, dirty = false }
			table.insert(order, edit.path)
		end
		local file = staged[edit.path]
		if string.find(file.src, edit.marker, 1, true) then
			note(string.format("SKIP  %-32s (already applied)", edit.name))
		else
			local out, err
			if edit.op == "insert" then
				out, err = insertAfter(file.src, edit.anchor, edit.text)
			elseif edit.op == "exact" then
				out, err = exactReplace(file.src, edit.anchor, edit.text)
			else
				out, err = spanReplace(file.src, edit.anchor, edit.stop, edit.text)
			end
			if not out then
				note(string.format("ABORT %-32s -> %s", edit.name, tostring(err)))
				return table.concat(report, NL)
			end
			file.src = out
			file.dirty = true
			note(string.format("EDIT  %-32s ok", edit.name))
		end
	end

	for _, path in ipairs(order) do
		local file = staged[path]
		if file.dirty then
			local ok, err = pcall(function()
				ScriptEditorService:UpdateSourceAsync(file.inst, function()
					return file.src
				end)
			end)
			note(string.format("WRITE %-42s %s", path, ok and "ok" or ("FAILED -> " .. tostring(err))))
		else
			note(string.format("WRITE %-42s skipped (no change)", path))
		end
	end

	-- VERDICT: re-read from the instances, so this reports what is actually on disk
	-- in Studio rather than what this pass believes it wrote.
	local missing = {}
	for _, edit in ipairs(EDITS) do
		local inst = resolve(edit.path)
		if not inst or not string.find((inst :: any).Source, edit.marker, 1, true) then
			table.insert(missing, edit.name)
		end
	end
	note(#missing == 0 and "VERDICT: all markers present" or ("VERDICT: MISSING -> " .. table.concat(missing, ", ")))
	return table.concat(report, NL)
end

return M
