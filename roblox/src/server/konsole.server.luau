--!strict
--[[
	Server entry point for the socket. Wires Shoes up to a Lori-backed logger and
	exposes it over Konsole.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Konsole = require(ReplicatedStorage.Packages.Konsole)
local etc = require(script.Parent.etc)
local lorilog = require(script.Parent.logging)
local Shoes = require(script.Parent.shoes)

-- Built once and shared: the socket logs through it, and so does this file, so
-- handler output lands in the same overlay as the socket's own rows.
local logger = lorilog.logger("shoes")

local socket = Shoes.new({
	baseUrl = "itsalwaysthedns.jerren.xyz",
}, logger)

socket.Message:Connect(function(message)
	logger.sprint(etc.LogLevel.Debug, "recv: %s", message)
end)

socket.Closed:Connect(function(reason)
	logger.sprint(etc.LogLevel.Warn, "closed: %s", reason)
end)

Konsole.define({
	name = "socket",
	rank = 100,
	aliases = { "sock" },
	description = "Shows socket state.",
	server = "socketStatus",
})

Konsole.define({
	name = "init",
	rank = 100,
	description = "Runs the datastore/http handshake and extracts the key.",
	server = "socketInit",
	cooldown = 5,
})

Konsole.define({
	name = "open",
	rank = 100,
	description = "Subscribes to MessagingService and opens the socket.",
	server = "socketOpen",
	cooldown = 3,
})

Konsole.define({
	name = "close",
	rank = 100,
	description = "Closes the socket.",
	server = "socketClose",
	args = {
		{ name = "reason", type = "string", required = false, default = "closed via konsole" },
	},
})

Konsole.host({
	socketStatus = function(context)
		local pending, frames = 0, 0
		-- `partial` rather than `buffer`: that name shadows Luau's buffer library.
		for _, partial in socket.buffers do
			pending += 1
			frames += partial.count
		end

		return Konsole.Result.status("Socket", {
			{ Field = "State", Value = socket.state },
			{ Field = "JobId", Value = socket.jobId },
			{ Field = "BaseUrl", Value = socket.baseUrl },
			{ Field = "Key", Value = socket.key and "set" or "none" },
			{ Field = "Sub", Value = socket.subscription and "active" or "none" },
			{ Field = "Partials", Value = `{pending} msg / {frames} frames` },
		})
	end,

	socketInit = function(context)
		if socket.state == "ready" or socket.state == "open" then
			return context.err("busy", `already {socket.state}`)
		end

		logger.log(etc.LogLevel.Phase, "init requested via konsole")

		if socket:init() ~= 0 then
			return context.err("init-failed", "init failed -- see log rows")
		end

		return context.reply(`state: {socket.state}`)
	end,

	socketOpen = function(context)
		if socket.state ~= "ready" then
			return context.err("not-ready", `state is {socket.state}, run init first`)
		end

		logger.log(etc.LogLevel.Phase, "open requested via konsole")

		if socket:open() ~= 0 then
			return context.err("open-failed", "open failed -- see log rows")
		end

		return context.reply(`state: {socket.state}`)
	end,

	socketClose = function(context, reason)
		if socket:close(reason) ~= 0 then
			return context.err("not-open", `socket is {socket.state}`)
		end

		return context.reply("closed")
	end,
})
