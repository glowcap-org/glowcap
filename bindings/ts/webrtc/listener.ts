// The browser's WebRTC listener: it answers offers the application hands in,
// with its own `RtcPeer` for each, and yields a keyed session that names the
// offerer once the DataChannel opens. `provideOffer`, `failExchange`,
// iteration, and `close` behave as on the Deno `Server` in `./driver.ts`, so
// one application's signaling code serves both.

import {
	formatLocatorUri,
	GlowcapError,
	type Host,
	isKeyDesignator,
	type Locator,
	Session,
	TRANSPORT_WEBRTC,
} from "@glowcap/runtime";
import {
	CLOSED,
	DESIGNATOR_SCHEME_KEY,
	INVALID_ARGUMENT,
	WEBRTC_MAX_ACCEPTS_IN_FLIGHT,
	WOULD_BLOCK,
} from "@glowcap/abi";
import { bringUp, mintExchange, type PeerOptions, type SignalingAuthority, type SignalingTarget } from "./exchange.ts";
import { assertSignalBytes } from "./signal.ts";

type Answering = Omit<SignalingAuthority, "offer">;

type Accept = {
	readonly abort: AbortController;
	/** Set when the DataChannel opens, after which the accept cannot be given up. */
	opened: boolean;
	/** Why the listener ended this accept itself, so its failure is not a fault. */
	ended: "given up" | "closed" | null;
};

/** A browser Host answering WebRTC offers. Iterate it for each accepted
 * `Session`, whose partner identity names the offerer with
 * authenticated-transport provenance. Sessions already yielded belong to the
 * application and stay open when the listener closes. */
export class Listener implements AsyncIterable<Session>, AsyncDisposable {
	readonly #host: Host;
	readonly #signaling: Answering;
	readonly #options: PeerOptions;
	readonly #locator: Locator;
	readonly #accepts = new Map<bigint, Accept>();
	readonly #ready: Session[] = [];
	readonly #waiters: Array<(session: Session | null) => void> = [];
	readonly #settled = new Set<Promise<void>>();
	#closing: Promise<void> | null = null;

