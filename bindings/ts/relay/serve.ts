// The runnable Deno reference relay for the ADR-0086 contract — the first-party
// consumer of this package's own `webSocketRelay`, and the Deno row of the
// cross-runtime relay matrix beside `bindings/python/relay.py` and
// `bindings/rust/relay`. It carries the raw bytes of a keyed CapTP session
// between a browser peer's WebSocket and a native host without parsing them, so
// the keyed handshake and session authority run end to end and the relay holds
// no capability.
//
// Three legs, dispatched by what the WebSocket names:
//   - `?to=host:port`         a raw TCP socket (kernel-backpressured).
//   - `?locator=<ocapn-uri>`  an iroh byte channel dialed through @pancake/iroh's
//                             `dialLocatorForRelay`.
//   - `?rendezvous=<id>`      a bridge onto the inbound socket a non-listening
//                             peer registered under its key designator at
//                             `/register?id=<id>` (the ADR-0088 cold-dial leg).
//
// Run it directly; it prints `DENO-RELAY-READY <port>` on stdout once listening:
//     deno run --allow-net --allow-ffi --allow-env --allow-read \
//         bindings/ts/relay/serve.ts <listen-port>
//
// The embedding app adds the target allow-list and capacity admission (see the
// rooms relay in apps/rooms/web/relay.ts); this reference relays wherever
// it is pointed so the conformance proofs can drive it.

import {
	denoIrohChannel,
	denoTcpChannel,
	type RelayConfig,
	Rendezvous,
	webSocketRelay,
} from "@pancake/relay";

// Liveness is the idle timeout; the per-session byte total is a runaway backstop
// over the session's life, not a memory bound (instantaneous memory is bounded
// by the backpressure on both legs). Both are set far above any real session.
// The conformance idle-timeout proof sets `PANCAKE_RELAY_IDLE_MS` low; a
// production run leaves it unset and gets the 60s default.
function idleTimeoutMsFromEnv(): number {
	try {
		const override = Deno.env.get("PANCAKE_RELAY_IDLE_MS");
		if (override) return Number(override);
	} catch {
		// no --allow-env; fall through to the default
	}
	return 60_000;
}
const relayConfig: RelayConfig = {
	idleTimeoutMs: idleTimeoutMsFromEnv(),
	maxBytesPerSession: 1024 * 1024 * 1024, // 1 GiB
};

// The cold-dial rendezvous table (ADR-0088): identity → held inbound sockets.
// The registration cap is the bounded-resources posture the other legs carry
// through `relayConfig`: a flood of fresh identities cannot pin unbounded held
// sockets. An identity already holding a socket replenishes its own queue
// freely (the embedding app adds per-identity policy, as with the allow-list).
const rendezvous = new Rendezvous();
const max_registrations = 64;

/** Dispatch one upgraded WebSocket to the channel its query names, then hand it
 * to the shared byte pump. One of `?to=host:port`, `?locator=<uri>`, or
 * `?rendezvous=<id>` must be present; the dials are @pancake/relay's shared,
 * hardened channel factories, and a rendezvous is a bridge onto a held
 * registered socket. */
function relay(socket: WebSocket, query: URLSearchParams): void {
	const to = query.get("to");
	const locator = query.get("locator");
	const rendezvous_id = query.get("rendezvous");
	if (rendezvous_id !== null) {
		// Take only after the upgrade succeeded: `take` removes the registration,
		// and a refusal that consumed it would strand the registered peer's held
		// socket (nothing closes it, so its accept parks and the pool never
		// replenishes).
		const held = rendezvous.take(rendezvous_id);
		if (held === undefined) {
			socket.close(1011, "rendezvous: peer not registered");
			return;
		}
		void webSocketRelay(
			socket,
			() => Promise.resolve(held),
			"rendezvous: registered peer went away",
			relayConfig,
		);
		return;
	}
	if (locator !== null) {
		void webSocketRelay(
			socket,
			() => denoIrohChannel(locator, "direct"),
			"iroh relay dial failed",
			relayConfig,
		);
		return;
	}
	if (to !== null) {
		const colon = to.lastIndexOf(":");
		const port = colon === -1 ? NaN : Number(to.slice(colon + 1));
		if (Number.isInteger(port) && port >= 1 && port <= 65535) {
			const host = to.slice(0, colon);
			void webSocketRelay(
				socket,
				() => denoTcpChannel(host, port),
				"TCP relay target unreachable",
				relayConfig,
			);
			return;
		}
	}
	socket.close(1008, "relay requires ?to=host:port or ?locator=<uri>");
}

const listenPort = Number(Deno.args[0] ?? "0");

Deno.serve({
	hostname: "127.0.0.1",
	port: listenPort,
	onListen: ({ port }) => console.log(`DENO-RELAY-READY ${port}`),
}, (req) => {
	const url = new URL(req.url);
	// RFC 6455 makes the Upgrade token case-insensitive, and clients disagree
	// on the casing (net/rfc6455 sends "WebSocket").
	if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
		return new Response("relay only", { status: 404 });
	}
	if (url.pathname === "/register") {
		const id = url.searchParams.get("id");
		if (id === null) return new Response("register requires ?id=<designator>", { status: 400 });
		if (!rendezvous.has(id) && rendezvous.registered().length >= max_registrations) {
			return new Response("rendezvous capacity exceeded", { status: 503 });
		}
		const { socket, response } = Deno.upgradeWebSocket(req);
		// Register at once, not at onopen: the wrap buffers the accept side's
		// early hello from the instant the socket exists (ADR-0088).
		rendezvous.register(id, socket);
		return response;
	}
	if (url.pathname !== "/relay") {
		return new Response("relay only", { status: 404 });
	}
	const { socket, response } = Deno.upgradeWebSocket(req);
	socket.onopen = () => relay(socket, url.searchParams);
	return response;
});
