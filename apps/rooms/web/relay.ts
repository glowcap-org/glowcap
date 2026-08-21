// DENO-SPECIFIC: the rooms relay endpoint's server side. It has two jobs, kept
// distinct: dial a far side and relay to it (`relayToTarget`, over a target the
// shared classifier already sorted into TCP or iroh), and bridge a cold-dialer to
// a browser that holds an inbound socket here (`bridgeRendezvous`, ADR-0088). The
// bytes are never parsed, so the keyed OCapN session rides through end to end.
//
// The relay never enumerates transports itself: `@pancake/runtime`'s
// `classifyRelayTarget` routes the target locator through the core
// `pancake_host_plan_dial`, the same classifier the handoff redeem-dial uses, so
// this relay sorts a locator exactly as every other runtime's relay does
// (ADR-0086).

import {
	denoIrohChannel,
	denoTcpChannel,
	isRendezvousDesignator,
	type RelayChannel,
	type RelayConfig,
	relayFailureLogger,
	Rendezvous,
	webSocketRelay,
} from "@pancake/relay";
import { BINDING_RELAY_MAX_BYTES_PER_SESSION, BINDING_RELAY_TCP_DIAL_TIMEOUT_MS } from "@pancake/abi";
import { type RelayTarget } from "./relay_target.ts";

export { isRendezvousDesignator };

// A chat session is a persistent, mostly-quiet byte pipe: a peer can sit in a
// room for a long time without typing, so no CapTP bytes cross the relay. A
// byte-traffic idle timeout cannot tell that live-but-quiet peer from a dead one
// and would reclaim it, forcing the page to reconnect every idle window. So the
// relay's own idle timeout is off (0 disables it in `relayBytes`); liveness is
// the WebSocket ping/pong instead, set as `idleTimeout` on the /relay upgrade in
// serve.ts. A live browser auto-pongs and stays connected; a dead one is reclaimed
// by that. Resources stay bounded by `maxRelaySessions` and the ping/pong reclaim.
const idleTimeoutMs = 0;
// Instantaneous memory is bounded by the WebSocket send-buffer backpressure in
// @pancake/relay; this per-session byte total is only a runaway backstop over the
// session's life, set far above any real chat session's traffic so a peer sitting
// in a room for hours is never dropped mid-conversation.
const maxBytesPerSession = BINDING_RELAY_MAX_BYTES_PER_SESSION;
const tcpDialTimeoutMs = BINDING_RELAY_TCP_DIAL_TIMEOUT_MS;
// The admission caps are a deployment knob, not pancake's scale claim. Each live
// relayed session costs the relay two file descriptors (the browser WebSocket and
// the socket it forwards to); each held cold-dial registration costs one. So the
// real ceiling is the host's own open-file limit, and an operator sizes the relay
// to its host by raising that limit (systemd LimitNOFILE, or ulimit) and setting
// PANCAKE_RELAY_MAX_SESSIONS / PANCAKE_RELAY_MAX_REGISTRATIONS to match.
//
// The default is a safe floor, not the relay's capacity. The relay cannot read
// its own descriptor limit under its scoped permissions (Deno gates /proc behind
// --allow-all, which a network server should not hold), so the default assumes
// only the POSIX-default soft limit and splits it, leaving headroom for the
// listener, the room dials, and stdio. The relay itself holds thousands of
// connections per GiB at about 80 KiB each, measured by `zig build relay-scaling`
// (bindings/ts/relay/test/scaling_bench.ts), so a real deployment raises these well
// past the floor. The cap is host policy, not pancake's scale claim: the core's
// ~2 KiB-per-session budget is a property of the sans-io engine, this one of the
// host the relay runs on.
const POSIX_DEFAULT_FD_SOFT_LIMIT = 1024;
function envCap(name: string): number | null {
	try {
		const v = Deno.env.get(name);
		if (v) {
			const n = Number(v);
			if (Number.isInteger(n) && n > 0) return n;
		}
	} catch {
		// no --allow-env; fall through to the default floor
	}
	return null;
}
// Leave 15% headroom, then give sessions (two fds each) and registrations (one fd
// each) an equal share of the descriptor budget, which lands registrations at
// twice the session cap.
const usableFds = Math.floor(POSIX_DEFAULT_FD_SOFT_LIMIT * 0.85);
const maxRelaySessions = envCap("PANCAKE_RELAY_MAX_SESSIONS") ??
	Math.max(16, Math.floor(usableFds / 4));
const maxRegistrations = envCap("PANCAKE_RELAY_MAX_REGISTRATIONS") ??
	Math.max(32, Math.floor(usableFds / 2));
// Browser peers normally hold two sockets ready. Four leaves room for a
// reconnect overlap without letting one claimed identity consume the global
// descriptor budget.
const maxRegistrationsPerIdentity = envCap("PANCAKE_RELAY_MAX_REGISTRATIONS_PER_IDENTITY") ?? 4;

