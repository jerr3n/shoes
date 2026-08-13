local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Konsole = require(ReplicatedStorage.Packages.Konsole)

local client = Konsole.create({
    input = { activationKeys = { Enum.KeyCode.Semicolon } },
})

client:bindRun(function(text)
    return Konsole.Dispatch.execute(text)
end)

local function refresh()
    client:setSuggestions(Konsole.Kommand.suggestions())
    client:setSchemas(Konsole.Kommand.schemas())
end

Konsole.Kommand.watch(refresh)
refresh()

client:show()