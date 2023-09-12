local WebSocket = require('ws')

local socket = WebSocket:new({ address = 'localhost', port = 8080 })

local connectionSuccess, err = socket:connect()
if not connectionSuccess then
	print("Failed connecting to websocket: " .. err)
	return
end

while true do
	local startTime = os.time()
	local message = socket:readMessage()
	local endTime = os.time()

	local elapsedTime = endTime - startTime
	print("Time elapsed (seconds): " .. elapsedTime)

	if message ~= nil then
		print("Received message: " .. message)
	end
end
