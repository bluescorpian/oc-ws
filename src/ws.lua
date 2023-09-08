local component = require('component');
local internet = component.getPrimary('internet');
local io = require("io");

---@class WebSocket
---@field address string
---@field port number
---@field path string
---@field key string
---@field readyState readyState
local WebSocket = {}

---@enum readyState
local READY_STATES = {
	CONNECTING = 0,
	OPEN = 1,
	CLOSING = 2,
	CLOSED = 3
}
WebSocket.READY_STATES = READY_STATES

---@enum opcode
local OPCODES = {
	CONTINUATION = 0x0,
	TEXT = 0x1,
	BINARY = 0x2,
	CLOSE = 0x8,
	PING = 0x9,
	PONG = 0xA
}

WebSocket.OPCODES = OPCODES

---@param address string
---@param port? number
---@param path? string
---@return WebSocket
function WebSocket:new(address, port, path)
	local socket = {}
	setmetatable(socket, self)
	self.__index = self;

	if not path then path = '/' end

	socket.address = address
	socket.port = port or 80
	socket.path = path
	socket.key = self.generateWebSocketKey()
	socket.readyState = 0

	return socket
end

function WebSocket:connect()
	self.connection = internet.connect(self.address, self.port)
	self.readyState = 0

	local connectionSuccess, connectionError = pcall(function() return self.connection:finishConnect() end)

	if not connectionSuccess then
		self:close()
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

	-- TODO: rewrite to use 1 byte at a time
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
		self:close()
		return false, 'Server doesn\'t support Websocket'
	end
	if (handshakeHeaders['sec-websocket-protocol'] ~= 'chat' and handshakeHeaders['sec-websocket-protocol'] ~= nil) then
		self:close()
		return false, 'Server doesn\'t support "chat" protocol'
	end

	return true, nil
	-- TODO: handle left over message
end

function WebSocket:send(message)
	if not self:isOpen() then return end

	local frame = self:createWebSocketFrame({ payload = message, opcode = OPCODES.TEXT })
	self.connection:write(frame)
end

function WebSocket:read()
	if not self:isOpen() then return end

	local websocketFrame = self:readWebSocketFrame()
	if websocketFrame.opcode == OPCODES.CLOSE then
		self:close()
	elseif websocketFrame.opcode == OPCODES.PING then
		self.connection:write(self:createWebSocketFrame({ opcode = OPCODES.PONG }))
	elseif websocketFrame.opcode == OPCODES.TEXT then
		return websocketFrame.payload
	end
end

function WebSocket:close()
	self.readyState = READY_STATES.CLOSING
	if self.connection then
		self.connection:write(self:createWebSocketFrame({ opcode = OPCODES.CLOSE }))
		self.connection:stop()
	end
	self.connection = nil
	self.readyState = READY_STATES.CLOSED
end

---@return boolean
function WebSocket:isOpen()
	return self.connection and self.readyState == READY_STATES.OPEN
end

function WebSocket:readWebSocketFrame()
	local frameHeader = self.connection:read(2)
	local frameHeaderBytes = { frameHeader:byte(1), frameHeader:byte(2) }
	-- TODO: handle connection closed

	-- get first bit, and last 4 bits
	local fin = frameHeaderBytes[1] & 0x80 == 0x80
	local opcode = frameHeaderBytes[1] & 0x0F

	local masked = frameHeaderBytes[2] & 0x80 == 0x80
	local payloadLength = frameHeaderBytes[2] & 0x7F

	if payloadLength == 126 then
		-- Extended payload length (16-bit)
		local extendedLength = socket:read(2)
		-- shifts first byte, a byte to the left and adds the second byte
		payloadLength = (extendedLength:byte(1) << 8) | extendedLength:byte(2)
	elseif payloadLength == 127 then
		-- Extended payload length (64-bit)
		local extendedLength = socket:read(8)
		-- Handle extremely large payloads
		payloadLength = 0
		for i = 1, 8 do
			payloadLength = (payloadLength << 8) | extendedLength:byte(i)
		end
	end

	if fin then
		local payload = nil
		if payloadLength then
			-- TODO: handle masked data
			payload = socket:read(payloadLength)
		end

		return {
			fin = fin,
			opcode = opcode,
			masked = masked,
			payloadLength = payloadLength,
			payload = payload
		}
	else
		-- TODO: handle fin bit
	end
end

---@return string
function WebSocket:createWebSocketFrame(frameOptions)
	local fin = true
	local opcode = 1
	local mask = false
	local payload = ""

	-- Check if frameOptions is provided and update variables accordingly
	if frameOptions then
		fin = frameOptions.fin ~= nil and frameOptions.fin or fin
		opcode = frameOptions.opcode ~= nil and frameOptions.opcode or opcode
		mask = frameOptions.mask ~= nil and frameOptions.mask or mask
		payload = frameOptions.payload or payload
	end

	local length = #message

	local frame = {}

	-- Creates 8 bit binary with first byte, the Fin bit (1 bit) set, RSV1-3 bits (3 bits) left empty, and Opcode (4 bits) added to the end
	frame[1] = fin and 0x80 or 0x00 | opcode

	local maskBit = mask and 0x80 or 0x00
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

	if mask then
		-- Masking key (4 bytes)
		local maskingKey = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
		for i = 1, 4 do
			frame[#frame + 1] = maskingKey[i]
		end

		-- Mask the message data
		for i = 1, length do
			local maskByte = maskingKey:byte((i - 1) % 4 + 1)
			frame[#frame + 1] = string.char(bit32.bxor(payload:byte(i), maskByte))
		end
	else
		for i = 1, length do
			frame[#frame + 1] = payload:sub(i, i)
		end
	end

	return string.char(table.unpack(frame))
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
