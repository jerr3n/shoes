-- if you are a luau-exclusive developer, you may not understand some of the conventions in this script.
-- that's alright. just know everything here is done for a reason.
const Signal = require(game.ReplicatedStorage.signal)
const DataStoreService = game:GetService("DataStoreService")
const Secure = DataStoreService:GetDataStore("SecureStore")
const HttpService = game:GetService("HttpService")
const MessagingService = game:GetService("MessagingService")
const chunk = require(script.Parent.chunk)
const etc = require(script.Parent.etc)
const BUFFER_TIMEOUT = 30                          -- seconds before a partial message is dropped

local Shoes = {}
Shoes.__index = Shoes
function Shoes.new(config, logger: etc.Logger)
    assert(type(config) == "table", "Socket.new expects a config table")
    assert(type(config.baseUrl) == "string", "config.baseUrl is required")

    local self = setmetatable({}, Shoes)
    self.logger = logger
    self.baseUrl = config.baseUrl:gsub("/+$", "")  -- strip trailing slash
    self.key = nil
    self.jobId = game.JobId
    if self.jobId == "" then
        self.jobId = string.format("STUDIO-%d-%d-%d", game.PlaceId, game.PlaceVersion, os.time())
    end
    self.state = "closed"                          -- closed | ready | opening | open | fail
    self.buffers = {}                              -- [msgId] = {chunks...}
    self.subscription = nil                        -- SubscribeAsync handle
    self.Message = Signal.new()
    self.Closed = Signal.new()
    self.Thread = nil
    -- logging.log
    logger.sprint(etc.LogLevel.Success, "created socket with jobid of %s", self.jobId)
    return self
end

function Shoes:init(): number
    self.logger.log(etc.LogLevel.Phase, "initialization starting...")
    self.logger.log(etc.LogLevel.Phase, "phase 1 - ds init")
    local ok, err = pcall(function()
            Secure:SetAsync(self.jobId, os.time())
    end)
    if not ok then
        self.state = "fail"
        self.logger.sprint(etc.LogLevel.Error, "phase 1 (datastore) failed: %s", tostring(err))
        return 1
    end
    self.logger.log(etc.LogLevel.Phase, "phase 2 - http init")
    local ok, res = pcall(function() 
        return HttpService:RequestAsync({
	    	Url = string.format("https://%s/init/%s", self.baseUrl ,self.jobId),
	    	Method = "GET",
    	})
    end)
    if not ok then
        self.state = "fail"
        self.logger.sprint(etc.LogLevel.Error, "phase 2 (http) failed: %s", tostring(res))
        return 1
    end
    if not res.Success then
        self.state = "fail"
        if res.StatusCode == 418 then
            self.logger.log(etc.LogLevel.Warn, "418 recv.\nbackend logs will need to be checked")
        end
        self.logger.sprint(
            etc.LogLevel.Error,
            "init failed: %d %s\n%s",
            res.StatusCode, res.StatusMessage, res.Body
        )
        return 1
    end
    self.logger.log(etc.LogLevel.Phase, "phase 3 - extraction")
    local ok, res = pcall(function()
        return Secure:GetAsync(self.jobId)
    end)
    if not ok then
        self.state = "fail"
        self.logger.sprint(etc.LogLevel.Error, "phase 3 (GetAsync) failed: %s", tostring(res))
        return 1
    end
    self.key = res
    local ok, res = pcall(function()
        return Secure:RemoveAsync(self.jobId)
    end)
    if not ok then
        -- TODO: this is really bad...
        -- TODO: maybe have backend generate a secret emergency api key?
        -- TODO: can send to /emergency/:id, would remove the key from sqlite.
    
        self.state = "fail"
        self.logger.sprint(etc.LogLevel.Error, "phase 3 (RemoveAsync) failed: %s", tostring(res))
        return 1
    end
    self.key = res
    self.logger.log(etc.LogLevel.Success, "phase 3 complete")
    self.state = "ready"
    self.logger.log(etc.LogLevel.Success, "initalization complete.")
    return 0
end

