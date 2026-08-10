-- TODO: make script.parent into serverscriptservice
const DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
const ServerScriptService = game:GetService("ServerScriptService")
const etc = require(script.Parent.etc) 
const Secure = DataStoreService:GetDataStore("SecureStore")
const session = require(script.Parent.session)
const logging = require(ServerScriptService.logging)
logging.log(logging.Output, "initalization starting")
logging.log(logging.Info, "phase 1 - ds setup")
local jobId = game.JobId
if jobId == "" then
	logging.log(logging.Info, "studio instance")
	jobId = string.format("STUDIO-%*-%*-%*", game.PlaceId, game.PlaceVersion, os.time())
end

-- something you may wanna know is that i used golang conventions (kinda)
local ok, err = pcall(function()
    Secure:SetAsync(jobId, os.time())
end)
if not ok then
    etc.safeguard(err)
    return
end
logging.log(logging.Info, "phase 1 complete - row set in ds")
logging.log(logging.Info, "phase 2 - http")
local ok, res = pcall(function()
    return HttpService:RequestAsync({
		Url = string.format("https://shoes.jerren.xyz/api/init/%s", jobId),
		Method = "GET",
	})
end)

if res.StatusCode == 418 then
    logging.log(logging.Warn, "418 from backend, backend logs will need to be reviewed")
end
if not ok then 
    etc.safeguard(res)
end
logging.log(logging.Output, "initalization success!")
session.start(jobId)