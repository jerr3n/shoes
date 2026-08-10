-- hi
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
ServerStorage:WaitForChild("SAFEGUARD")
Players.PlayerAdded:Connect(function(player: Player)
    player:Kick("SDS fail")
end)