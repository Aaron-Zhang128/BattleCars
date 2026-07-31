wait(3)
script.Parent.OnServerEvent:Connect(function(player,soundid)
script.Parent.Parent.SoundId = "rbxassetid://"..soundid
script.Parent.Parent:Play()
end)