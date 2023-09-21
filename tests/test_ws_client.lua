package.loaded.bdebug = nil
local bdebug = require('bdebug')
local event = require('event')
package.loaded.ws = nil
local WebSocket = require('ws')

local ws = WebSocket.new({ address = '127.0.0.1', port = 8080 })

while true do
	local connected, err = ws:finishConnect()
	if connected then break end
	if err then return print('Failed to connect: ' .. err) end
	if event.pull(1) == 'interrupted' then return end
end

print('Succesfully connected')

ws:send('Hello from client!')

while true do
	local messageType, message, err = ws:readMessage()
	if err then return print('Websocket Error: ' .. err) end
	if messageType == WebSocket.MESSAGE_TYPES.TEXT then
		print('Message Received: ' .. message)
	elseif messageType == WebSocket.MESSAGE_TYPES.PING then
		print('Ping')
		ws:pong(message)
	elseif messageType == WebSocket.MESSAGE_TYPES.PONG then
		print('Pong')
	end

	if event.pull(5) == 'interrupted' then return end
end
