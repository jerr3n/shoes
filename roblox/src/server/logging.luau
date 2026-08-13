--!strict
--[[
	lorilog.luau -- ModuleScript, server-side (next to shoes.luau and etc.luau)

	Adapts the `etc.Logger` interface onto Lori.

	Lori is a client overlay: it mounts a ScreenGui under PlayerGui, so a server
	script can never call it directly. This module hands the server something
	that satisfies `etc.Logger` and ships each line over a RemoteEvent; the
	companion client script renders it.

	Usage:
		local lorilog = require(script.Parent.lorilog)
		local socket = Shoes.new(config, lorilog.logger("shoes"))
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local etc = require(script.Parent.etc)

-- The client finds the RemoteEvent by this name, so the two files agree on the
-- string rather than on a shared module.
local REMOTE_NAME = "LoriLog"

local LoriLog = {}

-- Studio-only by default. FireAllClients would otherwise hand every player in a
-- live server your job IDs, backend status codes, and error strings. Flip this
-- deliberately, and only if you have gated it on something (a dev UserId list).
LoriLog.enabled = RunService:IsStudio()

local event: RemoteEvent? = nil

local function remote(): RemoteEvent
	if event then
		return event
	end

	local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if existing then
		event = existing :: RemoteEvent
		return existing :: RemoteEvent
	end

	local created = Instance.new("RemoteEvent")
	created.Name = REMOTE_NAME
	created.Parent = ReplicatedStorage
	event = created
	return created
end

--- Builds a Logger bound to `scope`, which becomes the left-hand label on every
--- Lori row. One per subsystem reads better than one global: "shoes", "chunk".
function LoriLog.logger(scope: string): etc.Logger
	assert(RunService:IsServer(), "lorilog is server-only")

	local target = remote()

	local function log(level: etc.LogLevel, message: string)
		if not LoriLog.enabled then
			return
		end
		target:FireAllClients(level, scope, message)
	end

	local function sprint(level: etc.LogLevel, message: string, ...: any)
		if not LoriLog.enabled then
			return
		end

		-- A bad format spec should cost you one ugly log row, not the code path
		-- that was trying to log.
		local ok, formatted = pcall(string.format, message, ...)
		log(level, ok and formatted or `bad format: {message}`)
	end

	return { log = log, sprint = sprint }
end

--- Wraps several loggers as one, so output can go to Lori and the Output window
--- at the same time. Handy while you still trust neither.
function LoriLog.fanout(...: etc.Logger): etc.Logger
	local targets = { ... }

	local function log(level: etc.LogLevel, message: string)
		for _, target in targets do
			target.log(level, message)
		end
	end

	local function sprint(level: etc.LogLevel, message: string, ...: any)
		local ok, formatted = pcall(string.format, message, ...)
		log(level, ok and formatted or `bad format: {message}`)
	end

	return { log = log, sprint = sprint }
end

return LoriLog
