local event = require('event')
local WebSocket = require('ws')

local socket = WebSocket:new({ address = 'localhost', port = 8080 })

while true do
	local connected, err = socket:finishConnect()
	if connected then break end
	if err then return print('Failed to connect: ' .. err) end
	if event.pullMultiple('internet_ready', 'interrupted') == 'interrupted' then return end
end

while true do
	local message, err = socket:readMessage()
	if err then return print('Websocket Error: ' .. err) end
	if message then print('Message Received: ' .. message) end

	if event.pullMultiple('internet_ready', 'interrupted') == 'interrupted' then return end
end
