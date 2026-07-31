--[[ PowerupDefs
	Thin authority over Config.POWERUPS. Shared so WeaponService (fires) and
	WeaponController (predicts + draws fx) can never disagree on a definition.

	One powerup slot per player at a time, like the original.
	Slot state is replicated on the Player as Config.ATTR.POWERUP / POWERUP_AMMO,
	written ONLY by WeaponService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Parent.Config)
local MathUtil = require(script.Parent.MathUtil)

local PowerupDefs = {}

--[[ Stable ordered list (Config.POWERUPS is a dictionary) AND the roster of what
	actually rolls: the seven modelled weapons plus SHIELD, which stays because it is
	a bubble rather than a gun and so never needed a turret model.

	MINE / FREEZE / ZAP are still fully defined in Config.POWERUPS, still have server
	handlers and still have client fx — they are simply not listed here, because a
	weapon with no model on your own roof reads as a bug beside four that have one.
	Adding an id back to this list is the whole revert. ]]
local ORDER = { "GUN", "DUALGUN", "CANNON", "MORTAR", "ROCKET", "FLAME", "RAILGUN", "SHIELD" }

function PowerupDefs.list()
	local out = {}
	for _, id in ipairs(ORDER) do
		local def = Config.POWERUPS[id]
		if def then
			table.insert(out, def)
		end
	end
	return out
end

function PowerupDefs.get(id: string?)
	if not id or id == "" then
		return nil
	end
	return Config.POWERUPS[id]
end

function PowerupDefs.exists(id: string?): boolean
	return PowerupDefs.get(id) ~= nil
end

function PowerupDefs.ammoFor(id: string): number
	local def = PowerupDefs.get(id)
	return def and def.ammo or 0
end

function PowerupDefs.cooldownFor(id: string): number
	local def = PowerupDefs.get(id)
	return def and def.cooldown or 0.5
end

--[[ Crate roll. The driver's car pulls its signature powerup more often
	(Config.SPECIAL_WEIGHT_BONUS), which is what makes cars feel different. ]]
function PowerupDefs.roll(carId: string?, rng: Random?)
	local car = carId and Config.CARS_BY_ID[carId]
	local bonusId = car and car.special or nil
	return MathUtil.weightedPick(PowerupDefs.list(), rng, bonusId, Config.SPECIAL_WEIGHT_BONUS)
end

-- Reads the slot straight off the player's attributes. Safe on client and server.
function PowerupDefs.slotOf(player: Instance)
	local id = player:GetAttribute(Config.ATTR.POWERUP)
	if not id or id == "" then
		return nil, 0
	end
	return PowerupDefs.get(id), player:GetAttribute(Config.ATTR.POWERUP_AMMO) or 0
end

-- Short kid-simple label for the HUD slot.
function PowerupDefs.shortName(id: string?): string
	local def = PowerupDefs.get(id)
	if not def then
		return ""
	end
	return def.name
end

return PowerupDefs
