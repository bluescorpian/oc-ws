// Echo server for the OCEmu and wss:// checks.
// Usage: node echo.js <port> [<key> <cert>]   (with key and cert it serves wss://)
import { readFileSync } from 'fs';
import { createServer as createHttp } from 'http';
import { createServer as createHttps } from 'https';
import { WebSocketServer } from 'ws';

const [port, key, cert] = process.argv.slice(2);
const server = key
	? createHttps({ key: readFileSync(key), cert: readFileSync(cert), minVersion: 'TLSv1.3' })
	: createHttp();
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
	ws.on('message', (data, isBinary) => ws.send(data, { binary: isBinary }));
});

server.listen(Number(port), '127.0.0.1', () => console.log(`listening on ${port}`));
