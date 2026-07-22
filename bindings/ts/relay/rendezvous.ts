// The cold-dial rendezvous (ADR-0088 capability 5). A peer that cannot be dialed
// — a browser opens no listening socket — registers its keyed identity here
// together with a held inbound WebSocket. A dialer that names that identity is
// bridged onto the held socket, the mirror of the browser-dials-native leg
// (`webSocketRelay`): the relay matches an identity to a held socket and forwards
// bytes, still parsing nothing and holding no capability. The keyed handshake
// runs end to end between the dialer and the registered peer through two relay
// legs, and the relay is blind to both.
//
// One held socket carries one inbound session. A registered peer that wants to
// accept another cold-dial registers a fresh socket; a bridge consumes the held
// one, so the peer replenishes on activation. Admission — which identities may
// register and be dialed — is the embedder's policy, above this registry.

import { type RelayChannel } from "./relay.ts";
import { webSocketChannel } from "./ws_relay.ts";

/** A rendezvous table keyed by peer identity (the designator a `keyed-tcp` /
 * iroh locator would name). Server-side state a relay embedder owns; the byte
 * plumbing stays in `webSocketChannel` / `webSocketRelay`, so this holds only
 * the identity→channels map. An embedder bridges a dialer by `take`-ing a held
 * channel and piping the dialer to it (the channel already buffers the accept
 * side's early hello).
 *
 * Each identity holds a FIFO *queue* of inbound sockets, not one, so a peer can
 * keep a small pool of registrations ready and two cold-dials that race do not
 * fight over one socket: `register` appends, `take` pops the oldest, and a
 * socket that closes drops itself out of the queue wherever it sits. A queue —
 * rather than a single evicting slot — is also why a re-registration never
 * closes a live sibling: registering the same identity adds capacity, it does
 * not tear down the peer's other held sockets.
 *
 * Admission — which identities may register at all — is the embedder's policy,
 * above this table. The relay is byte-transparent, so it cannot verify a
 * registrant holds the private key for the identity it names; the keyed
 * handshake still blocks impersonation (a squatter cannot complete it), but
 * flooding an identity's queue is an availability lever the embedder governs
 * exactly as it governs the dial allow-list. */
export class Rendezvous {
	// A FIFO queue of held inbound sockets per registered identity, each already
	// wrapped as a buffering channel (see `register`). Empty queues are pruned,
	// so a key present in the map always has at least one entry.
	readonly #held = new Map<string, Held[]>();

	/** Append `socket` to `designator`'s queue of inbound accept sockets. The
	 * socket is wrapped as a `RelayChannel` *now*, not at bridge time, so its
	 * inbound buffers from the instant of registration: a browser peer's accept
	 * side sends its signed `op:start-session` as soon as its socket opens, well
	 * before any dialer is bridged onto it, and those early bytes must be
	 * captured or the dialer waits forever for a hello it never sees. The socket
	 * drops itself out of the queue when it closes or errors, so a gone tab
	 * leaves no ghost and a corpse never sits ahead of a live sibling. */
	register(designator: string, socket: WebSocket): void {
		const entry: Held = { socket, channel: webSocketChannel(socket) };
		const queue = this.#held.get(designator);
		if (queue) queue.push(entry);
		else this.#held.set(designator, [entry]);
		const drop = () => this.#drop(designator, socket);
		socket.addEventListener("close", drop);
		socket.addEventListener("error", drop);
	}

	// Remove one specific socket from an identity's queue wherever it sits,
	// pruning the entry when its last socket goes.
	#drop(designator: string, socket: WebSocket): void {
		const queue = this.#held.get(designator);
		if (queue === undefined) return;
		const at = queue.findIndex((e) => e.socket === socket);
		if (at >= 0) queue.splice(at, 1);
		if (queue.length === 0) this.#held.delete(designator);
	}

	/** Whether an identity currently holds at least one socket (an
	 * admission/presence check). */
	has(designator: string): boolean {
		const queue = this.#held.get(designator);
		return queue !== undefined && queue.length > 0;
	}

	/** The identities currently registered (for a presence roster). */
	registered(): string[] {
		return [...this.#held.keys()];
	}

	/**
	 * Take (consume) the oldest held channel for `designator`, or undefined when
	 * none is held (the peer is not present). The caller pipes a dialer to the
	 * returned channel (already buffering the accept side's early hello);
	 * consuming it here means the registered peer replenishes with a fresh socket
	 * for the next cold-dial, so one held socket carries exactly one inbound
	 * session.
	 */
	take(designator: string): RelayChannel | undefined {
		const queue = this.#held.get(designator);
		if (queue === undefined || queue.length === 0) return undefined;
		const { channel } = queue.shift()!;
		if (queue.length === 0) this.#held.delete(designator);
		return channel;
	}
}

/** One held registration: the raw socket (for identity and drop-on-close) and
 * the buffering channel a bridge pipes a dialer to. */
interface Held {
	socket: WebSocket;
	channel: RelayChannel;
}
