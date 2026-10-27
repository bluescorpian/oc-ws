-- A deterministic, in-memory stand-in for everything oc-ws reaches through
-- ws.platform, for the unit suite. Unlike luasocket_platform.lua there is no
-- network: each connect() is answered by a scripted server the test set up
-- beforehand with fake.server{...}.
--
-- The socket keeps the OpenComputers internet card's semantics: connect
-- returns at once, finishConnect() is false while pending, true once connected
-- and raises on failure, read() returns at most 2048 bytes, "" when nothing
-- has arrived and nil at end of stream, and write() may accept only part of
-- the data and returns the byte count.
--
-- Time is virtual: uptime() reads a clock that only pull() and fake.advance()
-- move, so timeouts take no real time. Signals sent with pushSignal are
-- recorded in fake.signals; event.listen handlers and event.timer callbacks
-- run while the clock advances, as they do inside OpenOS's event.pull.
--
-- Run the suite from the repo root:  nix develop -c busted tests/unit
-- (OC_WS_SRC=<dir> loads ws.lua from another directory instead of src/.)
local M = {}

package.path = (os.getenv("OC_WS_SRC") or "src") .. "/?.lua;" .. package.path

local MAX_READ = 2048
local PULL_LIMIT = 200000 -- a library stuck polling fails the test instead of hanging it

-- RFC 6455 section 1.3: this nonce encodes to the sample key, whose accept
-- value is given there.
M.SAMPLE_NONCE = "the sample nonce"
M.SAMPLE_KEY = "dGhlIHNhbXBsZSBub25jZQ=="
M.SAMPLE_ACCEPT = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

---------------------------------------------------------------------------
-- Frame helpers (test side, written independently of the library)

-- An unmasked server-to-client frame. opts: fin (default true), rsv (0-7),
-- mask (4-byte key: sets the mask bit, which servers must not do),
-- len (override the encoded length), lenForm ("16" or "64" to force a wider
-- length encoding).
function M.frame(opcode, payload, opts)
	opts = opts or {}
	payload = payload or ""
	local fin = opts.fin == nil or opts.fin
	local b1 = (fin and 0x80 or 0) | ((opts.rsv or 0) << 4) | opcode
	local len = opts.len or #payload
	local maskBit = opts.mask and 0x80 or 0
	local head
	if opts.lenForm == "64" or (not opts.lenForm and len > 0xFFFF) then
		head = string.pack(">BBI8", b1, maskBit | 127, len)
	elseif opts.lenForm == "16" or len > 125 then
		head = string.pack(">BBI2", b1, maskBit | 126, len)
	else
		head = string.pack(">BB", b1, maskBit | len)
	end
	if opts.mask then
		return head .. opts.mask .. M.xor(payload, opts.mask)
	end
	return head .. payload
end

function M.xor(data, key)
	local out = {}
	for i = 1, #data do
		out[i] = string.char(data:byte(i) ~ key:byte((i - 1) % 4 + 1))
	end
	return table.concat(out)
end

function M.closePayload(code, reason)
	return string.pack(">I2", code) .. (reason or "")
end

-- Decodes one client frame at pos. Returns the frame and the next position,
-- or nil if the frame is not complete yet.
local function decodeFrame(buf, pos)
	if #buf - pos + 1 < 2 then return nil end
	local b1, b2 = buf:byte(pos, pos + 1)
	local f = {
		fin = b1 & 0x80 ~= 0,
		rsv = (b1 >> 4) & 7,
		opcode = b1 & 0x0F,
		masked = b2 & 0x80 ~= 0,
		lenCode = b2 & 0x7F,
	}
	local len, p = f.lenCode, pos + 2
	if len == 126 then
		if #buf < p + 1 then return nil end
		len, p = string.unpack(">I2", buf, p), p + 2
	elseif len == 127 then
		if #buf < p + 7 then return nil end
		len, p = string.unpack(">I8", buf, p), p + 8
	end
	f.length = len
	if f.masked then
		if #buf < p + 3 then return nil end
		f.key, p = buf:sub(p, p + 3), p + 4
	end
	if #buf < p + len - 1 then return nil end
	local body = buf:sub(p, p + len - 1)
	f.payload = f.masked and M.xor(body, f.key) or body
	if f.opcode == 0x8 and #f.payload >= 2 then
		f.code = string.unpack(">I2", f.payload)
		f.reason = f.payload:sub(3)
	end
	return f, p + len
end

---------------------------------------------------------------------------
-- Virtual clock, events and signals

local now, pulls, schedule, timers, listeners, readyQueue

local function reset()
	now, pulls = 1000, 0
	schedule, timers, listeners, readyQueue = {}, {}, {}, {}
	M.signals = {}
	M.servers = {}
	M.pending = {}
	M.connects = {}
	M.nonce = M.SAMPLE_NONCE
	M.maskKeys = { "\x37\xfa\x21\x3d", "\x01\x02\x03\x04", "\xa5\x5a\x00\xff" }
	M.keyIndex = 0
end

function M.now() return now end

