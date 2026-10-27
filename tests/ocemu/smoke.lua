-- Runs inside OCEmu's OpenOS (started from /home/.shrc by tests/ocemu/run.sh).
-- Reports each check through the emulator's stdout, then powers off.
local component = require("component")
local computer = require("computer")
local event = require("event")

local log = component.ocemu.log
local url = io.open("/home/url"):read("*l")
local failures = 0

local function check(name, ok, detail)
	log(("%s %s%s"):format(ok and "ok  " or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
	if not ok then failures = failures + 1 end
end

log("smoke: started")
local ok, err = pcall(function()
	local ws = require("ws")
	check("loads under OpenOS " .. _VERSION, ws._VERSION ~= nil, ws._VERSION)

	local conn, cerr = ws.connect(url)
	check("connects", conn ~= nil, cerr)
	if not conn then return end

	conn:send("hello from ocemu")
	local data, kind = conn:receive(5)
	check("receive echoes text", data == "hello from ocemu" and kind == "text", data)

	local blob = ("\0\255"):rep(40000)
	conn:send(blob, true)
	data, kind = conn:receive(10)
	check("receive echoes 80 KB binary", data == blob and kind == "binary", data and #data)

	check("poll returns timeout when idle", select(2, conn:poll()) == "timeout")

	conn:listen()
	conn:send("via events")
	local _, id, edata, ekind = event.pull(5, "websocket_message")
	check("listen pushes websocket_message", id == conn.id and edata == "via events" and ekind == "text", edata)

	conn:close()
	local _, cid, code = event.pull(5, "websocket_closed")
	check("close pushes websocket_closed", cid == conn.id and code == 1000, code)
end)
if not ok then check("no errors", false, err) end

log(failures == 0 and "SMOKE PASSED" or "SMOKE FAILED")
computer.shutdown()
