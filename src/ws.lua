local component = require('component');
local internet = component.getPrimary('internet');
local io = require("io");

local WebSocket = {}

function WebSocket:new(address, port, path)
	local socket = {}
	setmetatable(socket, self)
	self.__index = self;

	if not path then path = '/' end

	socket.address = address
	socket.port = port
	socket.path = path
	socket.key = self.generateWebSocketKey()

	return socket
end

function WebSocket:connect()
	self.connection = internet.connect(self.address, self.port)
	self.readyState = 0

	local connectionSuccess, connectionError = pcall(function() return self.connection:finishConnect() end)

	if not connectionSuccess then
		self:stop()
		return false, connectionError
	end

	local request = "GET " .. self.path .. " HTTP/1.1\r\n"
	request = request .. "Host: " .. self.address .. "\r\n"
	request = request .. "Upgrade: websocket\r\n"
	request = request .. "Connection: Upgrade\r\n"
	request = request .. "Sec-WebSocket-Key: " .. self.key .. "\r\n"
	request = request .. "Sec-WebSocket-Protocol: chat\r\n"
	request = request .. "Sec-WebSocket-Version: 13\r\n\r\n"

	self.connection:write(request)

	local handshakeResponse = self.connection.read()

	local statusLine = true
	local handshakeHeaders = {}
	for line in handshakeResponse:gmatch("[^\r\n]+") do
		if statusLine then
			local statusCode = string.match(line, "HTTP/%d%.%d (%d%d%d)")
			if (statusCode ~= '101') then
				return false, 'Wrong HTTP Code'
			end
			statusLine = false
		else
			local key, value = line:match("([^:]+):%s*([^%c]+)")
			if key and value then
				key = key:trim():lower()
				value = value:trim():lower()
				handshakeHeaders[key] = value
			end
		end
	end

	if handshakeHeaders['upgrade'] ~= 'websocket' or handshakeHeaders['connection'] ~= 'upgrade' then
		self:stop()
		return false, 'Server doesn\'t support Websocket'
	end
	if (handshakeHeaders['sec-websocket-protocol'] ~= 'chat' and handshakeHeaders['sec-websocket-protocol'] ~= nil) then
		self:stop()
		return false, 'Server doesn\'t support "chat" protocol'
	end

	return true, nil
	-- TODO: handle left over message
end

function WebSocket:generateWebSocketFrame(message, opcode)
	local frame = {}

	-- Creates 8 bit binary with first byte, the Fin bit (1 bit) set, RSV1-3 bits (3 bits) left empty, and Opcode (4 bits) added to the end
	frame[1] = 0x80 | opcode

	local length = #message
	local masking = false
	local maskBit = 0x00
	if masking then
		maskBit = 0x80
	end

	if length <= 125 then
		-- Mask bit is 1 bit set with 7 unset, the length should only take 7 bits
		frame[2] = maskBit | length
	elseif length <= 0xFFFF then
		-- Adds the mask bit with 126, which indicates the next 2 bytes are the payload length
		frame[2] = maskBit | 126
		-- moves the length 8 bits to the right, cutting off the overflow, and then taking the first 8 bits
		frame[3] = (length >> 8) & 0xFF
		-- Takes the last 8 bits
		frame[4] = length & 0xFF
	else
		frame[2] = maskBit | 127
		for i = 1, 8 do
			frame[i + 2] = (length >> ((8 - i) * 8)) & 0xFF
		end
	end
end

function WebSocket:close()
	self.connection:stop()
	self.connection = nil
	self.readyState = 3
end

function WebSocket.generateWebSocketKey()
	local random = io.open("/dev/random", "rb");
	local randomBytes = random:read(16);
	random:close()
	local websocketKey = encode64(randomBytes)

	return websocketKey
end

local base64_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function encode64(data)
	return ((data:gsub('.', function(x)
		local r, b = '', x:byte()
		for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
		return r;
	end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
		if (#x < 6) then return '' end
		local c = 0
		for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
		return base64_chars:sub(c + 1, c + 1)
	end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

return WebSocket
