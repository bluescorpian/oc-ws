-- luacheck: std +busted
-- Receiving: frame parsing (RFC 6455 section 5.2), fragmentation (5.4),
-- control frames (5.5), protocol errors (7.1.7, 7.4) and receive timeouts.
package.path = "tests/support/?.lua;" .. package.path
local fake = require("fake_platform")

local TEXT, BINARY, CONT, CLOSE, PING, PONG = 0x1, 0x2, 0x0, 0x8, 0x9, 0xA

describe("receiving", function()
	local conn, srv
	before_each(function()
		fake.install()
		conn, srv = fake.open()
	end)

	-- The connection failed with `code`: it told the server so in a close
	-- frame, dropped the socket and reports the code to the program.
	local function assertFailed(code)
		local data, status, got = conn:receive(0)
		assert.is_nil(data)
		assert.equal("closed", status)
		assert.equal(code, got)
		local f = srv:lastFrame()
		assert.truthy(f, "no close frame sent")
		assert.equal(CLOSE, f.opcode)
		assert.equal(code, f.code)
		assert.is_true(srv.closedByClient)
		assert.is_false(conn:isOpen())
	end

	describe("frame lengths", function()
		for _, n in ipairs({ 0, 1, 125, 126, 127, 65535, 65536, 70000 }) do
			it("reads a " .. n .. "-byte text message", function()
				local payload = ("abcdefghij"):rep(n // 10 + 1):sub(1, n)
				srv:sendFrame(TEXT, payload)
				local data, kind = conn:receive(1)
				assert.equal("text", kind)
				assert.equal(n, #data)
				assert.equal(payload, data)
			end)
		end

		it("reads a frame that trickles in one byte per read", function()
			fake.install()
			conn, srv = fake.open({ readChunk = 1 })
			srv:sendFrame(TEXT, ("x"):rep(300))
			assert.equal(("x"):rep(300), (conn:receive(1)))
		end)

		it("waits for the rest of a frame that arrives over time", function()
			local f = fake.frame(BINARY, ("z"):rep(5000))
			for i = 1, #f, 1000 do
				fake.at(i / 1000, function() srv:send(f:sub(i, i + 999)) end)
			end
			assert.equal(("z"):rep(5000), (conn:receive(10)))
		end)

		it("reads several frames that came in one read, one per receive", function()
			srv:send(fake.frame(TEXT, "one") .. fake.frame(TEXT, "two") .. fake.frame(BINARY, "three"))
			assert.same({ "one", "text" }, { conn:receive(0) })
			assert.same({ "two", "text" }, { conn:receive(0) })
			assert.same({ "three", "binary" }, { conn:receive(0) })
		end)

		it("accepts a longer length encoding than needed", function()
			srv:sendFrame(TEXT, "short", { lenForm = "64" })
			assert.equal("short", (conn:receive(0)))
		end)
	end)

	describe("messages", function()
		it("returns binary data unchanged, with kind binary", function()
			local all = {}
			for i = 0, 255 do all[#all + 1] = string.char(i) end
			all = table.concat(all)
			srv:sendFrame(BINARY, all)
			assert.same({ all, "binary" }, { conn:receive(0) })
		end)

		it("returns multi-byte UTF-8 text", function()
			srv:sendFrame(TEXT, "κόσμε €𝄞")
			assert.equal("κόσμε €𝄞", (conn:receive(0)))
		end)

		it("joins a fragmented text message", function()
			srv:sendFrame(TEXT, "Hel", { fin = false })
			srv:sendFrame(CONT, "lo, ", { fin = false })
			srv:sendFrame(CONT, "world", { fin = true })
			assert.same({ "Hello, world", "text" }, { conn:receive(0) })
		end)

		it("joins a fragmented binary message", function()
			srv:sendFrame(BINARY, "\0\1", { fin = false })
			srv:sendFrame(CONT, "\2\255")
			assert.same({ "\0\1\2\255", "binary" }, { conn:receive(0) })
		end)

		it("accepts empty fragments", function()
			srv:sendFrame(TEXT, "", { fin = false })
			srv:sendFrame(CONT, "a", { fin = false })
			srv:sendFrame(CONT, "")
			assert.equal("a", (conn:receive(0)))
		end)

		it("accepts a UTF-8 character split across fragments", function()
			local euro = "€" -- three bytes
			srv:sendFrame(TEXT, "a" .. euro:sub(1, 1), { fin = false })
			srv:sendFrame(CONT, euro:sub(2, 3))
			assert.equal("a€", (conn:receive(0)))
		end)

		it("does not deliver a fragmented message before its last fragment", function()
			srv:sendFrame(TEXT, "part", { fin = false })
			assert.same({ nil, "timeout" }, { conn:receive(0) })
			srv:sendFrame(CONT, "s")
			assert.equal("parts", (conn:receive(0)))
		end)

		it("handles a ping between fragments and still joins the message", function()
			srv:sendFrame(TEXT, "Hel", { fin = false })
			srv:sendFrame(PING, "mid")
			srv:sendFrame(CONT, "lo")
			assert.same({ "Hello", "text" }, { conn:receive(0) })
			local pong = srv:lastFrame()
			assert.equal(PONG, pong.opcode)
			assert.equal("mid", pong.payload)
		end)

		it("passes a pong between fragments to onPong and still joins the message", function()
			fake.install()
			local pongs = {}
			conn, srv = fake.open(nil, { onPong = function(p) pongs[#pongs + 1] = p end })
			srv:sendFrame(BINARY, "ab", { fin = false })
			srv:sendFrame(PONG, "p1")
			srv:sendFrame(CONT, "cd")
			assert.same({ "abcd", "binary" }, { conn:receive(0) })
			assert.same({ "p1" }, pongs)
		end)

		it("accepts a message of exactly maxMessageSize", function()
			fake.install()
			conn, srv = fake.open(nil, { maxMessageSize = 10 })
			srv:sendFrame(TEXT, ("a"):rep(10))
			assert.equal(("a"):rep(10), (conn:receive(0)))
		end)
	end)

	describe("pings", function()
		it("answers a ping with a pong carrying the same payload", function()
			srv:sendFrame(PING, "are you there")
			conn:receive(0)
			local f = srv:lastFrame()
			assert.equal(PONG, f.opcode)
			assert.is_true(f.fin)
			assert.is_true(f.masked)
			assert.equal("are you there", f.payload)
		end)

		it("answers an empty ping and a 125-byte ping", function()
			srv:sendFrame(PING, "")
			srv:sendFrame(PING, ("p"):rep(125))
			conn:receive(0)
			local frames = srv:frames()
			assert.equal(2, #frames)
			assert.equal("", frames[1].payload)
			assert.equal(("p"):rep(125), frames[2].payload)
		end)

		it("answers pings while the program waits for a message", function()
			fake.at(1, function() srv:sendFrame(PING, "1") end)
			fake.at(2, function() srv:sendFrame(TEXT, "msg") end)
			assert.equal("msg", (conn:receive(5)))
			assert.equal(PONG, srv:frames()[1].opcode)
		end)

		it("does not return pings or pongs as messages", function()
			srv:sendFrame(PING, "x")
			srv:sendFrame(PONG, "y")
			assert.same({ nil, "timeout" }, { conn:receive(0) })
		end)
	end)

	describe("protocol errors", function()
		it("fails with 1002 on a masked frame from the server", function()
			srv:sendFrame(TEXT, "hi", { mask = "\1\2\3\4" })
			assertFailed(1002)
		end)

		for _, rsv in ipairs({ 1, 2, 4 }) do
			it("fails with 1002 when reserved bit value " .. rsv .. " is set", function()
				srv:sendFrame(TEXT, "hi", { rsv = rsv })
				assertFailed(1002)
			end)
		end

		for _, op in ipairs({ 0x3, 0x7, 0xB, 0xF }) do
			it(("fails with 1002 on unknown opcode 0x%X"):format(op), function()
				srv:sendFrame(op, "")
				assertFailed(1002)
			end)
		end

		it("fails with 1002 on a fragmented ping", function()
			srv:sendFrame(PING, "x", { fin = false })
			assertFailed(1002)
		end)

		it("fails with 1002 on a fragmented close", function()
			srv:sendFrame(CLOSE, fake.closePayload(1000), { fin = false })
			assertFailed(1002)
		end)

		it("fails with 1002 on a ping over 125 bytes", function()
			srv:sendFrame(PING, ("p"):rep(126))
			assertFailed(1002)
		end)

		it("fails with 1002 on a continuation with nothing to continue", function()
			srv:sendFrame(CONT, "orphan")
			assertFailed(1002)
		end)

		it("fails with 1002 on a new message inside a fragmented one", function()
			srv:sendFrame(TEXT, "a", { fin = false })
			srv:sendFrame(TEXT, "b")
			assertFailed(1002)
		end)

		it("fails with 1002 on a 64-bit length with the top bit set", function()
			srv:send(string.pack(">BBI8", 0x82, 127, 0x8000000000000000))
			assertFailed(1002)
		end)

		for name, bytes in pairs({
			["a lone continuation byte"] = "\x80",
			["an invalid byte"] = "a\xffb",
			["an overlong encoding"] = "\xc0\xaf",
			["a UTF-16 surrogate"] = "\xed\xa0\x80",
			["a code point past U+10FFFF"] = "\xf4\x90\x80\x80",
			["a truncated sequence"] = "abc\xe2\x82",
		}) do
			it("fails with 1007 on text containing " .. name, function()
				srv:sendFrame(TEXT, bytes)
				assertFailed(1007)
			end)
		end

		it("fails with 1007 on a fragmented text message that ends mid-character", function()
			srv:sendFrame(TEXT, "ok", { fin = false })
			srv:sendFrame(CONT, "\xe2\x82")
			assertFailed(1007)
		end)

		it("does not check binary messages for UTF-8", function()
			srv:sendFrame(BINARY, "\xff\xfe")
			assert.equal("\xff\xfe", (conn:receive(0)))
		end)

		it("fails with 1009 on a frame over maxMessageSize", function()
			fake.install()
			conn, srv = fake.open(nil, { maxMessageSize = 10 })
			srv:sendFrame(TEXT, ("a"):rep(11))
			assertFailed(1009)
		end)

		it("fails with 1009 on a fragmented message whose total is over maxMessageSize", function()
			fake.install()
			conn, srv = fake.open(nil, { maxMessageSize = 10 })
			srv:sendFrame(TEXT, ("a"):rep(6), { fin = false })
			srv:sendFrame(CONT, ("a"):rep(5))
			assertFailed(1009)
		end)

		it("fails with 1009 as soon as a too-large length is announced", function()
			fake.install()
			conn, srv = fake.open(nil, { maxMessageSize = 1000 })
			srv:send(string.pack(">BBI8", 0x82, 127, 1 << 40))
			assertFailed(1009)
		end)

		it("enforces the 1 MiB default maxMessageSize", function()
			srv:send(string.pack(">BBI8", 0x82, 127, 1024 * 1024 + 1))
			assertFailed(1009)
		end)

		it("still returns the message that arrived before the error", function()
			srv:send(fake.frame(TEXT, "fine") .. fake.frame(TEXT, "bad", { mask = "abcd" }))
			assert.equal("fine", (conn:receive(0)))
			assertFailed(1002)
		end)
	end)

	describe("end of stream", function()
		it("reports 1006 when the stream ends without a close frame", function()
			srv:eof()
			local data, status, code = conn:receive(1)
			assert.is_nil(data)
			assert.equal("closed", status)
			assert.equal(1006, code)
			assert.is_false(conn:isOpen())
		end)

		it("delivers frames that arrived in the same read as the end of stream", function()
			srv:send(fake.frame(TEXT, "a") .. fake.frame(BINARY, "b"))
			srv:eof()
			assert.same({ "a", "text" }, { conn:receive(0) })
			assert.same({ "b", "binary" }, { conn:receive(0) })
			local data, status, code = conn:receive(0)
			assert.same({ nil, "closed", 1006 }, { data, status, code })
		end)

		it("uses the close frame's code when it arrived together with the end of stream", function()
			srv:sendClose(1001, "going away")
			srv:eof()
			assert.same({ nil, "closed", 1001, "going away" }, { conn:receive(0) })
		end)

		it("reports 1006 when the stream ends mid-frame", function()
			srv:send(fake.frame(TEXT, "complete"):sub(1, 5))
			srv:eof()
			local _, status, code = conn:receive(1)
			assert.equal("closed", status)
			assert.equal(1006, code)
		end)

		it("reports 1006 when reading raises an error", function()
			srv.sock.read = function() error("socket broke", 0) end
			local _, status, code = conn:receive(1)
			assert.equal("closed", status)
			assert.equal(1006, code)
		end)

		it("keeps reporting closed on later receives", function()
			srv:eof()
			conn:receive(0)
			local data, status, code = conn:receive(0)
			assert.same({ nil, "closed", 1006 }, { data, status, code })
		end)
	end)

	describe("timeouts", function()
		it("returns timeout after the given number of seconds", function()
			local start = fake.now()
			assert.same({ nil, "timeout" }, { conn:receive(3) })
			assert.near(start + 3, fake.now(), 0.15)
			assert.is_true(conn:isOpen())
		end)

		it("only checks with a timeout of 0", function()
			local start = fake.now()
			assert.same({ nil, "timeout" }, { conn:receive(0) })
			assert.equal(start, fake.now())
		end)

		it("poll returns a message that has arrived", function()
			srv:sendFrame(TEXT, "ready")
			assert.equal("ready", (conn:poll()))
		end)

		it("poll returns nothing without waiting when no message has arrived", function()
			local start = fake.now()
			assert.is_nil((conn:poll()))
			assert.equal(start, fake.now())
		end)

		it("waits without limit when no timeout is given", function()
			fake.at(500, function() srv:sendFrame(TEXT, "late") end)
			assert.equal("late", (conn:receive()))
		end)

		it("returns a message that arrives before the timeout", function()
			local start = fake.now()
			fake.at(2, function() srv:sendFrame(TEXT, "soon") end)
			assert.equal("soon", (conn:receive(5)))
			assert.near(start + 2, fake.now(), 0.15)
		end)
	end)
end)
