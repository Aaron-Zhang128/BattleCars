--[[ MathUtil
	Small pure helpers used across chassis, fx and UI. No state, no yields.
]]

local MathUtil = {}

function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Frame-rate independent exponential approach. `rate` is roughly "per second".
function MathUtil.damp(current: number, target: number, rate: number, dt: number): number
	return target + (current - target) * math.exp(-rate * dt)
end

-- Moves toward target by at most maxDelta.
function MathUtil.approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

function MathUtil.clamp01(v: number): number
	return math.clamp(v, 0, 1)
end

-- Maps v from [inMin,inMax] to [outMin,outMax], clamped.
function MathUtil.map(v: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	if inMax == inMin then
		return outMin
	end
	local t = math.clamp((v - inMin) / (inMax - inMin), 0, 1)
	return outMin + (outMax - outMin) * t
end

-- Two-sine organic drift, the house idle-motion recipe.
function MathUtil.drift(t: number, freq: number, phase: number, amp: number): number
	return (math.sin(t * freq + phase) * 0.7 + math.sin(t * freq * 1.7 + phase * 2 + 1) * 0.3) * amp
end

function MathUtil.pulse(t: number, speed: number, phase: number, amp: number): number
	return 1 + math.sin(t * speed + phase) * amp
end

--[[ Weighted pick. `entries` is an array of tables each holding a numeric `weight`.
	`bonus` optionally adds weight to whichever entry matches bonusKey on field `id`. ]]
function MathUtil.weightedPick(entries: { any }, rng: Random?, bonusId: string?, bonusWeight: number?)
	local total = 0
	for _, e in ipairs(entries) do
		local w = e.weight or 1
		if bonusId and e.id == bonusId then
			w = w + (bonusWeight or 0)
		end
		total = total + w
	end
	if total <= 0 then
		return entries[1]
	end

	local roll = (rng and rng:NextNumber() or math.random()) * total
	for _, e in ipairs(entries) do
		local w = e.weight or 1
		if bonusId and e.id == bonusId then
			w = w + (bonusWeight or 0)
		end
		roll = roll - w
		if roll <= 0 then
			return e
		end
	end
	return entries[#entries]
end

-- Random point inside a square of half-extent `half` around origin, on the XZ plane.
function MathUtil.randomXZ(half: number, rng: Random?): Vector2
	local r = rng or Random.new()
	return Vector2.new(r:NextNumber(-half, half), r:NextNumber(-half, half))
end

-- Flattens a vector onto the XZ plane and normalizes it. Returns zero vector if degenerate.
function MathUtil.flatUnit(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-4 then
		return Vector3.zero
	end
	return flat.Unit
end

-- Signed angle in degrees from `from` to `to` about the Y axis.
function MathUtil.signedYawTo(from: Vector3, to: Vector3): number
	local a, b = MathUtil.flatUnit(from), MathUtil.flatUnit(to)
	if a.Magnitude == 0 or b.Magnitude == 0 then
		return 0
	end
	local dot = math.clamp(a:Dot(b), -1, 1)
	local cross = a:Cross(b).Y
	return math.deg(math.acos(dot)) * (cross >= 0 and 1 or -1)
end

-- 1234567 -> "1,234,567"
function MathUtil.comma(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return out
end

-- 1500 -> "1.5K", 2300000 -> "2.3M". For tight HUD counters.
function MathUtil.short(n: number): string
	local abs = math.abs(n)
	if abs >= 1e6 then
		return string.format("%.1fM", n / 1e6):gsub("%.0M", "M")
	elseif abs >= 1e3 then
		return string.format("%.1fK", n / 1e3):gsub("%.0K", "K")
	end
	return tostring(math.floor(n + 0.5))
end

return MathUtil
