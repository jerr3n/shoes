const ServerScriptService = game:GetService("ServerScriptService")
const ServerStorage = game:GetService("ServerStorage")
const logging = require(ServerScriptService.logging)

local Etc = {}

function Etc.safeguard(reason: string?)
    logging.log(Enum.MessageType.MessageInfo, "engaging safeguard")
    if reason ~= nil then
        logging.fracture(Enum.MessageType.MessageError, reason)
    end
    local safeguard = Instance.new("Flag", ServerStorage)
    safeguard.Name = "SAFEGUARD"
end

return Etc