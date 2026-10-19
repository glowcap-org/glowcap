// The accepting half of the cold-dial rendezvous (ADR-0034 capability 5). A
// peer that opens no listening socket (a browser tab, or any process behind a
// NAT that declines a listener) cannot be dialed. Instead it registers its
// authenticated identity and a held inbound socket at a relay; a peer that redeems an
// introduction naming that identity is bridged onto the held socket, and the
// keyed or Noise handshake runs end to end between them. The relay parses
// nothing and holds no capability. The relay half is `@glowcap/relay`'s
// `Rendezvous`; this is the accepting side, runtime-neutral over the
// `WebSocket` global.
//
// `serveRendezvous` keeps a small pool of registration sockets, each parked in
// the accept handshake reading its socket until a dialer's bytes arrive through
// the bridge (a registration accept has no read deadline, so an idle
// registration waits). When one is bridged and its session opens, the
// host's publications answer it and the pool replenishes, so the peer can be
// cold-dialed again.
//
// The dialing side has exactly one mechanism, and it is not here: a
// `keyed-relay` locator carries its relay route in its `rendezvous-relay`
// hint, and the redeemer follows that hint. `@glowcap/relay`'s explicit
// connector opens the hinted WebSocket and drives
// `Session.establishDialedLocator` (the mirror of the `establishAccepted`
// this module parks on), and its FFI provider package carries the same
// dial inside the driver loop. Keeping the redeeming side on that one
// locator-carried route is what lets the conformance proof pin a single
// cold-dial mechanism rather than a raw dial-by-designator convenience
// beside it.