	constructor(host: Host, signaling: Answering, options: PeerOptions) {
		this.#host = host;
		this.#signaling = signaling;
		this.#options = options;
		this.#locator = {
			transport: TRANSPORT_WEBRTC,
			designator: host.designator(),
			hints: new Map(),
			hintWireForm: "boolean-false",
		};
	}

	/** The `webrtc` locator that names this Host's key. */
	get locator(): Locator {
		return this.#locator;
	}

	/** The locator as a URI. */
	get uri(): string {
		return formatLocatorUri(this.#locator);
	}

	/** The Host's key, which the listener is reached by. */
	get designator(): string {
		return this.#locator.designator;
	}

	get host(): Host {
		return this.#host;
	}

	/** Select this listener's locator as the Host's advertised location. */
	select(): void {
		this.#host.setAdvertisedLocator(this.#locator);
	}

	/** Hand in an SDP offer from the peer whose designator is `designator`.
	 * The listener answers through the authority's `answer`, and the returned
	 * exchange id names the accept for `failExchange`. A `GlowcapError` means no
	 * exchange was started: the listener is closed, `designator` is not a key or
	 * the offer is too large, or too many accepts are in flight.
	 *
	 * The browser builds its answer asynchronously, so a failure after this
	 * returns (the offer is malformed, `answer` throws, or ICE finds no route)
	 * ends the accept and is kept as a callerless failure on the Host. An
	 * accept has no deadline of its own. One whose offerer goes quiet holds its
	 * place until the application calls `failExchange`. */
	provideOffer(designator: string, sdp: string): bigint {
		if (this.#closing != null) {
			throw new GlowcapError(CLOSED, "webrtc provide_offer: the listener is closed");
		}
		if (!isKeyDesignator(designator)) {
			throw new GlowcapError(INVALID_ARGUMENT, "webrtc provide_offer: the offerer designator names no key");
		}
		try {
			assertSignalBytes("SDP offer", sdp);
		} catch (error) {
			throw new GlowcapError(INVALID_ARGUMENT, `webrtc provide_offer: ${(error as Error).message}`);
		}
		if (this.#accepts.size + this.#ready.length >= WEBRTC_MAX_ACCEPTS_IN_FLIGHT) {
			throw new GlowcapError(
				WOULD_BLOCK,
				`webrtc provide_offer: ${WEBRTC_MAX_ACCEPTS_IN_FLIGHT} accepts are already in flight`,
			);
		}
		const exchange = mintExchange();
		const accept: Accept = { abort: new AbortController(), opened: false, ended: null };
		this.#accepts.set(exchange, accept);
		const signaling = this.#signaling;
		const host = this.#host;
		const target: SignalingTarget = { designator, introducer: null };
		const settled = bringUp(
			host,
			signaling,
			exchange,
			target,
			this.#options,
			accept.abort.signal,
			"webrtc accept",
			{
				offerer: false,
				async negotiate(peer, step) {
					await step(peer.setRemoteOffer(sdp), "remote-offer");
					const answer = await step(peer.createAnswer(), "answer");
					await step(Promise.resolve().then(() => signaling.answer(exchange, target, answer)), "signaling");
				},
				opened() {
					accept.opened = true;
				},
				establish: (channel) =>
					Session.establishAccepted(host, {
						transport: TRANSPORT_WEBRTC,
						designatorScheme: DESIGNATOR_SCHEME_KEY,
						serverDesignator: host.designator(),
						channel,
						// The signaling authority scoped this exchange to the offerer, and
						// DTLS binds the channel to the SDP it carried (ADR-0028).
						verifiedChannelKey: designator,
					}),
			},
		).then(
			(session) => this.#deliver(exchange, session),
			(error) => {
				this.#accepts.delete(exchange);
				if (accept.ended == null) host.recordCallerlessBindingFailure("webrtc.accept", error);
			},
		);
		this.#settled.add(settled);
		void settled.finally(() => this.#settled.delete(settled));
		return exchange;
	}

	/** Give up on the accept `exchange` because its signaling broke or its
	 * offerer went quiet. It ends without a session and its candidate
	 * subscription is disposed. A `GlowcapError` means no such accept is in
	 * progress or its channel has already opened, and nothing changed. */
	failExchange(exchange: bigint): void {
		const accept = this.#accepts.get(exchange);
		if (accept == null || accept.opened) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				"webrtc fail_exchange: no such accept is in progress or its channel has already opened",
			);
		}
		accept.ended = "given up";
		accept.abort.abort();
	}

	// The next accepted session, or `null` once the listener is closed.
	#accept(): Promise<Session | null> {
		const ready = this.#ready.shift();
		if (ready != null) return Promise.resolve(ready);
		if (this.#closing != null) return Promise.resolve(null);
		return new Promise((resolve) => this.#waiters.push(resolve));
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		try {
			while (true) {
				const session = await this.#accept();
				if (session == null) return;
				yield session;
			}
		} finally {
			await this.close();
		}
	}

	/** Stop taking offers, end every accept still in flight, and close the
	 * sessions nobody has taken yet. Waits for each to finish. */
	close(): Promise<void> {
		if (this.#closing != null) return this.#closing;
		this.#closing = (async () => {
			for (const resolve of this.#waiters.splice(0)) resolve(null);
			for (const accept of this.#accepts.values()) {
				accept.ended = "closed";
				accept.abort.abort();
			}
			while (this.#settled.size !== 0) await Promise.allSettled([...this.#settled]);
			for (const session of this.#ready.splice(0)) await this.#discard(session);
		})();
		return this.#closing;
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}

	async #deliver(exchange: bigint, session: Session): Promise<void> {
		this.#accepts.delete(exchange);
		if (this.#closing != null) return await this.#discard(session);
		const waiter = this.#waiters.shift();
		if (waiter != null) waiter(session);
		else this.#ready.push(session);
	}

	async #discard(session: Session): Promise<void> {
		try {
			await session.closeTransport();
		} catch (error) {
			this.#host.recordCallerlessBindingFailure("webrtc.accept.close", error);
		}
	}
}

/** Answer WebRTC offers for `host` through `signaling`, and select the
 * listener's `webrtc` locator as the Host's advertised location. Hand each
 * inbound offer to `provideOffer`, and route the offerer's candidates to the
 * `onCandidate` sink the authority was given. */
export function listener(host: Host, signaling: Answering, options: PeerOptions = {}): Listener {
	const listening = new Listener(host, signaling, options);
	listening.select();
	return listening;
}
