--!strict
--[[
	lorilog.client.luau -- LocalScript, StarterPlayer/StarterPlayerScripts

	Mounts a Lori client and renders whatever the server sends over the LoriLog
	RemoteEvent. One row per line: a message containing newlines becomes several
	rows, which is what `fracture` used to do by hand.

	Deliberately knows nothing about etc.luau or the socket -- the only contract
	with the server is the remote's name and a (level, scope, message) payload.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lori = require(ReplicatedStorage.Packages.Lori)

local REMOTE_NAME = "LoriLog"

type Row = (scope: string, line: string, duration: number?) -> ()

-- Keyed by plain string, not by a LogLevel union: the level arrives off a
-- remote, so it is a string until proven otherwise, and an indexer typed to the
-- union cannot be looked up with one. Values stay typed, keys do not.
local DURATION: { [string]: number } = {
	debug = 4,
	info = 6,
	phase = 6,
	success = 8,
	warn = 20,
	error = 30,
}

local lori = Lori.create()

lori:mount(nil, {
	studioOnly = false,
	maxItems = 14,
	anchor = "tr",
	template = Lori.Templates.Empty,
})

-- Lori's tones are trace/phase/success/warn/error -- there is no info or debug,
-- so both fall back to trace.
local function traceRow(scope: string, line: string, duration: number?)
	lori:trace(scope, line, nil, duration)
end

local EMIT: { [string]: Row } = {
	debug = traceRow,
	info = traceRow,
	phase = function(scope, line, duration)
		lori:phase(scope, line, nil, duration)
	end,
	success = function(scope, line, duration)
		lori:success(scope, line, nil, duration)
	end,
	warn = function(scope, line, duration)
		lori:warn(scope, line, nil, duration)
	end,
	error = function(scope, line, duration)
		lori:error(scope, line, nil, duration)
	end,
}

local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME) :: RemoteEvent

remote.OnClientEvent:Connect(function(level: unknown, scope: unknown, message: unknown)
	-- Remote payloads are untrusted even from your own server: a type mismatch
	-- here would otherwise error inside the overlay on every log line.
	if type(level) ~= "string" or type(scope) ~= "string" or type(message) ~= "string" then
		return
	end

	local emit = EMIT[level]
	local label = scope

	-- An unknown level (etc.luau gained one and this file did not) degrades to a
	-- trace row tagged with "?" rather than erroring.
	if emit == nil then
		emit = traceRow
		label = `{scope}?`
	end

	local duration = DURATION[level]

	-- gmatch over "[^\n]+" drops empty lines, so a trailing newline does not
	-- produce a blank row.
	for line in string.gmatch(message, "[^\n]+") do
		emit(label, line, duration)
	end
end)
