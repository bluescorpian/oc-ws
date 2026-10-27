-- oc-ws: a WebSocket (RFC 6455) client for OpenComputers.
-- https://github.com/bluescorpian/oc-ws (MIT License)
--
-- Needs Lua 5.3 (the OpenComputers default) and an internet card with TCP
-- enabled. wss:// additionally needs libtls13 and a tier 2 data card.

local ws = { _VERSION = "2.0.0-dev" }

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
-- How long to wait between polls when no internet_ready signal arrives. The
-- signal is not delivered reliably (OCEmu never sends it), so it only shortens
-- the wait.
local POLL_INTERVAL = 0.1
local MAX_HANDSHAKE_SIZE = 16384
local WOULD_BLOCK = {}

local OP = { CONTINUATION = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA }
local KIND = { [OP.TEXT] = "text", [OP.BINARY] = "binary" }

-- Everything oc-ws needs from OpenComputers, so it can run elsewhere (tests,
-- the conformance suite) by replacing these functions.
local platform = {}
ws.platform = platform

function platform.internet() return require("component").internet end
function platform.uptime() return require("computer").uptime() end
function platform.pull(timeout, name) return require("event").pull(timeout, name) end
function platform.listen(name, fn) return require("event").listen(name, fn) end
function platform.ignore(name, fn) return require("event").ignore(name, fn) end
function platform.timer(interval, fn) return require("event").timer(interval, fn, math.huge) end
function platform.cancel(id) return require("event").cancel(id) end
function platform.push(...) return require("computer").pushSignal(...) end
function platform.tls() return require("tls13") end
function platform.tlsProfile(tls) return tls.profiles.opencomputers end

function platform.random(n)
	local bytes = {}
	for i = 1, n do bytes[i] = math.random(0, 255) end
	return string.char(table.unpack(bytes))
end

-- Sleeps until data may have arrived, at most POLL_INTERVAL and never past
-- the deadline.
local function wait(deadline)
	local t = POLL_INTERVAL
	if deadline then t = math.max(0, math.min(t, deadline - platform.uptime())) end
	platform.pull(t, "internet_ready")
end

---------------------------------------------------------------------------
-- Encoding helpers

