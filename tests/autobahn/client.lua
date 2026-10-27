-- Autobahn testsuite client: echoes every case back to the fuzzing server.
-- Run through tests/autobahn/run.sh.
package.path = "src/?.lua;tests/support/?.lua;" .. package.path
local ws = require("ws")
require("luasocket_platform")(ws)

local base = os.getenv("AUTOBAHN_URL") or "ws://127.0.0.1:9001"
local agent = "oc-ws"

local function open(path)
	local conn, err = ws.connect(base .. path, { maxMessageSize = 16 * 1024 * 1024, timeout = 30 })
	if not conn then error("connect " .. path .. ": " .. tostring(err)) end
	return conn
end

local conn = open("/getCaseCount")
local count = assert(tonumber((conn:receive(10))), "no case count")
conn:receive(10)

local only = tonumber(os.getenv("AUTOBAHN_CASE"))
for i = only or 1, only or count do
	local c = open(("/runCase?case=%d&agent=%s"):format(i, agent))
	while true do
		local data, kind = c:receive(60)
		if not data then break end
		c:send(data, kind == "binary")
	end
	if i % 50 == 0 or i == count then print(("case %d/%d"):format(i, count)) end
end

local reports = open("/updateReports?agent=" .. agent)
reports:receive(10)
print("reports updated")
