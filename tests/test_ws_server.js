import { WebSocketServer } from 'ws';
import readline from 'readline';

const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', function connection(ws) {
	console.log('Connection opened');
	ws.on('error', console.error);

	ws.on('message', (data) => {
		console.log('received: %s', data);
	});

	ws.once('close', () => {
		console.log('Connection closed');
		rl.off('line', handleLine);
	});

	ws.on('ping', () => {
		console.log('Ping');
		ws.pong();
	});
	ws.on('pong', () => {
		console.log('Pong');
	});

	ws.send('Hello from server!');

	const rl = readline.createInterface({
		input: process.stdin,
		output: process.stdout,
	});

	function handleLine(input) {
		ws.send(input);
	}

	rl.on('line', handleLine);

	ws.ping();
});

console.log('Server listening on port 8080');
