--[[ CarRegistry
	Roster lookups and ownership decoding. Shared by GarageService (validates purchases),
	GarageUI (draws cards), CarFactory (builds models) and SpawnService (picks the car).

	Ownership is replicated as a JSON array on Config.ATTR.OWNED, written ONLY by ProfileService.
]]

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Parent.Config)

local CarRegistry = {}

-- Roster in display order (Config.CARS order = cheapest-first progression).
function CarRegistry.all()
	return Config.CARS
end

function CarRegistry.get(carId: string?)
	if not carId then
		return nil
	end
	return Config.CARS_BY_ID[carId]
end

function CarRegistry.exists(carId: string?): boolean
	return CarRegistry.get(carId) ~= nil
end

function CarRegistry.starterId(): string
	return Config.STARTER_CAR
end

-- Falls back to the starter car rather than erroring, so a bad id never hard-stops a spawn.
function CarRegistry.getOrStarter(carId: string?)
	return CarRegistry.get(carId) or CarRegistry.get(Config.STARTER_CAR)
end

function CarRegistry.rarityColor(car): Color3
	return Config.UI.RARITY[car and car.rarity or "COMMON"] or Config.UI.RARITY.COMMON
end

function CarRegistry.isFree(car): boolean
	return car.starter == true or (car.price or 0) <= 0
end

function CarRegistry.priceText(car): string
	if CarRegistry.isFree(car) then
		return "FREE"
	end
	return tostring(car.price) .. " " .. string.upper(car.currency)
end

-- ---------- ownership ----------
--[[ Decodes the OWNED attribute into a set. Tolerates nil/garbage by returning
	just the starter car — a decode failure must never lock a player out of driving. ]]
function CarRegistry.decodeOwned(encoded: string?): { [string]: boolean }
	local set = { [Config.STARTER_CAR] = true }
	if type(encoded) ~= "string" or encoded == "" then
		return set
	end

	local ok, list = pcall(HttpService.JSONDecode, HttpService, encoded)
	if not ok or type(list) ~= "table" then
		warn("CarRegistry.decodeOwned: bad payload, defaulting to starter only")
		return set
	end

	for _, id in ipairs(list) do
		if CarRegistry.exists(id) then
			set[id] = true
		end
	end
	return set
end

function CarRegistry.encodeOwned(set: { [string]: boolean }): string
	local list = {}
	for id, owned in pairs(set) do
		if owned and CarRegistry.exists(id) then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return HttpService:JSONEncode(list)
end

-- Works on client and server: reads the replicated attribute.
function CarRegistry.ownedSet(player: Instance): { [string]: boolean }
	return CarRegistry.decodeOwned(player:GetAttribute(Config.ATTR.OWNED))
end

function CarRegistry.owns(player: Instance, carId: string): boolean
	return CarRegistry.ownedSet(player)[carId] == true
end

function CarRegistry.equippedId(player: Instance): string
	local id = player:GetAttribute(Config.ATTR.EQUIPPED)
	if CarRegistry.exists(id) then
		return id
	end
	return Config.STARTER_CAR
end

-- ---------- UI stat bars ----------
--[[ Normalizes each stat against the roster's best so garage bars are comparable.
	Returns { speed = 0..1, accel = 0..1, turn = 0..1, tough = 0..1 } ]]
local maxima = nil
local function computeMaxima()
	if maxima then
		return maxima
	end
	maxima = { topSpeed = 0, accel = 0, turn = 0, hp = 0 }
	for _, car in ipairs(Config.CARS) do
		maxima.topSpeed = math.max(maxima.topSpeed, car.stats.topSpeed)
		maxima.accel = math.max(maxima.accel, car.stats.accel)
		maxima.turn = math.max(maxima.turn, car.stats.turn)
		maxima.hp = math.max(maxima.hp, car.stats.hp)
	end
	return maxima
end

function CarRegistry.statBars(car)
	local m = computeMaxima()
	local s = car.stats
	return {
		speed = s.topSpeed / m.topSpeed,
		accel = s.accel / m.accel,
		turn = s.turn / m.turn,
		tough = s.hp / m.hp,
	}
end

return CarRegistry
