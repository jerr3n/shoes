const logging = require(script.Parent.logging)
const Signal = require(game.ReplicatedStorage.Shared.Signal)
const DataStoreService = game:GetService("DataStoreService")
const Secure = DataStoreService:GetDataStore("SecureStore")
const HttpService = game:GetService("HttpService")
const MessagingService = game:GetService("MessagingService")
const ServerScriptService = game:GetService("ServerScriptService")
const chunk = require(script.Parent.chunk)

local Shoes = {}
Shoes.__index = Shoes

function Shoes.new(config)
    assert(type(config) == "table", "Socket.new expects a config table")
    assert(type(config.baseUrl) == "string", "config.baseUrl is required")

    local self = setmetatable({}, Shoes)

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
    logging.fracture(logging.Output, string.format("created\njobid: %s", self.jobId))
    return self
end

function Shoes:init(): number
    logging.log(logging.Output, "starting initalization")
    logging.log(logging.Info, "stage 1 -- datastore")
    local ok, err = pcall(function()
            Secure:SetAsync(self.jobId, os.time())
    end)
    if not ok then
        self.state = "fail"
        logging.fracture(logging.Error, err)
        return 1
    end
    logging.fracture(logging.Info, "stage 1 complete\nstage 2 -- http")
    local ok, res = pcall(function() 
        return HttpService:RequestAsync({
	    	Url = string.format("https://%s/api/init/%s", self.baseUrl ,self.jobId),
	    	Method = "GET",
    	})
    end)
    if not ok then
        self.state = "fail"
        logging.fracture(logging.Error, tostring(res))
        return 1
    end
    if not res.Success then
        self.state = "fail"
        if res.StatusCode == 418 then
            logging.fracture(logging.Warn, "418 recv.\nbackend logs will need to be checked")
        end
        logging.fracture(logging.Error, string.format(
            "init failed: %d %s\n%s",
            res.StatusCode, res.StatusMessage, res.Body
        ))
        return 1
    end
    logging.fracture(logging.Info, "stage 2 complete\nstage 3 -- extraction")
    local ok, res = pcall(function()
        Secure:GetAsync(self.jobId)
    end)
    if not ok then
        self.state = "fail"
        logging.fracture(logging.Error, res)
        return 1
    end
    self.key = res
    local ok, res = pcall(function()
        Secure:RemoveAsync(self.jobId)
    end)
    if not ok then
        -- TODO: this is really bad...
        -- TODO: maybe have backend generate a secret emergency api key?
        -- TODO: can send to /emergency/:id, would remove the key from sqlite.
    
        self.state = "fail"
        logging.fracture(logging.Error, res)
        return 1
    end
    self.key = res
    logging.log(logging.Info, "stage 3 complete")
    self.state = "ready"
    logging.log(logging.Output, "initalization complete.") 
    return 0
end

function Shoes:open(): number
    logging.log(logging.Output, "opening socket...")
    if self.state ~= "ready" then
        logging.log(logging.Error, "socket is not ready. initialize it first.")
        self.state = "fail"
        return 1
    end
    self.state = "opening"
    local ok, res = pcall(function() 
        return HttpService:RequestAsync({
	    	Url = string.format("https://%s/api/open", self.baseUrl),
	    	Method = "GET",
            Headers = {
                ["X-API-Key"] = self.key
            }
    	})
    end)
    if not ok then 
        logging.fracture(logging.Error, res)
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
            logging.fracture(logging.Error, err)
            self.state = "fail"
            return 1;
        end
    end)
    logging.log(logging.Output, "socket is now open. enjoy your run!")
    return 0;
end
function Shoes:_receive()

end
function Shoes:close(reason: string?): number
    if self.state ~= "open" and self.state ~= "opening" then
        logging.log(logging.Warn, "socket is not open; nothing to close")
        return 1
    end

    self.state = "closed" 

    if self.subscription then
        local ok, err = pcall(function()
            self.subscription:Disconnect()
        end)
        if not ok then
            logging.fracture(logging.Error, tostring(err))
        end
        self.subscription = nil
    end

    if self.Thread and coroutine.status(self.Thread) ~= "dead" then
        pcall(task.cancel, self.Thread)
    end
    self.Thread = nil

    table.clear(self.buffers)
    self.Closed:Fire(reason or "closed")
    logging.log(logging.Output, "socket closed.")
    return 0
end
