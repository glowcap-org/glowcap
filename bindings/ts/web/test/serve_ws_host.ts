// The accepting half of the web-peer proof: a keyed OCapN host (dlopen stack,
// native archives) that accepts WebSocket connections directly, the ADR-0070
// Milestone 1 server shape. Each accepted socket is one byte channel; the
// stack's `Session.establishAccepted` drives the keyed handshake over it
// exactly as over an accepted TCP socket, so the WebSocket is a bearer, not a
// protocol translator.
//
// Started by `web_peer_test.ts`; prints one READY line of JSON (port and key
// designator) once the HTTP server is listening.

import {
	type Channel,
	Host,
	type Ref,
	Session,
	socketAddrDesignator,
	TRANSPORT_KEYED_TCP,
} from "@pancake/stack";

const seed = new Uint8Array(32).fill(0x5a);
const host = new Host(seed);
const designator = host.designator();

/** Adapt one accepted WebSocket to the stack's byte-channel seam. */
function channelOf(ws: WebSocket): Channel {
	const chunks: Uint8Array[] = [];
	let waiter: ((chunk: Uint8Array | null) => void) | null = null;
	let closed = false;
	ws.binaryType = "arraybuffer";
	ws.onmessage = (event: MessageEvent) => {
		const chunk = new Uint8Array(event.data as ArrayBuffer);
		if (waiter !== null) {
			const w = waiter;
			waiter = null;
			w(chunk);
		} else {
			chunks.push(chunk);
		}
	};
	ws.onclose = ws.onerror = () => {
		closed = true;
		if (waiter !== null) {
			const w = waiter;
			waiter = null;
			w(null);
		}
	};
	return {
		read(): Promise<Uint8Array | null> {
			const buffered = chunks.shift();
			if (buffered !== undefined) return Promise.resolve(buffered);
			if (closed) return Promise.resolve(null);
			return new Promise((r) => {
				waiter = r;
			});
		},
		write(data: Uint8Array): Promise<void> {
			ws.send(data as Uint8Array<ArrayBuffer>);
			return Promise.resolve();
		},
		close(): void {
			closed = true;
			try {
				ws.close();
			} catch {
				// already closed
			}
		},
	};
}

/** Serve one WebSocket-accepting host: each upgraded socket becomes a keyed
 * accepted session on `acceptingHost`, publishing the greeter. */
function serveHost(acceptingHost: Host, hostDesignator: string): Deno.HttpServer<Deno.NetAddr> {
	const server: Deno.HttpServer<Deno.NetAddr> = Deno.serve(
		{ hostname: "127.0.0.1", port: 0 },
		(request) => {
			if (request.headers.get("upgrade") !== "websocket") {
				return new Response("pancake web-peer test host", { status: 200 });
			}
			const { socket, response } = Deno.upgradeWebSocket(request);
			socket.onopen = () => {
				void (async () => {
					const session = await Session.establishAccepted(
						acceptingHost,
						TRANSPORT_KEYED_TCP,
						hostDesignator,
						channelOf(socket),
						socketAddrDesignator("127.0.0.1", server.addr.port),
					);
					// The browser peer fetches this by name, and its `greet`
					// exercises the reverse direction too: the callback ref the
					// caller passes is an object the *browser* hosts, so the tell
					// below runs the wasm module's behavior trampoline far side.
					session.publish("greeter", (verb, args) => {
						if (verb !== "greet") throw new Error(`unknown verb ${verb}`);
						const name = args[0] as string;
						const callback = args[1] as Ref | undefined;
						if (
							callback instanceof Object && callback !== null &&
							"reference" in callback
						) {
							void session.tell(callback as Ref, "notify", [`saw ${name}`]);
						}
						return `hello ${name}`;
					});
					session.serve().catch(() => {});
				})();
			};
			return response;
		},
	);
	return server;
}

const server = serveHost(host, designator);

// A second host on the Cap'n Proto grammar, so the proof covers the wasm
// peer negotiating and running the second codec too.
const capnpSeed = new Uint8Array(32).fill(0x6b);
const capnpHost = new Host(capnpSeed, { codec: "capnp" });
const capnpDesignator = capnpHost.designator();
const capnpServer = serveHost(capnpHost, capnpDesignator);

console.log(JSON.stringify({
	ready: true,
	port: server.addr.port,
	designator,
	capnpPort: capnpServer.addr.port,
	capnpDesignator,
}));
