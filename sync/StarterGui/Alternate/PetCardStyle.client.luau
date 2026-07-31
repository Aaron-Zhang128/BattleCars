-- Styles generated pet cards after the bold, dark Skills-card layout.
local gui = script.Parent
local UserInputService = game:GetService("UserInputService")
local sell = gui:WaitForChild("Frames"):WaitForChild("Sell")
local INK = Color3.fromRGB(18, 18, 16)

local function stroke(obj, thickness, color)
	local s = obj:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color or INK
	s.LineJoinMode = Enum.LineJoinMode.Miter
	s.Parent = obj
	return s
end

local function textStyle(label, color)
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextStrokeColor3 = INK
	label.TextStrokeTransparency = 0
end

-- The inventory lights the card the inspector is showing; this layer rebuilds
-- every card's rim, so it has to speak the same lime. Keep in sync with
-- CARD_SELECT_LIME in Alternate/Main.client.luau.
local SELECT_LIME = Color3.fromRGB(150, 255, 74)

local function styleCard(card)
	if card:GetAttribute("SkillCardStyled") then return end
	card:SetAttribute("SkillCardStyled", true)
	-- The inventory stamps the pet's rarity colour onto the card as an ATTRIBUTE,
	-- because the purge below destroys the strokes and gradients that used to carry
	-- it. Reading the leftover WHITE rim back out as "the rarity colour" is what
	-- made every pet's rarity text the same grey ramp; the attribute is the truth.
	local rarityColor = card:GetAttribute("RarityColor")
	if typeof(rarityColor) ~= "Color3" then
		local rarityStroke = card:FindFirstChild("RarityStroke") or card:FindFirstChildOfClass("UIStroke")
		rarityColor = rarityStroke and rarityStroke.Color or Color3.fromRGB(160, 160, 160)
	end
	for _, child in card:GetChildren() do
		if child:IsA("UIStroke") then child:Destroy() end
	end

	card.BackgroundColor3 = Color3.fromRGB(38, 33, 24)
	card.BackgroundTransparency = 0.12
	-- Named so the inventory's paintCard can find it -- it is the single owner of
	-- this rim's color, and it rests on INK, so the old "snap back to INK on any
	-- change" lock is gone: it also swallowed the selected-card highlight.
	local cardStroke = stroke(card, 4, INK)
	cardStroke.Name = "CardStroke"
	-- Styling is deferred, so a card can already be the selected one by the time
	-- its rim is rebuilt. Restore that state instead of dropping it to ink.
	if card:GetAttribute("Selected") then
		cardStroke.Color = SELECT_LIME
		cardStroke.Thickness = 4
	end
	-- Inner rarity ring, rebuilt because the stroke purge above took the original
	-- with it. It does two jobs: on this flat dark card it is the only at-a-glance
	-- rarity cue in the grid, and the inventory's paintCard tweens it as the
	-- SELECTED halo -- with the ring gone, a selected card had no halo at all.
	local selected = card:GetAttribute("Selected") == true
	local rarityRing = Instance.new("UIStroke")
	rarityRing.Name = "RarityStroke"
	rarityRing.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rarityRing.LineJoinMode = Enum.LineJoinMode.Miter
	rarityRing.Color = rarityColor
	rarityRing.Thickness = if selected then 2.5 else 1.5
	rarityRing.Transparency = if selected then 0 else 0.42
	rarityRing.Parent = card
	local corner = card:FindFirstChildOfClass("UICorner")
	if corner then corner.CornerRadius = UDim.new(0, 1) end
	for _, effect in card:GetChildren() do
		if effect:IsA("UIGradient") then effect:Destroy() end
	end

	local plate = card:FindFirstChild("Plate")
	if plate and plate:IsA("GuiObject") then
		plate.Position = UDim2.fromScale(0.5, 0.16)
		plate.Size = UDim2.fromScale(0.9, 0.62)
		-- A faint rarity wash behind the art instead of a bare transparent plate.
		-- The card BODY stays the shared dark brown (tinting whole cards per rarity
		-- fought the Skills-card look), but this gives rarity a second place to read
		-- from at grid distance, where an inner ring alone is easy to miss.
		plate.BackgroundColor3 = rarityColor
		plate.BackgroundTransparency = 0.78
		local plateStroke = plate:FindFirstChildOfClass("UIStroke")
		if plateStroke then plateStroke:Destroy() end
		local image = plate:FindFirstChildOfClass("ImageLabel")
		if image then image.Size = UDim2.fromScale(1.08, 1.08) end
	end

	for _, label in card:GetChildren() do
		-- SelectBadge is a corner sticker, not one of the card's text rows.
		if label:IsA("TextLabel") and label.Name ~= "SelectBadge" then
			local y = label.Position.Y.Scale
			if label.Name == "Ability" then
				label.Position = UDim2.fromScale(0.5, 0.72)
				label.Size = UDim2.fromScale(0.94, 0.14)
				textStyle(label, Color3.fromRGB(225, 225, 225))
			elseif y > 0.82 then
				label.Position = UDim2.fromScale(0.5, 0.82)
				label.Size = UDim2.fromScale(0.94, 0.17)
				label.TextXAlignment = Enum.TextXAlignment.Right
				label.Font = Enum.Font.GothamBlack
				label.TextColor3 = Color3.new(1, 1, 1)
				label.TextStrokeTransparency = 1
				local rarityOutline = Instance.new("UIStroke")
				rarityOutline.Name = "RarityOutline"
				rarityOutline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
				rarityOutline.Thickness = 2.25
				rarityOutline.Color = Color3.new(0, 0, 0)
				rarityOutline.Parent = label
				local rarityGradient = Instance.new("UIGradient")
				rarityGradient.Name = "RarityGradient"
				rarityGradient.Rotation = 90
				rarityGradient.Color = ColorSequence.new(
					rarityColor:Lerp(Color3.new(1, 1, 1), 0.68),
					rarityColor:Lerp(Color3.new(0, 0, 0), 0.32)
				)
				rarityGradient.Parent = label
			else
				label.Position = UDim2.fromScale(0.5, 0.015)
				label.Size = UDim2.fromScale(0.94, 0.2)
				textStyle(label, Color3.new(1, 1, 1))
			end
		end
	end
