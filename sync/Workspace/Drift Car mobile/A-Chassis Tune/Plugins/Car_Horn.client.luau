local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

UserInputService.InputBegan:Connect(function(input, gameProccesed)
	if not gameProccesed then
		if input.KeyCode == Enum.KeyCode.H then
			script:WaitForChild("CarHorn"):Play()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProccesed)
	if not gameProccesed then
		if input.KeyCode == Enum.KeyCode.H then
			script:WaitForChild("CarHorn"):Stop()
		end
	end
end)
