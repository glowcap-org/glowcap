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

import type { RelayChannel } from "./relay.ts";
import { MAX_RELAY_WEBSOCKET_MESSAGE_BYTES, webSocketChannel } from "./ws_relay.ts";
import { recordProcessBindingFailure, retainSecondaryFailure } from "@glowcap/runtime/transport";

const KEY_DESIGNATOR = /^[0-9a-f]{64}$/;

/** Whether `value` is the canonical Ed25519 key designator keyed-relay names.
 * Validate before an HTTP upgrade so attacker-controlled map keys stay both
 * semantically meaningful and fixed-size. */
export function isRendezvousDesignator(value: string): boolean {
	return KEY_DESIGNATOR.test(value);
}

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
	#heldCount = 0;
	#closed = false;
	#closePromise: Promise<void> | null = null;

	static #socketClosing(socket: WebSocket): boolean {
		return Number(socket.readyState) >= WebSocket.CLOSING;
	}

	/** Append `socket` to `designator`'s queue of inbound accept sockets. The
	 * socket is wrapped as a `RelayChannel` *now*, not at bridge time, so its
	 * inbound buffers from the instant of registration: a browser peer's accept
	 * side sends its signed `op:start-session` as soon as its socket opens, well
	 * before any dialer is bridged onto it, and those early bytes must be
	 * captured or the dialer waits forever for a hello it never sees. The socket
	 * drops itself out of the queue when it closes or errors, so a gone tab
	 * leaves no ghost and a corpse never sits ahead of a live sibling. */
	register(designator: string, socket: WebSocket): boolean {
		if (
			!isRendezvousDesignator(designator) ||
			this.#closed ||
			Rendezvous.#socketClosing(socket)
		) return false;
		const entry: Held = {
			designator,
			socket,
			channel: webSocketChannel(socket, {
				inboundHighWaterBytes: MAX_RELAY_WEBSOCKET_MESSAGE_BYTES,
			}),
			onDrop: () => this.#drop(entry),
		};
		socket.addEventListener("close", entry.onDrop);
		socket.addEventListener("error", entry.onDrop);
		if (Rendezvous.#socketClosing(socket) || this.#closed) {
			this.#detach(entry);
			this.#closeHeld(entry, "relay.rendezvous.register.rollback");
			return false;
		}
		const queue = this.#held.get(designator);
		if (queue) queue.push(entry);
		else this.#held.set(designator, [entry]);
		this.#heldCount++;
		return true;
	}

	// Remove one specific socket from an identity's queue wherever it sits,
	// pruning the entry when its last socket goes.
	#drop(entry: Held): void {
		const queue = this.#held.get(entry.designator);
		if (queue === undefined) return;
		const at = queue.indexOf(entry);
		if (at >= 0) {
			queue.splice(at, 1);
			this.#heldCount--;
			this.#detach(entry);
			this.#closeHeld(entry, "relay.rendezvous.registration.close");
		}
		if (queue.length === 0) this.#held.delete(entry.designator);
	}

	#detach(entry: Held): void {
		entry.socket.removeEventListener("close", entry.onDrop);
		entry.socket.removeEventListener("error", entry.onDrop);
	}

	#closeHeld(entry: Held, operation: string): Promise<void> {
		const closed = entry.channel.close();
		void closed.catch((error) => recordProcessBindingFailure(operation, error));
		return closed;
	}

	/** Whether an identity currently holds at least one socket (an
	 * admission/presence check). */
	has(designator: string): boolean {
		const queue = this.#held.get(designator);
		return queue !== undefined && queue.length > 0;
	}

	/** Number of held sockets across every identity. This, not the number of
	 * map keys, is the relay's descriptor and memory admission quantity. */
	heldCount(): number {
		return this.#heldCount;
	}

	/** Number of held sockets for one identity. */
	heldFor(designator: string): number {
		return this.#held.get(designator)?.length ?? 0;
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
		if (!isRendezvousDesignator(designator)) return undefined;
		const queue = this.#held.get(designator);
		if (queue === undefined || queue.length === 0) return undefined;
		const entry = queue.shift()!;
		this.#heldCount--;
		this.#detach(entry);
		if (queue.length === 0) this.#held.delete(designator);
		return entry.channel;
	}

	/** Close and join every still-held registration, then release its accounting. This is
	 * the registry's shutdown boundary: a taken channel belongs to its relay
	 * session and is deliberately not part of this table anymore. Idempotence
	 * makes signal/error teardown safe when both paths race. */
	close(): Promise<void> {
		if (this.#closePromise != null) return this.#closePromise;
		this.#closed = true;
		const entries = [...this.#held.values()].flat();
		this.#held.clear();
		this.#heldCount = 0;
		const closing: Promise<void>[] = [];
		for (const entry of entries) {
			this.#detach(entry);
			closing.push(this.#closeHeld(entry, "relay.rendezvous.shutdown.close"));
		}
		this.#closePromise = (async () => {
			let failure: unknown = null;
			for (const outcome of await Promise.allSettled(closing)) {
				if (outcome.status === "fulfilled") continue;
				if (failure == null) failure = outcome.reason;
				else retainSecondaryFailure(failure, outcome.reason);
			}
			if (failure != null) throw failure;
		})();
		void this.#closePromise.catch(() => {});
		return this.#closePromise;
	}
}

/** One held registration: the raw socket (for identity and drop-on-close) and
 * the buffering channel a bridge pipes a dialer to. */
interface Held {
	designator: string;
	socket: WebSocket;
	channel: RelayChannel;
	onDrop: () => void;
}