end

local function styleObject(obj)
	if obj.Name == "PetCard" and obj:IsA("Frame") then
		task.defer(styleCard, obj)
	elseif obj:IsA("Frame") and obj.Name:match("^Slot%d+$") then
		obj.BackgroundColor3 = INK
		obj.BackgroundTransparency = 0
		local slotStroke = stroke(obj, 4, INK)
		task.defer(function()
			if slotStroke.Parent then slotStroke.Color = INK end
		end)
	end
end

-- Keeps section headings and their card rows from overlapping.
local function layoutPanel()
	sell.AnchorPoint = Vector2.new(0.5, 0.5)
	sell.Position = UDim2.fromScale(0.5, 0.5)
	sell.Size = UDim2.fromScale(0.48, 0.76)

	local luckBar = sell:FindFirstChild("LuckBar")
	if luckBar and luckBar:IsA("GuiObject") then luckBar.Visible = false end

	local equipRow = sell:FindFirstChild("EquipRow")
	if equipRow then
		equipRow.Position = UDim2.fromScale(0.04, 0.23)
		equipRow.Size = UDim2.fromScale(0.92, 0.18)
	end

	local equippedLabel = sell:FindFirstChild("EquippedLabel")
	if equippedLabel then
		equippedLabel.Position = UDim2.fromScale(0.05, 0.17)
		equippedLabel.Size = UDim2.fromScale(0.30, 0.042)
	end
	local equippedDivider = sell:FindFirstChild("EquippedDivider")
	if equippedDivider then
		equippedDivider.Position = UDim2.fromScale(0.36, 0.20)
		equippedDivider.Size = UDim2.fromScale(0.59, 0.007)
	end

	local divider = sell:FindFirstChild("PetSectionDivider")
	if not divider then
		divider = Instance.new("Frame")
		divider.Name = "PetSectionDivider"
		divider.BorderSizePixel = 0
		divider.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		divider.ZIndex = 6
		divider.Parent = sell
	end
	divider.Position = UDim2.fromScale(0.04, 0.475)
	divider.Size = UDim2.new(0.92, 0, 0, 4)

	local collectionLabel = sell:FindFirstChild("CollectionLabel")
	if collectionLabel then
		collectionLabel.Position = UDim2.fromScale(0.05, 0.43)
		collectionLabel.Size = UDim2.fromScale(0.34, 0.04)
	end

	local list = sell:FindFirstChild("EquippedList")
	if list then
		list.Position = UDim2.fromScale(0.03, 0.49)
		if UserInputService.TouchEnabled and workspace.CurrentCamera.ViewportSize.Y <= 500 then
			-- Reserve a real 44px footer for the tutorial-friendly Equip Best button.
			list.Size = UDim2.fromScale(0.94, 0.31)
		else
			list.Size = UDim2.fromScale(0.94, 0.40)
		end
	end

	local dragHint = sell:FindFirstChild("DragHint")
	if dragHint then
		dragHint.AnchorPoint = Vector2.new(0, 0)
		dragHint.Position = UDim2.fromScale(0.44, 0.43)
		dragHint.Size = UDim2.fromScale(0.51, 0.042)
	end
