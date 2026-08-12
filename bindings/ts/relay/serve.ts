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
	isRendezvousDesignator,
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
// Admission counts held sockets, not identities: both the relay-wide descriptor
// budget and one identity's queue are bounded.
const rendezvous = new Rendezvous();
const max_registrations = 64;
const max_registrations_per_identity = 4;
const shutdown = new AbortController();
const activeRelaySockets = new Set<WebSocket>();
let relayShuttingDown = false;

function runRelay(
	socket: WebSocket,
	getChannel: Parameters<typeof webSocketRelay>[1],
	dialFailReason: string,
): void {
	if (relayShuttingDown) {
		socket.close(1001, "relay shutting down");
		return;
	}
	activeRelaySockets.add(socket);
	webSocketRelay(socket, getChannel, dialFailReason, relayConfig).catch((err) => {
		console.error(
			`relay: unexpected error: ${err instanceof Error ? err.message : String(err)}`,
		);
	}).finally(() => activeRelaySockets.delete(socket));
}

/** Dispatch one upgraded WebSocket to the channel its query names, then hand it
 * to the shared byte pump. One of `?to=host:port`, `?locator=<uri>`, or
 * `?rendezvous=<id>` must be present; the dials are @pancake/relay's shared,
 * hardened channel factories, and a rendezvous is a bridge onto a held
 * registered socket. */
function relay(socket: WebSocket, query: URLSearchParams): void {
	const to = query.get("to");
	const locator = query.get("locator");
	const rendezvous_id = query.get("rendezvous");
	if (rendezvous_id != null) {
		if (!isRendezvousDesignator(rendezvous_id)) {
			socket.close(1008, "invalid rendezvous designator");
			return;
		}
		// Take only after the upgrade succeeded: `take` removes the registration,
		// and a refusal that consumed it would strand the registered peer's held
		// socket (nothing closes it, so its accept parks and the pool never
		// replenishes).
		const held = rendezvous.take(rendezvous_id);
		if (held === undefined) {
			socket.close(1011, "rendezvous: peer not registered");
			return;
		}
		runRelay(
			socket,
			() => Promise.resolve(held),
			"rendezvous: registered peer went away",
		);
		return;
	}
	if (locator != null) {
		runRelay(
			socket,
			() => denoIrohChannel(locator, "direct"),
			"iroh relay dial failed",
		);
		return;
	}
	if (to != null) {
		const colon = to.lastIndexOf(":");
		const port = colon === -1 ? NaN : Number(to.slice(colon + 1));
		if (Number.isInteger(port) && port >= 1 && port <= 65535) {
			const host = to.slice(0, colon);
			runRelay(
				socket,
				() => denoTcpChannel(host, port),
				"TCP relay target unreachable",
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
	signal: shutdown.signal,
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
		if (id == null) return new Response("register requires ?id=<designator>", { status: 400 });
		if (!isRendezvousDesignator(id)) {
			return new Response("invalid rendezvous designator", { status: 400 });
		}
		if (
			rendezvous.heldCount() >= max_registrations ||
			rendezvous.heldFor(id) >= max_registrations_per_identity
		) {
			return new Response("rendezvous capacity exceeded", { status: 503 });
		}
		const { socket, response } = Deno.upgradeWebSocket(req);
		// Register at once, not at onopen: the wrap buffers the accept side's
		// early hello from the instant the socket exists (ADR-0088).
		if (!rendezvous.register(id, socket)) {
			socket.close(1001, "relay shutting down");
		}
		return response;
	}
	if (url.pathname !== "/relay") {
		return new Response("relay only", { status: 404 });
	}
	const { socket, response } = Deno.upgradeWebSocket(req);
	socket.onopen = () => relay(socket, url.searchParams);
	return response;
});

function stop(): void {
	if (relayShuttingDown) return;
	relayShuttingDown = true;
	shutdown.abort();
	rendezvous.close();
	for (const socket of activeRelaySockets) {
		try {
			socket.close(1001, "relay shutting down");
		} catch { /* already closed */ }
	}
}

Deno.addSignalListener("SIGINT", stop);
Deno.addSignalListener("SIGTERM", stop);
