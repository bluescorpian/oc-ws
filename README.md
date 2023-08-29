# oc-ws:

oc-ws is a WebSocket server and client library designed to facilitate seamless communication between Node.js applications and OpenComputers systems.

## Installation

To get started with oc-ws, simply install the package using npm:

```bash
npm install oc-ws
```

## Usage

### Setting Up a WebSocket Server

```javascript
import { WebSocketServer } from 'oc-ws';

const server = new WebSocketServer();

server.on('connection', (ws) => {
	console.log('New WebSocket connection established.');

	ws.on('message', (message) => {
		console.log('Received message:', message);
		ws.send('Message received: ' + message);
	});

	ws.on('close', () => {
		console.log('WebSocket connection closed.');
	});
});

server.listen(8080, () => {
	console.log('WebSocket server is listening on port 8080.');
});
```

## License

This project is licensed under the [AGPL-3.0-or-later](https://www.gnu.org/licenses/agpl-3.0.en.html) license.
