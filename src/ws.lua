local io = require("io");
local bit32 = require('bit32')
-- local bdebug = require('bdebug')

---@class WebSocket
---@field internet any
---@field address string
---@field port number
---@field path string
---@field key string
---@field readyState readyState
---@field private connection any
---@field private connectionCo thread
---@field private readMessageCo thread?
---@field private buffer string
---@field private messageBuffer string?
local WebSocket = {}
WebSocket.__index = WebSocket;

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

---@enum messageType
local MESSAGE_TYPES = {
	TEXT = 0,
	PING = 1,
	PONG = 2,
	CLOSE = 3
}
WebSocket.MESSAGE_TYPES = MESSAGE_TYPES

---@return WebSocket
function WebSocket.new(socketOptions)
	local socket = {}
	setmetatable(socket, WebSocket)
	assert(type(socketOptions.address) == 'string', 'socketOptions.address must be a string')
	socket.internet = socketOptions.internet or require('component').getPrimary('internet')
	assert(socket.internet.isTcpEnabled(), 'TCP must be enabled to use websocket')
	socket.address = socketOptions.address
	socket.port = socketOptions.port or 80
	socket.path = socketOptions.path or '/'
	socket.key = socket.generateWebSocketKey()
	socket.connection = socket.internet.connect(socket.address, socket.port)
	socket.readyState = READY_STATES.CONNECTING
	socket.connectionCo = coroutine.create(function() return socket:connectWebsocket() end)
	socket.buffer = ''

	return socket
end

function WebSocket:finishConnect()
	if self.readyState == READY_STATES.OPEN then return true end
	if self.connectionError then return nil, self.connectionError end
	if coroutine.status(self.connectionCo) ~= 'dead' then
		local success, connected, err = coroutine.resume(self.connectionCo)
		if not success then
			err = connected
			connected = nil
		end
		if err then
			self.connectionError = err
			return nil, err
		elseif type(connected) == 'boolean' then
			return connected
		end
	end
end

function WebSocket:send(message)
	if not self:isOpen() then return end

	local frame = self:createWebSocketFrame({ payload = message, opcode = OPCODES.TEXT })
	self.connection.write(frame)
end

function WebSocket:ping(data)
	return self.connection.write(self:createWebSocketFrame({ opcode = OPCODES.PING, payload = data }))
end

function WebSocket:pong(data)
	return self.connection.write(self:createWebSocketFrame({ opcode = OPCODES.PONG, payload = data }))
end

---@return messageType?, string?, string?
function WebSocket:readMessage()
	if not self.readMessageCo or coroutine.status(self.readMessageCo) == 'dead' then
		self.readMessageCo = coroutine.create(function()
			while true do
				local websocketFrame, err = self:readWebSocketFrame()
				if websocketFrame == nil then return nil, nil, err end
				if websocketFrame then
					if websocketFrame.opcode == OPCODES.TEXT then
						if websocketFrame.fin then
							coroutine.yield(MESSAGE_TYPES.TEXT, self.messageBuffer or websocketFrame.payload)
							self.messageBuffer = nil
						else
							self.messageBuffer = (self.messageBuffer or "") .. websocketFrame.payload
						end
					else
						self.messageBuffer = nil
						if websocketFrame.opcode == OPCODES.CLOSE then
							self:close()
							coroutine.yield(MESSAGE_TYPES.CLOSE)
						elseif websocketFrame.opcode == OPCODES.PING then
							coroutine.yield(MESSAGE_TYPES.PING, websocketFrame.payload)
						elseif websocketFrame.opcode == OPCODES.PONG then
							coroutine.yield(MESSAGE_TYPES.PONG, websocketFrame.payload)
						else
							error('Unsupported WebSocket opcode received: ' .. tostring(websocketFrame.opcode))
						end
					end
				end
			end
		end)
	end
	local success, messageType, message, err = coroutine.resume(self.readMessageCo)
	if not success then
		err = messageType
		messageType = nil
	end
	return messageType, message, err
end

function WebSocket:close()
	self.readyState = READY_STATES.CLOSING
	if self.connection then
		self.connection.write(self:createWebSocketFrame({ opcode = OPCODES.CLOSE }))
		self.connection.close()
	end
	self.readyState = READY_STATES.CLOSED
end

---@return boolean
function WebSocket:isOpen()
	return self.connection and self.readyState == READY_STATES.OPEN
end

---@private
function WebSocket:connectWebsocket()
	self.readyState = READY_STATES.CONNECTING

	local yieldable = coroutine.isyieldable()
	local connected = false
	repeat
		local c, connectionError = self.connection.finishConnect()
		connected = c
		if connectionError then return false, connectionError end
		if yieldable then coroutine.yield() end
	until connected

	local success, err = self:performHandshake()
	if success == true then
		self.readyState = READY_STATES.OPEN
	end
	return success, err