import type { Host } from "./host.ts";
import type { Timer } from "./timer.ts";
import { retainSecondaryFailure } from "./errors.ts";
import { Session } from "./session.ts";
import { TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "./locator.ts";
import type { Locator } from "./locator.ts";
import { type WebSocketByteChannel, webSocketChannel } from "./websocket.ts";
import { DESIGNATOR_SCHEME_KEY } from "@glowcap/abi";

/** The two wire profiles the relay rendezvous can carry. Required at the API
 * boundary so registration, the Host's advertised locator, and accepted
 * sessions cannot silently disagree about whether the byte pipe is sealed. */
export type RendezvousTransport = typeof TRANSPORT_KEYED_RELAY | typeof TRANSPORT_NOISE_RELAY;

// How many inbound sockets to hold ready at once, so a burst of cold-dials does
// not race a window where none is registered. A bridge consumes one; the pool
// replenishes on the session opening.
const DEFAULT_POOL = 2;

// Backoff before replacing a registration that closed without carrying a session
// (a torn-down socket, an unreachable relay), so a down relay is polled, not
// hot-looped.
const REPLENISH_BACKOFF_MS = 1_000;

/** A running rendezvous registration. `stop` is an idempotent barrier: it
 * cancels pending retries, closes registration sockets, and joins their
 * establishment work. Sessions already accepted belong to the Host and are
 * not closed with the listener. */
export interface RendezvousHandle {
	/** The complete locator installed on the Host and advertised to peers. */
	readonly locator: Locator;
	/** Settle when at least one registration socket is open. If the listener is
	 * stopped first, reject instead of leaving initialization parked forever. */
	ready(): Promise<void>;
	stop(): Promise<void>;
	/** Stop new admission, then join sessions already accepted through this
	 * listener without closing them. Use this process-teardown barrier before
	 * releasing the Host; an active peer may keep it pending indefinitely. */
	drain(): Promise<void>;
	[Symbol.asyncDispose](): Promise<void>;
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
 * `` (id) => `wss://example/register?id=${id}` ``. The host's publications
 * (`publish`) answer each accepted session. Returns a handle whose
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
	const pool = opts.pool ?? DEFAULT_POOL;
	if (!Number.isSafeInteger(pool) || pool <= 0) {
		throw new TypeError("rendezvous pool must be a positive safe integer");
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
	let stopped = false;
	let stopPromise: Promise<void> | null = null;
	let drainPromise: Promise<void> | null = null;
	// Adapt at construction, not after admission. The listener then has exactly
	// one owner for buffering and physical close from the socket's first byte:
	// pending registrations are retired through the channel barrier, while an
	// admitted channel is transferred unchanged to its Session.
	const pending = new Map<WebSocket, WebSocketByteChannel>();
	const registrations = new Set<Promise<void>>();
	const accepted = new Set<Promise<void>>();
	const retries = new Set<Timer>();
	let readyState: "pending" | "ready" | "stopped" = "pending";
	const readyWaiters: Array<{ resolve(): void; reject(error: Error): void }> = [];

	const publishReady = (): void => {
		if (readyState !== "pending") return;
		readyState = "ready";
		for (const waiter of readyWaiters.splice(0)) waiter.resolve();
	};

	const report = (operation: string, error: unknown): void => {
		host.recordCallerlessBindingFailure(operation, error);
		if (opts.onError == null) return;
		try {
			opts.onError(error);
		} catch (observerError) {
			host.recordCallerlessFailure("rendezvous.on-error", observerError);
		}
	};

	const schedule = (delay: number): void => {
		if (stopped) return;
		const timer = setTimeout(() => {
			retries.delete(timer);
			registerOne();
		}, delay);
		retries.add(timer);
	};

	const registerOne = (): void => {
		if (stopped) return;
		let ws: WebSocket;
		try {
			ws = new WebSocket(route.registerUrl(designator));
		} catch (err) {
			report("rendezvous.register.open", err);
			schedule(REPLENISH_BACKOFF_MS);
			return;
		}
		const channel = webSocketChannel(ws);
		pending.set(ws, channel);
		const work = (async () => {
			let admitted = false;
			try {
				await new Promise<void>((resolve, reject) => {
					let settled = false;
					const settle = (fn: () => void) => {
						if (settled) return;
						settled = true;
						ws.removeEventListener("open", onOpen);
						ws.removeEventListener("close", onClose);
						ws.removeEventListener("error", onError);
						fn();
					};
					const onOpen = () =>
						settle(() => {
							publishReady();
							resolve();
						});
					const onClose = () =>
						settle(() => reject(new Error("rendezvous register socket closed before open")));
					const onError = () => settle(() => reject(new Error("rendezvous register socket failed to open")));
					ws.addEventListener("open", onOpen, { once: true });
					ws.addEventListener("close", onClose, { once: true });
					ws.addEventListener("error", onError, { once: true });
					if (ws.readyState === WebSocket.OPEN) onOpen();
					else if (ws.readyState === WebSocket.CLOSING || ws.readyState === WebSocket.CLOSED) onClose();
				});
				if (stopped) return;
				// A registration is meant to park until a dialer is bridged. Once the
				// handshake succeeds, ownership moves from this listener to the Host:
				// stopping future admission must not tear down an admitted session.
				const session = await Session.establishAccepted(
					host,
					{
						transport,
						designatorScheme: DESIGNATOR_SCHEME_KEY,
						serverDesignator: designator,
						channel,
					},
					0,
				);
				admitted = true;
				pending.delete(ws);
				if (!stopped) registerOne();
				const serving = session.serve()
					.catch((error) => report("rendezvous.session.serve", error));
				accepted.add(serving);
				void serving.then(
					() => accepted.delete(serving),
					() => accepted.delete(serving),
				);
			} catch (error) {
				if (!stopped) report("rendezvous.register.accept", error);
			} finally {
				pending.delete(ws);
				if (!stopped && !admitted) schedule(REPLENISH_BACKOFF_MS);
			}
		})();
		registrations.add(work);
		void work.finally(() => registrations.delete(work));
	};

	for (let i = 0; i < pool; i++) registerOne();
	return {
		locator,
		ready() {
			if (readyState === "ready") return Promise.resolve();
			if (readyState === "stopped") {
				return Promise.reject(new Error("rendezvous stopped before a registration became ready"));
			}
			return new Promise<void>((resolve, reject) => readyWaiters.push({ resolve, reject }));
		},
		stop() {
			if (stopPromise != null) return stopPromise;
			stopped = true;
			if (readyState === "pending") {
				readyState = "stopped";
				const error = new Error("rendezvous stopped before a registration became ready");
				for (const waiter of readyWaiters.splice(0)) waiter.reject(error);
			}
			stopPromise = (async () => {
				for (const timer of retries) clearTimeout(timer);
				retries.clear();
				let failure: unknown = null;
				const closing = [...pending.values()].map((channel) => channel.close(1000, "rendezvous stopped"));
				for (const outcome of await Promise.allSettled(closing)) {
					if (outcome.status === "fulfilled") continue;
					if (failure == null) failure = outcome.reason;
					else retainSecondaryFailure(failure, outcome.reason);
				}
				for (const outcome of await Promise.allSettled([...registrations])) {
					if (outcome.status === "fulfilled") continue;
					if (failure == null) failure = outcome.reason;
					else retainSecondaryFailure(failure, outcome.reason);
				}
				if (failure != null) throw failure;
			})();
			return stopPromise;
		},
		drain() {
			if (drainPromise != null) return drainPromise;
			drainPromise = (async () => {
				await this.stop();
				let failure: unknown = null;
				while (accepted.size !== 0) {
					for (const outcome of await Promise.allSettled([...accepted])) {
						if (outcome.status === "fulfilled") continue;
						if (failure == null) failure = outcome.reason;
						else retainSecondaryFailure(failure, outcome.reason);
					}
				}
				if (failure != null) throw failure;
			})();
			return drainPromise;
		},
		[Symbol.asyncDispose]() {
			return this.stop();
		},
	};
}
