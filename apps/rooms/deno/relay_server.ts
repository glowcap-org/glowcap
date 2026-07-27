// DENO-SPECIFIC: the rooms relay endpoint's server side. It has two jobs, kept
// distinct: dial a far side and relay to it (`relayToTarget`, over a target the
// shared classifier already sorted into TCP or iroh), and bridge a cold-dialer to
// a browser that holds an inbound socket here (`bridgeRendezvous`, ADR-0088). The
// bytes are never parsed, so the keyed OCapN session rides through end to end.
//
// The relay never enumerates transports itself: `@pancake/stack`'s
// `classifyRelayTarget` routes the target locator through the core
// `pancake_host_plan_dial`, the same classifier the handoff redeem-dial uses, so
// this relay sorts a locator exactly as every other runtime's relay does
// (ADR-0086).

import {
	denoIrohChannel,
	denoTcpChannel,
	type RelayChannel,
	type RelayConfig,
	Rendezvous,
	webSocketRelay,
} from "@pancake/relay";
import { type RelayTarget } from "@pancake/stack";

// A chat session is a persistent, mostly-quiet byte pipe: a peer can sit in a
// room for a long time without typing, so no CapTP bytes cross the relay. A
// byte-traffic idle timeout cannot tell that live-but-quiet peer from a dead one
// and would reclaim it, forcing the page to reconnect every idle window. So the
// relay's own idle timeout is off (0 disables it in `relayBytes`); liveness is
// the WebSocket ping/pong instead, set as `idleTimeout` on the /relay upgrade in
// web.ts. A live browser auto-pongs and stays connected; a dead one is reclaimed
// by that. Resources stay bounded by `maxRelaySessions` and the ping/pong reclaim.
const idleTimeoutMs = 0;
// Instantaneous memory is bounded by the WebSocket send-buffer backpressure in
// @pancake/relay; this per-session byte total is only a runaway backstop over the
// session's life, set far above any real chat session's traffic so a peer sitting
// in a room for hours is never dropped mid-conversation.
const maxBytesPerSession = 1024 * 1024 * 1024;
const tcpDialTimeoutMs = 5_000;
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
// (bindings/ts/relay/scaling_bench.ts), so a real deployment raises these well
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

// Live relay sessions, counted from capacity admission until the relay's
// pair-atomic teardown finishes (dial failures included).
let activeRelaySessions = 0;

/** Whether the relay may dial `target`. An iroh target is allowed to any node:
 * node ids are key-verified and the keyed handshake carries session authority end
 * to end. That open-destination policy is deliberate for the demo, and it is named
 * attack surface: it makes the relay a bandwidth amplifier to any iroh peer,
 * bounded only by capacity and per-session backpressure. A TCP target is pinned to
 * the room server itself, `127.0.0.1:<roomPort>`, so a locator that classifies to
 * a TCP dial (a bare `host:port`, or a `tcp`/`keyed-tcp` URI whose hint names an
 * address) can only ever reach the room, never an arbitrary host. */
export function relayAllowed(target: RelayTarget, roomPort: number): boolean {
	return target.kind === "iroh" ||
		(target.hostname === "127.0.0.1" && target.port === roomPort);
}

/** Whether a browser `Origin` header may drive the relay: absent (non-browser
 * clients) or matching the request's own `Host`. A cross-origin page is
 * refused before the WebSocket upgrade. */
export function relayOriginAllowed(origin: string | null, host: string | null): boolean {
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

/** Whether a rendezvous registration is admitted. An identity already holding a
 * socket replenishes its own queue freely; a new identity must fit under the
 * registration cap, so a flood of fresh identities cannot pin unbounded held
 * sockets (ADR-0086 bounded resources, carried to the rendezvous leg). */
export function rendezvousAdmitted(
	registered: number,
	alreadyPresent: boolean,
	cap: number,
): boolean {
	return alreadyPresent || registered < cap;
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
	if (!relaySessionAdmitted(activeRelaySessions, maxRelaySessions)) {
		socket.close(1008, "relay capacity exceeded");
		return;
	}
	activeRelaySessions++;
	webSocketRelay(socket, getChannel, dialFailReason, relayConfig).catch((err) => {
		console.error(
			`relay: unexpected error: ${err instanceof Error ? err.message : String(err)}`,
		);
	}).finally(() => {
		activeRelaySessions--;
	});
}

// The cold-dial rendezvous (ADR-0088). A browser that opens no listening socket
// registers its keyed identity and a held inbound socket here; a peer that
// redeems an introduction naming that identity is bridged onto the held socket
// through the same byte pump every other leg uses. The relay still parses no
// frame and holds no capability — the keyed handshake runs end to end between
// the dialer and the registered browser through two relay legs.
const rendezvous = new Rendezvous();

/** Hold `socket` as the inbound accept socket for the peer identified by
 * `designator`, under the registration cap. The registered peer waits to be
 * cold-dialed; a bridge consumes the registration, so the peer registers a fresh
 * socket for the next dial (one held socket carries one inbound session). */
export function registerRendezvous(socket: WebSocket, designator: string): void {
	if (
		!rendezvousAdmitted(
			rendezvous.registered().length,
			rendezvous.has(designator),
			maxRegistrations,
		)
	) {
		socket.close(1008, "rendezvous capacity exceeded");
		return;
	}
	rendezvous.register(designator, socket);
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
			() => denoTcpChannel(target.hostname, target.port, { dialTimeoutMs: tcpDialTimeoutMs }),
			"TCP relay target unreachable",
		);
	} else {
		relayViaChannel(
			socket,
			() => denoIrohChannel(target.locator, "discovery"),
			"iroh relay dial failed",
		);
	}
}
