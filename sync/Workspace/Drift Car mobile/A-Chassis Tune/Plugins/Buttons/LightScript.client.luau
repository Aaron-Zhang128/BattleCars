local l = script.Parent
local Status = "Off"
local Car = script.Parent.Parent.Car.Value
local Event = Car:WaitForChild("SmeersLightsHandler")


script.Parent.Headlights.MouseButton1Down:Connect(function()
	Event:FireServer({["ToggleHeadlight"]=true})
end)

script.Parent.Highbeam.MouseButton1Down:Connect(function()
	Event:FireServer({["ToggleHighbeam"]=true})
end)

script.Parent.LeftSignal.MouseButton1Down:Connect(function()
	Event:FireServer({["ToggleLeftBlink"]=true})
end)

script.Parent.RightSignal.MouseButton1Down:Connect(function()
	Event:FireServer({["ToggleRightBlink"]=true})
end)

script.Parent.HazardsButton.MouseButton1Down:Connect(function()
	Event:FireServer({["ToggleHazards"]=true})
end)

script.Parent.Brake.MouseButton1Down:Connect(function()
	Event:FireServer({["EnableBrakes"]=true})
end)

script.Parent.Brake.MouseButton1Up:Connect(function()
	Event:FireServer({["DisableBrakes"]=true})
end)
