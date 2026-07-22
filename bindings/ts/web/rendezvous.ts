// The browser half of the cold-dial rendezvous (ADR-0088 capability 5). A
// browser opens no listening socket, so it cannot be dialed. Instead it
// registers its keyed identity and a held inbound socket at a relay; a peer that
// redeems an introduction naming that identity is bridged onto the held socket,
// and the keyed handshake runs end to end between them — the relay parses
// nothing and holds no capability. The relay half is `@pancake/relay`'s
// `Rendezvous`; this is the accepting side that runs in the browser.
//
// `serveRendezvous` keeps a small pool of registration sockets, each parked in
// the accept handshake reading its socket until a dialer's bytes arrive through
// the bridge (the browser handshake has no read deadline, so an idle
// registration simply waits). When one is bridged and its session opens, the
// host's giftables answer it and the pool replenishes, so the browser can be
// cold-dialed again.
//
// The dialing side has exactly one mechanism, and it is not here: a peer
// redeeming a `keyed-relay` handoff give reaches the registered browser through
// the dial executor's `keyed-relay` intercept (`stack/dial.ts`), which opens the
// same rendezvous channel over `net.connectRendezvous` and drives
// `Session.establishDialedLocator` — the mirror of the `establishAccepted` this
// module parks on. Keeping the redeeming side on that one path is what lets the
// conformance proof pin a single cold-dial mechanism rather than a raw
// dial-by-designator convenience beside it.

import { type Host, Session, TRANSPORT_KEYED_RELAY } from "@pancake/stack";
import { webSocketChannel } from "./ws_channel.ts";

// The keyed transport the rendezvous handshake runs under: the identity is a key
// designator (`Host.designator`, 64 hex), there is no dialable address, and the
// byte channel is the relay WebSocket. The keyed handshake authenticates the
// designator; the dialing side reaches it through `connectRendezvous` on the
// same symbol, so both ends must name the one source of truth for it — the
// `dial.ts` intercept keys on this exact constant.
const RENDEZVOUS_TRANSPORT = TRANSPORT_KEYED_RELAY;

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
	stop(): void;
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
	registerUrl: (designator: string) => string,
	opts: { pool?: number; onError?: (err: unknown) => void } = {},
): RendezvousHandle {
	const designator = host.designator();
	const pool = opts.pool ?? DEFAULT_POOL;
	const onError = opts.onError ?? (() => {});
	let stopped = false;
	const held = new Set<WebSocket>();

	const registerOne = (): void => {
		if (stopped) return;
		let ws: WebSocket;
		try {
			ws = new WebSocket(registerUrl(designator));
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
			Session.establishAccepted(host, RENDEZVOUS_TRANSPORT, designator, webSocketChannel(ws))
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
