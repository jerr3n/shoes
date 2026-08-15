--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local remote = ReplicatedStorage:WaitForChild("Message") :: RemoteEvent
local channels = TextChatService:WaitForChild("TextChannels")
local general = channels:WaitForChild("RBXGeneral") :: TextChannel

remote.OnClientEvent:Connect(function(text: string)
	general:DisplaySystemMessage(text)
end)