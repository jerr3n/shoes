const ReplicatedStorage = game:GetService("ReplicatedStorage")
const TextChatService = game:GetService("TextChatService")

-- The server cannot call DisplaySystemMessage, so it sends the text here.
const remote = ReplicatedStorage:WaitForChild("SystemMessage") :: RemoteEvent
const system = TextChatService:WaitForChild("TextChannels"):WaitForChild("RBXSystem") :: TextChannel

remote.OnClientEvent:Connect(function(message: string)
    system:DisplaySystemMessage(message)
end)

-- tell the server we are listening; anything sent before this is dropped
remote:FireServer()
