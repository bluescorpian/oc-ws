-- In-game check for oc-ws on a real OpenComputers computer. Installed to
-- /home/check.lua by install.lua; talks to the echo servers from
-- tests/ingame/run.sh. Prints each result and saves them to /home/check.txt.
local component = require("component")
local computer = require("computer")
local event = require("event")

local cfg = dofile("/home/pins.lua")
local lines, failures = {}, 0

local function say(s)
	print(s)
	lines[#lines + 1] = s
end

local function check(name, ok, detail)
	say(("%s %s%s"):format(ok and "ok  " or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
	if not ok then failures = failures + 1 end
end

local function skip(name, why) say(("skip %s (%s)"):format(name, why)) end

-- The sandbox has no collectgarbage; yielding gives the collector its turn.
local function freeKiB()
	for _ = 1, 5 do os.sleep(0) end
	return computer.freeMemory() // 1024
end

local function dataCardTier()
	if not component.isAvailable("data") then return 0 end
	local d = component.data
	if d.generateKeyPair then return 3 elseif d.random then return 2 else return 1 end
end

local readySignals = 0
local function countReady() readySignals = readySignals + 1 end
event.listen("internet_ready", countReady)

local function echoes(conn, label)
	local t = computer.uptime()
	conn:send("hello " .. label)
	local data, kind = conn:receive(10)
	check(label .. ": text echo", data == "hello " .. label and kind == "text", data or kind)
	local blob = ("\0\1\254\255"):rep(16 * 1024)
	local sent, sendErr = conn:send(blob, true)
	if sent then data, kind = conn:receive(30) end
	check(label .. ": 64 KiB binary echo", data == blob and kind == "binary",
		not sent and ("send: " .. tostring(sendErr)) or data and #data or kind)
	say(("     %s: both echoes took %.2fs"):format(label, computer.uptime() - t))
end

local tier = dataCardTier()
say(("oc-ws check on %s, %d KiB RAM total, %d KiB free, data card tier %d"):format(
	_VERSION, computer.totalMemory() // 1024, freeKiB(), tier))

local before = freeKiB()
local ws = require("ws")
say(("     oc-ws %s loaded, uses %d KiB"):format(ws._VERSION, before - freeKiB()))

-- ws:// with blocking receive
local conn, err = ws.connect(cfg.ws)
check("ws: connects", conn ~= nil, err)
if conn then
	echoes(conn, "ws")
	local t = computer.uptime()
	local data, kind = conn:receive(1)
	check("ws: receive times out after ~1s", data == nil and kind == "timeout", ("%.2fs"):format(computer.uptime() - t))

	-- listen mode
	conn:listen()
	conn:send("via events")
	local _, id, edata, ekind = event.pull(5, "websocket_message")
	check("ws: listen delivers websocket_message", id == conn.id and edata == "via events" and ekind == "text", edata)
	conn:close()
	local _, cid, code = event.pull(5, "websocket_closed")
	check("ws: close delivers websocket_closed 1000", cid == conn.id and code == 1000, code)
end
say(("     internet_ready signals seen so far: %d (0 means only the polling path ran)"):format(readySignals))

-- wss://
before = freeKiB()
local okTls, tlsErr = pcall(require, "tls13")
if not okTls then
	skip("wss", "libtls13 did not load: " .. tostring(tlsErr))
elseif tier < 2 then
	skip("wss", "needs a tier 2 or 3 data card")
else
	say(("     libtls13 loaded, uses %d KiB, %d KiB left"):format(before - freeKiB(), freeKiB()))

	local function tryTls(label, url, pin)
		local t = computer.uptime()
		local c, cerr = ws.connect(url, { timeout = 60, tls = { fingerprint = pin } })
		check(label .. ": connects with the pinned certificate", c ~= nil, cerr)
		if c then
			say(("     %s: handshake took %.2fs, %d KiB free"):format(label, computer.uptime() - t, freeKiB()))
			-- oc-ws should report failures, not raise them; count a raise and go on.
			local okEcho, echoErr = pcall(echoes, c, label)
			check(label .. ": echoes run without raising an error", okEcho, echoErr)
			c:close()
			check(label .. ": closes with 1000", c.closeCode == 1000, c.closeCode)
		end
	end

	tryTls("wss/rsa", cfg.rsa.url, cfg.rsa.fingerprint)
	local c, cerr = ws.connect(cfg.rsa.url, { timeout = 60, tls = { fingerprint = ("00"):rep(32) } })
	check("wss/rsa: refuses a wrong pin", c == nil and tostring(cerr):find("does not match", 1, true) ~= nil, cerr)

	if tier >= 3 then
		tryTls("wss/p256", cfg.p256.url, cfg.p256.fingerprint)
	else
		skip("wss/p256", "P-256 needs a tier 3 data card")
	end
end

event.ignore("internet_ready", countReady)
say(failures == 0 and "ALL CHECKS PASSED" or ("%d CHECK(S) FAILED"):format(failures))
local f = io.open("/home/check.txt", "w")
if f then
	f:write(table.concat(lines, "\n"), "\n")
	f:close()
	print("results saved to /home/check.txt")
end
