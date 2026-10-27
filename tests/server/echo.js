// wss:// echo server for tests/tls/run.sh. Usage: node tls-echo.js <key> <cert> <port>
import { readFileSync } from 'fs';
import { createServer } from 'https';
import { WebSocketServer } from 'ws';

const [key, cert, port] = process.argv.slice(2);
const server = createServer({ key: readFileSync(key), cert: readFileSync(cert), minVersion: 'TLSv1.3' });
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
	ws.on('message', (data, isBinary) => ws.send(data, { binary: isBinary }));
});

server.listen(Number(port), '127.0.0.1', () => console.log(`listening on ${port}`));
