-- luacheck: std +busted
-- Sending: client-to-server masking (RFC 6455 section 5.3), length encoding
-- (5.2), partial socket writes, send timeouts and pings.
package.path = "tests/support/?.lua;" .. package.path
local fake = require("fake_platform")

local TEXT, BINARY, PING, PONG = 0x1, 0x2, 0x9, 0xA

describe("sending", function()
	local conn, srv
	before_each(function()
		fake.install()
		conn, srv = fake.open()
	end)

	local function payloadOf(n)
		local t = {}
		for i = 1, n do t[i] = string.char((i * 7 + 3) % 256) end
		return table.concat(t)
	end

	it("masks Hello exactly as the RFC 6455 section 5.7 example", function()
		-- fake's first mask key is the RFC's 37 fa 21 3d
		assert.is_true(conn:send("Hello"))
		assert.equal("\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58", srv.written:sub(#srv.request + 1))
	end)

	for _, n in ipairs({ 0, 1, 2, 3, 4, 5, 6, 7, 125, 126, 127, 1023, 1024, 1025, 1027, 4099, 65535, 65536, 70001 }) do
		it("sends a correctly masked " .. n .. "-byte frame with the right length encoding", function()
			local payload = payloadOf(n)
			assert.is_true(conn:send(payload, true))
			local f = srv:lastFrame()
			assert.truthy(f)
			assert.is_true(f.fin)
			assert.equal(0, f.rsv)
			assert.equal(BINARY, f.opcode)
			assert.is_true(f.masked)
			assert.equal(n, f.length)
			local lenCode = n <= 125 and n or (n <= 0xFFFF and 126 or 127)
			assert.equal(lenCode, f.lenCode)
			assert.equal(payload, f.payload)
		end)
	end

	it("sends text by default and binary when asked", function()
		conn:send("t")
		conn:send("b", true)
		local frames = srv:frames()
		assert.equal(TEXT, frames[1].opcode)
		assert.equal(BINARY, frames[2].opcode)
	end)

	it("uses a new masking key for each frame", function()
		conn:send("a")
		conn:send("a")
		local frames = srv:frames()
		assert.are_not.equal(frames[1].key, frames[2].key)
		assert.equal("a", frames[2].payload)
	end)

	it("resends what the socket did not accept until the whole frame is out", function()
		fake.install()
		conn, srv = fake.open({ writeLimits = { 1, 0, 3, 0, 0, 700, 2 } })
		local payload = payloadOf(3001)
		assert.is_true(conn:send(payload))
		assert.equal(payload, srv:lastFrame().payload)
		assert.equal(1, #srv:frames())
	end)

	it("resends a large frame accepted in uneven pieces", function()
		fake.install()
		conn, srv = fake.open({ writeLimits = { 4096, 0, 1, 1500 } })
		local payload = payloadOf(70000)
		assert.is_true(conn:send(payload, true))
		assert.equal(payload, srv:lastFrame().payload)
	end)

	it("keeps frames in order when several are sent through a slow socket", function()
		fake.install()
		conn, srv = fake.open({ writeLimits = { 5, 0 } })
		for i = 1, 5 do conn:send("message " .. i) end
		local frames = srv:frames()
		assert.equal(5, #frames)
		for i = 1, 5 do assert.equal("message " .. i, frames[i].payload) end
	end)

	it("waits while the socket buffer is full and finishes once it drains", function()
		local start = fake.now()
		srv.cfg.writeLimits = { 0 }
		fake.at(2, function() srv.cfg.writeLimits = nil end)
		assert.is_true(conn:send("queued"))
		assert.equal("queued", srv:lastFrame().payload)
		assert.is_true(fake.now() >= start + 2)
	end)

	it("gives up after sendTimeout when the socket accepts nothing", function()
		fake.install()
		conn, srv = fake.open(nil, { sendTimeout = 2 })
		srv.cfg.writeLimits = { 0 }
		local start = fake.now()
		local ok, err = conn:send("stuck")
		assert.is_nil(ok)
		assert.is_string(err)
		assert.near(start + 2, fake.now(), 0.15)
	end)

	it("gives up after 10 seconds by default", function()
		srv.cfg.writeLimits = { 0 }
		local start = fake.now()
		assert.is_nil((conn:send("stuck")))
		assert.near(start + 10, fake.now(), 0.15)
	end)

	it("reports a write error as a lost connection (1006)", function()
		srv.cfg.writeError = "connection reset"
		local ok, err = conn:send("x")
		assert.is_nil(ok)
		assert.is_string(err)
		local data, status, code = conn:receive(0)
		assert.same({ nil, "closed", 1006 }, { data, status, code })
	end)

	it("refuses to send once closed", function()
		srv:echoCloses()
		conn:close()
		local ok, err = conn:send("late")
		assert.is_nil(ok)
		assert.is_string(err)
	end)

	it("rejects data that is not a string", function()
		assert.has_error(function() conn:send(42) end)
	end)

	describe("ping", function()
		it("sends a masked ping with the payload", function()
			assert.is_true(conn:ping("hello?"))
			local f = srv:lastFrame()
			assert.equal(PING, f.opcode)
			assert.is_true(f.masked)
			assert.equal("hello?", f.payload)
		end)

		it("sends an empty ping by default", function()
			conn:ping()
			assert.equal("", srv:lastFrame().payload)
		end)

		it("accepts 125 bytes and rejects 126", function()
			assert.is_true(conn:ping(("p"):rep(125)))
			assert.has_error(function() conn:ping(("p"):rep(126)) end)
		end)

		it("passes the server's pong to onPong", function()
			fake.install()
			local got = {}
			conn, srv = fake.open(nil, { onPong = function(p) got[#got + 1] = p end })
			srv.onFrame = function(f)
				if f.opcode == PING then srv:sendFrame(PONG, f.payload) end
			end
			conn:ping("echo me")
			conn:receive(0)
			assert.same({ "echo me" }, got)
		end)
	end)
end)
