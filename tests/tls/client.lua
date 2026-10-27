-- wss:// checks against tests/server/tls-echo.js. Run through tests/tls/run.sh.
local libtls = assert(os.getenv("LIBTLS13_DIR"), "LIBTLS13_DIR not set")
package.path = table.concat({ "src/?.lua", "tests/support/?.lua", libtls .. "/?.lua", libtls .. "/?/init.lua", package.path }, ";")
local ws = require("ws")
local platform = require("luasocket_platform")(ws)

-- The opencomputers profile draws randomness from a data card; off OC, use
-- the default (pure Lua) profile with the OS's randomness and X25519.
function platform.tlsProfile(tls)
	local group = require("tls13.group")
	local rng = platform.random
	local profile = setmetatable({}, { __index = tls.profiles.default })
	function profile.rng() return rng end
	function profile.namedGroups()
		local x25519 = group.makeX25519(rng)
		return {
			tls.makeNamedGroup {
				code = 0x001d,
				name = "x25519",
				generateEagerly = true,
				decodePublicKey = x25519.decodePublicKey,
				encodePublicKey = x25519.encodePublicKey,
				generateKeyPair = x25519.generateKeyPair,
				deriveSharedSecret = x25519.deriveSharedSecret,
			},
		}
	end
	return profile
end

local url = assert(os.getenv("WSS_URL"))
local expected = assert(os.getenv("FINGERPRINT")):lower():gsub("[^%x]", "")
local failures = 0

local function check(name, ok, detail)
	print(("%s %s%s"):format(ok and "ok  " or "FAIL", name, detail and (" (" .. tostring(detail) .. ")") or ""))
	if not ok then failures = failures + 1 end
end

local started = platform.uptime()
local conn, err = ws.connect(url, { timeout = 30 })
check("connects over TLS", conn ~= nil, err)
if conn then
	check(("handshake took %.2fs"):format(platform.uptime() - started), true)
	check("reports the certificate fingerprint", conn.fingerprint == expected, conn.fingerprint)
	conn:send("hello over tls")
	local data, kind = conn:receive(10)
	check("echoes text", data == "hello over tls" and kind == "text", data)
	local blob = ("\0\1\2\255"):rep(5000)
	conn:send(blob, true)
	data, kind = conn:receive(10)
	check("echoes 20 KB binary", data == blob and kind == "binary", data and #data)
	conn:close()
	check("closes cleanly", conn.state == "closed" and conn.closeCode == 1000, conn.closeCode)
end

conn, err = ws.connect(url, { timeout = 30, tls = { fingerprint = os.getenv("FINGERPRINT") } })
check("accepts the matching pin (openssl colon form)", conn ~= nil, err)
if conn then conn:close() end

conn, err = ws.connect(url, { timeout = 30, tls = { fingerprint = ("00"):rep(32) } })
check("refuses a wrong pin", conn == nil and tostring(err):find("does not match", 1, true) ~= nil, err)

os.exit(failures == 0 and 0 or 1)
