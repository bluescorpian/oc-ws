-- luacheck: std +busted
-- The closing handshake (RFC 6455 sections 5.5.1, 7.1 and 7.4).
-- Tests tagged #bug document behaviour that contradicts the RFC and fail
-- until it is fixed; `busted tests/unit --exclude-tags=bug` skips them.
package.path = "tests/support/?.lua;" .. package.path
local fake = require("fake_platform")

local TEXT, CLOSE = 0x1, 0x8

describe("closing", function()
	local conn, srv
	before_each(function()
		fake.install()
		conn, srv = fake.open()
	end)

	local function closedWith()
		local data, status, code, reason = conn:receive(0)
		assert.is_nil(data)
		assert.equal("closed", status)
		return code, reason
	end

	describe("started by the client", function()
		it("sends a masked close frame with the code and reason", function()
			srv:echoCloses()
			assert.is_true(conn:close(4000, "done here"))
			local f = srv:frames()[1]
			assert.equal(CLOSE, f.opcode)
			assert.is_true(f.fin)
			assert.is_true(f.masked)
			assert.equal(4000, f.code)
			assert.equal("done here", f.reason)
		end)

		it("sends 1000 when no code is given", function()
			srv:echoCloses()
			conn:close()
			assert.equal(1000, srv:frames()[1].code)
		end)

		it("finishes when the server answers, then closes the socket", function()
			srv:echoCloses()
			conn:close(1000, "bye")
			assert.is_false(conn:isOpen())
			assert.is_true(srv.closedByClient)
			local code, reason = closedWith()
			assert.equal(1000, code)
			assert.equal("bye", reason)
		end)

		it("reports the code from the server's close frame", function()
			srv.onFrame = function(f)
				if f.opcode == CLOSE then
					srv:sendClose(1001, "server leaving")
					srv:eof()
				end
			end
			conn:close(1000)
			local code, reason = closedWith()
			assert.equal(1001, code)
			assert.equal("server leaving", reason)
		end)

		it("waits for a reply that arrives later", function()
			srv.onFrame = function(f)
				if f.opcode == CLOSE then fake.at(1, function() srv:sendFrame(CLOSE, f.payload) end) end
			end
			local start = fake.now()
			conn:close()
			assert.near(start + 1, fake.now(), 0.15)
			assert.equal(1000, (closedWith()))
		end)

		it("skips data frames the server sent before answering", function()
			srv.onFrame = function(f)
				if f.opcode == CLOSE then
					srv:sendFrame(TEXT, "in flight")
					srv:sendFrame(CLOSE, f.payload)
				end
			end
			conn:close()
			assert.equal(1000, (closedWith()))
		end)

		it("gives up after closeTimeout when the server never answers", function()
			fake.install()
			conn, srv = fake.open(nil, { closeTimeout = 1 })
			local start = fake.now()
			assert.is_true(conn:close())
			assert.near(start + 1, fake.now(), 0.15)
			assert.is_true(srv.closedByClient)
			assert.is_false(conn:isOpen())
		end)

		it("gives up after 3 seconds by default", function()
			local start = fake.now()
			conn:close()
			assert.near(start + 3, fake.now(), 0.15)
		end)

		-- RFC 6455 7.1.5: with no close frame received, the connection close
		-- code is 1006. The library reports the code it sent itself.
		it("reports 1006 when the server never answers #bug", function()
			fake.install()
			conn, srv = fake.open(nil, { closeTimeout = 1 })
			conn:close(1000, "bye")
			assert.equal(1006, (closedWith()))
		end)

		it("reports 1006 when the server drops the connection without answering #bug", function()
			srv.onFrame = function(f) if f.opcode == CLOSE then srv:eof() end end
			conn:close(1000, "bye")
			assert.equal(1006, (closedWith()))
		end)

		it("does nothing when already closed", function()
			srv:echoCloses()
			conn:close()
			local frames = #srv:frames()
			assert.is_true(conn:close())
			assert.equal(frames, #srv:frames())
		end)

		it("rejects a reason over 123 bytes", function()
			assert.has_error(function() conn:close(1000, ("r"):rep(124)) end)
		end)

		for _, code in ipairs({ 1005, 1006, 1015 }) do
			it("never sends reserved code " .. code, function()
				srv:echoCloses()
				pcall(conn.close, conn, code)
				for _, f in ipairs(srv:frames()) do assert.are_not.equal(code, f.code) end
			end)
		end
	end)

	describe("started by the server", function()
		it("echoes the server's code and reports it with the reason", function()
			srv:sendClose(1001, "going away")
			local code, reason = closedWith()
			assert.equal(1001, code)
			assert.equal("going away", reason)
			local f = srv:lastFrame()
			assert.equal(CLOSE, f.opcode)
			assert.is_true(f.masked)
			assert.equal(1001, f.code)
			assert.is_false(conn:isOpen())
			assert.is_true(srv.closedByClient)
		end)

		it("reports 1005 for a close frame without a code, and answers it", function()
			srv:sendClose()
			assert.equal(1005, (closedWith()))
			local f = srv:lastFrame()
			assert.equal(CLOSE, f.opcode)
			assert.is_nil(f.code)
		end)

		it("delivers messages sent before the close frame first", function()
			srv:send(fake.frame(TEXT, "last words") .. fake.frame(CLOSE, fake.closePayload(1000)))
			assert.equal("last words", (conn:receive(0)))
			assert.equal(1000, (closedWith()))
		end)

		for _, code in ipairs({ 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 3000, 3999, 4000, 4999 }) do
			it("accepts close code " .. code, function()
				srv:sendClose(code)
				assert.equal(code, (closedWith()))
				assert.equal(code, srv:lastFrame().code)
			end)
		end

		for _, code in ipairs({ 0, 999, 1004, 1005, 1006, 1015, 1016, 1100, 2000, 2999, 5000, 65535 }) do
			it("fails with 1002 on invalid close code " .. code, function()
				srv:sendClose(code)
				assert.equal(1002, (closedWith()))
				assert.equal(1002, srv:lastFrame().code)
			end)
		end

		it("fails with 1002 on a 1-byte close payload", function()
			srv:sendFrame(CLOSE, "\3")
			assert.equal(1002, (closedWith()))
			assert.equal(1002, srv:lastFrame().code)
		end)

		it("fails with 1007 on a close reason that is not UTF-8", function()
			srv:sendClose(1000, "\xff\xfe")
			assert.equal(1007, (closedWith()))
			assert.equal(1007, srv:lastFrame().code)
		end)

		it("accepts a 123-byte UTF-8 close reason", function()
			local reason = ("é"):rep(61) .. "x" -- 123 bytes
			srv:sendClose(1000, reason)
			local code, got = closedWith()
			assert.equal(1000, code)
			assert.equal(reason, got)
		end)
	end)
end)
