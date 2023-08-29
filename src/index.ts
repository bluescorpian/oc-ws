import net from 'net';
import { EventEmitter } from 'events';

export class WebSocketServer extends EventEmitter {
	private tcpServer: net.Server;
	clients: WebSocket[];

	constructor() {
		super();

		this.tcpServer = net.createServer((socket) => {
			this.handleConnection(socket);
		});

		/**
		 * An array of WebSocket client instances.
		 * @type {WebSocket[]}
		 */
		this.clients = [];
	}

	private handleConnection(socket: net.Socket) {
		const ws = new WebSocket(socket);
		this.clients.push(ws);

		/**
		 * Emitted when a new WebSocket connection is established.
		 * @event WebSocketServer#connection
		 * @param {WebSocket} ws - The WebSocket instance representing the new connection.
		 */
		this.emit('connection', ws);
	}

	/**
	 * Starts listening on the specified port for incoming WebSocket connections.
	 * @param {number} port - The port to listen on.
	 * @param {Function} [cb] - A callback function to execute when the server starts listening.
	 * @returns {WebSocketServer} The WebSocketServer instance.
	 */
	listen(port: number, cb?: () => void): WebSocketServer {
		this.tcpServer.listen(port, cb);
		return this;
	}

	/**
	 * Closes the WebSocket server.
	 * @returns {WebSocketServer} The WebSocketServer instance.
	 */
	close(): WebSocketServer {
		this.tcpServer.close();
		return this;
	}
}

export class WebSocket extends EventEmitter {
	private socket: net.Socket;
	messageLength: number | null = null;
	messageChunk: Buffer = Buffer.alloc(0);

	constructor(socket: net.Socket) {
		super();
		this.socket = socket;

		socket.on('data', (data) => {
			this.handleData(data);
		});
		socket.on('error', (err) => {
			/**
			 * Emitted when an error occurs on the WebSocket connection.
			 * @event WebSocket#error
			 * @param {Error} err - The error object.
			 */
			this.emit('error', err);
		});

		socket.on('close', () => {
			/**
			 * Emitted when the WebSocket connection is closed.
			 * @event WebSocket#close
			 */
			this.emit('close');
		});
	}

	private handleData(data: Buffer) {
		try {
			let dataIndex = 0;

			while (dataIndex < data.length) {
				// If not currently processing a message chunk, read the next message length
				if (this.messageLength === null) {
					if (data.length - dataIndex < 4) break; // Insufficient data to read message length

					this.messageLength = data.readUInt32BE(dataIndex);
					dataIndex += 4;
					this.messageChunk = Buffer.alloc(0);
				}

				const chunkToAdd = data.subarray(
					dataIndex,
					dataIndex + (this.messageLength - this.messageChunk.length)
				);
				this.messageChunk = Buffer.concat([this.messageChunk, chunkToAdd]);
				dataIndex += chunkToAdd.length;

				if (this.messageChunk.length >= this.messageLength) {
					/**
					 * Emitted when a complete message is received on the WebSocket connection.
					 * @event WebSocket#message
					 * @param {string} message - The received message.
					 */
					this.emit('message', this.messageChunk.toString());
					this.messageChunk = Buffer.alloc(0);
					this.messageLength = null;
				}
			}
		} catch (err) {
			this.emit('error', err);
		}
	}

	/**
	 * Sends a message over the WebSocket connection.
	 * @param {string} data - The message to send.
	 * @returns {boolean} Returns true if the write operation was successful, false otherwise.
	 */
	send(data: string): boolean {
		const lengthBuffer = Buffer.alloc(4);
		lengthBuffer.writeUInt32BE(data.length);

		return this.socket.write(Buffer.concat([lengthBuffer, Buffer.from(data)]));
	}

	/**
	 * Destroys the WebSocket connection.
	 * @returns {WebSocket} The WebSocket instance.
	 */
	destroy(): WebSocket {
		this.socket.destroy();
		return this;
	}
}
