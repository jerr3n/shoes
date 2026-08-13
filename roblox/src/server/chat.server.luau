local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = Instance.new("RemoteEvent")
remote.Name = "SystemMessage"
remote.Parent = ReplicatedStorage

local function broadcast(text: string)
	remote:FireAllClients(text)
end

broadcast('<font color="rgb(255,170,0)">[Server]</font>: example')