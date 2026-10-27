// Host side of the in-game check (tests/ingame/run.sh): serves the files the
// OpenComputers computer installs, and echo servers for it to talk to.
//   http://127.0.0.1:8000/   files under <filesDir>
//   ws://127.0.0.1:8080/     plain echo
//   wss://127.0.0.1:8443/    echo with the RSA certificate
//   wss://127.0.0.1:8444/    echo with the P-256 certificate (needs a tier 3 data card)
// Usage: node ingame.js <filesDir> <certDir>
import { readFileSync, statSync } from 'fs';
import { createServer as createHttp } from 'http';
import { createServer as createHttps } from 'https';
import { join, normalize } from 'path';
import { WebSocketServer } from 'ws';

const [filesDir, certDir] = process.argv.slice(2);
const host = '127.0.0.1';

createHttp((req, res) => {
	const path = normalize(join(filesDir, decodeURIComponent(req.url.split('?')[0])));
	try {
		if (!path.startsWith(normalize(filesDir)) || !statSync(path).isFile()) throw new Error();
		console.log(`file  ${req.url}`);
		// A Content-Length rather than chunked encoding: OCEmu's HTTP client
		// returns an empty body for chunked responses.
		const body = readFileSync(path);
		res.writeHead(200, { 'Content-Length': body.length }).end(body);
	} catch {
		res.writeHead(404).end('not found\n');
	}
}).listen(8000, host);

function echo(server, label) {
	new WebSocketServer({ server }).on('connection', (ws) => {
		console.log(`${label} connection`);
		ws.on('message', (data, isBinary) => ws.send(data, { binary: isBinary }));
		ws.on('close', (code) => console.log(`${label} closed ${code}`));
	});
}

const plain = createHttp();
echo(plain, 'ws   ');
plain.listen(8080, host);

for (const [name, port] of [['rsa', 8443], ['p256', 8444]]) {
	const server = createHttps({
		key: readFileSync(join(certDir, `${name}.key`)),
		cert: readFileSync(join(certDir, `${name}.pem`)),
		minVersion: 'TLSv1.3',
	});
	echo(server, `wss/${name}`);
	server.listen(port, host);
}

console.log('serving on 127.0.0.1: files :8000, ws :8080, wss RSA :8443, wss P-256 :8444');