local function sha1(msg)
	local M = 0xFFFFFFFF
	local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
	local bits = #msg * 8
	msg = msg .. "\128" .. ("\0"):rep((55 - #msg) % 64) .. string.pack(">I8", bits)
	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do w[i] = string.unpack(">I4", msg, chunk + i * 4) end
		for i = 16, 79 do
			local x = w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16]
			w[i] = ((x << 1) | (x >> 31)) & M
		end
		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f, k = (b & c) | (~b & d), 0x5A827999
			elseif i < 40 then
				f, k = b ~ c ~ d, 0x6ED9EBA1
			elseif i < 60 then
				f, k = (b & c) | (b & d) | (c & d), 0x8F1BBCDC
			else
				f, k = b ~ c ~ d, 0xCA62C1D6
			end
			local t = (((a << 5) | (a >> 27)) + f + e + k + w[i]) & M
			e, d, c, b, a = d, c, ((b << 30) | (b >> 2)) & M, a, t
		end
		h0, h1, h2, h3, h4 = (h0 + a) & M, (h1 + b) & M, (h2 + c) & M, (h3 + d) & M, (h4 + e) & M
	end
	return string.pack(">I4I4I4I4I4", h0, h1, h2, h3, h4)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = (a << 16) | ((b or 0) << 8) | (c or 0)
		local q = {}
		for j = 1, 4 do
			local idx = (n >> (24 - j * 6)) & 0x3F
			q[j] = B64:sub(idx + 1, idx + 1)
		end
		if not b then q[3] = "=" end
		if not c then q[4] = "=" end
		out[#out + 1] = table.concat(q)
	end
	return table.concat(out)
end

local function validUtf8(s)
	if not utf8.len(s) then return false end
	-- utf8.len in Lua 5.3 still accepts surrogates and code points past U+10FFFF.
	return not (s:find("\xED[\xA0-\xBF]") or s:find("\xF4[\x90-\xBF]") or s:find("[\xF5-\xFF]"))
end

local function validCloseCode(code)
	return (code >= 1000 and code <= 1003) or (code >= 1007 and code <= 1014)
		or (code >= 3000 and code <= 4999)
end

-- Masks in 1 KiB blocks: building one Lua value per byte runs low-tier
-- computers out of memory on payloads of a few tens of kilobytes.
local MASK_WORDS = 256
local MASK_BLOCK_FMT = ">" .. ("I4"):rep(MASK_WORDS)

local function mask(payload, key)
	local k = string.unpack(">I4", key)
	local n, i, out = #payload, 1, {}
	while i + MASK_WORDS * 4 - 1 <= n do
		local words = { string.unpack(MASK_BLOCK_FMT, payload, i) }
		for j = 1, MASK_WORDS do words[j] = words[j] ~ k end
		out[#out + 1] = string.pack(MASK_BLOCK_FMT, table.unpack(words, 1, MASK_WORDS))
		i = i + MASK_WORDS * 4
	end
	while i + 3 <= n do
		out[#out + 1] = string.pack(">I4", string.unpack(">I4", payload, i) ~ k)
		i = i + 4
	end
	local j = 1
	while i <= n do
		out[#out + 1] = string.char(payload:byte(i) ~ key:byte(j))
		i, j = i + 1, j + 1
	end
	return table.concat(out)
end

local function encodeFrame(opcode, payload)
	local len = #payload
	local header
	if len < 126 then
		header = string.pack(">BB", 0x80 | opcode, 0x80 | len)
	elseif len < 0x10000 then
		header = string.pack(">BBI2", 0x80 | opcode, 0x80 | 126, len)
	else
		header = string.pack(">BBI8", 0x80 | opcode, 0x80 | 127, len)
	end
	local key = platform.random(4)
	return header .. key .. mask(payload, key)
end

local function parseUrl(url)
	local scheme, rest = url:match("^([wW][sS][sS]?)://(.+)$")
	if not scheme then return nil, "URL must start with ws:// or wss://" end
	local secure = #scheme == 3
	local authority, path = rest:match("^([^/?#]+)(.*)$")
	if not authority or authority:find("@", 1, true) then return nil, "URL has no valid host" end
	path = path:gsub("#.*$", "")
	if path:sub(1, 1) ~= "/" then path = "/" .. path end
	local host, port = authority:match("^%[(.+)%]:?(%d*)$")
	if not host then host, port = authority:match("^([^:]+):?(%d*)$") end
	if not host then return nil, "URL has no valid host" end
	local defaultPort = secure and 443 or 80
	port = tonumber(port) or defaultPort
	local hostHeader = host:find(":", 1, true) and "[" .. host .. "]" or host
	if port ~= defaultPort then hostHeader = hostHeader .. ":" .. port end
	return { secure = secure, host = host, port = port, path = path, hostHeader = hostHeader }
end

---------------------------------------------------------------------------
-- Transports: a plain TCP socket, or one wrapped in TLS. Both expose
-- read() -> chunk | "" (nothing yet) | nil, err, write(data) -> bytes | nil, err,
-- and close().

local function tcpTransport(sock)
	local t = {}
	function t.read()
		local ok, chunk, err = pcall(sock.read)
		if not ok then return nil, tostring(chunk) end
		if chunk == nil then return nil, err or "connection closed" end
		return chunk
	end
	function t.write(data)
		local ok, n, err = pcall(sock.write, data)
		if not ok then return nil, tostring(n) end
		if n == nil then return nil, err or "connection closed" end
		return n
	end
	function t.close() pcall(sock.close) end
	return t
end

local function hex(s)
	return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

local function isIpLiteral(host)
	return host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true)
end

-- libtls13 does blocking reads. During the handshake they wait for data; after
-- it, they run in a coroutine that yields whenever the socket has nothing, so
-- the connection's reads stay non-blocking.
local function tlsTransport(conn, sock, u, tlsOpts, deadline)
	local okLoad, tls = pcall(platform.tls)
	if not okLoad then
		return nil, "wss:// needs libtls13 (oppm install libtls13): " .. tostring(tls)
	end

	local yielding = false
	local raw = {}
	function raw.read(_, n)
		while true do
			local ok, chunk, err = pcall(sock.read, n)
			if not ok then return nil, tostring(chunk) end
			if chunk == nil then return nil, err or "connection closed" end
			if chunk ~= "" then return chunk end
			if yielding then
				coroutine.yield(WOULD_BLOCK)
			else
				if platform.uptime() >= deadline then return nil, "TLS handshake timed out" end
				wait(deadline)
			end
		end
	end
	function raw.write(_, data)
		while true do
			local ok, n, err = pcall(sock.write, data)
			if not ok then return nil, tostring(n) end
			if n == nil then return nil, err or "connection closed" end
			if n > 0 then return n end
			platform.pull(POLL_INTERVAL, "internet_ready")
		end
	end
	function raw.close() pcall(sock.close) end

	-- Record the server's public key as the handshake verifies its signature,
	-- so it can be compared against a pinned fingerprint.
	local base = platform.tlsProfile(tls)
	local serverKey
	local profile = setmetatable({}, { __index = base })
	function profile.signatureAlgorithms()
		local algs = base.signatureAlgorithms()
		for i, alg in ipairs(algs) do
			algs[i] = setmetatable({
				decodePublicKey = function(self, pkInfo)
					serverKey = pkInfo.subjectPublicKey:toBytes()
					return alg.decodePublicKey(self, pkInfo)
				end,
			}, { __index = alg })
		end
		return algs
	end

	local stream, err = tls.wrapRaw(raw, profile, {
		serverName = not isIpLiteral(u.host) and u.host or nil,
		alpnProtocol = "http/1.1",
	})
	if not stream then
		raw.close()
		return nil, "TLS handshake failed: " .. tostring(err)
	end

	local fingerprint = serverKey and hex(require("tls13.crypto.hash.sha2").sha256():update(serverKey):finish())
	conn.fingerprint = fingerprint
	local pin = tlsOpts.fingerprint
	if pin and pin:lower():gsub("[^%x]", "") ~= fingerprint then
		raw.close()
		return nil, ("server key fingerprint %s does not match the pinned one"):format(tostring(fingerprint))
	end

	local reader = coroutine.create(function()
		while true do
			local data, readErr = stream:read()
			if not data then return nil, tostring(readErr) end
			coroutine.yield(data)
		end
	end)

	local t = {}
	function t.read()
		yielding = true
		local ok, data, readErr = coroutine.resume(reader)
		yielding = false
		if not ok then return nil, tostring(data) end
		if data == WOULD_BLOCK then return "" end
		if data == nil then return nil, readErr or "connection closed" end
		return data
	end
	function t.write(data)
		local n, writeErr = stream:write(data)
		if not n then return nil, tostring(writeErr) end
		return n
	end
	function t.close() pcall(stream.close, stream) end
	return t
end

---------------------------------------------------------------------------
-- Connection

local Connection = {}
Connection.__index = Connection

local function newConnection(opts)
	return setmetatable({
		state = "connecting",
		maxMessageSize = opts.maxMessageSize or 1024 * 1024,
		closeTimeout = opts.closeTimeout or 3,
		inbuf = "",
		inpos = 1,
		outq = "",
		queue = {},
	}, Connection)
end

function Connection:flush()
	while #self.outq > 0 do
		local n, err = self.transport.write(self.outq)
		if not n then return self:lost(err) end
		if n == 0 then return end
		self.outq = self.outq:sub(n + 1)
	end
end

function Connection:flushAll(deadline)
	self:flush()
	while #self.outq > 0 and self.state ~= "closed" do
		if deadline and platform.uptime() >= deadline then return nil, "send timed out" end
		wait(deadline)
		self:flush()
	end
	if self.state == "closed" then return nil, "connection closed" end
	return true
end

function Connection:closeTransport()
	if self.transport then self.transport.close() end
	self.state = "closed"
	self.outq = ""
	self:stopListening()
end

-- The TCP connection ended. Whether that was clean depends on whether the
-- closing handshake had already finished.
function Connection:lost(err)
	if self.state ~= "closed" then
		if not self.closeCode then
			self.closeCode, self.closeReason = 1006, err or "connection lost"
		end
		self:closeTransport()
		self:deliverClose()
	end
end

-- Fail the connection (RFC 6455 section 7.1.7) after a protocol violation.
function Connection:fail(code, reason)
	if self.state == "open" then
		self.outq = self.outq .. encodeFrame(OP.CLOSE, string.pack(">I2", code))
		self:flush()
	end
	self.closeCode, self.closeReason = code, reason
	self:closeTransport()
	self:deliverClose()
end

function Connection:deliver(data, kind)
	if self.listening then
		platform.push("websocket_message", self.id, data, kind)
	else
		self.queue[#self.queue + 1] = { data, kind }
	end
end

function Connection:deliverClose()
	if self.listening or self.wasListening then
		platform.push("websocket_closed", self.id, self.closeCode, self.closeReason)
	end
end

function Connection:handleClose(payload)
	local code, reason = 1005, ""
	if #payload == 1 then return self:fail(1002, "close frame with a 1-byte payload") end
	if #payload >= 2 then
		code = string.unpack(">I2", payload)
		reason = payload:sub(3)
		if not validCloseCode(code) then return self:fail(1002, "invalid close code " .. code) end
		if not validUtf8(reason) then return self:fail(1007, "close reason is not valid UTF-8") end
	end
	if self.state == "open" then
		-- Server started the close: echo its code, then end the connection.
		self.outq = self.outq .. encodeFrame(OP.CLOSE, code == 1005 and "" or string.pack(">I2", code))
		self:flush()
	end
	self.closeCode, self.closeReason = code, reason
	self:closeTransport()
	self:deliverClose()
end

-- Handles one complete frame. Returns false once the connection has ended.
function Connection:handleFrame(fin, opcode, payload)
	if opcode >= 0x8 then
		if opcode == OP.CLOSE then
			self:handleClose(payload)
		elseif opcode == OP.PING then
			if self.state == "open" then
				self.outq = self.outq .. encodeFrame(OP.PONG, payload)
				self:flush()
			end
		elseif self.onPong then
			self.onPong(payload)
		end
	elseif self.state ~= "open" then
		return true -- data after we sent a close frame is discarded
	elseif opcode == OP.CONTINUATION then
		if not self.fragOpcode then return self:fail(1002, "continuation frame with nothing to continue") end
		self.fragments[#self.fragments + 1] = payload
		self.fragSize = self.fragSize + #payload
		if self.fragSize > self.maxMessageSize then return self:fail(1009, "message too big") end
		if fin then
			local data, kind = table.concat(self.fragments), KIND[self.fragOpcode]
			self.fragOpcode, self.fragments = nil, nil
			if kind == "text" and not validUtf8(data) then return self:fail(1007, "text message is not valid UTF-8") end
			self:deliver(data, kind)
		end
	else
		if self.fragOpcode then return self:fail(1002, "new message started inside a fragmented one") end
		if fin then
			if opcode == OP.TEXT and not validUtf8(payload) then
				return self:fail(1007, "text message is not valid UTF-8")
			end
			self:deliver(payload, KIND[opcode])
		else
			self.fragOpcode, self.fragments, self.fragSize = opcode, { payload }, #payload
		end
	end
	return self.state ~= "closed"
end

-- Parses complete frames from the input buffer. Outside listen mode it stops
-- after each message so the program sees (and can answer) it before a later
-- frame fails the connection. Returns true when frames may be left unparsed.
function Connection:processFrames()
	while self.state ~= "closed" do
		if #self.queue > 0 and not self.listening then return true end
		local buf, pos = self.inbuf, self.inpos
		local avail = #buf - pos + 1
		if avail < 2 then break end
		local b1, b2 = buf:byte(pos, pos + 1)
		local fin, rsv, opcode = b1 & 0x80 ~= 0, b1 & 0x70, b1 & 0x0F
		local len, headerLen = b2 & 0x7F, 2

		if rsv ~= 0 then return self:fail(1002, "reserved bits set without an extension") end
		if b2 & 0x80 ~= 0 then return self:fail(1002, "server sent a masked frame") end
		if not (opcode <= OP.BINARY or (opcode >= OP.CLOSE and opcode <= OP.PONG)) then
			return self:fail(1002, "unknown opcode " .. opcode)
		end
		if opcode >= 0x8 and (not fin or len > 125) then
			return self:fail(1002, "control frames must be unfragmented and at most 125 bytes")
		end

		if len == 126 then
			if avail < 4 then break end
			len, headerLen = string.unpack(">I2", buf, pos + 2), 4
		elseif len == 127 then
			if avail < 10 then break end
			len, headerLen = string.unpack(">i8", buf, pos + 2), 10
			if len < 0 then return self:fail(1002, "frame length has its top bit set") end
		end
		if len > self.maxMessageSize then return self:fail(1009, "message too big") end
		if avail < headerLen + len then break end

		local payload = buf:sub(pos + headerLen, pos + headerLen + len - 1)
		self.inpos = pos + headerLen + len
		if not self:handleFrame(fin, opcode, payload) then return end
	end
	if self.inpos > #self.inbuf then
		self.inbuf, self.inpos = "", 1
	elseif self.inpos > 65536 then
		self.inbuf, self.inpos = self.inbuf:sub(self.inpos), 1
	end
end

-- Reads whatever has arrived on the socket. Returns false and the reason once
-- the socket has reached end of stream or failed; the caller handles the frames
-- that arrived before that and then calls lost().
function Connection:readAvailable()
	while true do
		local chunk, err = self.transport.read()
		if chunk == nil then return false, err end
		if chunk == "" then return true end
		self.inbuf = self.inbuf .. chunk
	end
end

function Connection:step()
	self:flush()
	if self.state ~= "closed" and not self.eof then
		local alive, err = self:readAvailable()
		if not alive then self.eof = err or "connection closed" end
	end
	if self.state ~= "closed" then
		local more = self:processFrames()
		if self.eof and not more then self:lost(self.eof) end
	end
	if self.state == "closing" and platform.uptime() >= self.closeDeadline then
		self:closeTransport()
		self:deliverClose()
	end
end

-- Moves the connection forward without blocking: sends what is queued, reads
-- what has arrived, and handles complete frames.
function Connection:pump()
	if self.state == "closed" or self.pumping then return end
	self.pumping = true
	local ok, err = pcall(self.step, self)
	self.pumping = false
	if not ok then error(err, 0) end
end

---Sends a message. Text is the default; pass `true` as the second argument
---to send binary data.
---@param data string
---@param binary? boolean
---@return true|nil ok, string? err
function Connection:send(data, binary)
	assert(type(data) == "string", "data must be a string")
	if self.state ~= "open" then return nil, "connection is not open" end
	self.outq = self.outq .. encodeFrame(binary and OP.BINARY or OP.TEXT, data)
	return self:flushAll(platform.uptime() + (self.sendTimeout or 10))
end

---Sends a ping. Pongs from the server go to the `onPong` option.
---@param data? string at most 125 bytes
function Connection:ping(data)
	data = data or ""
	assert(#data <= 125, "ping payload must be at most 125 bytes")
	if self.state ~= "open" then return nil, "connection is not open" end
	self.outq = self.outq .. encodeFrame(OP.PING, data)
	return self:flushAll(platform.uptime() + (self.sendTimeout or 10))
end

---Waits for the next message.
---Returns `data, kind` (kind is "text" or "binary"), `nil, "timeout"`, or
---`nil, "closed", code, reason` once the connection has ended.
---@param timeout? number seconds; nil waits forever, 0 only checks
function Connection:receive(timeout)
	assert(not self.listening, "receive cannot be used while the connection is listening")
	local deadline = timeout and platform.uptime() + timeout
	while true do
		self:pump()
		local msg = table.remove(self.queue, 1)
		if msg then return msg[1], msg[2] end
		if self.state == "closed" then return nil, "closed", self.closeCode, self.closeReason end
		if deadline and platform.uptime() >= deadline then return nil, "timeout" end
		wait(deadline)
	end
end

---Returns the next message if one has arrived, without waiting.
function Connection:poll()
	return self:receive(0)
end

---Starts the closing handshake and waits (up to the closeTimeout option) for
---the server to finish it.
---@param code? integer defaults to 1000 (normal closure)
---@param reason? string at most 123 bytes
function Connection:close(code, reason)
	code, reason = code or 1000, reason or ""
	assert(validCloseCode(code), "invalid close code")
	assert(#reason <= 123, "close reason must be at most 123 bytes")
	if self.state == "open" then
		self.state = "closing"
		self.closeDeadline = platform.uptime() + self.closeTimeout
		-- Replaced by the server's code when it answers.
		self.closeCode, self.closeReason = code, reason
		self.outq = self.outq .. encodeFrame(OP.CLOSE, string.pack(">I2", code) .. reason)
		while self.state ~= "closed" do
			self:pump()
			if self.state ~= "closed" then wait(self.closeDeadline) end
		end
	elseif self.state ~= "closed" then
		self:closeTransport()
	end
	return true
end

function Connection:isOpen()
	return self.state == "open"
end

---Hands incoming messages to the OpenOS event system instead of `receive`:
---  websocket_message, id, data, kind
---  websocket_closed,  id, code, reason
---`id` is the connection's `id` field.
function Connection:listen()
	if self.listening or self.state == "closed" then return end
	self.listening, self.wasListening = true, true
	for _, msg in ipairs(self.queue) do platform.push("websocket_message", self.id, msg[1], msg[2]) end
	self.queue = {}
	self.readyHandler = function(_, _, sockId)
		if sockId == nil or sockId == self.sockId then self:pump() end
	end
	platform.listen("internet_ready", self.readyHandler)
	self.timerId = platform.timer(POLL_INTERVAL, function() self:pump() end)
	self:pump()
end

function Connection:stopListening()
	if not self.listening then return end
	self.listening = false
	platform.ignore("internet_ready", self.readyHandler)
	platform.cancel(self.timerId)
end

---------------------------------------------------------------------------
-- Opening handshake

local function parseResponse(head, key, protocols)
	local status = head:match("^HTTP/%d%.%d (%d%d%d)")
	if status ~= "101" then
		return nil, "server answered " .. (head:match("^([^\r\n]*)") or "nothing") .. " instead of 101"
	end
	local headers = {}
	for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
		name, value = name:lower(), value:match("^(.-)%s*$")
		headers[name] = headers[name] and headers[name] .. ", " .. value or value
	end
	local function hasToken(value, token)
		for t in (value or ""):gmatch("[^,%s]+") do
			if t:lower() == token then return true end
		end
		return false
	end
	if not hasToken(headers["upgrade"], "websocket") then return nil, "response is missing Upgrade: websocket" end
	if not hasToken(headers["connection"], "upgrade") then return nil, "response is missing Connection: Upgrade" end
	if headers["sec-websocket-accept"] ~= base64(sha1(key .. GUID)) then
		return nil, "server sent a wrong Sec-WebSocket-Accept"
	end
	if headers["sec-websocket-extensions"] then return nil, "server enabled an extension that was not offered" end
	local protocol = headers["sec-websocket-protocol"]
	if protocol then
		local offered = false
		for _, p in ipairs(protocols or {}) do offered = offered or p == protocol end
		if not offered then return nil, "server chose subprotocol " .. protocol .. " that was not offered" end
	end
	return headers, protocol
end

---Opens a WebSocket connection and waits until it is ready.
---Options:
---  timeout        seconds for connecting and the handshake (default 10)
---  headers        table of extra request headers, e.g. Authorization
---  protocols      list of subprotocols to offer; the chosen one ends up in conn.protocol
---  maxMessageSize largest message accepted, in bytes (default 1 MiB)
---  closeTimeout   seconds close() waits for the server (default 3)
---  sendTimeout    seconds send() waits for a full socket buffer (default 10)
---  onPong         function(payload) called for each pong
---  internet       internet card proxy (default: the primary one)
---  tls            for wss://: { fingerprint = "<sha256 of the server's public key, hex>" }
---@param url string ws://host[:port][/path] or wss://...
---@param opts? table
---@return table|nil connection, string? err
function ws.connect(url, opts)
	opts = opts or {}
	local u, err = parseUrl(url)
	if not u then return nil, err end
	local deadline = platform.uptime() + (opts.timeout or 10)

	local inet = opts.internet or platform.internet()
	if not inet then return nil, "no internet card" end
	local ok, sock, connectErr = pcall(inet.connect, u.host, u.port)
	if not ok then return nil, tostring(sock) end
	if not sock then return nil, connectErr or "could not open a TCP connection" end

	local conn = newConnection(opts)
	conn.onPong, conn.sendTimeout, conn.url = opts.onPong, opts.sendTimeout, url
	conn.sockId = sock.id and sock.id()
	conn.id = conn.sockId or tostring(conn):match("0x%x+") or tostring(conn)

	local function abort(msg)
		pcall(sock.close)
		conn.state = "closed"
		return nil, msg
	end

	while true do
		local fok, done, ferr = pcall(sock.finishConnect)
		if not fok then return abort(tostring(done)) end
		if done then break end
		if ferr then return abort(ferr) end
		if platform.uptime() >= deadline then return abort("connection timed out") end
		wait(deadline)
	end

	if u.secure then
		local transport, terr = tlsTransport(conn, sock, u, opts.tls or {}, deadline)
		if not transport then return abort(terr) end
		conn.transport = transport
	else
		conn.transport = tcpTransport(sock)
	end

	local key = base64(platform.random(16))
	local request = {
		"GET " .. u.path .. " HTTP/1.1",
		"Host: " .. u.hostHeader,
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Key: " .. key,
		"Sec-WebSocket-Version: 13",
	}
	if opts.protocols and #opts.protocols > 0 then
		request[#request + 1] = "Sec-WebSocket-Protocol: " .. table.concat(opts.protocols, ", ")
	end
	for name, value in pairs(opts.headers or {}) do
		request[#request + 1] = name .. ": " .. value
	end
	conn.outq = table.concat(request, "\r\n") .. "\r\n\r\n"
	local sent, sendErr = conn:flushAll(deadline)
	if not sent then
		conn:closeTransport()
		return nil, sendErr
	end

	local headEnd
	while true do
		local alive, readErr = conn:readAvailable()
		headEnd = conn.inbuf:find("\r\n\r\n", 1, true)
		if headEnd then
			-- Frames that came with the response are handled once open; a
			-- closed socket shows up on the first pump.
			break
		end
		if not alive then
			conn:closeTransport()
			return nil, "connection closed during the handshake: " .. tostring(readErr or "end of stream")
		end
		if #conn.inbuf > MAX_HANDSHAKE_SIZE then
			conn:closeTransport()
			return nil, "handshake response too large"
		end
		if platform.uptime() >= deadline then
			conn:closeTransport()
			return nil, "handshake timed out"
		end
		wait(deadline)
	end

	local headers, protocol = parseResponse(conn.inbuf:sub(1, headEnd + 1), key, opts.protocols)
	if not headers then
		conn:closeTransport()
		return nil, protocol
	end
	conn.protocol, conn.headers = protocol, headers
	conn.inbuf = conn.inbuf:sub(headEnd + 4)
	conn.state = "open"
	conn.closeCode, conn.closeReason = nil, nil
	conn:processFrames()
	return conn
end

return ws
