// The accepting half of the cold-dial rendezvous (ADR-0088 capability 5). A
// peer that opens no listening socket — a browser tab, or any process behind a
// NAT that declines a listener — cannot be dialed. Instead it registers its
// keyed identity and a held inbound socket at a relay; a peer that redeems an
// introduction naming that identity is bridged onto the held socket, and the
// keyed handshake runs end to end between them — the relay parses nothing and
// holds no capability. The relay half is `@pancake/relay`'s `Rendezvous`; this
// is the accepting side, runtime-neutral over the `WebSocket` global.
//
// `serveRendezvous` keeps a small pool of registration sockets, each parked in
// the accept handshake reading its socket until a dialer's bytes arrive through
// the bridge (a registration accept has no read deadline, so an idle
// registration simply waits). When one is bridged and its session opens, the
// host's giftables answer it and the pool replenishes, so the peer can be
// cold-dialed again.
//
// The dialing side has exactly one mechanism, and it is not here: the core
// classifies a `keyed-relay` locator as the `rendezvous` dial shape, and the
// dial executor's arm for it (`dial.ts`) opens the rendezvous channel the
// dialing host was configured for (`Host.setRendezvousUrl`) and drives
// `Session.establishDialedLocator` — the mirror of the `establishAccepted`
// this module parks on. Keeping the redeeming side on that one path is what
// lets the conformance proof pin a single cold-dial mechanism rather than a
// raw dial-by-designator convenience beside it.

import type { Host } from "./host.ts";
import { Session } from "./session.ts";
import { TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "./locator.ts";
import { webSocketChannel } from "./ws_channel.ts";
import { DESIGNATOR_SCHEME_KEY } from "@pancake/abi";

/** The two wire profiles the relay rendezvous can carry. Required at the API
 * boundary so registration, the Host's advertised locator, and accepted
 * sessions cannot silently disagree about whether the byte pipe is sealed. */
export type RendezvousTransport =
	| typeof TRANSPORT_KEYED_RELAY
	| typeof TRANSPORT_NOISE_RELAY;

// How many inbound sockets to hold ready at once, so a burst of cold-dials does
// not race a window where none is registered. A bridge consumes one; the pool
// replenishes on the session opening.
const DEFAULT_POOL = 2;

// Backoff before replacing a registration that closed without carrying a session
// (a torn-down socket, an unreachable relay), so a down relay is polled, not
// hot-looped.
const REPLENISH_BACKOFF_MS = 1_000;

/** A running rendezvous registration. `stop` ends it and closes every held
 * socket. */
export interface RendezvousHandle {
	/** The complete locator installed on the Host and advertised to peers. */
	readonly locator: Locator;
	stop(): void;
}

/** The two URLs a rendezvous owner must distinguish: registration is the
 * local socket it opens; relay is the route peers must receive in its locator. */
export interface RendezvousRoute {
	registerUrl(designator: string): string;
	relayUrl: string;
}

/**
 * Serve inbound cold-dials to `host` through a relay rendezvous. `registerUrl`
 * builds the relay's register endpoint for this host's designator, e.g.
 * `` (id) => `wss://example/register?id=${id}` ``. The host's giftables
 * (`publishGiftable`) answer each accepted session. Returns a handle whose
 * `stop` ends registration.
 */
export function serveRendezvous(
	host: Host,
	transport: RendezvousTransport,
	route: RendezvousRoute,
	opts: { pool?: number; onError?: (err: unknown) => void } = {},
): RendezvousHandle {
	if (transport !== TRANSPORT_KEYED_RELAY && transport !== TRANSPORT_NOISE_RELAY) {
		throw new TypeError(`unsupported rendezvous transport ${transport}`);
	}
	const designator = host.designator();
	// The registration is the reachability owner, so it publishes the same
	// complete locator its accepted sessions use. Callers cannot set one symbol
	// and accidentally accept on the other.
	const locator: Locator = {
		transport,
		designator,
		hints: new Map([["rendezvous-relay", route.relayUrl]]),
		hintWireForm: "map",
	};
	host.setAdvertisedLocator(locator);
	const pool = opts.pool ?? DEFAULT_POOL;
	const onError = opts.onError ?? (() => {});
	let stopped = false;
	const held = new Set<WebSocket>();

	const registerOne = (): void => {
		if (stopped) return;
		let ws: WebSocket;
		try {
			ws = new WebSocket(route.registerUrl(designator));
		} catch (err) {
			onError(err);
			if (!stopped) setTimeout(registerOne, REPLENISH_BACKOFF_MS);
			return;
		}
		held.add(ws);
		let opened = false;
		const replenish = () => {
			held.delete(ws);
			// An idle registration that closed before carrying a session is
			// replaced (with backoff) so the pool stays full; one that opened
			// already refilled below.
			if (!stopped && !opened) setTimeout(registerOne, REPLENISH_BACKOFF_MS);
		};
		// Drive the accept handshake only once the register socket is open. As one
		// half of the crossed hello the accept side sends its own signed
		// `op:start-session` the moment it opens; writing that frame to a
		// still-connecting socket throws and drops it, and the dialer then waits
		// forever for a reply that never comes. The relay buffers this socket's
		// inbound from the instant it registers, so the accept side's early hello
		// reaches the relay's held channel even though no dialer is bridged yet.
		const onOpen = () => {
			ws.removeEventListener("error", onPreOpenError);
			// The one accept in this binding that opts out of the handshake bound.
			// A registration is *meant* to park: it holds an open socket until a
			// dialer is bridged onto it, which may be minutes away, and there is
			// no accept loop behind it for a silent partner to block. The pool
			// replenishes on close, so a dead registration costs one socket, not
			// a hang.
			Session.establishAccepted(
				host,
				{
					transport,
					designatorScheme: DESIGNATOR_SCHEME_KEY,
					serverDesignator: designator,
					channel: webSocketChannel(ws),
				},
				0,
			)
				.then((session) => {
					opened = true;
					if (!stopped) registerOne(); // a dial landed; refill the pool
					return session.serve();
				})
				.catch((err) => onError(err))
				.finally(replenish);
		};
		const onPreOpenError = () => {
			onError(new Error("rendezvous register socket failed to open"));
			replenish();
		};
		ws.addEventListener("open", onOpen, { once: true });
		ws.addEventListener("error", onPreOpenError, { once: true });
	};

	for (let i = 0; i < pool; i++) registerOne();
	return {
		locator,
		stop() {
			stopped = true;
			for (const ws of held) {
				try {
					ws.close();
				} catch { /* already closed */ }
			}
		},
	};
}
