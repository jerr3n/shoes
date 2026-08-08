local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local logging = require(ServerScriptService.logging)
logging.log(Enum.MessageType.MessageInfo, "initalization starting")
const Secure = DataStoreService:GetDataStore("SecureStore") -- important
local _, err = pcall(function()
    Secure:SetAsync(game.JobId, os.time())
end)
if err ~= nil then
    logging.log(Enum.MessageType.MessageInfo, "engaging safeguard")
    local safeguard = Instance.new("Flag", ServerStorage)
    safeguard.Name = "SAFEGUARD"
else
    logging.log(Enum.MessageType.MessageInfo, "initalization success")
end
