script.Parent.MouseButton1Down:Connect(function()
	local player = game.Players.LocalPlayer
	local Character = player.Character:WaitForChild("Humanoid")
	
	Character.Sit = true
end)