// Live relay sessions, counted from capacity admission until the relay's
// pair-atomic teardown finishes (dial failures included).
let activeRelaySessions = 0;
const activeRelaySockets = new Set<WebSocket>();
let relayShuttingDown = false;
const logRelayFailure = relayFailureLogger();

/** A cleartext-TCP address the relay may dial, besides the room server. */
export interface TcpPeer {
	hostname: string;
	port: number;
}

/** Whether the relay may dial `target`.
 *
 * An iroh target is allowed to any node: node ids are key-verified and the keyed
 * handshake carries session authority end to end. That open-destination policy is
 * deliberate for the demo, and it is named attack surface: it makes the relay a
 * bandwidth amplifier to any iroh peer, bounded only by capacity and per-session
 * backpressure.
 *
 * A TCP target has to be named, because a TCP address can be anything: the room
 * server itself at `127.0.0.1:<roomPort>`, or one of `tcpPeers`, which an
 * operator sets. Where iroh's destination has to be an OCapN peer holding a key,
 * a TCP destination could as easily be a database or an SSH daemon on the same
 * host, so a page cannot be allowed to choose one. Whose address a member claims
 * does not change that: a member registers whatever locator it likes and the
 * directory says so plainly, which is exactly why a registration is not grounds
 * to open a socket.
 *
 * The cost of naming them is real and worth stating. A member reachable only over
 * cleartext TCP — a Goblins vat on a TCP netlayer is the ordinary one — cannot be
 * direct-messaged from a browser until the operator lists it. A member on iroh
 * needs no such listing, which is one more reason `docs/boundaries.md` calls
 * cleartext TCP a testing and interop transport rather than a deployment one.
 *
 * An onion target is allowed only when it names the room server this process
 * supervises (`roomOnion`, that room's own service id). The relay holds no Tor
 * client: an allowed onion target is carried to the service's local forward
 * endpoint, the same bytes a Tor circuit would deliver there, so a foreign
 * onion service is not reachable through it at all. */
export function relayAllowed(
	target: RelayTarget,
	roomPort: number,
	tcpPeers: readonly TcpPeer[] = [],
	roomOnion: string | null = null,
): boolean {
	if (target.kind === "iroh") return true;
	if (target.kind === "onion") {
		return roomOnion !== null && target.designator === roomOnion;
	}
	if (target.hostname === "127.0.0.1" && target.port === roomPort) return true;
	return tcpPeers.some((peer) => peer.hostname === target.hostname && peer.port === target.port);
}

/** Read a `host:port,host:port` list of extra TCP relay destinations, dropping
 * anything that is not one. An entry that cannot be read is dropped rather than
 * refused wholesale, so one typo does not take the rest of the list with it; a
 * destination that never appears fails visibly at the dial instead. */
export function parseTcpPeers(raw: string | null | undefined): TcpPeer[] {
	if (!raw) return [];
	const peers: TcpPeer[] = [];
	for (const entry of raw.split(",")) {
		const text = entry.trim();
		if (text.length === 0) continue;
		const cut = text.lastIndexOf(":");
		if (cut <= 0) continue;
		const port = Number(text.slice(cut + 1));
		if (!Number.isInteger(port) || port < 1 || port > 65535) continue;
		peers.push({ hostname: text.slice(0, cut), port });
	}
	return peers;
}

/** Whether a browser `Origin` header may drive the relay: absent (non-browser
 * clients) or matching the request's own `Host`. A cross-origin page is
 * refused before the WebSocket upgrade. */
export function relayOriginAllowed(
	origin: string | null,
	host: string | null,
): boolean {
	if (!origin) return true;
	if (!host) return false;
	try {
		return new URL(origin).host === host;
	} catch {
		return false;
	}
}

/** Whether a new relay session fits under the live-session cap: admit below the
 * ceiling, refuse at or above it. The cap is the embedder's admission policy
 * (ADR-0086 bounded resources); the reference relay leaves it unset. */
export function relaySessionAdmitted(active: number, cap: number): boolean {
	return active < cap;
}

/** Whether a rendezvous registration fits both the relay-wide held-socket
 * budget and one identity's queue budget. */
export function rendezvousAdmitted(
	heldTotal: number,
	heldForIdentity: number,
	totalCap: number,
	perIdentityCap: number,
): boolean {
	return heldTotal < totalCap && heldForIdentity < perIdentityCap;
}

const relayConfig: RelayConfig = { idleTimeoutMs, maxBytesPerSession };

/** Admit a relay session under the capacity cap, then hand the WebSocket to the
 * shared byte pump against the channel `getChannel` opens. The pump
 * (`webSocketRelay`) owns the byte plumbing and teardown; this wrapper owns only
 * the live-session count. */
function relayViaChannel(
	socket: WebSocket,
	getChannel: () => Promise<RelayChannel>,
	dialFailReason: string,
): void {
	if (relayShuttingDown) {
		socket.close(1001, "relay shutting down");
		return;
	}
	if (!relaySessionAdmitted(activeRelaySessions, maxRelaySessions)) {
		socket.close(1008, "relay capacity exceeded");
		return;
	}
	activeRelaySessions++;
	activeRelaySockets.add(socket);
	webSocketRelay(socket, getChannel, dialFailReason, relayConfig).catch(
		(err) => {
			if (relayShuttingDown) return;
			logRelayFailure(err);
		},
	).finally(() => {
		activeRelaySessions--;
		activeRelaySockets.delete(socket);
	});
}

