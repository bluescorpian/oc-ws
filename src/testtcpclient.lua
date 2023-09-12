local event = require('event')
local internet = require('component').getPrimary('internet')

local socket = internet.connect('localhost', 8080)

local connected = false
repeat
	local c, connectionError = socket:finishConnect()
	connected = c
	if connectionError then return print('Failed to connect: ' .. connectionError) end
until connected

-- socket.close()
-- print(socket.read())


-- while true do
-- 	local connected, err = socket:finishConnect()
-- 	print(string.format('Connected: %s Error: %s', connected, err))
-- 	local data = socket.read()
-- 	print('Data: ' .. tostring(data))
-- 	print('======')

-- 	-- if data == nil and not closed then
-- 	-- 	print('Socket closed')
-- 	-- 	closed = true
-- 	-- 	socket:close()
-- 	-- end

-- 	local id = event.pullMultiple('internet_ready', 'interrupted')
-- 	-- if not success then break end
-- 	print('Event: ' .. id)
-- 	if id == 'interrupted' then break end
-- end
