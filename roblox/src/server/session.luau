--!strict
local DataStoreService = game:GetService("DataStoreService")
const store = DataStoreService:GetDataStore("SecureStore")

local Session = {}
local key: string? = nil
local waiting: { thread } = {}
local started = false

function Session.await(): string
	if key then return key end
	table.insert(waiting, coroutine.running())
	return coroutine.yield()
end

function Session.start(jobId: string)
	if started then return end
	started = true

	task.spawn(function()
		local delay = 2
		for _ = 1, 8 do
			local ok, record = pcall(store.GetAsync, store, jobId)
			if ok and type(record) == "string" then -- unnecessary to count len, empty strings throw errors in ds
				key = record
				pcall(store.RemoveAsync, store, jobId)
				for _, thread in waiting do
					task.spawn(thread, key)
				end
				table.clear(waiting)
				return
			end
			task.wait(delay)
		end
		warn("session key bootstrap failed")
	end)
end

return Session