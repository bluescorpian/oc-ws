# oc-ws

[![CI](https://img.shields.io/github/actions/workflow/status/bluescorpian/oc-ws/ci.yml?branch=main&label=CI)](https://github.com/bluescorpian/oc-ws/actions/workflows/ci.yml)
[![Lua 5.3](https://img.shields.io/badge/lua-5.3-000080?logo=lua&logoColor=white)](https://www.lua.org/manual/5.3/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**oc-ws** is a WebSocket client for [OpenComputers](https://github.com/MightyPirates/OpenComputers).
It lets a computer in Minecraft hold a live, two-way connection to a server
outside the game: a Discord bot, a dashboard, a chat bridge, a control panel
for your base. It is a single Lua file that runs on an internet card, and it
passes the [Autobahn](https://github.com/crossbario/autobahn-testsuite)
WebSocket conformance suite.

```lua
local ws = require("ws")

local conn = assert(ws.connect("ws://example.com:8080/chat"))
conn:send("hello from Minecraft")
print(conn:receive(10))   --> hello from the server   text
conn:close()
```

## Features

* The full WebSocket protocol (RFC 6455): text and binary messages,
  fragmented messages, ping and pong, and the closing handshake with codes
  and reasons.
* Encrypted `wss://` connections through
  [libtls13](https://github.com/OpenPrograms/Fingercomp-Programs/tree/master/libtls13),
  with certificate pinning so you know you reached your own server.
* Blocking calls with timeouts for simple scripts, or OpenOS events
  (`websocket_message`, `websocket_closed`) for programs with their own
  event loop.
* Answers pings for you, rejects protocol violations with the right close
  code, and caps message size so a misbehaving server can't run your
  computer out of memory.
* Subprotocols and custom request headers, e.g. `Authorization`.
* Tested off the game on every change: unit tests, the Autobahn suite, real
  TLS servers, and a boot of OpenOS in the [OCEmu](https://github.com/zenith391/OCEmu)
  emulator.

## Contents

* [Installation](#installation)
* [How to use](#how-to-use)
  * [Connecting](#connecting)
  * [Sending and receiving](#sending-and-receiving)
  * [Using OpenOS events](#using-openos-events)
  * [Secure connections (wss://)](#secure-connections-wss)
  * [Closing](#closing)
* [API reference](#api-reference)
* [Compatibility](#compatibility)
* [Upgrading from v1](#upgrading-from-v1)
* [Development](#development)
* [License](#license)

## Installation

You need an **internet card**. TCP must be enabled in the server's config,
which it is by default.

With [OPPM](https://ocdoc.cil.li/tutorial:program:oppm):

```sh
oppm install oc-ws
```

Or download the file directly:

```sh
wget https://raw.githubusercontent.com/bluescorpian/oc-ws/v2.0.0/src/ws.lua /usr/lib/ws.lua
```

For `wss://`, also install libtls13 and fit a tier 2 data card (see
[Secure connections](#secure-connections-wss)):

```sh
oppm install libtls13
```

## How to use

### Connecting

```lua
local ws = require("ws")

local conn, err = ws.connect("ws://example.com:8080/socket")
if not conn then
  error("could not connect: " .. err)
end
```

`ws.connect` waits until the connection is open, or gives up after 10
seconds, and returns `nil` and a reason on failure. The URL takes the usual
form: `ws://host[:port][/path][?query]`. The port defaults to 80, or 443 for
`wss://`.

Options go in a second argument:

```lua
local conn = ws.connect("ws://example.com/socket", {
  timeout = 5,                                 -- seconds to connect and handshake
  headers = { Authorization = "Bearer abc123" },
  protocols = { "chat.v2", "chat.v1" },        -- the server picks one: conn.protocol
  maxMessageSize = 256 * 1024,                 -- bytes; larger messages close the connection
})
```

### Sending and receiving

```lua
conn:send("a text message")
conn:send(string.char(1, 2, 3), true)   -- true sends binary

local data, kind = conn:receive(5)      -- wait up to 5 seconds
if data then
  print("got a " .. kind .. " message: " .. data)   -- kind is "text" or "binary"
elseif kind == "timeout" then
  print("nothing yet")
elseif kind == "closed" then
  print("connection closed")
end
```

`receive()` with no timeout waits until a message arrives. `poll()` checks
without waiting. A loop that keeps going until the server hangs up:

```lua
while true do
  local data, kind, code, reason = conn:receive()
  if not data then
    print(("closed: %s %s"):format(code, reason))
    break
  end
  print(data)
end
```

Pings from the server are answered automatically. To check the connection is
alive, send your own with `conn:ping()` and pass an `onPong` function in the
options to hear the reply.

### Using OpenOS events

`receive` blocks your program the way `os.sleep` does: other events that
arrive meanwhile (key presses, redstone, modem messages) are not seen. If your
program already runs an event loop, hand the connection to OpenOS instead:

```lua
local event = require("event")

conn:listen()
while true do
  local name, id, a, b = event.pullMultiple("websocket_message", "websocket_closed", "key_down")
  if name == "websocket_message" and id == conn.id then
    print("message (" .. b .. "): " .. a)
  elseif name == "websocket_closed" and id == conn.id then
    print("closed with code " .. tostring(a))
    break
  elseif name == "key_down" then
    conn:send("you pressed a key")
  end
end
```

| Event | Arguments |
| --- | --- |
| `websocket_message` | `id`, `data`, `kind` (`"text"` or `"binary"`) |
| `websocket_closed` | `id`, `code`, `reason` |

`id` is the connection's `conn.id`, so one program can listen to several
connections at once.

### Secure connections (wss://)

OpenComputers' internet card only offers plain TCP, so the encryption runs in
Lua, using [libtls13](https://github.com/OpenPrograms/Fingercomp-Programs/tree/master/libtls13)
by Fingercomp. Install it with `oppm install libtls13`, fit at least a
**tier 2 data card**, and connect with a `wss://` URL:

```lua
local conn = assert(ws.connect("wss://example.com/socket"))
```

> [!WARNING]
> libtls13 encrypts the connection but does **not** check the server's
> certificate against certificate authorities. Without a pin (below),
> anyone who can intercept the traffic can pretend to be your server.

To make sure you reached your own server, pin its certificate. Get the
fingerprint on any machine with OpenSSL:

```sh
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

and pass it in, colons and all:

```lua
local conn, err = ws.connect("wss://example.com/socket", {
  tls = { fingerprint = "AB:CD:EF:...:12" },
})
```

A connection to any other certificate fails, and the error shows the
fingerprint it got. You can also connect once without a pin and read
`conn.fingerprint`. A pinned certificate has to be updated when the server
renews it.

Which servers work:

* **TLS 1.3 only.** Servers that only speak TLS 1.2 refuse the connection.
* **RSA and P-384 certificates** work with a tier 2 data card. **P-256
  certificates** need a **tier 3** data card. P-256 is common (Cloudflare,
  and Let's Encrypt's ECDSA certificates use it), so a tier 3 card is the
  safe choice.

### Closing

```lua
conn:close()                       -- code 1000, normal closure
conn:close(4000, "shutting down")  -- your own code (3000-4999) and reason
```

`close` tells the server and waits up to 3 seconds (`closeTimeout`) for it to
agree. After a close, from either side, `receive` returns
`nil, "closed", code, reason`. The code is **1006** when the connection
dropped without a proper close.

## API reference

### `ws.connect(url [, options]) -> conn | nil, err`

Opens a connection and waits until it is ready.

| Option | Default | Meaning |
| --- | --- | --- |
| `timeout` | `10` | Seconds allowed for connecting and the handshake. |
| `headers` | none | Table of extra request headers. |
| `protocols` | none | List of subprotocols to offer. |
| `maxMessageSize` | `1048576` | Largest message accepted, in bytes. A larger one closes the connection with code 1009. |
| `closeTimeout` | `3` | Seconds `close()` waits for the server. |
| `sendTimeout` | `10` | Seconds `send()` waits when the network is backed up. |
| `onPong` | none | `function(payload)` called for each pong. |
| `internet` | primary card | Internet card component proxy to use. |
| `tls` | none | For `wss://`: `{ fingerprint = "..." }` to pin the server certificate. |

### Connection methods

| Method | Returns | |
| --- | --- | --- |
| `conn:send(data [, binary])` | `true` or `nil, err` | Sends text, or binary when `binary` is `true`. |
| `conn:receive([timeout])` | `data, kind` / `nil, "timeout"` / `nil, "closed", code, reason` | Waits for the next message. No timeout waits forever. |
| `conn:poll()` | same as `receive` | Returns a message only if one has already arrived. |
| `conn:ping([data])` | `true` or `nil, err` | Sends a ping (up to 125 bytes). |
| `conn:close([code [, reason]])` | `true` | Closes the connection. |
| `conn:listen()` | | Delivers messages as OpenOS events instead of through `receive`. |
| `conn:isOpen()` | `boolean` | Whether messages can be sent. |

### Connection fields

| Field | |
| --- | --- |
| `conn.id` | Identifies the connection in events. |
| `conn.state` | `"open"`, `"closing"` or `"closed"`. |
| `conn.protocol` | The subprotocol the server chose, if any. |
| `conn.headers` | The server's handshake response headers (lower-case names). |
| `conn.fingerprint` | For `wss://`: the server certificate's SHA-256 fingerprint. |
| `conn.closeCode`, `conn.closeReason` | Why the connection closed. |

## Compatibility

* **Lua 5.3**, the default architecture. The Lua 5.2 architecture cannot load
  oc-ws. Tested with OpenOS from OpenComputers 1.8.
* **An internet card** with TCP enabled.
* **Local and private addresses are blocked by default.** OpenComputers
  refuses connections to `127.0.0.1`, `192.168.x.x` and other private ranges.
  To reach a server on the same machine or your LAN, add an allow rule ahead
  of `"deny private"` in the `filteringRules` list of `opencomputers.cfg`,
  e.g. `"allow ip:192.168.1.10"`.
* **`wss://`** needs libtls13 and a tier 2 data card, or tier 3 for P-256
  certificates. See [Secure connections](#secure-connections-wss).
* **No compression.** oc-ws does not offer the `permessage-deflate`
  extension, so servers send uncompressed messages.

### Conformance

The [Autobahn testsuite](https://github.com/crossbario/autobahn-testsuite) runs
against oc-ws in CI. Of its 247 client cases, 240 pass outright, 3 are
informational, and 4 are marked non-strict (6.4.1 to 6.4.4: invalid UTF-8 is
caught when the frame completes, not partway through it). None fail. The
performance cases (9.x) and the compression cases (12.x, 13.x) are not run.

## Upgrading from v1

v2 changes the API. The old one is still available as
[v1.0.0](https://github.com/bluescorpian/oc-ws/releases/tag/v1.0.0).

| v1 | v2 |
| --- | --- |
| `WebSocket.new({address, port, path})`, then call `finishConnect()` until it returns true | `ws.connect("ws://address:port/path")` |
| `ws:readMessage()` in a loop with `event.pull` | `conn:receive(timeout)`, `conn:poll()` or `conn:listen()` |
| `MESSAGE_TYPES.TEXT`, `PING`, `PONG`, `CLOSE` | `kind` is `"text"` or `"binary"`; pings are answered for you; a close shows up as `nil, "closed", code, reason` |
| `ws:pong(data)` | not needed |
| `READY_STATES` numbers | `conn.state` strings |

## Development

The tools come from a Nix dev shell (`nix develop`, or `direnv allow`).

```sh
nix develop -c luacheck .                # lint
nix develop -c busted tests/unit         # unit tests, under a second
nix develop -c tests/autobahn/run.sh     # Autobahn suite (needs Docker)
nix develop -c tests/tls/run.sh          # wss:// against a local TLS 1.3 server
nix develop .#ocemu -c tests/ocemu/run.sh  # boots OpenOS in OCEmu
```

The unit tests and the Autobahn and TLS runs execute oc-ws on desktop Lua
5.3, with the internet card replaced: by an in-memory fake for the unit
tests, and by LuaSocket for the others. The OCEmu run is the one that
exercises the real OpenOS.

## License

oc-ws is released under the [MIT License](LICENSE).

## Credits

[feldim2425's websocket_client](https://github.com/feldim2425/OC-Programs/tree/master/websocket_client)
helped with the first version, and `wss://` is built on Fingercomp's
[libtls13](https://github.com/OpenPrograms/Fingercomp-Programs/tree/master/libtls13).