local function dispatchReady()
	while #readyQueue > 0 do
		local args = table.remove(readyQueue, 1)
		for _, fn in ipairs(listeners[args[1]] or {}) do fn(table.unpack(args, 1, args.n)) end
	end
end

local function nextEvent(limit)
	local best, kind, idx
	for i, s in ipairs(schedule) do
		if s.t <= limit and (not best or s.t < best) then best, kind, idx = s.t, "s", i end
	end
	for id, tm in pairs(timers) do
		if tm.t <= limit and (not best or tm.t < best) then best, kind, idx = tm.t, "t", id end
	end
	return best, kind, idx
end

-- Moves the clock forward, running scheduled server actions, timers and
-- signal listeners in time order.
function M.advance(dt)
	local target = now + (dt or 0)
	dispatchReady()
	while true do
		local t, kind, idx = nextEvent(target)
		if not t then break end
		now = math.max(now, t)
		if kind == "s" then
			local s = table.remove(schedule, idx)
			s.fn()
		else
			local tm = timers[idx]
			tm.t = tm.t + tm.interval
			tm.fn()
		end
		dispatchReady()
	end
	now = target
end

function M.at(dt, fn)
	schedule[#schedule + 1] = { t = now + dt, fn = fn }
end

function M.listenerCount(name)
	local n = 0
	for k, list in pairs(listeners) do
		if name == nil or k == name then n = n + #list end
	end
	return n
end

function M.timerCount()
	local n = 0
	for _ in pairs(timers) do n = n + 1 end
	return n
end

-- Signals of one name, as argument lists without the name.
function M.signalsNamed(name)
	local out = {}
	for _, s in ipairs(M.signals) do
		if s[1] == name then out[#out + 1] = { table.unpack(s, 2, s.n) } end
	end
	return out
end

---------------------------------------------------------------------------
-- Scripted servers

local Server = {}
Server.__index = Server

local function defaultRespond(srv)
	srv:send(M.response())
end

-- A handshake response. Without arguments it is a valid 101 for the sample
-- key; `lines` replaces the header lines and `status` the status line.
function M.response(lines, status)
	lines = lines or {
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Accept: " .. M.SAMPLE_ACCEPT,
	}
	local head = (status or "HTTP/1.1 101 Switching Protocols") .. "\r\n"
	for _, l in ipairs(lines) do head = head .. l .. "\r\n" end
	return head .. "\r\n"
end

-- Configures the server that answers the next connect(). cfg:
--   respond(srv)    called once the request has arrived (default: valid 101)
--   afterResponse   bytes sent right behind the default response, same read
--   connectAfter    virtual seconds until finishConnect() returns true (default 0:
--                   the first call returns false, the next true)
--   neverConnect    finishConnect() never completes
--   connectError    finishConnect() raises this message
--   refuse          internet.connect() returns nil, refuse
--   writeLimits     list of byte counts write() accepts per call, cycled
--   readChunk       largest chunk read() returns (at most 2048)
--   writeError      write() raises this once the handshake is done
--   noReadySignal   arriving data sends no internet_ready signal (as in OCEmu)
function M.server(cfg)
	cfg = cfg or {}
	local srv = setmetatable({
		cfg = cfg,
		inbound = "",
		written = "",
		eofSent = false,
		closedByClient = false,
		writeCalls = 0,
		readCalls = 0,
		parsePos = 1,
		decoded = {},
	}, Server)
	M.pending[#M.pending + 1] = srv
	return srv
end

function Server:send(bytes)
	self.inbound = self.inbound .. bytes
	if self.sock and not self.cfg.noReadySignal then
		readyQueue[#readyQueue + 1] = { "internet_ready", "inet-address", self.id, n = 3 }
	end
end

function Server:sendFrame(opcode, payload, opts)
	self:send(M.frame(opcode, payload, opts))
end

function Server:sendClose(code, reason)
	self:sendFrame(0x8, code and M.closePayload(code, reason) or "")
end

-- Ends the stream: reads return what is buffered, then nil.
function Server:eof()
	self.eofSent = true
	if self.sock and not self.cfg.noReadySignal then
		readyQueue[#readyQueue + 1] = { "internet_ready", "inet-address", self.id, n = 3 }
	end
end

-- Client frames written after the handshake request, decoded.
function Server:frames()
	return self.decoded
end

function Server:lastFrame()
	return self.decoded[#self.decoded]
end

-- Value of a request header (case-insensitive name), or nil.
function Server:header(name)
	return self.requestHeaders and self.requestHeaders[name:lower()]
end

function Server:received(bytes)
	self.written = self.written .. bytes
	if not self.request then
		local e = self.written:find("\r\n\r\n", 1, true)
		if not e then return end
		self.request = self.written:sub(1, e + 3)
		self.requestLine = self.request:match("^([^\r\n]*)")
		self.requestHeaders = {}
		self.requestHeaderCount = 0
		for name, value in self.request:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
			self.requestHeaders[name:lower()] = value
			self.requestHeaderCount = self.requestHeaderCount + 1
		end
		self.parsePos = e + 4
		if self.cfg.respond then
			self.cfg.respond(self)
		else
			defaultRespond(self)
			if self.cfg.afterResponse then self:send(self.cfg.afterResponse) end
		end
	end
	while true do
		local f, nextPos = decodeFrame(self.written, self.parsePos)
		if not f then break end
		self.parsePos = nextPos
		self.decoded[#self.decoded + 1] = f
		if self.onFrame then self.onFrame(f, self) end
	end
end

-- Server behaviour for the closing handshake: answer a client close frame by
-- echoing its payload, then end the stream.
function Server:echoCloses()
	self.onFrame = function(f)
		if f.opcode == 0x8 then
			self:sendFrame(0x8, f.payload)
			self:eof()
		end
	end
	return self
end

local nextSockId = 0

local function newSocket(srv, host, port)
	nextSockId = nextSockId + 1
	srv.id = "sock-" .. nextSockId
	srv.host, srv.port = host, port
	local cfg = srv.cfg
	local connectAt = now + (cfg.connectAfter or 0)
	local firstCall = true
	local s = {}
	srv.sock = s

	function s.finishConnect()
		if srv.closedByClient then error("socket is closed", 0) end
		if cfg.connectError then error(cfg.connectError, 0) end
		if cfg.neverConnect then return false end
		if firstCall then
			firstCall = false
			return false
		end
		return now >= connectAt
	end

	function s.read(n)
		srv.readCalls = srv.readCalls + 1
		if srv.closedByClient then error("socket is closed", 0) end
		local max = math.min(n or MAX_READ, MAX_READ, cfg.readChunk or MAX_READ)
		if #srv.inbound > 0 then
			local chunk = srv.inbound:sub(1, max)
			srv.inbound = srv.inbound:sub(max + 1)
			return chunk
		end
		if srv.eofSent then return nil end
		return ""
	end

	function s.write(data)
		srv.writeCalls = srv.writeCalls + 1
		if srv.closedByClient then error("socket is closed", 0) end
		if cfg.writeError and srv.request then error(cfg.writeError, 0) end
		local n = #data
		if cfg.writeLimits then
			local limits = cfg.writeLimits
			n = math.min(n, limits[(srv.writeCalls - 1) % #limits + 1])
		end
		if n > 0 then srv:received(data:sub(1, n)) end
		return n
	end

	function s.close()
		srv.closedByClient = true
	end

	function s.id() return srv.id end
	return s
end

local card = {
	address = "inet-address",
	connect = function(host, port)
		M.connects[#M.connects + 1] = { host = host, port = port }
		local srv = table.remove(M.pending, 1)
		if not srv then error("test bug: connect() with no fake.server configured", 0) end
		M.servers[#M.servers + 1] = srv
		if srv.cfg.refuse then return nil, srv.cfg.refuse end
		return newSocket(srv, host, port)
	end,
}

---------------------------------------------------------------------------
-- Installation

-- Loads a fresh copy of the library wired to a fresh fake. Returns ws.
function M.install()
	reset()
	package.loaded.ws = nil
	local ws = require("ws")
	local p = ws.platform
	function p.internet() return card end
	function p.uptime() return now end
	function p.pull(timeout)
		pulls = pulls + 1
		if pulls > PULL_LIMIT then error("fake: pull() called too often; the library is spinning", 0) end
		if timeout == nil then
			local t = nextEvent(math.huge)
			if not t then error("fake: pull() with no timeout and nothing scheduled would block forever", 0) end
			M.advance(t - now)
		else
			M.advance(timeout)
		end
		return nil
	end
	function p.listen(name, fn)
		listeners[name] = listeners[name] or {}
		table.insert(listeners[name], fn)
		return true
	end
	function p.ignore(name, fn)
		for i, f in ipairs(listeners[name] or {}) do
			if f == fn then
				table.remove(listeners[name], i)
				return true
			end
		end
		return false
	end
	local nextTimer = 0
	function p.timer(interval, fn)
		nextTimer = nextTimer + 1
		timers[nextTimer] = { t = now + interval, interval = interval, fn = fn }
		return nextTimer
	end
	function p.cancel(id)
		local had = timers[id] ~= nil
		timers[id] = nil
		return had
	end
	function p.push(...)
		M.signals[#M.signals + 1] = table.pack(...)
		return true
	end
	function p.random(n)
		if n == 16 then return M.nonce end
		if n == 4 then
			M.keyIndex = M.keyIndex + 1
			return M.maskKeys[(M.keyIndex - 1) % #M.maskKeys + 1]
		end
		return ("\x5a"):rep(n)
	end
	function p.tls() error("fake: no TLS library in the unit suite", 0) end
	M.ws = ws
	return ws
end

-- Sets up a server with cfg, connects to url (default ws://example.com/) with
-- opts and fails the test if that does not succeed. Returns conn, srv.
function M.open(cfg, opts, url)
	local srv = M.server(cfg)
	local conn, err = M.ws.connect(url or "ws://example.com/", opts)
	assert(conn, "connect failed: " .. tostring(err))
	return conn, srv
end

return M
