const logging = require(script.Parent.logging)
const Signal = require(game.ReplicatedStorage.Shared.Signal)
const DataStoreService = game:GetService("DataStoreService")
const Secure = DataStoreService:GetDataStore("SecureStore")
const HttpService = game:GetService("HttpService")
const ServerScriptService = game:GetService("ServerScriptService")
local session = require(script.Parent.session)
const chunking = require(script.Parent.chunking)

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
    logging.fracture(logging.Output, string.format("created\njobid: %s", self.jobId))
    return self
end

function Shoes:init()
    logging.log(logging.Output, "starting initalization")
    logging.log(logging.Info, "stage 1 -- datastore")
    local ok, err = pcall(function()
            Secure:SetAsync(self.jobId, os.time())
    end)
    if not ok then
        self.state = "fail"
        logging.fracture(logging.Error, err)
        return
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
        logging.fracture(logging.Error, res)
        if res.StatusCode == 418 then
            logging.fracture(logging.Warn, "418 recv.\nbackend logs will need to be checked")
        end
        return
    end
    logging.fracture(logging.Info, "stage 2 complete\nstage 3 -- extraction")
    local ok, res = pcall(function()
        Secure:GetAsync(self.jobId)
    end)
    if not ok then
        self.state = "fail"
        logging.fracture(logging.Error, res)
        return
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
        return
    end
    self.key = res
    logging.log(logging.Info, "stage 3 complete")
    self.state = "ready"
    logging.log(logging.Output, "initalization complete.") 
end

--[[
packet example:
---
packet 0 
first two header bytes: 00 (symbolizing its the first packet)
second two header bytes: xx (variable, how many packets in decimal in hex)
body (1012 bytes)
crc32 footer - 8 bytes
00ff..1012bytes..crc32
---
packet 1 and so on
first two header bytes: xx (variable, which packet its in in decimal converted to hex)
body (1014 bytes)
crc32 footer - 8 bytes
xx..1014bytes..crc32
]]

--[[
    Splits a payload into publishable packets. See chunking.luau for the frame.
]]
function Shoes:open()

end