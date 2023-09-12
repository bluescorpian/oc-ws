import net from 'net';

const server = net.createServer((socket) => {
	console.log('Connection received');
	socket.on('error', (err) => {
		console.error(`Socket error: ${err.message}`);
	});

	socket.on('data', (data) => {
		console.log('Data received: %s', data.toString());
	});

	// const interval = setInterval(() => {
	// 	console.log('Sending message');
	// 	// socket.write(Math.random().toString());
	// }, 5000);

	setTimeout(() => {
		socket.write('Hello World!');
		console.log('Sent message');
	}, 2000);

	socket.on('end', () => {
		console.log('Connection terminated');
		// clearInterval(interval);
	});
});

const PORT = 8080;
const HOST = '127.0.0.1';

server.listen(PORT, undefined, () => {
	console.log(`Server listening on ${HOST}:${PORT}`);
});
