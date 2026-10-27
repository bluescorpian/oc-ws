-- luacheck: std +busted
-- Event mode: Connection:listen() turns incoming messages into
-- websocket_message / websocket_closed signals.
package.path = "tests/support/?.lua;" .. package.path
local fake = require("fake_platform")

local TEXT, BINARY, PING, PONG = 0x1, 0x2, 0x9, 0xA

describe("listen", function()
	local conn, srv
	before_each(function()
		fake.install()
		conn, srv = fake.open()
	end)

	local function messages() return fake.signalsNamed("websocket_message") end
	local function closes() return fake.signalsNamed("websocket_closed") end

	it("pushes websocket_message with the connection id, data and kind", function()
		conn:listen()
		srv:sendFrame(TEXT, "hello")
		srv:sendFrame(BINARY, "\0\1")
		fake.advance(0.5)
		assert.same({ { conn.id, "hello", "text" }, { conn.id, "\0\1", "binary" } }, messages())
	end)

	it("pushes messages that arrived before listen, in order, then later ones", function()
		fake.install()
		conn, srv = fake.open({ afterResponse = fake.frame(TEXT, "a") .. fake.frame(TEXT, "b") })
		conn:listen()
		srv:sendFrame(TEXT, "c")
		fake.advance(0.5)
		local got = {}
		for _, m in ipairs(messages()) do got[#got + 1] = m[2] end
		assert.same({ "a", "b", "c" }, got)
	end)

	it("picks up data even when no internet_ready signal arrives", function()
		fake.install()
		conn, srv = fake.open({ noReadySignal = true })
		conn:listen()
		srv:sendFrame(TEXT, "quiet")
		fake.advance(1)
		assert.same({ { conn.id, "quiet", "text" } }, messages())
	end)

	it("answers pings while listening", function()
		conn:listen()
		srv:sendFrame(PING, "p")
		fake.advance(0.5)
		local f = srv:lastFrame()
		assert.equal(PONG, f.opcode)
		assert.equal("p", f.payload)
	end)

	it("joins fragmented messages", function()
		conn:listen()
		srv:sendFrame(TEXT, "frag", { fin = false })
		fake.advance(0.5)
		srv:sendFrame(0x0, "ment")
		fake.advance(0.5)
		assert.same({ { conn.id, "fragment", "text" } }, messages())
	end)

	it("pushes websocket_closed with the server's code and reason, and stops listening", function()
		conn:listen()
		srv:sendClose(1001, "bye")
		fake.advance(0.5)
		assert.same({ { conn.id, 1001, "bye" } }, closes())
		assert.equal(0, fake.listenerCount())
		assert.equal(0, fake.timerCount())
	end)

	it("pushes websocket_closed with 1006 when the connection is lost", function()
		conn:listen()
		srv:sendFrame(TEXT, "before")
		srv:eof()
		fake.advance(0.5)
		assert.same({ { conn.id, "before", "text" } }, messages())
		local c = closes()
		assert.equal(1, #c)
		assert.equal(conn.id, c[1][1])
		assert.equal(1006, c[1][2])
		assert.equal(0, fake.timerCount())
	end)

	it("pushes websocket_closed with the error code on a protocol violation", function()
		conn:listen()
		srv:sendFrame(TEXT, "\xff")
		fake.advance(0.5)
		local c = closes()
		assert.equal(1, #c)
		assert.equal(1007, c[1][2])
		assert.equal(0, #messages())
		assert.equal(0, fake.listenerCount())
	end)

	it("pushes websocket_closed once when the program closes the connection", function()
		srv:echoCloses()
		conn:listen()
		conn:close(1000, "done")
		fake.advance(1)
		local c = closes()
		assert.equal(1, #c)
		assert.equal(1000, c[1][2])
		assert.equal(0, fake.listenerCount())
		assert.equal(0, fake.timerCount())
	end)

	it("does not push signals when not listening", function()
		srv:sendFrame(TEXT, "x")
		srv:sendClose(1000)
		conn:receive(0)
		conn:receive(0)
		assert.equal(0, #fake.signals)
	end)

	it("cannot be combined with receive", function()
		conn:listen()
		assert.has_error(function() conn:receive(0) end)
	end)

	it("gives each connection its own id", function()
		local other, srv2 = fake.open()
		conn:listen()
		other:listen()
		srv2:sendFrame(TEXT, "two")
		srv:sendFrame(TEXT, "one")
		fake.advance(0.5)
		assert.are_not.equal(conn.id, other.id)
		local byId = {}
		for _, m in ipairs(messages()) do byId[m[1]] = m[2] end
		assert.same({ [conn.id] = "one", [other.id] = "two" }, byId)
	end)
end)
