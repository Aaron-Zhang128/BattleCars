wait(3)
script.Parent.OnServerEvent:Connect(function(player)
if script.Parent.Parent.bass.Enabled == false then
script.Parent.Parent.bass.Enabled = true
elseif script.Parent.Parent.bass.Enabled == true then
script.Parent.Parent.bass.Enabled = false
end
end)