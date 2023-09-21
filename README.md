# oc-ws

**oc-ws** a WebSocket library for OpenComputers.

## Installation

To use oc-ws in your OpenComputers project, follow these steps:

1. Download the oc-ws library file from the [GitHub repository](https://github.com/bluescorpian/oc-ws).

2. Save the `ws.lua` file in your OpenComputers project directory.

3. In your OpenComputers program, import the oc-ws library using the `require` function:

   ```lua
   local WebSocket = require("ws")
   ```

## Usage

Here's a basic example of how to create a WebSocket client and send a message using oc-ws:

```lua
-- Import the oc-ws library
local WebSocket = require("ws")

-- Create a new WebSocket instance
local ws = WebSocket.new({
    address = "ws://example.com",
    port = 80,
    path = "/websocket",
})

-- Connect to the WebSocket server
while true do
	local connected, err = socket:finishConnect()
	if connected then break end
	if err then return print('Failed to connect: ' .. err) end
	if event.pull(1) == 'interrupted' then return end
end
print("Connected to WebSocket server!")

-- Send a message
ws:send("Hello, WebSocket!")

-- Read incoming messages
while true do
	local messageType, message, err = ws:readMessage()
	if err then return print('Websocket Error: ' .. err) end
	if messageType == WebSocket.MESSAGE_TYPES.TEXT then
		print('Message Received: ' .. message)
	elseif messageType == WebSocket.MESSAGE_TYPES.PING then
		print('Ping')
		ws:pong(message)
	elseif messageType == WebSocket.MESSAGE_TYPES.PONG then
		print('Pong')
	end

	if event.pull(5) == 'interrupted' then return end
end


-- Close the WebSocket connection when done
ws:close()
```

## License

oc-ws is licensed under the [GNU Affero General Public License (AGPL)](https://www.gnu.org/licenses/agpl-3.0.html).

## Credits

I used [feldim2425](https://github.com/feldim2425/OC-Programs/tree/master/websocket_client) project to help with my implementation.