end

local function layoutSquares()
	local side = math.clamp(math.floor(sell.AbsoluteSize.Y * 0.17), 82, 104)
	local list = sell:FindFirstChild("EquippedList")
	local listGrid = list and list:FindFirstChildOfClass("UIGridLayout")
	if listGrid then
		listGrid.CellSize = UDim2.fromOffset(side, side)
		listGrid.CellPadding = UDim2.fromOffset(18, 18)
	end
	local equipRow = sell:FindFirstChild("EquipRow")
	local equipGrid = equipRow and equipRow:FindFirstChildOfClass("UIGridLayout")
	if equipGrid then
		-- Fit only real equipped pets and the green +1 Pet Slot button.
		-- Empty capacity deliberately has no placeholder box.
		local cellCount = 0
		for _, child in equipRow:GetChildren() do
			if child:IsA("GuiObject") then cellCount += 1 end
		end
		cellCount = math.max(1, cellCount)
		local availableWidth = math.max(1, math.floor(equipRow.AbsoluteSize.X))
		local gap = math.clamp(math.floor(availableWidth * 0.025), 10, 22)
		local fitSide = math.floor((availableWidth - gap * (cellCount - 1)) / cellCount)
		local rowHeight = math.max(1, math.floor(equipRow.AbsoluteSize.Y))
		local equipSide = math.max(1, math.min(side, fitSide, rowHeight))
		equipGrid.CellSize = UDim2.fromOffset(equipSide, equipSide)
		equipGrid.CellPadding = UDim2.fromOffset(gap, 0)
		equipGrid.FillDirectionMaxCells = cellCount
		equipGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
		equipGrid.VerticalAlignment = Enum.VerticalAlignment.Center
	end
end

-- Parenting one populated card raises DescendantAdded for the card and every
-- child below it. Coalesce that entire burst into one layout pass instead of
-- scheduling two full layouts per descendant.
local layoutQueued = false
local function queueLayout()
	if layoutQueued then return end
	layoutQueued = true
	task.defer(function()
		layoutQueued = false
		if not sell.Parent then return end
		layoutPanel()
		layoutSquares()
	end)
end

for _, obj in sell:GetDescendants() do styleObject(obj) end
sell.DescendantAdded:Connect(function(obj)
	styleObject(obj)
	queueLayout()
end)
queueLayout()
sell:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueLayout)