end

---@private
---@return boolean, string?
function WebSocket:performHandshake()
	-- Perform handshake
	local request = "GET " .. self.path .. " HTTP/1.1\r\n"
	request = request .. "Host: " .. self.address .. "\r\n"
	request = request .. "Upgrade: websocket\r\n"
	request = request .. "Connection: Upgrade\r\n"
	request = request .. "Sec-WebSocket-Key: " .. self.key .. "\r\n"
	-- request = request .. "Sec-WebSocket-Protocol: chat\r\n"
	request = request .. "Sec-WebSocket-Version: 13\r\n\r\n"

	local written, err = self.connection.write(request)
	if written == nil then return false, err end

	local handshakeResponse = ''
	while handshakeResponse:sub(-4) ~= '\r\n\r\n' do
		local data, err = self:read(1)
		if data == nil then return false, err end

		handshakeResponse = handshakeResponse .. data
	end

	local statusLine = true
	local handshakeHeaders = {}
	for line in handshakeResponse:gmatch("[^\r\n]+") do
		if statusLine then
			local statusCode = string.match(line, "HTTP/%d%.%d (%d%d%d)")
			print(line)
			print(statusCode)
			if (statusCode ~= '101') then
				return false, 'Wrong HTTP Code'
			end
			statusLine = false
		else
			local key, value = line:match("([^:]+):%s*([^%c]+)")
			if key and value then
				key = string.lower(key)
				value = string.lower(value)
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

	return true
end

---@return string?, string?
function WebSocket:read(n)
	local yieldable = coroutine.isyieldable()
	if self.buffer == nil then self.buffer = '' end

	while true do
		if n == nil then
			local buf = self.buffer
			self.buffer = ''
			return buf
		elseif #self.buffer >= n then
			local data = string.sub(self.buffer, 1, n)
			self.buffer = string.sub(self.buffer, n + 1)
			return data
		end

		local chunk, err = self.connection.read()

		if chunk == nil then
			self:close()
			return nil, err
		end

		self.buffer = self.buffer .. chunk

		if yieldable and chunk == '' then
			coroutine.yield()
		end
	end
end

function WebSocket:readWebSocketFrame()
	local frameHeader, err = self:read(2)
	if frameHeader == nil then return nil, err end
	local frameHeaderBytes = { frameHeader:byte(1), frameHeader:byte(2) }

	-- get first bit, and last 4 bits
	local fin = frameHeaderBytes[1] & 0x80 == 0x80
	local opcode = frameHeaderBytes[1] & 0x0F

	local masked = frameHeaderBytes[2] & 0x80 == 0x80
	local payloadLength = frameHeaderBytes[2] & 0x7F

	if payloadLength == 126 then
		-- Extended payload length (16-bit)
		local extendedLength = self:read(2)
		-- shifts first byte, a byte to the left and adds the second byte
		payloadLength = (extendedLength:byte(1) << 8) | extendedLength:byte(2)
	elseif payloadLength == 127 then
		-- Extended payload length (64-bit)
		local extendedLength = self:read(8)
		-- Handle extremely large payloads
		payloadLength = 0
		for i = 1, 8 do
			payloadLength = (payloadLength << 8) | extendedLength:byte(i)
		end
	end
	local payload = nil
	if payloadLength then
		-- TODO: handle masked data
		payload, err = self:read(payloadLength)
		if payload == nil then return nil, err end
	end

	return {
		fin = fin,
		opcode = opcode,
		masked = masked,
		payloadLength = payloadLength,
		payload = payload
	}
end

---@return string
function WebSocket:createWebSocketFrame(frameOptions)
	local fin = true
	local opcode = OPCODES.TEXT
	local mask = true
	local payload = ""

	-- Check if frameOptions is provided and update variables accordingly
	if frameOptions then
		fin = frameOptions.fin ~= nil and frameOptions.fin or fin
		opcode = frameOptions.opcode ~= nil and frameOptions.opcode or opcode
		mask = frameOptions.mask ~= nil and frameOptions.mask or mask
		payload = frameOptions.payload or payload
	end

	local length = #payload

	local frame = {}

	-- Creates 8 bit binary with first byte, the Fin bit (1 bit) set, RSV1-3 bits (3 bits) left empty, and Opcode (4 bits) added to the end
	frame[1] = (fin and 0x80 or 0x00) | opcode

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
			local maskByte = maskingKey[(i - 1) % 4 + 1]
			frame[#frame + 1] = bit32.bxor(payload:byte(i), maskByte)
		end
	else
		for i = 1, length do
			frame[#frame + 1] = string.byte(payload:sub(i, i))
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
