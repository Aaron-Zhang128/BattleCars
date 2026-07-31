--[[ VfxKit — the authored particle packs, wrapped in the three shapes this game needs.

	PURPOSE
		ReplicatedStorage.VFXs holds 15 hand-authored emitter packs (FIRE, ICE,
		LIGHTNING, CONFETTI, GOLD, RADIOACTIVE, ...). Each one is a Part with a pile
		of ParticleEmitters tuned as a pet-sized AURA: they loop forever, they sit
		still, and they are sized for a 4-stud pet rather than a 24-stud car.

		This module is the ONLY place that knows how to turn one of those packs into a
		one-shot hit, a state aura or a directional jet, at car scale and inside a hard
		budget. FxController stays a list of WHAT HAPPENED; nothing above this line
		ever touches an emitter property.

	THE THREE SHAPES
		burst(name, at, opts)         one-shot: clone -> Emit(n) -> self-destruct.
		                              Explosions, pickup pops, ram sparks, freeze hits.
		aura(owner, key, name, opts)  looping emitters parented INTO a live part, so
		                              they follow it for free and die with it.
		                              Frozen / shielded / juggernaut / burning cars.
		jet(key, name, origin, dir)   a directional cone that stays lit while it keeps
		                              being refreshed, and gutters out when it stops.
		                              The flamethrower.

	BUDGET
		Every shape is capped, and a cap evicts the OLDEST member rather than dropping
		the newest event — the same rule FxController's part pools follow. Emitters are
		cloned per use (an emitter cannot be shared between two parents) but the packs
		themselves are resolved once and cached.

	DEGRADES TO NOTHING
		A missing pack — folder deleted, name typo, asset not replicated yet — returns
		nil instead of erroring, so every caller can keep its hand-built fallback and
		the game still plays with the whole VFXs folder gone.

	CONTRACT WITH THE PACKS
		* Emitters hang off the pack Part itself OR off an Attachment under it. Both
		  are collected, and both are re-parented onto one Attachment here.
		* Authored Size / Speed / Lifetime are the ART. opts.scale MULTIPLIES them; it
		  never replaces them, so a repaint of a pack in Studio shows up in game.
		* An emitter whose authored Speed is ~0 is a STATIONARY SPRITE (the flame
		  sheets, the smoke plates). Only those get a jet's or a blast's velocity —
		  the ones that already spray (embers, confetti debris) keep their own spread,
		  which is what stops an explosion from turning every layer into one shell.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VfxKit = {}

-- ==========================================================================
-- § 1) Tunables. Caps are per-shape and independent: a firefight full of bursts
--      must never be able to starve the frozen-car auras.
-- ==========================================================================
local CFG = {
	HOST_FOLDER = "Fx", -- FxController's runtime folder; we nest under it
	HOST_SUB = "Packs",

	BURST_CAP = 18,
	AURA_CAP = 26,
	JET_CAP = 8,

	-- A burst emits "this many seconds worth" of each emitter's authored Rate,
	-- times opts.count. Authored rates are 2-30, so 0.6s is a handful per layer.
	BURST_SECONDS = 0.6,
	EMIT_MAX = 44, -- per emitter, per burst — the ceiling on one loud event
	GRACE = 0.4, -- kept alive past the longest particle lifetime before destroy

	JET_HOLD = 0.2, -- keep emitting this long after the last refresh
	JET_LINGER = 2.0, -- destroy an idle jet after this (it may fire again)
	JET_TURN_RATE = 16, -- rad/s the jet swings toward a new aim; ticks arrive at 12 Hz
	JET_FLICKER_HZ = 37,

	STILL_SPEED = 5, -- authored Speed.Max at or below this = a stationary sprite
	SWEEP_INTERVAL = 1.0, -- how often dead aura entries are reaped
}

-- ==========================================================================
-- § 2) Pack resolution. ReplicatedStorage.VFXs is where they land on import;
--      CrashCore.Assets.Vfx is where they belong if they are ever tidied away.
--      Both are searched so moving the folder cannot break a single call site.
-- ==========================================================================
local packRoot: Instance? = nil
local packs: { [string]: any } = {}

