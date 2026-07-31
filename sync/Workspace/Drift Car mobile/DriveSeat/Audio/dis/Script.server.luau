wait(3)
script.Parent.OnServerEvent:Connect(function(player)
if script.Parent.Parent.dist.Enabled == false then
script.Parent.Parent.dist.Enabled = true
elseif script.Parent.Parent.dist.Enabled == true then
script.Parent.Parent.dist.Enabled = false
end
end)