-- luacheck: std +busted
-- Opening handshake (RFC 6455 section 4) and URL handling (section 3).
package.path = "tests/support/?.lua;" .. package.path
local fake = require("fake_platform")

describe("ws.connect", function()
	local ws
	before_each(function() ws = fake.install() end)

	describe("URL", function()
		local function connectTo(url)
			local srv = fake.server()
			local conn, err = ws.connect(url)
			return conn, err, srv
		end

		it("connects ws:// to port 80 and requests /", function()
			local conn, _, srv = connectTo("ws://example.com")
			assert.truthy(conn)
			assert.same({ host = "example.com", port = 80 }, fake.connects[1])
			assert.equal("GET / HTTP/1.1", srv.requestLine)
			assert.equal("example.com", srv:header("Host"))
		end)

		it("sends path and query as the request target", function()
			local _, _, srv = connectTo("ws://example.com/chat/room?id=7&x=y")
			assert.equal("GET /chat/room?id=7&x=y HTTP/1.1", srv.requestLine)
		end)

		it("treats a query with no path as /?query", function()
			local _, _, srv = connectTo("ws://example.com?id=7")
			assert.equal("GET /?id=7 HTTP/1.1", srv.requestLine)
		end)

		it("uses an explicit port and puts it in the Host header", function()
			local _, _, srv = connectTo("ws://example.com:8080/x")
			assert.same({ host = "example.com", port = 8080 }, fake.connects[1])
			assert.equal("example.com:8080", srv:header("Host"))
		end)

		it("leaves the default port out of the Host header", function()
			local _, _, srv = connectTo("ws://example.com:80/")
			assert.equal("example.com", srv:header("Host"))
		end)

		it("puts port 443 in the Host header for ws://, where it is not the default", function()
			local _, _, srv = connectTo("ws://example.com:443/")
			assert.equal("example.com:443", srv:header("Host"))
		end)

		it("accepts the scheme in any case", function()
			local conn = connectTo("WS://example.com/")
			assert.truthy(conn)
		end)

		it("connects to a bracketed IPv6 literal and brackets it in Host", function()
			local _, _, srv = connectTo("ws://[::1]:9000/")
			assert.same({ host = "::1", port = 9000 }, fake.connects[1])
			assert.equal("[::1]:9000", srv:header("Host"))
		end)

		it("connects wss:// to port 443 by default", function()
			fake.server()
			ws.connect("wss://example.com/")
			assert.same({ host = "example.com", port = 443 }, fake.connects[1])
		end)

		it("connects wss:// to an explicit port", function()
			fake.server()
			ws.connect("wss://example.com:8443/")
			assert.same({ host = "example.com", port = 8443 }, fake.connects[1])
		end)

		for _, url in ipairs({ "http://example.com/", "example.com", "ws:/example.com", "ws://", "ws://user@example.com/" }) do
			it("rejects " .. url .. " without opening a socket", function()
				local conn, err = ws.connect(url)
				assert.is_nil(conn)
				assert.is_string(err)
				assert.equal(0, #fake.connects)
			end)
		end
	end)

	describe("request", function()
		it("is a GET with the headers RFC 6455 section 4.1 requires", function()
			local _, srv = fake.open()
			assert.equal("GET / HTTP/1.1", srv.requestLine)
			assert.equal("example.com", srv:header("Host"))
			assert.equal("websocket", srv:header("Upgrade"):lower())
			assert.equal("upgrade", srv:header("Connection"):lower())
			assert.equal("13", srv:header("Sec-WebSocket-Version"))
			assert.equal(fake.SAMPLE_KEY, srv:header("Sec-WebSocket-Key"))
			assert.equal("\r\n\r\n", srv.request:sub(-4))
		end)

		it("uses a key that is the base64 of 16 random bytes", function()
			fake.nonce = ("\0"):rep(16)
			local srv = fake.server({
				respond = function(s)
					s:send(fake.response({ "Upgrade: websocket", "Connection: Upgrade",
						"Sec-WebSocket-Accept: ICX+Yqv66kxgM0FcWaLWlFLwTAI=" }))
				end,
			})
			local conn, err = ws.connect("ws://example.com/")
			assert.truthy(conn, err)
			assert.equal("AAAAAAAAAAAAAAAAAAAAAA==", srv:header("Sec-WebSocket-Key"))
		end)

		it("sends custom headers", function()
			local _, srv = fake.open(nil, { headers = { Authorization = "Bearer abc", ["X-Thing"] = "1" } })
			assert.equal("Bearer abc", srv:header("Authorization"))
			assert.equal("1", srv:header("X-Thing"))
		end)

		it("offers the requested subprotocols", function()
			local srv = fake.server({ respond = function(s) s:send(fake.response()) end })
			ws.connect("ws://example.com/", { protocols = { "chat", "superchat" } })
			assert.equal("chat, superchat", srv:header("Sec-WebSocket-Protocol"))
		end)

		it("offers no subprotocol header when none are requested", function()
			local _, srv = fake.open()
			assert.is_nil(srv:header("Sec-WebSocket-Protocol"))
		end)

		it("is delivered whole when the socket accepts a few bytes per write", function()
			local _, srv = fake.open({ writeLimits = { 3, 0, 1, 7 } })
			assert.equal(fake.SAMPLE_KEY, srv:header("Sec-WebSocket-Key"))
			assert.equal("13", srv:header("Sec-WebSocket-Version"))
		end)
	end)

	describe("response", function()
		local function answer(response, opts)
			fake.server({ respond = function(s) s:send(response) end })
			return ws.connect("ws://example.com/", opts)
		end
		local good = { "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: " .. fake.SAMPLE_ACCEPT }

		it("opens the connection on a valid 101", function()
			local conn = answer(fake.response())
			assert.truthy(conn)
			assert.is_true(conn:isOpen())
		end)

		it("matches header names and the Upgrade value case-insensitively", function()
			local conn, err = answer(fake.response({ "upgrade: WebSocket", "CONNECTION: upgrade",
				"sec-websocket-accept: " .. fake.SAMPLE_ACCEPT }))
			assert.truthy(conn, err)
		end)

		it("finds Upgrade among other tokens in Connection", function()
			local conn, err = answer(fake.response({ "Upgrade: websocket", "Connection: keep-alive, Upgrade",
				"Sec-WebSocket-Accept: " .. fake.SAMPLE_ACCEPT }))
			assert.truthy(conn, err)
		end)

		it("rejects a Connection header that only contains upgrade as part of a token", function()
			local conn = answer(fake.response({ "Upgrade: websocket", "Connection: keep-alive, upgraded",
				"Sec-WebSocket-Accept: " .. fake.SAMPLE_ACCEPT }))
			assert.is_nil(conn)
		end)

		it("rejects a wrong Sec-WebSocket-Accept", function()
			local conn, err = answer(fake.response({ "Upgrade: websocket", "Connection: Upgrade",
				"Sec-WebSocket-Accept: ICX+Yqv66kxgM0FcWaLWlFLwTAI=" }))
			assert.is_nil(conn)
			assert.is_string(err)
		end)

		it("rejects a missing Sec-WebSocket-Accept", function()
			assert.is_nil((answer(fake.response({ "Upgrade: websocket", "Connection: Upgrade" }))))
		end)

		it("rejects a missing Upgrade header", function()
			assert.is_nil((answer(fake.response({ "Connection: Upgrade", "Sec-WebSocket-Accept: " .. fake.SAMPLE_ACCEPT }))))
		end)

		it("rejects an Upgrade header that is not websocket", function()
			assert.is_nil((answer(fake.response({ "Upgrade: h2c", "Connection: Upgrade",
				"Sec-WebSocket-Accept: " .. fake.SAMPLE_ACCEPT }))))
		end)

		it("rejects a missing Connection header", function()
			assert.is_nil((answer(fake.response({ "Upgrade: websocket", "Sec-WebSocket-Accept: " .. fake.SAMPLE_ACCEPT }))))
		end)

		for _, status in ipairs({ "HTTP/1.1 200 OK", "HTTP/1.1 400 Bad Request", "HTTP/1.1 302 Found" }) do
			it("fails on " .. status .. " and reports the status", function()
				local conn, err = answer(fake.response(good, status))
				assert.is_nil(conn)
				assert.matches(status:match("%d%d%d"), err, 1, true)
			end)
		end

		it("closes the socket when the handshake fails", function()
			local srv = fake.server({ respond = function(s) s:send(fake.response(good, "HTTP/1.1 403 Forbidden")) end })
			ws.connect("ws://example.com/")
			assert.is_true(srv.closedByClient)
		end)

		it("rejects an extension the client did not offer", function()
			local lines = { table.unpack(good) }
			lines[#lines + 1] = "Sec-WebSocket-Extensions: permessage-deflate"
			assert.is_nil((answer(fake.response(lines))))
		end)

		it("exposes the subprotocol the server chose", function()
			local lines = { table.unpack(good) }
			lines[#lines + 1] = "Sec-WebSocket-Protocol: superchat"
			local conn, err = answer(fake.response(lines), { protocols = { "chat", "superchat" } })
			assert.truthy(conn, err)
			assert.equal("superchat", conn.protocol)
		end)

		it("leaves protocol nil when the server chose none", function()
			local conn = answer(fake.response(), { protocols = { "chat" } })
			assert.truthy(conn)
			assert.is_nil(conn.protocol)
		end)

		it("rejects a subprotocol that was not offered", function()
			local lines = { table.unpack(good) }
			lines[#lines + 1] = "Sec-WebSocket-Protocol: other"
			assert.is_nil((answer(fake.response(lines), { protocols = { "chat" } })))
		end)

		it("rejects a subprotocol when none was offered", function()
			local lines = { table.unpack(good) }
			lines[#lines + 1] = "Sec-WebSocket-Protocol: chat"
			assert.is_nil((answer(fake.response(lines))))
		end)

		it("is parsed when it arrives one byte per read", function()
			local conn, err = (function()
				fake.server({ readChunk = 1 })
				return ws.connect("ws://example.com/")
			end)()
			assert.truthy(conn, err)
		end)

		it("is parsed when it arrives in pieces over time", function()
			local resp = fake.response()
			fake.server({
				respond = function(s)
					for i = 1, #resp, 10 do
						fake.at(i / 100, function() s:send(resp:sub(i, i + 9)) end)
					end
				end,
			})
			local conn, err = ws.connect("ws://example.com/")
			assert.truthy(conn, err)
		end)

		it("delivers a frame that arrived in the same read as the response", function()
			local conn = fake.open({ afterResponse = fake.frame(0x1, "early") })
			assert.same({ "early", "text" }, { conn:receive(0) })
		end)

		it("fails when the stream ends during the handshake", function()
			fake.server({ respond = function(s) s:send("HTTP/1.1 101 Switching") s:eof() end })
			local conn, err = ws.connect("ws://example.com/")
			assert.is_nil(conn)
			assert.is_string(err)
		end)
	end)

	describe("connecting", function()
		it("waits for finishConnect to report the connection", function()
			local conn = fake.open({ connectAfter = 2 })
			assert.truthy(conn)
			assert.is_true(fake.now() >= 1002)
		end)

		it("reports a refused connect", function()
			fake.server({ refuse = "TCP connections are unavailable" })
			local conn, err = ws.connect("ws://example.com/")
			assert.is_nil(conn)
			assert.matches("TCP connections are unavailable", err, 1, true)
		end)

		it("reports an error raised by finishConnect", function()
			local srv = fake.server({ connectError = "connection refused" })
			local conn, err = ws.connect("ws://example.com/")
			assert.is_nil(conn)
			assert.matches("connection refused", err, 1, true)
			assert.is_true(srv.closedByClient)
		end)

		it("times out connecting after the timeout option", function()
			local srv = fake.server({ neverConnect = true })
			local conn, err = ws.connect("ws://example.com/", { timeout = 5 })
			assert.is_nil(conn)
			assert.matches("time", err)
			assert.near(1005, fake.now(), 0.2)
			assert.is_true(srv.closedByClient)
		end)

		it("times out connecting after 10 seconds by default", function()
			fake.server({ neverConnect = true })
			assert.is_nil((ws.connect("ws://example.com/")))
			assert.near(1010, fake.now(), 0.2)
		end)

		it("times out a handshake the server never answers", function()
			local srv = fake.server({ respond = function() end })
			local conn, err = ws.connect("ws://example.com/", { timeout = 4 })
			assert.is_nil(conn)
			assert.matches("time", err)
			assert.near(1004, fake.now(), 0.2)
			assert.is_true(srv.closedByClient)
		end)

		it("counts connecting and the handshake against one timeout", function()
			fake.server({ connectAfter = 3, respond = function() end })
			assert.is_nil((ws.connect("ws://example.com/", { timeout = 5 })))
			assert.near(1005, fake.now(), 0.2)
		end)

		it("times out a request the socket never accepts", function()
			fake.server({ writeLimits = { 0 } })
			local conn = ws.connect("ws://example.com/", { timeout = 3 })
			assert.is_nil(conn)
			assert.near(1003, fake.now(), 0.2)
		end)

		it("uses the internet card passed in the internet option", function()
			local used = false
			local srv = fake.server()
			local primary = ws.platform.internet()
			local card = {
				connect = function(host, port)
					used = true
					return primary.connect(host, port)
				end,
			}
			ws.platform.internet = function() error("primary card must not be used") end
			local conn = ws.connect("ws://example.com/", { internet = card })
			assert.truthy(conn)
			assert.is_true(used)
			assert.truthy(srv.request)
		end)
	end)
end)
