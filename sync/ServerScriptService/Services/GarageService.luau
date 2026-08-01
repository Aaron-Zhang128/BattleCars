--[[ GarageService
	Owns the GarageAction remote end to end: buying and equipping cars.

	REMOTE (pinned)
		GarageAction  C->S  (action: "buy"|"equip", carId: string)
		              S->C  (ok: boolean, message: string, carId: string)  -- FireClient the requester
		Notify        S->C  (text: string, mood: "gold"|"green"|"red")     -- green on a successful buy

	DATA FLOW
		client card tap -> GarageAction -> validate (player / Net.throttle / action whitelist /
		carId in CarRegistry) -> ProfileService.spend -> grantCar -> setEquipped
		-> GarageAction:FireClient(ok, message, carId). Ownership and balances replicate
		through ProfileService's attributes; this service never writes an attribute itself.

	ATTRIBUTES: none written here. Money / Gems / OwnedCars / EquippedCar belong to
	ProfileService — every mutation goes through its API.

	ORDER OF OPERATIONS (money safety)
		Debit first, then grant. A car is never handed out before the spend succeeds, and if
		grantCar somehow fails the spend is refunded and warned. No path leaves a player
		debited without the car.

	INIT ORDER: last in Main's ORDER. ProfileService and SpawnService are resolved LAZILY
	through ctx.svc at call time, never captured at init.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local Config = require(core:WaitForChild("Config"))
local Net = require(core:WaitForChild("Net"))
local CarRegistry = require(core:WaitForChild("Shared"):WaitForChild("CarRegistry"))

local GarageService = {}

local ATTR = Config.ATTR

-- Exact action whitelist. Anything else is a malformed or hostile client.
local ACTIONS = {
	buy = true,
	equip = true,
}

-- Kid copy: ~5 words, one clause, no jargon.
local MSG = {
	BOUGHT = "Unlocked!",
	EQUIPPED = "Equipped!",
	NEXT_LIFE = "Next life!",
	ALREADY_OWNED = "You already own it!",
	NEED_MONEY = "Need more money!",
	NEED_GEMS = "Need more gems!",
	NOT_OWNED = "Buy it first!",
	NOT_READY = "One second...",
}

local NOTIFY_MOOD_GOOD = "green"

local serverCtx = nil
local initialized = false

-- ==========================================================================
-- lazy sibling lookup — services after this one in ORDER may not exist yet
-- ==========================================================================

local function profileService()
	return serverCtx and serverCtx.svc and serverCtx.svc.ProfileService or nil
end

--[[ True when the player currently has a live car. Wrapped in pcall because SpawnService is a
	sibling: a failure there must not turn an equip into an error. ]]
local function hasLiveCar(player: Instance): boolean
	local spawnService = serverCtx and serverCtx.svc and serverCtx.svc.SpawnService
	if not spawnService or type(spawnService.getCar) ~= "function" then
		return false
	end
	local ok, car = pcall(spawnService.getCar, player)
	return ok and car ~= nil
end

-- ==========================================================================
-- actions — each returns (ok: boolean, message: string)
-- ==========================================================================

local function handleBuy(player: Instance, carId: string): (boolean, string)
	local Profile = profileService()
	if not Profile or not Profile.isLoaded(player) then
		return false, MSG.NOT_READY
	end
	if Profile.owns(player, carId) then
		return false, MSG.ALREADY_OWNED
	end

	local car = CarRegistry.get(carId)
	local currency = car.currency
	local price = CarRegistry.isFree(car) and 0 or (car.price or 0)

	-- Debit FIRST: never hand out a car we were not paid for.
	if price > 0 and not Profile.spend(player, currency, price) then
		return false, (currency == ATTR.GEMS) and MSG.NEED_GEMS or MSG.NEED_MONEY
	end

	if not Profile.grantCar(player, carId) then
		-- Refund: a player must never end up debited without the car.
		if price > 0 then
			if currency == ATTR.GEMS then
				Profile.addGems(player, price)
			else
				Profile.addMoney(player, price)
			end
		end
		warn(
			string.format(
				"GarageService: grantCar failed for %s / %s — refunded %d %s",
				player.Name,
				carId,
				price,
				tostring(currency)
			)
		)
		return false, MSG.NOT_READY
	end

	-- Auto-equip: a kid who just bought a car expects to drive it.
	Profile.setEquipped(player, carId)
	return true, MSG.BOUGHT
end

local function handleEquip(player: Instance, carId: string): (boolean, string)
	local Profile = profileService()
	if not Profile or not Profile.isLoaded(player) then
		return false, MSG.NOT_READY
	end
	if not Profile.owns(player, carId) then
		return false, MSG.NOT_OWNED
	end
	if not Profile.setEquipped(player, carId) then
		return false, MSG.NOT_OWNED
	end

	--[[ Mid-match with a live car: the running car is deliberately NOT swapped or respawned
		underneath the player. SpawnService reads the equipped car at spawn time, so say
		plainly that it lands next life. ]]
	if hasLiveCar(player) then
		return true, MSG.NEXT_LIFE
	end
	return true, MSG.EQUIPPED
end

-- ==========================================================================
-- remote handler
-- ==========================================================================

function GarageService.init(ctx)
	if initialized then
		return
	end
	initialized = true
	serverCtx = ctx

	local garageRemote = (ctx.net and ctx.net.GarageAction) or Net.server("GarageAction")
	local notifyRemote = (ctx.net and ctx.net.Notify) or Net.server("Notify")
	local gate = Net.throttle()

	garageRemote.OnServerEvent:Connect(function(player, action, carId)
		-- Never trust the client. Identity, then rate, then every argument.
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		-- Gated before the arg checks so a hostile client cannot flood warn() faster than the gap.
		if not gate(player) then
			return
		end
		if type(action) ~= "string" or ACTIONS[action] ~= true then
			warn("GarageService: bad action from " .. player.Name .. " -> " .. tostring(action))
			return
		end
		if type(carId) ~= "string" or not CarRegistry.exists(carId) then
			warn("GarageService: bad carId from " .. player.Name .. " -> " .. tostring(carId))
			return
		end

		local ok, message
		if action == "buy" then
			ok, message = handleBuy(player, carId)
		else
			ok, message = handleEquip(player, carId)
		end

		-- The player may have left while a profile call yielded.
		if not player:IsDescendantOf(Players) then
			return
		end

		garageRemote:FireClient(player, ok, message, carId)
		if ok and action == "buy" then
			notifyRemote:FireClient(player, message, NOTIFY_MOOD_GOOD)
		end
	end)
end

-- ==========================================================================
-- TODO(monetization): dev products for gems + ProcessReceipt live HERE.
--
-- Nothing is wired yet on purpose: Config.PRODUCTS and Config.PASSES are intentionally
-- empty and we do NOT invent placeholder ids (a wrong id silently eats real purchases).
--
-- When the products exist, populate Config.PRODUCTS (id -> { gems = n }) and add:
--   1. A receipt dedup ring of Config.DATA.RECEIPT_RING_SIZE entries: an array of
--      PurchaseId strings plus a set for O(1) lookup and a rolling write index. On a
--      repeat PurchaseId return Enum.ProductPurchaseDecision.PurchaseGranted WITHOUT
--      granting again — Roblox re-delivers receipts and double-granting is a real bug.
--   2. MarketplaceService.ProcessReceipt = function(info) ... end, set exactly once from
--      init(). Resolve the product through Config.PRODUCTS[info.ProductId]; an unknown id
--      returns NotProcessedYet so it is not consumed.
--   3. Grant through ProfileService.addGems(player, n) — never write Gems directly — then
--      force a save before returning PurchaseGranted, so a server crash cannot lose paid
--      currency. That save-before-granted step needs a public flush on ProfileService,
--      which does not exist yet (see HANDOFF).
--   4. If the buyer already left, return NotProcessedYet so the receipt is redelivered.
-- ==========================================================================

return GarageService
