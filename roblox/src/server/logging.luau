local LogService = game:GetService("LogService")

--[=[
	@class Logging

	Thin wrapper around [LogService] for prefixed and multi-line output.
]=]
local Logging = {}
--[=[
	Logs a single message, prefixed with `[shoes]`.

	Non-string values are stringified, so tables, numbers, and instances can be
	passed directly.

```lua
	Logging.log(Enum.MessageType.MessageWarning, "cache miss")
	-- [shoes] cache miss
```

	@param level Enum.MessageType -- Severity the message is logged at
	@param message any -- Value to log; stringified if not already a string
]=]
function Logging.log(level: Enum.MessageType, message: any)
    local str = string.format("[shoes] %*", message)
    LogService:Log(level, str)
end
--[=[
	Logs a multi-line message as one entry per line.

	A message containing newlines is collapsed into a single entry by the output
	window, which makes stack traces and serialized tables hard to read. This
	splits on newlines (normalizing CRLF first) and logs each line separately.

	Unlike [Logging.log], the `[shoes]` prefix is not applied.

	@param level Enum.MessageType -- Severity each line is logged at
	@param message any -- Value to log; stringified, then split on newlines
]=]
function Logging.fracture(level: Enum.MessageType, message: any) 
    local str = tostring(message)
    local lines = str:gsub("\r\n", "\n"):split("\n")
    for _, v in ipairs(lines) do
        LogService:Log(level, v)
    end
end

Logging.Error = Enum.MessageType.MessageError
Logging.Warn = Enum.MessageType.MessageWarning
Logging.Info = Enum.MessageType.MessageInfo
Logging.Output = Enum.MessageType.MessageOutput
return Logging