// The cold-dial rendezvous (ADR-0088). A browser that opens no listening socket
// registers its keyed identity and a held inbound socket here; a peer that
// redeems an introduction naming that identity is bridged onto the held socket
// through the same byte pump every other leg uses. The relay still parses no
// frame and holds no capability — the keyed handshake runs end to end between
// the dialer and the registered browser through two relay legs.
const rendezvous = new Rendezvous();

/** Stop accepting relay work and close every resource owned by this relay.
 * Deno's HTTP abort closes the listener, but it is not the owner of the
 * rendezvous channels or of a far-side dial already in progress. Keeping this
 * boundary here makes signal/error teardown release both classes exactly once. */
export function shutdownRelay(): void {
	if (relayShuttingDown) return;
	relayShuttingDown = true;
	rendezvous.close();
	for (const socket of activeRelaySockets) {
		try {
			socket.close(1001, "relay shutting down");
		} catch { /* already closed */ }
	}
}

/** Hold `socket` as the inbound accept socket for the peer identified by
 * `designator`, under the registration cap. The registered peer waits to be
 * cold-dialed; a bridge consumes the registration, so the peer registers a fresh
 * socket for the next dial (one held socket carries one inbound session). */
export function registerRendezvous(
	socket: WebSocket,
	designator: string,
): void {
	if (!isRendezvousDesignator(designator)) {
		socket.close(1008, "invalid rendezvous designator");
		return;
	}
	if (
		!rendezvousAdmitted(
			rendezvous.heldCount(),
			rendezvous.heldFor(designator),
			maxRegistrations,
			maxRegistrationsPerIdentity,
		)
	) {
		socket.close(1008, "rendezvous capacity exceeded");
		return;
	}
	if (!rendezvous.register(designator, socket)) {
		socket.close(1001, "relay shutting down");
	}
}

/** Bridge `socket` (a dialer) to the browser registered under `designator`,
 * consuming that registration and piping the two through the shared byte pump.
 * Closes the dialer when the peer is not present, so the caller learns the
 * target is offline rather than the session failing silently. The cold-dial
 * side of the relay: a bridge to a held socket, distinct from dialing a far
 * side (`relayToTarget`). */
export function bridgeRendezvous(socket: WebSocket, designator: string): void {
	// Admission before the take, because `take` *removes* the registration. A
	// refusal after it would consume the registered peer's held socket and drop
	// it: nothing closes that socket, so its accept-side handshake parks
	// forever, and the browser only replenishes when a held channel settles or
	// closes. Two refusals empty its pool, and it silently leaves the roster
	// while its own UI still shows connected. The sibling `relayToTarget` is
	// safe because it passes a thunk, so a refusal opens nothing.
	if (relayShuttingDown) {
		socket.close(1001, "relay shutting down");
		return;
	}
	if (!isRendezvousDesignator(designator)) {
		socket.close(1008, "invalid rendezvous designator");
		return;
	}
	if (!relaySessionAdmitted(activeRelaySessions, maxRelaySessions)) {
		socket.close(1008, "relay capacity exceeded");
		return;
	}
	const held = rendezvous.take(designator);
	if (held === undefined) {
		socket.close(1011, "rendezvous: peer not registered");
		return;
	}
	// `held` is already a buffering channel over the registered peer's socket, so
	// the accept side's early hello is captured; pipe the dialer to it.
	relayViaChannel(
		socket,
		() => Promise.resolve(held),
		"rendezvous: registered peer went away",
	);
}

/** Dial the far side the classified `target` names and relay the WebSocket to it:
 * TCP for a `host_port` shape, iroh for a `peer_id` one. The classification is the
 * shared `classifyRelayTarget`, so this relay never re-decides the transport. The
 * cold-dial rendezvous is a *bridge* to a held socket, not a dial, so it is a
 * separate path (`bridgeRendezvous`), not an arm here. The caller has already
 * checked `relayAllowed`. */
export function relayToTarget(socket: WebSocket, target: RelayTarget): void {
	if (target.kind === "tcp") {
		relayViaChannel(
			socket,
			() =>
				denoTcpChannel(target.hostname, target.port, {
					dialTimeoutMs: tcpDialTimeoutMs,
				}),
			"TCP relay target unreachable",
		);
	} else if (target.kind === "iroh") {
		relayViaChannel(
			socket,
			() => denoIrohChannel(target.locator, "discovery"),
			"iroh relay dial failed",
		);
	} else {
		// An admitted onion target is rewritten to the supervised room's local
		// forward endpoint before this dial (serve_http.ts); this relay holds no
		// Tor client, so one arriving unrewritten is a caller mistake to refuse.
		socket.close(1011, "onion target was not resolved to its forward endpoint");
	}
}
