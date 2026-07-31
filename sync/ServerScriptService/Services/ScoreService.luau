--[[ ScoreService
	Round scoring: crowns, kills, the live board, and the end-of-round payout.

	PURPOSE
		Owns the per-round score table. It is the ONLY writer of the Crowns and Kills
		player attributes, and the only path by which crowns change.

	DATA FLOW
		PickupService.addCrowns  ->  crowns up   (crown pickup)
		CombatService.addCrowns  ->  crowns move (steal on the killer, zero on the victim)
		CombatService.recordKill ->  kills up + kill feed
		MatchService.resetRound / getBoard / payoutRound drive the round boundaries.

		Every change mirrors to attributes on the Player, so the HUD updates with no remote:
			Crowns  crowns held this round
			Kills   kills this round

	REMOTES (S->C)
		MatchEvent "crown" -> FireClient { amount = number, total = number }
			Fired ONLY for positive gains (the "+1" pop). Losses (death drop, steal,
			zeroing) are read off the Crowns attribute, so no remote is sent for them.
		MatchEvent "kill"  -> FireAllClients { killerName = string?, victimName, crowns }
			Fired from recordKill — that call site is the one place that knows killer,
			victim and crowns stolen together. CombatService must NOT also fire it.
		Notify -> FireClient(text, "gold") with each player's coin total at payout.

	SERVICES USED — resolved LAZILY through ctx.svc at call time:
		ProfileService  isLoaded addCoins addGems noteRoundResult

	INIT ORDER
		Inited before MatchService. ProfileService is inited first but is only ever
		touched at payout time, long after every service exists.

	SCORE
		A round entry is { crowns, kills, points }. `points` is the generic bucket the
		MODE pays into (ModeService: a juggernaut takedown, surviving an elimination) —
		it exists so a new mode needs no new attribute anywhere. Which of the three
		actually PLACES is Shared.GameModes.scoreOf's call, mirrored onto the player as
		Config.ATTR.SCORE so the HUD, the nametags and the results card all read one
		number and none of them has to know which mode is running.

	PUBLIC API
		addCrowns(player, n) -> newTotal      recordKill(killer, victim, crownsStolen)
		addPoints(player, n) -> newTotal      resetRound()
		getBoard() -> rows                   payoutRound() -> { [userId] = coins }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = ReplicatedStorage:WaitForChild("CrashCore")
local sharedFolder = core:WaitForChild("Shared")
local Config = require(core:WaitForChild("Config"))
local MathUtil = require(sharedFolder:WaitForChild("MathUtil"))
local GameModes = require(sharedFolder:WaitForChild("GameModes"))

local ATTR = Config.ATTR
local ECON = Config.ECONOMY

local GEM_ROLL_CAP = 200 -- safety bound on the per-crown gem roll loop
local NOTIFY_MOOD = "gold"

local ScoreService = {}

local ctx
local matchEvent
local notifyRemote
local rng = Random.new()
local round = {} -- [Player] = { crowns = number, kills = number, points = number }

-- ==========================================================================
-- Internals
-- ==========================================================================

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function mirror(player: Player, entry)
	player:SetAttribute(ATTR.CROWNS, entry.crowns)
	player:SetAttribute(ATTR.KILLS, entry.kills)
	--[[ The ONE number this mode places on, derived here rather than at each reader, so
		the HUD board, the world nametags and the results card can never disagree about
		what your score is — and none of them has to branch on the mode to find out. ]]
	player:SetAttribute(ATTR.SCORE, GameModes.scoreOf(entry))
end

-- Fetches (or creates, zeroed) the round entry for a player still in the server.
local function entryFor(player: Player)
	if not isPlayer(player) or not player.Parent then
		return nil
	end
	local entry = round[player]
	if not entry then
		entry = { crowns = 0, kills = 0, points = 0 }
		round[player] = entry
		mirror(player, entry)
	end
	return entry
end

-- pcall wrapper for ProfileService calls: one bad profile must not drop everyone's payout.
local function profileCall(fnName: string, ...): (boolean, any)
	local profiles = ctx and ctx.svc.ProfileService
	local fn = type(profiles) == "table" and profiles[fnName] or nil
	if type(fn) ~= "function" then
		warn("ScoreService: ProfileService." .. fnName .. " unavailable")
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn("ScoreService: ProfileService." .. fnName .. " failed -> " .. tostring(result))
		return false, nil
	end
	return true, result
end

-- ==========================================================================
-- Public API
-- ==========================================================================

--[[ The ONLY way crowns change. `n` may be negative (death drop / steal); the total
	clamps at 0. Returns the new total. ]]
function ScoreService.addCrowns(player: Player, n: number): number
	if not isPlayer(player) then
		warn("ScoreService.addCrowns: not a player")
		return 0
	end
	if type(n) ~= "number" or n ~= n then -- NaN guard
		warn("ScoreService.addCrowns: bad amount for " .. player.Name)
		return 0
	end

	local entry = entryFor(player)
	if not entry then
		return 0
	end

	local whole = n >= 0 and math.floor(n) or math.ceil(n) -- truncate toward zero
	local before = entry.crowns
	entry.crowns = math.max(0, before + whole)
	if entry.crowns == before then
		return before -- no-op or fully clamped: nothing to replicate
	end

	mirror(player, entry)

	-- Positive gains only: the client pops a "+n". Losses ride the Crowns attribute.
	if whole > 0 and matchEvent then
		matchEvent:FireClient(player, "crown", { amount = whole, total = entry.crowns })
	end

	return entry.crowns
end

--[[ Records a death. `killer` is nil for pit / self deaths (no kill credited, but the
	feed still announces it). Crown movement itself is the caller's job via addCrowns. ]]
function ScoreService.recordKill(killer: Player?, victim: Player, crownsStolen: number?)
	if not isPlayer(victim) then
		warn("ScoreService.recordKill: bad victim")
		return
	end

	local stolen = 0
	if type(crownsStolen) == "number" and crownsStolen == crownsStolen then
		stolen = math.max(0, math.floor(crownsStolen))
	end

	local killerName = nil
	if isPlayer(killer) and killer ~= victim then
		local entry = entryFor(killer)
		if entry then
			entry.kills += 1
			mirror(killer, entry)
			killerName = killer.Name
		end
	end

	if matchEvent then
		matchEvent:FireAllClients("kill", {
			killerName = killerName,
			victimName = victim.Name,
			crowns = stolen,
		})
	end
end

--[[ The mode's generic score bucket. ModeService is the only caller: a kill is worth
	Config.MODES.KILL_POINTS, taking the juggernaut down is worth far more, and surviving
	an elimination pays at the end of the round. Never negative — unlike crowns, points
	are earned and cannot be stolen back — and it returns the new total. ]]
function ScoreService.addPoints(player: Player, n: number): number
	if not isPlayer(player) then
		warn("ScoreService.addPoints: not a player")
		return 0
	end
	if type(n) ~= "number" or n ~= n or n <= 0 then
		return 0
	end

	local entry = entryFor(player)
	if not entry then
		return 0
	end

	entry.points += math.floor(n)
	mirror(player, entry)
	return entry.points
end

--[[ Rows for players still in the server, sorted on the MODE's score, then kills, then
	crowns, then userId ascending so the order is deterministic (table.sort is not stable)
	and still reads sensibly whichever of the three this mode happens to place on. ]]
function ScoreService.getBoard(): { any }
	local rows = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = round[player]
		if entry then
			table.insert(rows, {
				player = player,
				name = player.Name,
				userId = player.UserId,
				crowns = entry.crowns,
				kills = entry.kills,
				points = entry.points or 0,
				score = GameModes.scoreOf(entry),
				team = GameModes.teamOf(player),
			})
		end
	end

	table.sort(rows, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.kills ~= b.kills then
			return a.kills > b.kills
		end
		if a.crowns ~= b.crowns then
			return a.crowns > b.crowns
		end
		return a.userId < b.userId
	end)

	return rows
end

-- Zeroes every score and attribute. Called by MatchService on entering Lobby.
function ScoreService.resetRound()
	round = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = { crowns = 0, kills = 0, points = 0 }
		round[player] = entry
		mirror(player, entry)
	end
end

--[[ Pays out the finished round and returns { [userId] = coins } for the results card.
	coins = participation + crowns * COINS_PER_CROWN + kills * COINS_PER_KILL
	        + COINS_PER_PLACEMENT[place] for the top 4.
	Gems: one GEM_DROP_CHANCE roll per crown banked, GEM_DROP_AMOUNT each. ]]
function ScoreService.payoutRound(): { [number]: number }
	local board = ScoreService.getBoard()
	local payouts = {}

	for place, row in ipairs(board) do
		local player = row.player
		if player and player.Parent then
			--[[ The points term is what pays a Juggernaut or Elimination round: those
				modes bank no crowns at all, so without it the whole payout would be
				kills plus placement. ]]
			local coins = ECON.COINS_PARTICIPATION
				+ ECON.COINS_PER_CROWN * row.crowns
				+ ECON.COINS_PER_KILL * row.kills
				+ (ECON.COINS_PER_POINT or 0) * (row.points or 0)
			local placementBonus = ECON.COINS_PER_PLACEMENT[place]
			if placementBonus then
				coins += placementBonus
			end
			coins = math.max(0, math.floor(coins))

			local gems = 0
			for _ = 1, math.min(row.crowns, GEM_ROLL_CAP) do
				if rng:NextNumber() < ECON.GEM_DROP_CHANCE then
					gems += ECON.GEM_DROP_AMOUNT
				end
			end

			payouts[player.UserId] = coins

			-- Refuse to bank into a profile that never loaded cleanly.
			local _, loaded = profileCall("isLoaded", player)
			if loaded == true then
				if coins > 0 then
					profileCall("addCoins", player, coins)
				end
				if gems > 0 then
					profileCall("addGems", player, gems)
				end
				profileCall("noteRoundResult", player, row.crowns, row.kills)
			else
				warn("ScoreService: profile not loaded, payout skipped for " .. player.Name)
			end

			-- Re-check after the ProfileService calls above (they may yield).
			if player.Parent and notifyRemote and coins > 0 then
				notifyRemote:FireClient(player, "+" .. MathUtil.comma(coins) .. " coins!", NOTIFY_MOOD)
			end
		end
	end

	return payouts
end

function ScoreService.init(context)
	ctx = context
	matchEvent = ctx.net.MatchEvent
	notifyRemote = ctx.net.Notify

	for _, player in ipairs(Players:GetPlayers()) do
		entryFor(player)
	end

	Players.PlayerAdded:Connect(function(player)
		entryFor(player) -- zeroed attributes immediately, so the HUD never reads nil
	end)

	Players.PlayerRemoving:Connect(function(player)
		round[player] = nil
	end)
end

return ScoreService