local function root(): Instance?
	if packRoot and packRoot.Parent then
		return packRoot
	end
	packRoot = ReplicatedStorage:FindFirstChild("VFXs")
	if not packRoot then
		local core = ReplicatedStorage:FindFirstChild("CrashCore")
		local assets = core and core:FindFirstChild("Assets")
		packRoot = (assets and assets:FindFirstChild("Vfx")) or nil
	end
	return packRoot
end

function VfxKit.pack(name: string): Instance?
	local cached = packs[name]
	if cached ~= nil then
		return cached or nil
	end
	local folder = root()
	if not folder then
		return nil -- not replicated yet: do NOT cache the miss
	end
	local found = folder:FindFirstChild(name)
	packs[name] = found or false
	return found
end

function VfxKit.has(name: string): boolean
	return VfxKit.pack(name) ~= nil
end

-- Every pack name currently on disk, for a debug listing.
function VfxKit.names(): { string }
	local out = {}
	local folder = root()
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			table.insert(out, child.Name)
		end
	end
	return out
end

-- ==========================================================================
-- § 3) Emitter shaping. One function decides what a clone looks like, so the
--      three shapes cannot drift apart in how they read opts.
-- ==========================================================================
local function wanted(emitterName: string, only: { string }?, skip: { string }?): boolean
	if only then
		local hit = false
		for _, want in ipairs(only) do
			if string.find(emitterName, want, 1, true) then
				hit = true
				break
			end
		end
		if not hit then
			return false
		end
	end
	if skip then
		for _, dodge in ipairs(skip) do
			if string.find(emitterName, dodge, 1, true) then
				return false
			end
		end
	end
	return true
end

local function scaledSequence(seq: NumberSequence, mul: number): NumberSequence
	local kps = table.create(#seq.Keypoints)
	for i, kp in ipairs(seq.Keypoints) do
		kps[i] = NumberSequenceKeypoint.new(kp.Time, kp.Value * mul, kp.Envelope * mul)
	end
	return NumberSequence.new(kps)
end

--[[ opts:
	scale      multiplies Size, Speed and Acceleration — the one "make it car-sized" dial
	rate       multiplies Rate (auras run slower than authored, jets run hotter)
	lifetime   multiplies Lifetime
	color      flattens Color to one tint (pickup pops take the pickup's colour)
	zoffset    added to ZOffset, to lift a layer off the surface it sits on
	motion     { speed: NumberRange?, spread: Vector2?, direction: NormalId?, drag: number?,
	             acceleration: Vector3? } applied ONLY to stationary sprites (see header)
]]
local function shapeEmitter(e: ParticleEmitter, opts: any)
	local still = e.Speed.Max <= CFG.STILL_SPEED -- decided BEFORE scale touches it

	local scale = opts.scale or 1
	if scale ~= 1 then
		e.Size = scaledSequence(e.Size, scale)
		e.Speed = NumberRange.new(e.Speed.Min * scale, e.Speed.Max * scale)
		e.Acceleration = e.Acceleration * scale
	end
	if opts.rate then
		e.Rate = e.Rate * opts.rate
	end
	if opts.lifetime then
		e.Lifetime = NumberRange.new(e.Lifetime.Min * opts.lifetime, e.Lifetime.Max * opts.lifetime)
	end
	if opts.color then
		e.Color = ColorSequence.new(opts.color)
	end
	if opts.zoffset then
		e.ZOffset += opts.zoffset
	end

	local motion = opts.motion
	if motion and still then
		if motion.speed then
			e.Speed = motion.speed
		end
		if motion.spread then
			e.SpreadAngle = motion.spread
		end
		if motion.direction then
			e.EmissionDirection = motion.direction
		end
		if motion.drag then
			e.Drag = motion.drag
		end
		if motion.acceleration then
			e.Acceleration = motion.acceleration
		end
	end
end

-- ==========================================================================
-- § 4) Host parts. Anchored, query-free, shadow-free: a pure carrier for an
--      Attachment. Lives under Workspace.Fx so nothing pollutes the arena tree.
-- ==========================================================================
local function hostFolder(): Instance
	local fx = Workspace:FindFirstChild(CFG.HOST_FOLDER)
	if not fx then
		fx = Instance.new("Folder")
		fx.Name = CFG.HOST_FOLDER
		fx.Parent = Workspace
	end
	local sub = fx:FindFirstChild(CFG.HOST_SUB)
	if not sub then
		sub = Instance.new("Folder")
		sub.Name = CFG.HOST_SUB
		sub.Parent = fx
	end
	return sub
end

local function anchorPart(name: string, cf: CFrame): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Transparency = 1
	part.CastShadow = false
	part.Locked = true
	part.Parent = hostFolder()
	return part
end

local function resolvePart(owner: Instance?): BasePart?
	if not owner then
		return nil
	end
	if owner:IsA("BasePart") then
		return owner
	end
	if owner:IsA("Model") then
		return owner.PrimaryPart or owner:FindFirstChildWhichIsA("BasePart", true)
	end
	return owner:FindFirstChildWhichIsA("BasePart", true)
end

-- ==========================================================================
-- § 5) burst — one-shot. Parent FIRST, then clone and Emit: an emitter that is
--      not in the rendered DataModel yet swallows its own Emit call.
-- ==========================================================================
local bursts: { any } = {} -- FIFO, oldest first

