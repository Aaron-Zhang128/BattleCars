--[[ CombatService
	The ONLY place damage is applied and the ONLY place a kill is resolved.

	PURPOSE
		Ram resolution (the core kill verb), Hp bookkeeping, freeze + shield effects,
		knockback impulses, and death resolution (crown transfer + kill record).

	DATA FLOW
		SpawnService.spawnCar        -> onCarSpawned(player, car): hooks Hull.Touched,
		                                resets Hp, arms spawn protection.
		Hull.Touched                 -> resolveContact -> ChassisSpec.ramResult
		                                -> applyKnockback + applyDamage
		applyDamage reaching 0 Hp    -> killCar
			-> ScoreService.addCrowns   victim zeroed first, then the killer's steal
			-> ScoreService.recordKill  credits the kill AND owns the "kill" feed broadcast
			-> PickupService.dropCrowns the scatter half, at the death position
			-> WeaponService.clearPowerup            the slot is lost on death
			-> ModeService.onKill                    mode points, and the juggernaut
			                                         crown changing hands
			-> SpawnService.despawnCar               owns lives, the death remote, model teardown
		WeaponService calls applyDamage / applyFreeze / applyShield / applyKnockback.
		SpawnService's pit watchdog calls killCar(player, "fell") with no killer.

	REMOTES (server -> client, fire only; this service listens to nothing)
		WeaponFx    "HIT"        { origin = victimHull, victimId, attackerId, amount,
		                           hp, maxHp, killed } — every damage event, COALESCED
		                           per attacker/victim pair (see noteHitFx)
		WeaponFx    "RAM"        { origin = contactPoint, dir = hitDirection }
		            "SHIELD_POP" { origin = carPosition, color }
		The MatchEvent "kill" feed is NOT fired here — ScoreService.recordKill fires it,
		so broadcasting it too would double every kill-feed entry.

	ATTRIBUTES WRITTEN (nothing else may write these)
		car.Hp            reset to MaxHp on spawn, decremented by applyDamage
		car.FrozenUntil   server-time deadline, cleared by the expiry sweep
		car.StaggerUntil  set by applyKnockback so the owning client yields drive authority
		                  long enough for the impulse to survive (see applyKnockback)
		hull network ownership — TEMPORARILY revoked to the server for the stagger window and
		                  restored by the sweep. SpawnService owns the ownership assignment at
		                  spawn; this is the one place it is ever borrowed afterwards.
		car.Invuln        spawn protection deadline, re-armed in onCarSpawned (SpawnService
		                  stamps it once at spawn too — deliberate overlap, same Config
		                  value; every LATER change to it is ours)
		player.Frozen     HUD mirror of car.FrozenUntil
		player.Shielded   set by applyShield, cleared by the expiry sweep
		Reads but NEVER writes Crowns / Lives / Alive / PowerupSlot / MaxHp — those
		belong to ScoreService / SpawnService / WeaponService / CarFactory.

	INIT ORDER
		Main inits this after SpawnService + WeaponService and before ScoreService +
		MatchService, so every sibling is resolved LAZILY at call time via ctx.svc.

	DESIGN DECISIONS (documented so they stay consistent)
		* A knock below Config.RAM.MIN_KNOCK_TO_STAGGER is a CHIP HIT: impulse only, no stagger
		  and no ownership borrow, so sustained machine-gun fire cannot hold a car paralysed
		  for a whole burst. GUN knockback is therefore cosmetic by design.
		* Knockback at or above that threshold needs THREE things together, and drops dead
		  without any one of them:
		  an ApplyImpulse (never a velocity write, which the simulating peer overwrites next
		  step), a StaggerUntil stamp so the victim's client stops commanding Drive, AND the
		  server taking network ownership of the hull for that window — an owning client's
		  simulation is authoritative, so it can discard a server impulse outright. Ownership
		  is handed back from the expiry sweep, never a per-hit task.delay. Staying
		  server-authoritative is deliberate: telling the client to knock itself back would
		  let any client ignore the message and be immune to every ram and rocket.
		* Shield is DURATION based: it absorbs every hit (damage and freeze) until it
		  expires and pops visually on each absorb. It is NOT consumed on hit, so the
		  absorb path never calls WeaponService.clearPowerup.
		* Head-on (both cars closing) resolves SYMMETRICALLY: both take the hit and
		  neither eats self damage on top — the mutual damage is already the punishment.
		* Both hulls' Touched handlers fire for one physical collision. resolveContact is
		  role-agnostic and the cooldown key is the RESOLVED (attacker, victim) ordered
		  pair, so the duplicate event finds the cooldown burned and adds nothing.
		* Spawn protection blocks ram damage in BOTH directions: a protected car neither
		  deals nor takes a body slam.
		* RING-OUT CREDIT: every hit stamps lastAttacker[victim]. A pit death inside
		  Config.RAM.KILL_CREDIT_SECONDS of a hit credits that attacker with the full kill
		  (steal + feed + credit), because shoving someone off is the best play in the genre
		  and paid nothing otherwise. Unassisted pit deaths stay killer-less. The cause is
		  untouched, so the death card still reads as a fall.
		* applyKnockback takes an OPTIONAL 4th `attackerPlayer` — additive to the pinned
		  signature, so 3-argument callers are unaffected. Pass it for a pure shove that
		  deals no damage, otherwise that shove earns no ring-out credit.

	CAUSE IDS — SpawnService spends a life ONLY for "killed" and "fell", so every cause
		is normalized before it reaches despawnCar. A raw weapon id like "ROCKET" would
		silently cost the victim no life.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local ChassisSpec = require(sharedFolder:WaitForChild("ChassisSpec"))
local MatchState = require(sharedFolder:WaitForChild("MatchState"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))

local CFG = Config.RAM
local MATCH = Config.MATCH
local ATTR = Config.ATTR
local CAR_ATTR = ChassisSpec.ATTR

-- Hulls closer together than this have no usable contact normal.
local CONTACT_EPSILON = 0.01

--[[ The only despawn causes SpawnService charges a life for. Callers may hand us any
	descriptive causeId (a powerup id, "fell"); despawnCauseFor normalizes it so a ram or
	a rocket always costs a life and only the pit watchdog's "fell" passes through. ]]
local CAUSE = {
	KILLED = "killed",
	FELL = "fell",
}

local function despawnCauseFor(causeId: string?): string
	return causeId == CAUSE.FELL and CAUSE.FELL or CAUSE.KILLED
end

local CombatService = {}

local ctxRef -- shared service context from Main (net + svc)

local liveCars = {} -- [Player] = { car = Model, hull = BasePart, mass = number, conns = {RBXScriptConnection} }
local carOwner = {} -- [Model] = Player; mirrors SpawnService.playerFromCar for the hot Touched path
local ramCooldown = {} -- [attackerPlayer] = { [victimPlayer] = server time the pair may hit again }
local shieldUntil = {} -- [Player] = server time the shield expires
local killing = {} -- [Player] = true while a kill resolves (idempotence guard)
local lastAttacker = {} -- [victimPlayer] = { player = Player, at = server time } for ring-out credit
local pendingRestore = {} -- [Player] = { car, hull, expiry } network ownership to hand back

-- ==========================================================================
-- helpers
-- ==========================================================================

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function isPositive(value: any): boolean
	-- Rejects nil, non-numbers, NaN and zero/negative "damage".
	return type(value) == "number" and value == value and value > 0
end

local function fireFx(kind: string, payload: { [string]: any })
	local remote = ctxRef and ctxRef.net and ctxRef.net.WeaponFx
	if remote then
		remote:FireAllClients(kind, payload)
	end
end

--[[ Remembers who last hit `victim` so a ring-out death can still credit them. Called from
	every path that lands force on a car — damage AND a pure shove. Most recent wins; the
	record table is reused so the hot ram path allocates nothing. ]]
local function noteAttacker(victim: Player, attacker: Player?)
	if not isPlayer(attacker) or attacker == victim then
		return
	end

	local record = lastAttacker[victim]
	if record then
		record.player = attacker
		record.at = workspace:GetServerTimeNow()
	else
		lastAttacker[victim] = { player = attacker, at = workspace:GetServerTimeNow() }
	end
end

--[[ HIT FX. One broadcast per damage event so every client can flash the victim's
	highlight and the two players it concerns can see the number. Fired from the ONE damage
	funnel, so a ram, a rocket, a mortar shell and a tick of flame all announce themselves
	the same way and no weapon can be added that forgets to.

	COALESCED PER (attacker, victim) PAIR, because the hold weapons land 12-14 hits a
	second: one remote per tick is a stream nobody asked for, and on screen it reads as
	"3 3 3 3 3" where "37" reads as a burst. A hit inside HIT_FX_GAP of the last send adds
	its damage to a pending total and schedules ONE deferred flush, so the tail of a burst
	is never silently dropped. A KILL always sends immediately — that is the frame the
	feedback matters most, and the car is about to stop existing.

	The PAIR keying is the point: merging two attackers into one number would credit the
	wrong player and cost the other their hit marker entirely. ]]
local HIT_FX_GAP = 0.12
local WORLD_ATTACKER = "world" -- table key for environmental damage, which has no Player

local hitFx = {} -- [victim] = { [attacker | WORLD_ATTACKER] = pending record }

local function flushHitFx(victim: Player, key: any)
	local perVictim = hitFx[victim]
	local record = perVictim and perVictim[key]
	if not record then
		return -- the car (or the player) went away with damage still pending
	end
	record.scheduled = false

	local amount = record.amount
	record.amount = 0
	if amount <= 0 or typeof(record.origin) ~= "Vector3" then
		return
	end

	local attacker = record.attacker
	record.sentAt = os.clock()
	fireFx("HIT", {
		origin = record.origin,
		victimId = victim.UserId,
		attackerId = isPlayer(attacker) and attacker.Parent and attacker.UserId or nil,
		amount = amount,
		hp = record.hp,
		maxHp = record.maxHp,
		killed = record.killed or nil,
	})
	record.killed = false
end

local function noteHitFx(victim: Player, attacker: Player?, amount: number, origin: Vector3?, hp: number, maxHp: number?, killed: boolean)
	if typeof(origin) ~= "Vector3" then
		return -- FxController keys every fx off a position; no hull, no fx
	end

	local perVictim = hitFx[victim]
	if not perVictim then
		perVictim = {}
		hitFx[victim] = perVictim
	end
	local key = isPlayer(attacker) and attacker or WORLD_ATTACKER
	local record = perVictim[key]
	if not record then
		record = { attacker = isPlayer(attacker) and attacker or nil, amount = 0, sentAt = 0, scheduled = false }
		perVictim[key] = record
	end

	record.amount += amount
	record.origin = origin
	record.hp = hp
	record.maxHp = maxHp
	record.killed = record.killed or killed

	local wait = HIT_FX_GAP - (os.clock() - record.sentAt)
	if killed or wait <= 0 then
		flushHitFx(victim, key)
	elseif not record.scheduled then
		record.scheduled = true
		task.delay(wait, function()
			flushHitFx(victim, key)
		end)
	end
end

--[[ Ring-out credit: the attacker who last hit this player, if the hit is recent enough
	and they are still here. Shoving someone into a pit is the best play in the genre, so
	it pays the full kill — otherwise the victim loses everything and the shover gets zero. ]]
local function recentAttackerFor(victim: Player): Player?
	local record = lastAttacker[victim]
	if not record then
		return nil
	end

	local attacker = record.player
	if not isPlayer(attacker) or not attacker.Parent or attacker == victim then
		return nil -- credited player has left the server
	end
	if workspace:GetServerTimeNow() - record.at > CFG.KILL_CREDIT_SECONDS then
		return nil -- they drove into the pit on their own time
	end
	return attacker
end

--[[ The car we are allowed to touch: registered by onCarSpawned and still in the world.
	Falls back to SpawnService for a car that somehow never got a Combat hook.
	Returns car, hull (both nil when the player has no live car). ]]
local function getLiveCar(player: Player)
	local entry = liveCars[player]
	if entry and entry.car.Parent then
		return entry.car, entry.hull
	end

	local spawnSvc = ctxRef and ctxRef.svc.SpawnService
	if spawnSvc then
		local ok, car = pcall(spawnSvc.getCar, player)
		if ok and typeof(car) == "Instance" and car:IsA("Model") and car.Parent then
			return car, ChassisSpec.getHull(car)
		end
	end
	return nil, nil
end

-- Drops every hook and transient effect tied to one car. Safe to call twice.
local function releaseCar(player: Player)
	local entry = liveCars[player]
	if not entry then
		return
	end

	liveCars[player] = nil
	carOwner[entry.car] = nil
	hitFx[player] = nil -- a pending damage number has no car left to float over
	pendingRestore[player] = nil -- the wreck is going away; there is nothing to hand back
	for _, conn in ipairs(entry.conns) do
		conn:Disconnect()
	end

	-- Transient debuffs die with the car so the next spawn is never born frozen or shielded.
	shieldUntil[player] = nil
	if player.Parent then
		player:SetAttribute(ATTR.FROZEN, false)
		player:SetAttribute(ATTR.SHIELDED, false)
	end
end

--[[ Walks up from a touched part to the car model owning it. CarFactory makes every
	cosmetic CanTouch = false, so in practice this only ever runs one level up from a Hull;
	the walk stays as a cheap safety net against a fender ever becoming touchable. ]]
local function carModelFromPart(part: BasePart): Instance?
	local node = part.Parent
	while node and node ~= workspace do
		if carOwner[node] then
			return node
		end
		if node:IsA("Model") and node:GetAttribute(CAR_ATTR.OWNER) ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Registry first (allocation-free in the Touched path), SpawnService as the fallback.
local function ownerOfCar(carModel: Instance): Player?
	local known = carOwner[carModel]
	if known then
		return known
	end

	local spawnSvc = ctxRef and ctxRef.svc.SpawnService
	if spawnSvc then
		local ok, player = pcall(spawnSvc.playerFromCar, carModel)
		if ok and isPlayer(player) then
			return player
		end
	end
	return nil
end

--[[ The mode's friendly-fire rule. Resolved LAZILY (ModeService may still be loading)
	and failing OPEN on purpose: every question asked of it here is "may this hit land?",
	and a mode service that is missing or throwing must never be able to switch damage
	off for the whole server. Modes without teams answer true for every pair. ]]
local function canDamage(attacker: Player?, victim: Player?): boolean
	local mode = ctxRef and ctxRef.svc and ctxRef.svc.ModeService
	if type(mode) ~= "table" or type(mode.canDamage) ~= "function" then
		return true
	end
	local ok, allowed = pcall(mode.canDamage, attacker, victim)
	if not ok then
		return true
	end
	return allowed ~= false
end

-- ==========================================================================
-- ram resolution
-- ==========================================================================

--[[ Resolves ONE direction of a contact: `attacker` slams `victim` along `hitDir`.
	Returns true when a real hit landed. A touch too soft to damage burns nothing at
	all — no cooldown, no fx — so a gentle nudge never eats the next real slam. ]]
local function applyRam(
	attacker: Player,
	attackerEntry: { [string]: any },
	victim: Player,
	victimEntry: { [string]: any },
	hitDir: Vector3,
	closingSpeed: number,
	withSelfDamage: boolean
): boolean
	local now = workspace:GetServerTimeNow()
	local cooldowns = ramCooldown[attacker]
	if cooldowns and (cooldowns[victim] or 0) > now then
		return false
	end

	local rearHit = ChassisSpec.isRearHit(hitDir, victimEntry.hull.CFrame.LookVector)
	local damage, knockback = ChassisSpec.ramResult(closingSpeed, attackerEntry.mass, victimEntry.mass, rearHit)
	if damage <= 0 then
		return false
	end

	if not cooldowns then
		cooldowns = {}
		ramCooldown[attacker] = cooldowns
	end
	cooldowns[victim] = now + CFG.COOLDOWN

	-- Shove first: applyDamage can kill the victim and tear the hull down under us.
	local flat = MathUtil.flatUnit(hitDir)
	local shoveDir = (flat.Magnitude > 0 and flat or hitDir) + Vector3.new(0, CFG.KNOCKBACK_LIFT, 0)
	CombatService.applyKnockback(victim, shoveDir, knockback, attacker)

	CombatService.applyDamage(victim, damage, attacker, CAUSE.KILLED)
	if withSelfDamage then
		-- The rammer pays for the crash too. If that kills them the car they rammed
		-- gets the credit — you died on their bumper.
		CombatService.applyDamage(attacker, ChassisSpec.ramSelfDamage(damage), victim, CAUSE.KILLED)
	end
	return true
end

--[[ Resolves one car-vs-car contact, role-agnostic.

	Closing speed is the two hulls' AssemblyLinearVelocity projected onto the contact
	direction: closing = (velA - velB):Dot(dirAB), which is exactly A's speed toward B
	plus B's speed toward A. Cars drifting apart give a negative value and never hit. ]]
local function resolveContact(playerA: Player, entryA: { [string]: any }, playerB: Player, entryB: { [string]: any })
	local carA, carB = entryA.car, entryB.car
	if not carA.Parent or not carB.Parent then
		return
	end

	local now = workspace:GetServerTimeNow()
	if ChassisSpec.isInvulnerable(carA, now) or ChassisSpec.isInvulnerable(carB, now) then
		return -- spawn protection on either side: no ram in either direction
	end

	--[[ Team-mates just BOUNCE: no damage either way, no knockback, no fx — and because
		this returns before applyRam is reached, no cooldown is burned either, so a
		friendly shunt can never eat the ram window a rival was about to walk into.
		Gating the whole CONTACT rather than each direction is the point: the pair is
		symmetric, so asking once is both cheaper and impossible to get half-right. ]]
	if not canDamage(playerA, playerB) then
		return
	end

	local hullA, hullB = entryA.hull, entryB.hull
	local delta = hullB.Position - hullA.Position
	if delta.Magnitude < CONTACT_EPSILON then
		return
	end
	local dirAB = delta.Unit

	local closeA = hullA.AssemblyLinearVelocity:Dot(dirAB) -- A's speed toward B
	local closeB = -hullB.AssemblyLinearVelocity:Dot(dirAB) -- B's speed toward A
	local closingSpeed = closeA + closeB
	if closingSpeed <= 0 then
		return
	end

	local contactPoint = hullA.Position + delta * 0.5
	local resolved, fxDir = false, dirAB

	if closeA > 0 and closeB > 0 then
		-- Head-on: both drove into it, so both take the hit and neither stacks self damage.
		local hitB = applyRam(playerA, entryA, playerB, entryB, dirAB, closingSpeed, false)
		local hitA = applyRam(playerB, entryB, playerA, entryA, -dirAB, closingSpeed, false)
		resolved = hitB or hitA
		fxDir = closeA >= closeB and dirAB or -dirAB
	elseif closeA > 0 then
		resolved = applyRam(playerA, entryA, playerB, entryB, dirAB, closingSpeed, true)
	else
		resolved = applyRam(playerB, entryB, playerA, entryA, -dirAB, closingSpeed, true)
		fxDir = -dirAB
	end

	if resolved then
		-- One burst per resolved collision, at the contact midpoint.
		fireFx("RAM", { origin = contactPoint, dir = fxDir })
	end
end

local function onHullTouched(player: Player, otherPart: BasePart)
	--[[ The mountaintop hub is bumper cars: outside a Match a shove is physics and
		nothing else — no damage, no knockback, no kill, no crown scatter. Gating the
		contact here keeps the ram path a single funnel; weapons need no equivalent gate
		because they only exist inside a round. ]]
	if not MatchState.isMatch() then
		return
	end

	local entry = liveCars[player]
	if not entry or not entry.car.Parent then
		return
	end

	local otherCar = carModelFromPart(otherPart)
	if not otherCar or otherCar == entry.car then
		return -- arena geometry, a pickup, or our own bodywork
	end

	local otherPlayer = ownerOfCar(otherCar)
	if not otherPlayer or otherPlayer == player then
		return
	end

	local otherEntry = liveCars[otherPlayer]
	if not otherEntry or otherEntry.car ~= otherCar then
		return -- not a live, Combat-registered car
	end

	resolveContact(player, entry, otherPlayer, otherEntry)
end

-- ==========================================================================
-- expiry sweep — freeze, shield, and handing knocked hulls back to their drivers
-- ==========================================================================

--[[ Gives a staggered hull back to its driver. Getting this wrong is WORSE than a weak
	knock: a car left server-owned drives with a full network round trip of input lag for
	the rest of its life. So re-verify everything first, and if the car was destroyed or
	replaced during the window do nothing at all — SpawnService assigns ownership on its
	next spawn, and touching a stale hull would fight it. ]]
local function restoreOwnership(player: Player, pending: { [string]: any })
	local hull = pending.hull
	if not hull or not hull.Parent then
		return -- wreck already torn down
	end
	if not isPlayer(player) or not player.Parent then
		return -- left mid-window; there is nobody to own it
	end

	local currentCar = getLiveCar(player)
	if currentCar ~= pending.car then
		return -- car destroyed or already replaced; its owner is set at spawn
	end

	pcall(hull.SetNetworkOwner, hull, player)
end

local function sweep()
	local now = workspace:GetServerTimeNow()

	--[[ Ownership restores run from this ONE sweep rather than a task.delay per hit, so
		overlapping knocks cannot race competing restores and a round ending mid-window
		cannot leave an orphaned timer behind. ]]
	for player, pending in pairs(pendingRestore) do
		if now >= pending.expiry then
			pendingRestore[player] = nil
			restoreOwnership(player, pending)
		end
	end

	for player, entry in pairs(liveCars) do
		if not entry.car.Parent then
			releaseCar(player) -- defensive: Destroying normally gets here first
		elseif player:GetAttribute(ATTR.FROZEN) == true and not ChassisSpec.isFrozen(entry.car, now) then
			player:SetAttribute(ATTR.FROZEN, false)
		end
	end

	for player, expiry in pairs(shieldUntil) do
		if now >= expiry then
			shieldUntil[player] = nil
			if player.Parent then
				player:SetAttribute(ATTR.SHIELDED, false)
			end
		end
	end
end

-- ==========================================================================
-- public API
-- ==========================================================================

--[[ Called by SpawnService immediately after a car is built and network-owned.
	Hooks the hull, resets Hp and arms spawn protection. ]]
function CombatService.onCarSpawned(player: Player, car: Instance)
	if not isPlayer(player) then
		warn("CombatService.onCarSpawned: not a player")
		return
	end
	if typeof(car) ~= "Instance" or not car:IsA("Model") then
		warn("CombatService.onCarSpawned: not a car model for " .. player.Name)
		return
	end

	local hull = ChassisSpec.getHull(car)
	if not hull then
		warn("CombatService.onCarSpawned: no Hull on " .. car:GetFullName())
		return
	end

	releaseCar(player) -- a respawn must never keep the previous car's Touched hook alive
	lastAttacker[player] = nil -- no ring-out credit carries across a life

	-- resolveCar, not resolve(carId): the Juggernaut's body carries its own mass, and
	-- entry.mass below is exactly what ChassisSpec.ramResult weighs a collision with.
	local resolved = ChassisSpec.resolveCar(car)
	local now = workspace:GetServerTimeNow()

	-- MaxHp belongs to CarFactory; read it, fall back to the spec, never write it.
	local maxHp = tonumber(car:GetAttribute(CAR_ATTR.MAX_HP)) or resolved.maxHp
	car:SetAttribute(CAR_ATTR.HP, maxHp)
	car:SetAttribute(CAR_ATTR.FROZEN_UNTIL, 0)
	car:SetAttribute(CAR_ATTR.STAGGER_UNTIL, 0) -- a fresh car always has full drive authority
	-- SpawnService stamps this once at spawn too; re-stamping the same Config value keeps
	-- a car spawned by any path protected, and every later change to it is ours alone.
	car:SetAttribute(CAR_ATTR.INVULN, now + MATCH.SPAWN_PROTECT)
	player:SetAttribute(ATTR.FROZEN, false)

	local entry = {
		car = car,
		hull = hull,
		mass = resolved.mass,
		conns = {},
	}
	liveCars[player] = entry
	carOwner[car] = player

	table.insert(
		entry.conns,
		hull.Touched:Connect(function(otherPart)
			onHullTouched(player, otherPart)
		end)
	)
	table.insert(
		entry.conns,
		car.Destroying:Connect(function()
			releaseCar(player)
		end)
	)
end

--[[ The single damage funnel. Returns true when this hit killed the car.
	attackerPlayer is optional (environmental damage); causeId is a cause id string. ]]
function CombatService.applyDamage(victimPlayer: Player, amount: number, attackerPlayer: Player?, causeId: string?): boolean
	if not isPlayer(victimPlayer) or not isPositive(amount) then
		return false
	end
	if not isPlayer(attackerPlayer) or attackerPlayer == victimPlayer then
		attackerPlayer = nil -- you never get kill credit for your own death
	end
	local cause = type(causeId) == "string" and causeId or nil

	--[[ Friendly fire, at the ONE funnel every weapon and every ram passes through.
		WeaponService refuses a team-mate up front as well (so the paired knockback and
		freeze are skipped with the damage); this is the backstop that makes the rule
		true for anything that ever calls in here. ]]
	if attackerPlayer and not canDamage(attackerPlayer, victimPlayer) then
		return false
	end

	if killing[victimPlayer] then
		return false -- already dying this frame
	end

	local car, hull = getLiveCar(victimPlayer)
	if not car then
		return false -- despawned, dead, or never spawned
	end

	local now = workspace:GetServerTimeNow()
	if ChassisSpec.isInvulnerable(car, now) then
		return false -- spawn protection: nothing happened, so nothing to credit
	end

	-- Credited even when the shield eats the damage below: they still landed the shove
	-- that may punt this car into a pit a second from now.
	noteAttacker(victimPlayer, attackerPlayer)

	--[[ Shield is duration based: it absorbs the hit entirely, as many times as it is
		hit, and pops visually each time. It is not consumed here, so the powerup slot
		stays put and WeaponService.clearPowerup is deliberately NOT called. ]]
	if victimPlayer:GetAttribute(ATTR.SHIELDED) == true then
		fireFx("SHIELD_POP", {
			origin = hull and hull.Position or nil,
			color = Config.POWERUPS.SHIELD.color,
		})
		return false
	end

	local hp = tonumber(car:GetAttribute(CAR_ATTR.HP)) or 0
	local newHp = math.max(0, hp - amount)
	car:SetAttribute(CAR_ATTR.HP, newHp)

	--[[ Announce the hit BEFORE killCar. On a killing blow that call tears the car down,
		and what the client draws off this — the victim's highlight flash and the number
		over its roof — wants the model still standing when the remote lands. The amount
		sent is what the car actually LOST, not what was asked for, so a 200-damage rocket
		into a car on 30 hp pops "-30" rather than lying about the overkill. ]]
	noteHitFx(
		victimPlayer,
		attackerPlayer,
		hp - newHp,
		hull and hull.Position or nil,
		newHp,
		tonumber(car:GetAttribute(CAR_ATTR.MAX_HP)),
		newHp <= 0
	)

	if newHp > 0 then
		return false
	end

	CombatService.killCar(victimPlayer, cause or CAUSE.KILLED, attackerPlayer)
	return true
end

--[[ Resolves a death exactly once: crown transfer, kill record, powerup wipe, teardown.
	Idempotent — a rocket and a ram landing on the same frame kill once. The guard is held
	across the despawn, so SpawnService calling back in cannot double-resolve. ]]
function CombatService.killCar(victimPlayer: Player, cause: string?, killerPlayer: Player?)
	if not isPlayer(victimPlayer) then
		warn("CombatService.killCar: not a player")
		return
	end
	if killing[victimPlayer] then
		return
	end

	--[[ RING-OUT CREDIT. A pit death arrives here with no killer, but if somebody shoved
		this car within Config.RAM.KILL_CREDIT_SECONDS they earned the kill outright — the
		steal, the feed entry and the credit all name them. A genuinely unassisted pit death
		(drove in alone, or the credit window lapsed) stays killer-less. The cause stays
		whatever the caller said, so the death card still reads as a fall. ]]
	if not isPlayer(killerPlayer) or killerPlayer == victimPlayer then
		killerPlayer = recentAttackerFor(victimPlayer)
	end
	lastAttacker[victimPlayer] = nil -- consumed; a fresh life starts with a clean slate

	local causeId = type(cause) == "string" and cause or CAUSE.KILLED

	-- Read the wreck BEFORE anything can destroy it: despawnCar below tears the model
	-- down synchronously, and the scatter needs this position.
	local _, hull = getLiveCar(victimPlayer)
	local deathPosition = hull and hull.Position
	if not deathPosition then
		local spawnSvc = ctxRef and ctxRef.svc.SpawnService
		if spawnSvc then
			local ok, state = pcall(spawnSvc.lastKnownState, victimPlayer)
			if ok and type(state) == "table" then
				deathPosition = state.pos or state.position
			end
		end
	end

	killing[victimPlayer] = true

	--[[ Crown transfer. ScoreService owns the Crowns attribute, so the steal, the zeroing
		and the kill record all go through it. Victim is zeroed FIRST: addCrowns clamps the
		total at 0 and only announces positive gains, so the drop is silent. recordKill is
		what broadcasts the kill feed (nil killer = announced, credited to nobody), so it
		shares this pcall with the crown moves and a pickup failure cannot swallow it. ]]
	local crowns = tonumber(victimPlayer:GetAttribute(ATTR.CROWNS)) or 0
	local stolen = killerPlayer and math.floor(crowns * MATCH.CROWN_DROP_FRACTION) or 0
	local scattered = killerPlayer and (crowns - stolen) or math.floor(crowns * MATCH.CROWN_SCATTER_FRACTION)

	local okScore, scoreErr = pcall(function()
		local score = ctxRef.svc.ScoreService
		if crowns > 0 then
			score.addCrowns(victimPlayer, -crowns)
		end
		if stolen > 0 then
			score.addCrowns(killerPlayer, stolen)
		end
		score.recordKill(killerPlayer, victimPlayer, stolen)
	end)
	if not okScore then
		warn("CombatService.killCar: crown transfer failed -> " .. tostring(scoreErr))
	end

	--[[ The mode's own bookkeeping: the points this kill was worth, and — in Juggernaut —
		the crown passing to whoever just took the monster down. Its own pcall, so a fault
		in a mode can neither swallow the crown transfer above nor strand the despawn below. ]]
	local okMode, modeErr = pcall(function()
		local mode = ctxRef.svc.ModeService
		if type(mode) == "table" and type(mode.onKill) == "function" then
			mode.onKill(killerPlayer, victimPlayer)
		end
	end)
	if not okMode then
		warn("CombatService.killCar: mode hook failed -> " .. tostring(modeErr))
	end

	-- Loot + slot wipe. Separate pcall so neither can strand the despawn below.
	local okDrop, dropErr = pcall(function()
		if scattered > 0 and deathPosition then
			ctxRef.svc.PickupService.dropCrowns(deathPosition, scattered)
		end
		ctxRef.svc.WeaponService.clearPowerup(victimPlayer)
	end)
	if not okDrop then
		warn("CombatService.killCar: crown scatter / powerup clear failed -> " .. tostring(dropErr))
	end

	-- SpawnService owns lives, the CarLifecycle "destroyed" remote and the model teardown.
	-- It only charges a life for "killed" / "fell", hence the normalization.
	local okDespawn, despawnErr = pcall(function()
		ctxRef.svc.SpawnService.despawnCar(victimPlayer, despawnCauseFor(causeId), killerPlayer)
	end)
	killing[victimPlayer] = nil
	if not okDespawn then
		warn("CombatService.killCar: despawn failed for " .. victimPlayer.Name .. " -> " .. tostring(despawnErr))
	end
end

-- Freeze ray. Never shortens a longer freeze already running.
function CombatService.applyFreeze(victimPlayer: Player, seconds: number)
	if not isPlayer(victimPlayer) or not isPositive(seconds) then
		return
	end

	local car = getLiveCar(victimPlayer)
	if not car then
		return
	end

	local now = workspace:GetServerTimeNow()
	if ChassisSpec.isInvulnerable(car, now) then
		return
	end
	if victimPlayer:GetAttribute(ATTR.SHIELDED) == true then
		return -- the shield eats debuffs as well as damage
	end

	local expiry = math.max(tonumber(car:GetAttribute(CAR_ATTR.FROZEN_UNTIL)) or 0, now + seconds)
	car:SetAttribute(CAR_ATTR.FROZEN_UNTIL, expiry)
	victimPlayer:SetAttribute(ATTR.FROZEN, true) -- HUD mirror; the sweep clears it
end

-- Shield powerup. Duration based; the sweep clears the attribute on expiry.
function CombatService.applyShield(player: Player, seconds: number)
	if not isPlayer(player) or not isPositive(seconds) then
		return
	end
	if not getLiveCar(player) then
		return -- no car to protect
	end

	local now = workspace:GetServerTimeNow()
	shieldUntil[player] = math.max(shieldUntil[player] or 0, now + seconds)
	player:SetAttribute(ATTR.SHIELDED, true)
end

--[[ Shared shove helper: rams, rocket blasts, mines and zaps ALL land through here, which
	is why the stagger stamp and the ownership dance live here and never at the call sites.

	IMPULSE, never a velocity write: a server-side AssemblyLinearVelocity write is overwritten
	by the simulating peer's very next physics step. Cosmetics are Massless, so AssemblyMass
	is the hull mass (120 * stats.mass) and scaling by it makes `speed` an exact studs/s
	delta-v — a Mini Tank and a Rocket Car both fly the distance the ram math intended.
	See the body for why the server takes the assembly for the stagger window.

	`attackerPlayer` is optional and additive to the pinned signature: pass it so a pure
	shove that deals no damage still earns the ring-out credit. ]]
function CombatService.applyKnockback(victimPlayer: Player, direction: Vector3, speed: number, attackerPlayer: Player?)
	if not isPlayer(victimPlayer) or not isPositive(speed) then
		return
	end
	if typeof(direction) ~= "Vector3" or direction.Magnitude < CONTACT_EPSILON then
		return
	end

	local car, hull = getLiveCar(victimPlayer)
	if not car or not hull or not hull.Parent then
		return
	end

	--[[ Same friendly-fire rule as damage, and it has to be here too: a shove that deals
		no damage never reaches applyDamage, so without this a team-mate could still be
		punted over the wall for a free ring-out. Only gated when an attacker is named —
		an anonymous impulse is environmental and always lands. ]]
	if attackerPlayer and not canDamage(attackerPlayer, victimPlayer) then
		return
	end

	-- A shove with no damage at all still earns the ring-out credit.
	noteAttacker(victimPlayer, attackerPlayer)

	local impulse = direction.Unit * speed * hull.AssemblyMass

	--[[ CHIP HITS DO NOT STAGGER. Below Config.RAM.MIN_KNOCK_TO_STAGGER this is not a shove,
		so apply the impulse and leave the driver completely alone — no stamp, no ownership
		borrow. Gating on `speed`, the post-falloff value we are actually about to deliver,
		means an edge-of-blast hit is judged on what it really does (edge rocket ~21 and edge
		mine ~27 still shove; a GUN bullet at 4 does not).
		Intended consequence: GUN knockback is cosmetic, because without the ownership borrow
		the victim's own Drive erases a 4-magnitude impulse almost immediately. The machine
		gun chips a fleeing car down; it is not a push weapon. ]]
	if speed < CFG.MIN_KNOCK_TO_STAGGER then
		hull:ApplyImpulse(impulse)
		return
	end

	local now = workspace:GetServerTimeNow()
	local expiry = now + CFG.STAGGER_SECONDS

	--[[ STAGGER, then TAKE THE ASSEMBLY, then impulse. Both halves are required:
		1. StaggerUntil tells ChassisController to stop commanding Drive (its LinearVelocity
		   carries MaxForce ~= mass * 450 and would erase the impulse inside ~0.1s). It
		   clamps its force to the vertical axis for this window so the car still hovers.
		2. Revoking network ownership is what makes the impulse LAND. The owning client's
		   simulation is authoritative for an assembly it owns, so a server ApplyImpulse on
		   it can be discarded outright — yielding the client's Drive is necessary but not
		   sufficient. Server-side simulation for the window keeps this authoritative; the
		   alternative (asking the client to knock itself back) is a free immunity exploit
		   for any client that simply ignores the message.
		Cost is ~0.35s of input lag for the victim, masked by the fact that they are being
		thrown through the air anyway. ]]
	car:SetAttribute(CAR_ATTR.STAGGER_UNTIL, expiry)
	pcall(hull.SetNetworkOwner, hull, nil)
	hull:ApplyImpulse(impulse)

	--[[ ONE pending restore per player: an overlapping knock extends the same deadline
		instead of scheduling a second competing restore, so ownership is handed back exactly
		once, at the end of the last window. Always monotonic, so a new hit never shortens a
		running stagger. ]]
	local pending = pendingRestore[victimPlayer]
	if pending and pending.car == car then
		pending.expiry = math.max(pending.expiry, expiry)
	else
		pendingRestore[victimPlayer] = { car = car, hull = hull, expiry = expiry }
	end
end

function CombatService.init(ctx)
	ctxRef = ctx

	Players.PlayerRemoving:Connect(function(player)
		releaseCar(player)
		killing[player] = nil
		shieldUntil[player] = nil
		lastAttacker[player] = nil
		hitFx[player] = nil
		pendingRestore[player] = nil -- no ownership to restore to a player who left

		-- Drop the leaver from every pair table so no departed Player is held anywhere.
		ramCooldown[player] = nil
		for _, victims in pairs(ramCooldown) do
			victims[player] = nil
		end
		for victim, record in pairs(lastAttacker) do
			if record.player == player then
				lastAttacker[victim] = nil
			end
		end
		for _, records in pairs(hitFx) do
			records[player] = nil
		end
	end)

	--[[ ONE sweep for every deadline: freeze, shield and the network-ownership restore. No
		per-hit task.delay pileups, and nothing orphaned when a round ends mid-window. ]]
	RunService.Heartbeat:Connect(sweep)
end

return CombatService