function Shoes:open(): number
    self.logger.log(etc.LogLevel.Phase, "opening socket...")

    if self.state ~= "ready" then
        self.logger.log(etc.LogLevel.Error, "socket is not ready. initialize it first.")
        self.state = "fail"
        return 1
    end
    self.state = "opening"
    local ok, res = pcall(function() 
        return HttpService:RequestAsync({
	    	Url = string.format("https://%s/open", self.baseUrl),
	    	Method = "GET",
            Headers = {
                ["X-API-Key"] = self.key
            }
    	})
    end)
    if not ok then 
        self.logger.sprint(etc.LogLevel.Error, "open request failed: %s", tostring(res))
        self.state = "fail"
        return 1;
    end
    self.Thread = task.spawn(function() 
        self.state = "open"
        local ok, err = pcall(function()
            self.subscription = MessagingService:SubscribeAsync(self.jobId, function(packet)
                if self.state ~= "open" then return end
                self:_receive(packet.Data)
            end)
        end)
        if not ok then 
            self.logger.sprint(etc.LogLevel.Error, "subscribe failed: %s", tostring(err))
            self.state = "fail"
            return 1;
        end
    end)
    self.logger.log(etc.LogLevel.Success, "socket is now open. enjoy your run!")
    return 0;
end
function Shoes:_sweep()
    local now = os.clock()
    for messageId, pending in self.buffers do
        if now - pending.stamp > BUFFER_TIMEOUT then
            self.buffers[messageId] = nil
            self.logger.sprint(
                etc.LogLevel.Warn,
                "dropped incomplete message %* (%*/%* frames)",
                chunk.formatMessageId(messageId), pending.count, pending.total
            )
        end
    end
end

-- Keyed by message ID, not crc: the crc only rides on the first frame, and that
-- frame may arrive last. total is unknown until it does.
function Shoes:_receive(frame: string)
    local parsed = chunk.parseFrame(frame, self.logger)
    if parsed == nil then
        return
    end
    local id = parsed.messageId

    local pending = self.buffers[id]
    if pending == nil then
        pending = { total = nil, crc = nil, flags = nil, count = 0, frames = {}, stamp = os.clock() }
        self.buffers[id] = pending
    end

    if parsed.total ~= nil then
        pending.total = parsed.total
        pending.crc = parsed.crc
        pending.flags = parsed.flags
    end

    -- A position past total would otherwise inflate count and complete the
    -- message with a real slot still empty.
    if pending.total ~= nil and parsed.position >= pending.total then
        self.logger.sprint(
            etc.LogLevel.Warn,
            "dropping frame at position %* on %*, total is %*",
            parsed.position, chunk.formatMessageId(id), pending.total
        )
        return
    end

    if pending.frames[parsed.position] ~= nil then
        self.logger.sprint(
            etc.LogLevel.Debug,
            "duplicate frame %* on %*", parsed.position, chunk.formatMessageId(id)
        )
        return
    end

    pending.frames[parsed.position] = parsed.payload
    pending.count += 1
    pending.stamp = os.clock()

    if pending.total == nil or pending.count < pending.total then
        self:_sweep()
        return
    end

    self.buffers[id] = nil

    local ordered = table.create(pending.total)
    for i = 0, pending.total - 1 do
        local payload = pending.frames[i]
        if payload == nil then
            self.logger.sprint(
                etc.LogLevel.Error,
                "missing frame at position %* on %*", i, chunk.formatMessageId(id)
            )
            return
        end
        table.insert(ordered, payload)
    end

    local message = chunk.assemble(ordered, pending.crc, pending.flags, self.logger)
    if message == nil then
        self.logger.sprint(etc.LogLevel.Error, "assemble failed on %*", chunk.formatMessageId(id))
        return
    end

    self.Message:Fire(message)
end
-- dont know dont care what that data is
function Shoes:send(data)
    local key = self.key
    local ok, res = pcall(function()
        return HttpService.RequestAsync({
        Url = string.format("https://%s/send", key),
        Method = "POST",
        Header = {
            ["API-Key"] = key
        },
        Body = tostring(data)
        })
    end)
    if not ok then 
        return 1
    end
    if not res.Success then
        return 1
    end
    return 0
end
function Shoes:close(reason: string?): number
    if self.state ~= "open" and self.state ~= "opening" then
        self.logger.log(etc.LogLevel.Debug, "socket is not open; nothing to close")
        return 1
    end

    self.state = "closed" 

    if self.subscription then
        local ok, err = pcall(function()
            self.subscription:Disconnect()
        end)
        if not ok then
            self.logger.sprint(etc.LogLevel.Error, "disconnect failed: %s", tostring(err))
        end
        self.subscription = nil
    end

    if self.Thread and coroutine.status(self.Thread) ~= "dead" then
        pcall(task.cancel, self.Thread)
    end
    self.Thread = nil

    table.clear(self.buffers)
    self.Closed:Fire(reason or "closed")
    self.logger.log(etc.LogLevel.Phase, "socket closed.")
    return 0
end

return Shoes