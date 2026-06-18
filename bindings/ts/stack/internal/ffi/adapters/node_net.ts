// Internal: the `node:net` socket seam, shared by the Bun and Node adapters.
//
// Bun and Node both implement `node:net`, so one event-driven adapter serves
// both. It bridges Node's push-style socket (`'data'`/`'end'`/`'error'` events)
// to the pull-style `NetConn.read()` the async pump wants: the socket is kept
// paused and resumed one read at a time, so inbound bytes are bounded by the
// pump's pace rather than buffered without limit.

// @ts-nocheck — typed against node:net's ambient types, present under Bun/Node.
import { connect as netConnect, createServer, type Server, type Socket } from "node:net";
import type { NetConn, NetListener } from "../runtime.ts";

/** A `NetConn` over one `node:net` socket. Reads pull one chunk at a time. */
export class SocketConn implements NetConn {
	#socket: Socket;
	#pending: Uint8Array[] = [];
	#wake: (() => void) | null = null;
	#ended = false;
	#error: Error | null = null;
	#addr: { hostname: string; port: number };

	constructor(socket: Socket) {
		this.#socket = socket;
		this.#addr = {
			hostname: socket.localAddress ?? "127.0.0.1",
			port: socket.localPort ?? 0,
		};
		socket.pause();
		socket.on("data", (d: Uint8Array) => {
			this.#pending.push(d);
			this.#signal();
		});
		socket.on("end", () => {
			this.#ended = true;
			this.#signal();
		});
		socket.on("close", () => {
			this.#ended = true;
			this.#signal();
		});
		socket.on("error", (e: Error) => {
			this.#error = e;
			this.#ended = true;
			this.#signal();
		});
	}

	#signal(): void {
		const w = this.#wake;
		if (w !== null) {
			this.#wake = null;
			w();
		}
	}

	#drain(): Uint8Array {
		if (this.#pending.length === 1) {
			const only = this.#pending[0];
			this.#pending = [];
			return only;
		}
		let total = 0;
		for (const c of this.#pending) total += c.length;
		const grown = new Uint8Array(total);
		let off = 0;
		for (const c of this.#pending) {
			grown.set(c, off);
			off += c.length;
		}
		this.#pending = [];
		return grown;
	}

	async read(): Promise<Uint8Array | null> {
		if (this.#error !== null) throw this.#error;
		if (this.#pending.length > 0) return this.#drain();
		if (this.#ended) return null;
		this.#socket.resume();
		await new Promise<void>((res) => {
			this.#wake = res;
		});
		this.#socket.pause();
		if (this.#error !== null) throw this.#error;
		if (this.#pending.length > 0) return this.#drain();
		return null; // clean end of stream
	}

	write(data: Uint8Array): Promise<void> {
		return new Promise<void>((res, rej) => {
			this.#socket.write(
				data,
				(err?: Error | null) => (err ? rej(err) : res()),
			);
		});
	}

	close(): void {
		try {
			this.#socket.destroy();
		} catch {
			// already closed
		}
	}

	localAddr(): { hostname: string; port: number } {
		return this.#addr;
	}
}

export function socketConnect(host: string, port: number): Promise<NetConn> {
	return new Promise<NetConn>((res, rej) => {
		const socket = netConnect({ host, port });
		socket.once("connect", () => res(new SocketConn(socket)));
		socket.once("error", rej);
	});
}

/** A `NetListener` over a `node:net` server. Accepted sockets queue until
 * `accept()` pulls them, so a slow consumer never drops a partner. */
class ServerListener implements NetListener {
	#server: Server;
	readonly port: number;
	#queue: Socket[] = [];
	#wake: (() => void) | null = null;
	#closed = false;

	constructor(server: Server, port: number) {
		this.#server = server;
		this.port = port;
		server.on("connection", (socket: Socket) => {
			this.#queue.push(socket);
			const w = this.#wake;
			if (w !== null) {
				this.#wake = null;
				w();
			}
		});
		server.on("close", () => {
			this.#closed = true;
			const w = this.#wake;
			if (w !== null) {
				this.#wake = null;
				w();
			}
		});
	}

	async accept(): Promise<NetConn> {
		for (;;) {
			const socket = this.#queue.shift();
			if (socket !== undefined) return new SocketConn(socket);
			if (this.#closed) throw new Error("listener closed");
			await new Promise<void>((res) => {
				this.#wake = res;
			});
		}
	}

	close(): void {
		this.#closed = true;
		try {
			this.#server.close();
		} catch {
			// already closed
		}
	}
}

export function socketListen(host: string, port: number): Promise<NetListener> {
	return new Promise<NetListener>((res, rej) => {
		const server = createServer();
		server.once("error", rej);
		server.listen(port, host, () => {
			const addr = server.address();
			const bound = addr !== null && typeof addr === "object" ? addr.port : port;
			res(new ServerListener(server, bound));
		});
	});
}
