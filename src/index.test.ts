import { WebSocket, WebSocketServer } from '.';
import net from 'net';

const PORT = 3000;

let wss: WebSocketServer;
let ws: WebSocket;
let client: net.Socket;

beforeEach(() => {
	return new Promise<void>((res) => {
		wss = new WebSocketServer();
		wss.once('connection', (websocket: WebSocket) => {
			ws = websocket;
			res();
		});
		client = net.createConnection({
			host: 'localhost',
			port: PORT,
		});
		wss.listen(PORT);
	});
});

afterEach(() => {
	client.destroy();
	ws.destroy();
	wss.close();
});

test('WebSocket Message Splitting', () => {
	return new Promise<void>((res, rej) => {
		const messages: string[] = ['Hello,', 'world!', 'This is', 'a test.'];

		client.on('data', (data) => {
			client.write(data);
		});

		let msgIndex = 0;
		ws.on('message', (msg) => {
			expect(msg).toBe(messages[msgIndex]);
			msgIndex++;

			if (msgIndex >= messages.length) res();
		});

		ws.once('error', rej);

		messages.forEach((m) => ws.send(m));
	});
});
