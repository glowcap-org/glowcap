// The accepting half of the web-peer proof: a keyed OCapN host (dlopen runtime,
// FFI archives) that accepts connections, either WebSocket (default, ADR-0034)
// or TCP (for relay tests). Each accepted socket is one byte
// channel; the runtime's `Session.establishAccepted` drives the keyed handshake
// over it, so the transport is a bearer, not a protocol translator.
//
// Flags:
//   --tcp-only: Listen on TCP instead of WebSocket (for relay tests)
//   address: TCP bind address (host:port, e.g. 127.0.0.1:0); ignored for WebSocket

import { type Channel, Host, Ref, Session, TRANSPORT_KEYED_TCP } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import { webSocketChannel } from "@glowcap/runtime";
import { DESIGNATOR_SCHEME_KEY } from "@glowcap/abi";

const tcpOnly = Deno.args.includes("--tcp-only");
const addressArg = Deno.args.find((a) => !a.startsWith("-"));

/** Wrap Deno.Conn to match the Channel interface. */
function wrapTcpConn(conn: Deno.Conn): Channel {
	return {
		async read(): Promise<Uint8Array | null> {
			const buf = new Uint8Array(64 * 1024);
			const n = await conn.read(buf);
			return n === null ? null : buf.subarray(0, n);
		},
		async write(data: Uint8Array): Promise<void> {
			let off = 0;
			while (off < data.length) off += await conn.write(data.subarray(off));
		},
		close(): void {
			try {
				conn.close();
			} catch {
				// already closed
			}
		},
	};
}

const seed = new Uint8Array(32).fill(0x5a);
const host = new Host(seed);
const designator = host.designator();

/** Serve one WebSocket-accepting host: each upgraded socket becomes a keyed
 * accepted session on `acceptingHost`, publishing the greeter. */
function serveHost(acceptingHost: Host, hostDesignator: string): Deno.HttpServer<Deno.NetAddr> {
	const server: Deno.HttpServer<Deno.NetAddr> = Deno.serve(
		{ hostname: "127.0.0.1", port: 0 },
		(request) => {
			if (request.headers.get("upgrade") !== "websocket") {
				return new Response("glowcap web-peer test host", { status: 200 });
			}
			const { socket, response } = Deno.upgradeWebSocket(request);
			socket.onopen = () => {
				void (async () => {
					const session = await Session.establishAccepted(
						acceptingHost,
						{
							transport: TRANSPORT_KEYED_TCP,
							designatorScheme: DESIGNATOR_SCHEME_KEY,
							serverDesignator: hostDesignator,
							channel: webSocketChannel(socket),
							localAddress: tcp.addressDesignator("127.0.0.1", server.addr.port),
						},
					);
					// The browser peer fetches this by name, and its `greet`
					// exercises the reverse direction too: the callback ref the
					// caller passes is an object the *browser* hosts, so the tell
					// below runs the wasm module's behavior trampoline far side.
					session.publish("greeter", (verb, args) => {
						if (verb !== "greet") throw new Error(`unknown verb ${verb}`);
						const name = args[0] as string;
						const callback = args[1];
						if (callback instanceof Ref) {
							void session.tell(callback, "notify", [`saw ${name}`]);
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

/** Serve one TCP-accepting host: each accepted connection becomes a keyed
 * session over a raw byte channel. */
async function serveTcpHost(
	acceptingHost: Host,
	hostDesignator: string,
	address: string,
): Promise<Deno.Listener> {
	const [host, portStr] = address.split(":");
	const port = portStr === "0" ? 0 : Number(portStr);
	const listener = await Deno.listen({ hostname: host, port });

	(async () => {
		for await (const conn of listener) {
			void (async () => {
				try {
					const session = await Session.establishAccepted(
						acceptingHost,
						{
							transport: TRANSPORT_KEYED_TCP,
							designatorScheme: DESIGNATOR_SCHEME_KEY,
							serverDesignator: hostDesignator,
							channel: wrapTcpConn(conn),
							localAddress: tcp.addressDesignator(
								host,
								(listener.addr as Deno.NetAddr).port,
							),
						},
					);
					session.publish("greeter", (verb, args) => {
						if (verb !== "greet") throw new Error(`unknown verb ${verb}`);
						const name = args[0] as string;
						const callback = args[1];
						if (callback instanceof Ref) {
							void session.tell(callback, "notify", [`saw ${name}`]);
						}
						return `hello ${name}`;
					});
					session.serve().catch(() => {});
				} catch (err) {
					console.error(`session error: ${err}`);
				}
			})();
		}
	})().catch(() => {});

	return listener;
}

if (tcpOnly) {
	// TCP-only mode (for relay tests): one listener, no Cap'n Proto variant.
	const listener = await serveTcpHost(host, designator, addressArg || "127.0.0.1:0");
	const addr = listener.addr as Deno.NetAddr;
	console.log(JSON.stringify({
		ready: true,
		port: addr.port,
		designator,
		capnpPort: 0,
		capnpDesignator: "",
	}));
} else {
	// WebSocket mode (default): HTTP servers for both Syrup and Cap'n Proto.
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
}
