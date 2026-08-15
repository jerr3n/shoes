--!strict
--[[
	outputlog.luau -- ModuleScript, server-side (next to shoes.luau and etc.luau)

	Adapts the `etc.Logger` interface onto [LogService], i.e. the Output window.
	This is the old `Logging` module rewritten to the same shape as `lorilog`,
	so the two are interchangeable and can be combined with `LoriLog.fanout`.

	Usage:
		local outputlog = require(script.Parent.outputlog)
		local socket = Shoes.new(config, outputlog.logger("shoes"))

		-- or, both sinks at once:
		local socket = Shoes.new(config, lorilog.fanout(
			lorilog.logger("shoes"),
			outputlog.logger("shoes")
		))
]]

local LogService = game:GetService("LogService")

local etc = require(script.Parent.etc)

local OutputLog = {}

-- Unlike lorilog there is nothing to leak here: LogService output is only
-- visible to whoever is attached to the server. Left as a switch anyway so a
-- caller can mute a sink without unwiring it.
OutputLog.enabled = true

-- `etc.LogLevel` is a string union; the Output window only has four colours.
-- debug/phase go out as plain output, info is blue, and success has no
-- distinct rendering so it rides along with info.
local MESSAGE_TYPE: { [etc.LogLevel]: Enum.MessageType } = {
	debug = Enum.MessageType.MessageOutput,
	info = Enum.MessageType.MessageInfo,
	warn = Enum.MessageType.MessageWarning,
	error = Enum.MessageType.MessageError,
	phase = Enum.MessageType.MessageOutput,
	success = Enum.MessageType.MessageInfo,
}

-- Anchor to server start once, then advance with the monotonic clock.
-- `time()` alone only ticks per frame, so every line in a frame would share a
-- stamp and the microsecond digits would be dead weight.
local startGameTime = time()
local startClock = os.clock()

local function stamp(): string
	return string.format("[%12.6f]", startGameTime + (os.clock() - startClock))
end

--- Builds a Logger bound to `scope`, which replaces the old hardcoded
--- `[shoes]` prefix on every row. One per subsystem: "shoes", "chunk".
---
--- `fracture` is gone as a separate entry point -- every message is split on
--- newlines and logged a line at a time, since a multi-line message is
--- collapsed into one unreadable entry by the Output window otherwise. Each
--- line carries its own `dmesg`-style timestamp and the scope prefix.
function OutputLog.logger(scope: string): etc.Logger
	local prefix = `[{scope}]`

	local function log(level: etc.LogLevel, message: string)
		if not OutputLog.enabled then
			return
		end

		local messageType = MESSAGE_TYPE[level] or Enum.MessageType.MessageOutput
		local lines = tostring(message):gsub("\r\n", "\n"):split("\n")

		for _, line in lines do
			LogService:Log(messageType, string.format("%* %s %*", prefix, stamp(), line))
		end
	end

	local function sprint(level: etc.LogLevel, message: string, ...: any)
		if not OutputLog.enabled then
			return
		end
		-- A bad format spec should cost you one ugly log row, not the code path
		-- that was trying to log.
		local ok, formatted = pcall(string.format, message, ...)
		log(level, ok and formatted or `bad format: {message}`)
	end

	return { log = log, sprint = sprint }
end

return OutputLog
