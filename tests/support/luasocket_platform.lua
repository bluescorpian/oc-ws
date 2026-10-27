-- Runs oc-ws on a desktop Lua 5.3 by standing in for the OpenComputers
-- internet card with LuaSocket. The fake socket keeps the card's semantics:
-- connect returns at once and finishConnect reports progress, read returns at
-- most 2048 bytes, "" when nothing has arrived and nil at end of stream, and
-- write may accept only part of the data.
local socket = require("socket")

local MAX_READ = 2048

local function newSocket(host, port)
	-- socket.tcp() picks the family on connect, so "localhost" may go to ::1.
	local tcp = assert((socket.tcp4 or socket.tcp)())
	tcp:settimeout(0)
	local _, err = tcp:connect(host, port)
	local state = (err == nil) and "connected" or "connecting"
	if err and err ~= "timeout" and err ~= "Operation already in progress" then
		state, err = "failed", err
	end

	local s = {}
	function s.finishConnect()
		if state == "connected" then return true end
		if state == "failed" then error(err, 0) end
		local _, writable = socket.select(nil, { tcp }, 0)
		if writable[1] then
			-- A connect that failed also shows as writable; probe it.
			local peer, perr = tcp:getpeername()
			if not peer then
				state, err = "failed", perr
				error(perr, 0)
			end
			state = "connected"
			return true
		end
		return false
	end
	function s.read(n)
		n = math.min(n or MAX_READ, MAX_READ)
		local data, rerr, partial = tcp:receive(n)
		data = data or partial
		if data and #data > 0 then return data end
		if rerr == "closed" then return nil end
		return ""
	end
	function s.write(data)
		local sent, werr, partialSent = tcp:send(data)
		if sent then return sent end
		if werr == "closed" then return nil, "connection lost" end
		return partialSent or 0
	end
	function s.close() tcp:close() end
	function s.id() return tostring(tcp) end
	return s
end

local start = socket.gettime()

return function(ws)
	local p = ws.platform
	function p.internet()
		return {
			connect = function(host, port) return newSocket(host, port) end,
		}
	end
	function p.uptime() return socket.gettime() - start end
	function p.pull(timeout) socket.sleep(math.min(timeout or 0, 0.01)) end
	function p.random(n)
		local f = assert(io.open("/dev/urandom", "rb"))
		local bytes = f:read(n)
		f:close()
		return bytes
	end
	return p
end
