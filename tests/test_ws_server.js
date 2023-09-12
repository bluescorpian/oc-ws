import { WebSocketServer } from 'ws';

const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', function connection(ws) {
	console.log('Connection opened');
	ws.on('error', console.error);

	ws.on('message', function message(data) {
		console.log('received: %s', data);
	});
	ws.on('close', () => {
		console.log('Connection closed');
		clearInterval(interval);
	});

	ws.on('ping', () => {
		console.log('Ping');
		ws.pong();
	});
	ws.on('pong', () => console.log('Pong'));

	ws.send('Hello World!');

	const interval = setInterval(() => {
		ws.ping();
	}, 5000);
});

console.log('Server listening on port 8080');
