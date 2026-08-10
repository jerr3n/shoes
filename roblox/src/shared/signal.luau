local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({listeners = {}}, Signal)
end

function Signal:Connect(fn)
    table.insert(self.listeners, fn)
    return {
        Disconnect = function()
            local i = table.find(self.listeners, fn)
            if i then table.remove(self.listeners, i) end
        end,
    }
end

function Signal:Fire(...)
    for _, fn in ipairs(table.clone(self.listeners)) do
        task.spawn(fn, ...)
    end
end

function Signal:DisconnectAll()
    self.listeners = {}
end

return Signal