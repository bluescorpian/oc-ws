-- In-game installer for the oc-ws check. Downloads everything listed in the
-- host's manifest (oc-ws, libtls13, check.lua, pins.lua) from run.sh's file
-- server.
local fs = require("filesystem")
local internet = require("internet")

local base = ... or "http://127.0.0.1:8000/"

local function fetch(path)
	local chunks = {}
	for chunk in internet.request(base .. path) do chunks[#chunks + 1] = chunk end
	return table.concat(chunks)
end

local count = 0
for line in fetch("manifest.txt"):gmatch("[^\n]+") do
	local src, dest = line:match("^(%S+)%s+(%S+)$")
	local data = fetch(src)
	fs.makeDirectory(fs.path(dest))
	local f = assert(io.open(dest, "wb"))
	f:write(data)
	f:close()
	count = count + 1
end
print(("installed %d files; now run: /home/check.lua"):format(count))