local function trimBursts()
	while #bursts > CFG.BURST_CAP do
		local oldest = table.remove(bursts, 1)
		if oldest and oldest.part and oldest.part.Parent then
			oldest.part:Destroy()
		end
	end
end

function VfxKit.burst(name: string, at: any, opts: any?): BasePart?
	local pack = VfxKit.pack(name)
	if not pack then
		return nil
	end
	opts = opts or {}

	local cf
	if typeof(at) == "CFrame" then
		cf = at
	elseif typeof(at) == "Vector3" then
		cf = CFrame.new(at)
	else
		return nil
	end

	local part = anchorPart("Burst_" .. name, cf)
	local att = Instance.new("Attachment")
	att.Parent = part

	local seconds = opts.seconds or CFG.BURST_SECONDS
	local count = opts.count or 1
	local life, layers = 0, 0
	for _, src in ipairs(pack:GetDescendants()) do
		if src:IsA("ParticleEmitter") and wanted(src.Name, opts.only, opts.skip) then
			local e = src:Clone()
			shapeEmitter(e, opts)
			e.Enabled = false -- one shot only; the authored Rate must not keep running
			e.Parent = att
			e:Emit(math.clamp(math.ceil(e.Rate * seconds * count), 1, CFG.EMIT_MAX))
			life = math.max(life, e.Lifetime.Max)
			layers += 1
		end
	end

	if layers == 0 then
		part:Destroy()
		return nil
	end

	local total = life + CFG.GRACE
	table.insert(bursts, { part = part, dieAt = os.clock() + total })
	trimBursts()
	-- Backstop, exactly like FxController's pools: a dead frame loop still cleans up.
	task.delay(total + 0.25, function()
		if part.Parent then
			part:Destroy()
		end
	end)
	return part
end

-- ==========================================================================
-- § 6) aura — looping emitters parented INTO a live part. No follow code: the
--      Attachment rides the part, and both die when the car does.
-- ==========================================================================
local auras: { [Instance]: any } = {}
local auraCount = 0

function VfxKit.clearAura(owner: Instance, key: string)
	local perOwner = auras[owner]
	local entry = perOwner and perOwner[key]
	if not entry then
		return
	end
	perOwner[key] = nil
	auraCount = math.max(0, auraCount - 1)
	if entry.att and entry.att.Parent then
		entry.att:Destroy()
	end
	if next(perOwner) == nil then
		auras[owner] = nil
	end
