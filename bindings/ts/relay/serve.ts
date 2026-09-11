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
//   - `?locator=<ocapn-uri>`  an iroh byte channel dialed through @glowcap/iroh's
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
// rooms relay in apps/rooms/rust/native/src/web/relay.rs); this reference relays wherever
// it is pointed so the conformance proofs can drive it.

import {
	denoIrohChannel,
	denoTcpChannel,
	isRendezvousDesignator,
	type RelayConfig,
	relayFailureLogger,
	Rendezvous,
	webSocketRelay,
} from "@glowcap/relay";
import { BINDING_RELAY_IDLE_TIMEOUT_MS, BINDING_RELAY_MAX_BYTES_PER_SESSION } from "@glowcap/abi";

// Liveness is the idle timeout; the per-session byte total is a runaway backstop
// over the session's life, not a memory bound (instantaneous memory is bounded
// by the backpressure on both legs). Defaults come from generated binding policy.
// The conformance idle-timeout proof sets `GLOWCAP_RELAY_IDLE_MS` low; a
// production run leaves it unset and gets the 60s default.
function idleTimeoutMsFromEnv(): number {
	try {
		const override = Deno.env.get("GLOWCAP_RELAY_IDLE_MS");
		if (override) return Number(override);
	} catch {
		// no --allow-env; fall through to the default
	}
	return BINDING_RELAY_IDLE_TIMEOUT_MS;
}
const relayConfig: RelayConfig = {
	idleTimeoutMs: idleTimeoutMsFromEnv(),
	maxBytesPerSession: BINDING_RELAY_MAX_BYTES_PER_SESSION,
};

// The cold-dial rendezvous table (ADR-0088): identity → held inbound sockets.
// Admission counts held sockets, not identities: both the relay-wide descriptor
// budget and one identity's queue are bounded.
const rendezvous = new Rendezvous();
const max_registrations = 64;
const max_registrations_per_identity = 4;
const shutdown = new AbortController();
const relayShutdown = new AbortController();
const activeRelayWork = new Set<Promise<void>>();
const logRelayFailure = relayFailureLogger();
let relayShuttingDown = false;
let relayStop: Promise<void> | null = null;
const plaintextCanaryText = Deno.env.get("GLOWCAP_RELAY_PLAINTEXT_CANARY");
if (plaintextCanaryText?.length === 0) {
	throw new Error("GLOWCAP_RELAY_PLAINTEXT_CANARY must not be empty");
}
const plaintextCanary = plaintextCanaryText == null ? null : new TextEncoder().encode(plaintextCanaryText);
const canaryPrefix = plaintextCanary == null ? null : (() => {
	const prefix = new Uint32Array(plaintextCanary.length);
	for (let i = 1, matched = 0; i < plaintextCanary.length; i++) {
		while (matched > 0 && plaintextCanary[i] !== plaintextCanary[matched]) matched = prefix[matched - 1];
		if (plaintextCanary[i] === plaintextCanary[matched]) matched++;
		prefix[i] = matched;
	}
	return prefix;
})();
let auditedBinaryMessages = 0;
let plaintextCanaryMatches = 0;

/** Test-process evidence only: when the browser gate supplies a canary, scan
 * exactly the binary messages arriving at the relay without retaining them.
 * The default relay installs no listener and pays no per-message branch. */
function auditRelaySocket(socket: WebSocket): void {
	if (plaintextCanary == null || canaryPrefix == null) return;
	let matched = 0;
	socket.addEventListener("message", (event) => {
		if (!(event.data instanceof ArrayBuffer)) return;
		auditedBinaryMessages++;
		for (const byte of new Uint8Array(event.data)) {
			while (matched > 0 && byte !== plaintextCanary[matched]) matched = canaryPrefix[matched - 1];
			if (byte !== plaintextCanary[matched]) continue;
			matched++;
			if (matched !== plaintextCanary.length) continue;
			plaintextCanaryMatches++;
			matched = canaryPrefix[matched - 1];
		}
	});
}

function runRelay(
	socket: WebSocket,
	getChannel: Parameters<typeof webSocketRelay>[1],
	dialFailReason: string,
): void {
	if (relayShuttingDown) {
		socket.close(1001, "relay shutting down");
		return;
	}
	const work = webSocketRelay(socket, getChannel, dialFailReason, relayConfig, {
		signal: relayShutdown.signal,
	}).catch((err) => {
		// Process shutdown closes every admitted socket below. That deliberately
		// interrupts the pump's pending read and has the signal handler as its
		// recipient; it is not an unexpected serving failure.
		if (relayShuttingDown) return;
		logRelayFailure(err);
	});
	activeRelayWork.add(work);
	void work.finally(() => activeRelayWork.delete(work));
}

/** Dispatch one upgraded WebSocket to the channel its query names, then hand it
 * to the shared byte pump. One of `?to=host:port`, `?locator=<uri>`, or
 * `?rendezvous=<id>` must be present; the dials are @glowcap/relay's shared,
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
const tlsCertPath = Deno.env.get("GLOWCAP_RELAY_TLS_CERT");
const tlsKeyPath = Deno.env.get("GLOWCAP_RELAY_TLS_KEY");
if ((tlsCertPath == null) !== (tlsKeyPath == null)) {
	throw new Error("GLOWCAP_RELAY_TLS_CERT and GLOWCAP_RELAY_TLS_KEY must be set together");
}
const tls = tlsCertPath == null ? null : {
	cert: await Deno.readTextFile(tlsCertPath),
	key: await Deno.readTextFile(tlsKeyPath!),
};

const serveOptions: Deno.ServeTcpOptions = {
	hostname: "127.0.0.1",
	port: listenPort,
	signal: shutdown.signal,
	onListen: ({ port }) => console.log(`DENO-RELAY-READY ${port}`),
};
const handler = (req: Request): Response => {
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
		// The relay's result-bearing byte pump owns the explicit idle timeout and
		// pair-atomic teardown. Disable Deno's independent WebSocket ping timer so
		// it cannot preempt that owner with an uncorrelated transport close.
		const { socket, response } = Deno.upgradeWebSocket(req, { idleTimeout: 0 });
		auditRelaySocket(socket);
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
	const { socket, response } = Deno.upgradeWebSocket(req, { idleTimeout: 0 });
	auditRelaySocket(socket);
	socket.onopen = () => relay(socket, url.searchParams);
	return response;
};
if (tls == null) Deno.serve(serveOptions, handler);
else Deno.serve({ ...serveOptions, ...tls }, handler);

function stop(): Promise<void> {
	if (relayStop != null) return relayStop;
	relayShuttingDown = true;
	relayStop = (async () => {
		const registrations = rendezvous.close();
		relayShutdown.abort();
		await Promise.allSettled([registrations, ...activeRelayWork]);
		if (plaintextCanary != null) {
			console.log(`DENO-RELAY-AUDIT ${auditedBinaryMessages} ${plaintextCanaryMatches}`);
		}
		shutdown.abort();
	})();
	return relayStop;
}

Deno.addSignalListener("SIGINT", () => void stop());
Deno.addSignalListener("SIGTERM", () => void stop());
