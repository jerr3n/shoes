local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = ReplicatedStorage:WaitForChild("SystemMessage")
local general = TextChatService:WaitForChild("TextChannels"):WaitForChild("RBXGeneral")

remote.OnClientEvent:Connect(function(text: string)
	general:DisplaySystemMessage(text)
end)