end

function VfxKit.clearAuras(owner: Instance)
	local perOwner = auras[owner]
	if not perOwner then
		return
	end
	for key in pairs(perOwner) do
		VfxKit.clearAura(owner, key)
	end
end

function VfxKit.hasAura(owner: Instance, key: string): boolean
	local perOwner = auras[owner]
	local entry = perOwner and perOwner[key]
	return entry ~= nil and entry.att.Parent ~= nil
end

--[[ Idempotent: calling it every state pass is the intended usage, so a 10 Hz
	"is this car still frozen" loop can just call aura() and clearAura() blindly.
	opts.host pins the part to attach to (FxController passes Body/Shell, never the
	invisible Hull); opts.offset moves the emission point inside it. ]]
function VfxKit.aura(owner: Instance, key: string, name: string, opts: any?): any?
	opts = opts or {}
	local perOwner = auras[owner]
	local existing = perOwner and perOwner[key]
	if existing then
		if existing.att.Parent and existing.name == name then
			return existing
		end
		VfxKit.clearAura(owner, key) -- host destroyed underneath it, or a repaint
		perOwner = auras[owner]
	end

	local host = opts.host or resolvePart(owner)
	if not host or not host.Parent then
		return nil
	end
	if auraCount >= CFG.AURA_CAP then
		return nil
	end
	local pack = VfxKit.pack(name)
	if not pack then
		return nil
	end

	local att = Instance.new("Attachment")
	att.Name = "Vfx_" .. key
	att.Position = opts.offset or Vector3.zero
	att.Parent = host

	local layers = 0
	for _, src in ipairs(pack:GetDescendants()) do
		if src:IsA("ParticleEmitter") and wanted(src.Name, opts.only, opts.skip) then
			local e = src:Clone()
			shapeEmitter(e, opts)
			e.Enabled = true
			e.Parent = att
			layers += 1
		end
	end
	if layers == 0 then
		att:Destroy()
		return nil
	end

	local entry = { att = att, host = host, name = name }
	perOwner = perOwner or {}
	perOwner[key] = entry
	auras[owner] = perOwner
	auraCount += 1
	return entry
end

