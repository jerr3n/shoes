--[[
etc.luau
things that do not belong in shoes' primary module or chunking module, but are still necessary


phase - changes something
info - take a guess
success, error, warn - ibid
]]
local Etc = {}
local LogLevel = table.freeze({
	Info = "info",
	Warn = "warn",
	Error = "error",
	Phase = "phase",
	Success = "success",
	Debug = "debug",
})

export type LogLevel = "info" | "warn" | "error" | "phase" | "success" | "debug"
export type Log = (level: LogLevel, message: string) -> ()
export type Sprint = (level: LogLevel, message: string, ...any) -> ()
export type Logger = { log: Log, sprint: Sprint }
Etc.LogLevel = LogLevel
return Etc
