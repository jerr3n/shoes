local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")
local Shoes = require(ServerScriptService.shoes)
local Logger = require(ServerScriptService.logging)
local cmds = TextChatService:WaitForChild("TextChatCommands")
local chatRemote = Instance.new("RemoteEvent")
local route = ""
local sock = nil
local ready = false
chatRemote.Name = "Message"
chatRemote.Parent = game.ReplicatedStorage

local stage = 1

local function escape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function broadcast(cfg): number
	local prefix = if cfg.clr ~= nil
		then string.format("<font color=\"#%s\">%s:</font>", cfg.clr, cfg.name)
		else string.format("%s:", cfg.name)
	chatRemote:FireAllClients(`{prefix} {escape(cfg.msg)}`)
	return #Players:GetPlayers()
end

local function makecmd(name: string)
	local newCommand = Instance.new('TextChatCommand')
	newCommand.Name = string.format("%scmd", name)
	newCommand.PrimaryAlias = string.format("/%s", name)
	newCommand.Parent = cmds
	return newCommand
end

local rx = coroutine.create(function()
	coroutine.yield() -- there is probably a better way tod o this
	sock.Message:Connect(function(message) 
		
	end)
end)
local tx = coroutine.create(function()
	coroutine.yield()
end)
local New = makecmd("new")
local Prime = makecmd("prime")

New.Triggered:Connect(function(textSource: TextSource, message: string)
	local player = Players:GetPlayerByUserId(textSource.UserId)
	if not player then return end
	local args = string.split(message, " ")
	table.remove(args, 1)
	route = args[1]
	broadcast({
		msg = string.format("Creating socket instance routing to %s", args[1]),
		name = "Sys",
	})
	sock = Shoes.new({baseUrl = route}, Logger.logger("shoes"))
end)
Prime.Triggered:Connect(function(textSource: TextSource, message: string)
	local player = Players:GetPlayerByUserId(textSource.UserId)
	if not player then return end
	local args = string.split(message, " ")
	table.remove(args, 1)
	route = args[1]
	broadcast({
		msg = "Priming proof of concept...",
		name = "Sys",
	})
	sock = Shoes.new({baseUrl = route}, Logger.logger("shoes"))
	sock:init()
	sock:open()
	coroutine.resume(rx)
	coroutine.resume(tx)
end)