-- ==========================================================================
-- § 7) jet — a directional cone that lives between refreshes.
--
--      The flamethrower fires ~12 times a second and each tick is one WeaponFx
--      event, so drawing a fresh jet per tick would strobe. Instead the FIRST tick
--      builds the rig and every later tick just re-aims it; it gutters out
--      JET_HOLD after the last tick and is destroyed JET_LINGER after that.
--
--      opts.getPosition is a callback (the shooter's live turret muzzle), polled
--      every frame — the jet must follow a car doing 190 studs/s, and 12 Hz of
--      payload origins is not smooth enough to hang fire on.
-- ==========================================================================
local jets: { [any]: any } = {}
local jetCount = 0

function VfxKit.stopJet(key: any)
	local rec = jets[key]
	if not rec then
		return
	end
	jets[key] = nil
	jetCount = math.max(0, jetCount - 1)
	if rec.part and rec.part.Parent then
		rec.part:Destroy()
	end
end

local function setJetLit(rec: any, lit: boolean)
	if rec.lit == lit then
		return
	end
	rec.lit = lit
	for _, e in ipairs(rec.emitters) do
		e.Enabled = lit
	end
	if rec.light then
		rec.light.Enabled = lit
	end
end

function VfxKit.jet(key: any, name: string, origin: Vector3, dir: Vector3, opts: any?): any?
	if typeof(origin) ~= "Vector3" or typeof(dir) ~= "Vector3" or dir.Magnitude < 1e-3 then
		return nil
	end
	opts = opts or {}
	local aim = dir.Unit

	local rec = jets[key]
	if rec and not rec.part.Parent then
		VfxKit.stopJet(key)
		rec = nil
	end

	if not rec then
		local pack = VfxKit.pack(name)
		if not pack then
			return nil
		end
		if jetCount >= CFG.JET_CAP then
			return nil
		end
		local part = anchorPart("Jet_" .. tostring(key), CFrame.lookAt(origin, origin + aim))
		local att = Instance.new("Attachment")
		att.Parent = part

		local emitters = {}
		for _, src in ipairs(pack:GetDescendants()) do
			if src:IsA("ParticleEmitter") and wanted(src.Name, opts.only, opts.skip) then
				local e = src:Clone()
				shapeEmitter(e, opts)
				e.Enabled = false
				e.Parent = att
				table.insert(emitters, e)
			end
		end
		if #emitters == 0 then
			part:Destroy()
			return nil
		end

		local light
		if opts.light then
			light = Instance.new("PointLight")
			light.Color = opts.light.color or Color3.new(1, 1, 1)
			light.Range = opts.light.range or 20
			light.Brightness = opts.light.brightness or 2
			light.Shadows = false
			light.Enabled = false
			light.Parent = part
		end

		rec = {
			part = part,
			att = att,
			emitters = emitters,
			light = light,
			lightBase = light and light.Brightness or 0,
			look = aim,
			lit = false,
		}
		jets[key] = rec
		jetCount += 1
	end

	rec.origin = origin
	rec.dir = aim
	rec.getPosition = opts.getPosition or rec.getPosition
	rec.lastSeen = os.clock()
	setJetLit(rec, true)
	return rec
end

local function stepJets(dt: number, now: number)
	for key, rec in pairs(jets) do
		if not rec.part.Parent then
			jets[key] = nil
			jetCount = math.max(0, jetCount - 1)
		else
			local idle = now - rec.lastSeen
			if idle > CFG.JET_LINGER then
				VfxKit.stopJet(key)
			else
				if rec.lit and idle > CFG.JET_HOLD then
					setJetLit(rec, false)
				end
				if rec.lit then
					local pos = rec.origin
					if rec.getPosition then
						local ok, live = pcall(rec.getPosition)
						if ok and typeof(live) == "Vector3" then
							pos = live
						end
					end
					-- Swing toward the new aim instead of snapping: 12 Hz of payloads
					-- against a 60+ fps camera reads as a stutter if the cone teleports.
					local look = rec.look:Lerp(rec.dir, math.clamp(dt * CFG.JET_TURN_RATE, 0, 1))
					if look.Magnitude > 1e-3 then
						rec.look = look.Unit
					end
					rec.part.CFrame = CFrame.lookAt(pos, pos + rec.look)
					if rec.light and rec.lightBase > 0 then
						rec.light.Brightness = rec.lightBase * (0.82 + 0.28 * math.abs(math.sin(now * CFG.JET_FLICKER_HZ)))
					end
				end
			end
		end
	end
end

-- ==========================================================================
-- § 8) step + housekeeping. One call from FxController's single frame loop.
-- ==========================================================================
local sweepAccum = 0

local function sweepAuras()
	for owner, perOwner in pairs(auras) do
		for key, entry in pairs(perOwner) do
			-- The Attachment dies with the car; this only reaps our bookkeeping.
			if not entry.att.Parent or not entry.host.Parent or not owner.Parent then
				VfxKit.clearAura(owner, key)
			end
		end
	end
end

function VfxKit.step(dt: number)
	local now = os.clock()

	for i = #bursts, 1, -1 do
		local rec = bursts[i]
		if not rec.part.Parent then
			table.remove(bursts, i)
		elseif now >= rec.dieAt then
			rec.part:Destroy()
			table.remove(bursts, i)
		end
	end

	stepJets(dt, now)

	sweepAccum += dt
	if sweepAccum >= CFG.SWEEP_INTERVAL then
		sweepAccum = 0
		sweepAuras()
	end
end

function VfxKit.counts(): (number, number, number)
	return #bursts, auraCount, jetCount
end

return VfxKit
