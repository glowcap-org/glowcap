// The runnable Deno reference relay for the ADR-0086 contract — the first-party
// consumer of this package's own `webSocketRelay`, and the Deno row of the
// cross-runtime relay matrix beside `bindings/python/relay.py` and
// `bindings/rust/relay`. It carries the raw bytes of a keyed CapTP session
// between a browser peer's WebSocket and a native host without parsing them, so
// the keyed handshake and session authority run end to end and the relay holds
// no capability.
//
// Two transports, dispatched by what the WebSocket names:
//   - `?to=host:port`         a raw TCP socket (kernel-backpressured).
//   - `?locator=<ocapn-uri>`  an iroh byte channel dialed through @pancake/iroh's
//                             `dialLocatorForRelay`.
//
// Run it directly; it prints `DENO-RELAY-READY <port>` on stdout once listening:
//     deno run --allow-net --allow-ffi --allow-env --allow-read \
//         bindings/ts/relay/serve.ts <listen-port>
//
// The embedding app adds the target allow-list and capacity admission (see the
// rooms relay in apps/rooms/web/relay.ts); this reference relays wherever
// it is pointed so the conformance proofs can drive it.

import { denoIrohChannel, denoTcpChannel, type RelayConfig, webSocketRelay } from "@pancake/relay";

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

/** Dispatch one upgraded WebSocket to the channel its query names, then hand it
 * to the shared byte pump. One of `?to=host:port` or `?locator=<uri>` must be
 * present; the dials are @pancake/relay's shared, hardened channel factories. */
function relay(socket: WebSocket, query: URLSearchParams): void {
	const to = query.get("to");
	const locator = query.get("locator");
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
	if (url.pathname !== "/relay" || req.headers.get("upgrade") !== "websocket") {
		return new Response("relay only", { status: 404 });
	}
	const { socket, response } = Deno.upgradeWebSocket(req);
	socket.onopen = () => relay(socket, url.searchParams);
	return response;
});
