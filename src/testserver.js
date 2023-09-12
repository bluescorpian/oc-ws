import { WebSocketServer } from 'ws';

const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', (ws) => {
	ws.on('error', console.error);

	ws.on('message', function message(data) {
		console.log('received: %s', data);
	});

	const interval = setInterval(() => {
		ws.send(Math.random().toString());
	}, 1000);

	ws.on('close', () => {
		clearInterval(interval);
	});
});
