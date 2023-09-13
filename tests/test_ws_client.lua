local event = require('event')
package.loaded.ws = nil
local WebSocket = require('ws')

local socket = WebSocket.new({ address = '127.0.0.1', port = 8080 })

while true do
	print('Connection attempt')
	local connected, err = socket:finishConnect()
	if connected then break end
	if err then return print('Failed to connect: ' .. err) end
	if event.pull(0.1) == 'interrupted' then return end
end

print('Succesfully connected')

while true do
	local message, err = socket:readMessage()
	if err then return print('Websocket Error: ' .. err) end
	if message then print('Message Received: ' .. message) end

	if event.pull() == 'interrupted' then return end
end
