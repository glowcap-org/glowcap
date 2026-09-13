/// <reference path="../../virtual-glowcap-web.d.ts" />

/**
 * Live capability consumer — CapTP peer, reconnect, and the inbox that
 * feeds `feed.ts`. The viewer writes only the capability protocol:
 * it enlivens the announced trace capability, hosts an inbox, and asks
 * to subscribe. It never writes a trace record or gains authority over
 * the observed room.
 *
 * The bounded record payload is the same JSON string the producer/schema
 * path already uses. There is one parser and one converter; CapTP is
 * only the capability transport around that authority.
 */

import type { TimelineEvent } from "../timeline.ts";
import type { EngineError } from "../errors.ts";
import type { BrowserRuntime, GlowcapWebModule } from "./glowcap-web-api.ts";
import { makeBaseEventConverter } from "./feed.ts";
import { type BaseTimelineEvent, numberFromWire } from "./record.ts";

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 5_000;
export const MAX_TRACE_RECORD_BYTES = 1 << 20;

function retirementError(cause: unknown): EngineError {
	return {
		code: "internal",
		title: "Live connection did not close cleanly",
		detail: cause instanceof Error ? cause.message : String(cause),
		recovery: "The feed is disconnected. Reconnect from Live if you still need it.",
		cause,
	};
}

export type LivePeer = {
	/** Retire this exact session. Resolves once its transport and hosted
	 * inbox are released, and rejects with the exact retirement failure, which
	 * the caller owns: a rejection left unobserved is fatal to the page. */
	close: () => Promise<void>;
	/** Settles when this exact CapTP session and its hosted inbox are gone,
	 * including a retirement the peer started itself. */
	closed: Promise<void>;
};
export type LivePeerFactory = (
	sturdyref: string,
	onRecord: (line: string) => void,
) => Promise<LivePeer>;

let browserRuntimePromise: Promise<BrowserRuntime> | null = null;

/** The capability the trace endpoint requires of the socket itself, presented
 * as the `cap` query parameter (the rooms endpoint's admission contract). The
 * sturdyref's swissnum IS that capability, so the viewer presents what it
 * already holds and the operator pastes nothing extra. Module state because
 * the runtime — and so its `wsUrl` mapping — is created once for the page,
 * while each dial's capability comes from the sturdyref being dialed. */
let vizSocketCap = "";

function wasmUrl(): string {
	const configured = (globalThis as { __OCV_GLOWCAP_WASM_URL?: string })
		.__OCV_GLOWCAP_WASM_URL;
	return configured ?? "/glowcap_host.wasm";
}

async function browserRuntime(): Promise<BrowserRuntime> {
	if (browserRuntimePromise !== null) return await browserRuntimePromise;
	browserRuntimePromise = (async () => {
		const override = (globalThis as {
			__OCV_GLOWCAP_WEB_LOADER?: () => Promise<GlowcapWebModule>;
		}).__OCV_GLOWCAP_WEB_LOADER;
		const web = override === undefined ? await import("virtual:glowcap-web") : await override();
		// `init` is identity-sensitive by design. Keep this one options object
		// for the page, so remounting Live mode does not attempt a second runtime.
		return await web.init({
			wasm: fetch(wasmUrl()),
			wsUrl: (host, port) =>
				vizSocketCap === ""
					? `ws://${host}:${port}/`
					: `ws://${host}:${port}/?cap=${encodeURIComponent(vizSocketCap)}`,
		});
	})();
	try {
		return await browserRuntimePromise;
	} catch (error) {
		browserRuntimePromise = null;
		throw error;
	}
}

/** The production browser peer. The socket is created by `@glowcap/runtime` from
 * the sturdyref's parsed locator; this function never interprets or forwards
 * CapTP bytes. */
export const browserPeerFactory: LivePeerFactory = async (
	sturdyref,
	onRecord,
) => {
	const runtime = await browserRuntime();
	const { locator, swissnum } = runtime.parseSturdyRef(sturdyref, "v1_0");
	vizSocketCap = new TextDecoder().decode(swissnum);
	const session = await runtime.connect(locator);
	const closed = session.serve();
	// One retirement per session, with one owner for its outcome. A retirement
	// started while the pump is live (by the inbox, or by the feed) is adopted
	// into the peer's `closed` the moment it starts, so no window exists in
	// which it is unobserved; one requested after the pump has ended is
	// returned to its caller instead.
	let retirement: Promise<void> | null = null;
	let adopt!: (outcome: Promise<void>) => void;
	let pumpEnded = false;
	const gone = new Promise<void>((resolve, reject) => {
		adopt = resolve;
		closed.then(
			() => {
				pumpEnded = true;
				resolve(retirement ?? undefined);
			},
			(error) => {
				pumpEnded = true;
				reject(error);
			},
		);
	});
	// tolerant: the caller receives this same promise as `closed` once
	// construction succeeds and observes its outcome there. The inbox can
	// receive records before subscribe returns, so this handler only keeps a
	// failure during construction from surfacing as an unhandled rejection.
	void gone.catch(() => {});
	const retire = (): Promise<void> => {
		if (retirement === null) {
			retirement = Promise.resolve().then(() => session.close());
			if (!pumpEnded) adopt(retirement);
		}
		return retirement;
	};
	try {
		const inbox = session.spawn((verb, args) => {
			if (
				verb !== "record" || args.length !== 1 ||
				typeof args[0] !== "string"
			) {
				throw new Error("trace inbox expects one JSON string record");
			}
			const bytes = new TextEncoder().encode(args[0]).byteLength;
			if (bytes > MAX_TRACE_RECORD_BYTES) {
				void retire();
				throw new Error("trace record exceeds the viewer bound");
			}
			onRecord(args[0]);
			return null;
		});
		const trace = await session.enliven(sturdyref);
		await session.send(trace, "subscribe", [inbox]);
		return {
			closed: gone,
			close: () => {
				const started = retire();
				return pumpEnded ? started : gone;
			},
		};
	} catch (error) {
		// tolerant: the failure that brought construction down is the one
		// thrown; a close that then fails too is retirement of a session the
		// caller never received, and its cause would only shadow the first.
		await retire().catch(() => {});
		await closed.catch(() => {});
		throw error;
	}
};

export class LiveFeed {
	#sturdyref: string;
	#peer: LivePeer | null = null;
	#factory: LivePeerFactory;
	#convert = makeBaseEventConverter();
	#subscribers = new Set<(ev: TimelineEvent) => void>();
	#errorSubscribers = new Set<(error: EngineError) => void>();
	/** Who hears whether this feed is connected, or null when nobody
	 * owns it any more. A feed that has been disconnected clears the
	 * slot, because `ws.onclose` fires asynchronously AFTER `close()`
	 * returns: a slot left pointing at the last owner is how a
	 * replaced feed writes `false` over its successor's `true`. */
	#onConnectionChange: ((connected: boolean) => void) | null = null;
	/** Highest live-tail producer `seq` applied. A reconnect's snapshot still
	 * passes through at old sequence numbers so it can reconcile current state;
	 * ordinary live records at or below this are dropped. Scoped to the
	 * producer `#epoch`: a restarted producer restarts its seq, so
	 * the window resets with the epoch (the converter separately
	 * retires the dead epoch's topology). */
	#lastSeq = Number.NEGATIVE_INFINITY;
	#epoch: number | undefined = undefined;
	/** True after `disconnect()` — a deliberate close never
	 * reconnects; a dropped connection does, with capped backoff. */
	#closedByUser = false;
	#reconnectTimer: number | null = null;
	#reconnectDelayMs = RECONNECT_MIN_MS;
	#generation = 0;
	#connecting = false;

	constructor(
		sturdyref: string,
		factory: LivePeerFactory = browserPeerFactory,
	) {
		this.#sturdyref = sturdyref;
		this.#factory = factory;
	}

	connect(): void {
		if (this.#peer !== null || this.#connecting) return;
		this.#closedByUser = false;
		if (
			!this.#sturdyref.startsWith("ocapn://") ||
			!this.#sturdyref.includes("/s/")
		) {
			this.#emitError({
				code: "validation",
				title: "Live capability invalid",
				detail: `The live endpoint did not provide a sturdyref: "${this.#sturdyref}"`,
				recovery: "Paste the complete sturdyref announced by the rooms server.",
			});
			return;
		}
		const generation = ++this.#generation;
		this.#connecting = true;
		void this.#factory(
			this.#sturdyref,
			(line) => this.#receive(generation, line),
		).then(
			(peer) => {
				this.#connecting = false;
				if (generation !== this.#generation || this.#closedByUser) {
					this.#observeRetirement(peer.close());
					return;
				}
				this.#peer = peer;
				this.#reconnectDelayMs = RECONNECT_MIN_MS;
				this.#onConnectionChange?.(true);
				void peer.closed.then(
					() => this.#peerClosed(generation),
					(cause) => this.#peerClosed(generation, cause),
				);
			},
			(cause) => {
				this.#connecting = false;
				if (generation !== this.#generation || this.#closedByUser) {
					return;
				}
				this.#onConnectionChange?.(false);
				this.#emitError({
					code: "internal",
					title: "Live capability unreachable",
					detail: cause instanceof Error ? cause.message : String(cause),
					recovery: "Check the sturdyref and the rooms server, then wait for reconnect.",
					cause,
				});
				this.#scheduleReconnect();
			},
		);
	}

	#receive(generation: number, line: string): void {
		if (generation !== this.#generation || this.#closedByUser) return;
		if (
			new TextEncoder().encode(line).byteLength > MAX_TRACE_RECORD_BYTES
		) {
			return;
		}
		try {
			const raw = JSON.parse(line) as BaseTimelineEvent;
			const epoch = numberFromWire(raw.epoch);
			if (epoch != null && epoch !== this.#epoch) {
				this.#epoch = epoch;
				this.#lastSeq = Number.NEGATIVE_INFINITY;
			}
			const seq = numberFromWire(raw.seq);
			if (seq != null) {
				// Replay is the endpoint's complete current snapshot, not history to
				// deduplicate. Old sequence numbers must reach the converter so replay
				// completion can remove observations that disappeared during outage.
				if (raw.replay !== true && seq <= this.#lastSeq) return;
				this.#lastSeq = Math.max(this.#lastSeq, seq);
			}
			const converted = this.#convert(raw);
			for (const ev of converted) {
				for (const sub of this.#subscribers) sub(ev);
			}
		} catch (error) {
			this.#emitError({
				code: "validation",
				title: "Live record unreadable",
				detail: error instanceof Error ? error.message : String(error),
				recovery:
					"The feed stays connected and later records still arrive. Reload Live if the stage looks wrong.",
				cause: error,
			});
		}
	}

	/** The live peer ended. A clean close is the connection change alone; a
	 * fault is reported once with the reconnect as its recovery, so the
	 * person watching Live learns why the stage went quiet. */
	#peerClosed(generation: number, cause?: unknown): void {
		if (generation !== this.#generation || this.#closedByUser) return;
		this.#peer = null;
		this.#connecting = false;
		this.#onConnectionChange?.(false);
		if (cause !== undefined) {
			this.#emitError({
				code: "internal",
				title: "Live connection lost",
				detail: cause instanceof Error ? cause.message : String(cause),
				recovery: "Reconnecting. The stage keeps what it has, and a replay fills in what changed.",
				cause,
			});
		}
		this.#scheduleReconnect();
	}

	#scheduleReconnect(): void {
		if (this.#closedByUser || this.#reconnectTimer !== null) return;
		this.#reconnectTimer = setTimeout(() => {
			this.#reconnectTimer = null;
			this.connect();
		}, this.#reconnectDelayMs) as unknown as number;
		this.#reconnectDelayMs = Math.min(
			this.#reconnectDelayMs * 2,
			RECONNECT_MAX_MS,
		);
	}

	/** Close for good. A disconnected feed never reconnects and never
	 *  reports a connection change again: the slot is cleared here so the
	 *  `onclose` the browser delivers after this call reaches nobody. A
	 *  retirement that fails is still reported to `onError`, because it has
	 *  no other owner. */
	disconnect(): void {
		this.#closedByUser = true;
		this.#generation += 1;
		this.#onConnectionChange = null;
		if (this.#reconnectTimer !== null) {
			clearTimeout(this.#reconnectTimer);
			this.#reconnectTimer = null;
		}
		if (this.#peer !== null) {
			this.#observeRetirement(this.#peer.close());
			this.#peer = null;
		}
		this.#connecting = false;
	}

	/** A retirement has no caller to answer to: `disconnect()` returns before
	 * the transport is gone, and a stale generation's close has nobody
	 * waiting. Its failure still goes to the feed's one failure channel
	 * rather than becoming an unowned rejection. */
	#observeRetirement(retirement: Promise<void>): void {
		void retirement.catch((cause) => this.#emitError(retirementError(cause)));
	}

	subscribe(cb: (ev: TimelineEvent) => void): () => void {
		this.#subscribers.add(cb);
		return () => {
			this.#subscribers.delete(cb);
		};
	}

	/**
	 * Hear whether this feed is connected. Returns an unsubscribe, the
	 * way `subscribe` does, and for the same reason one level
	 * up: the owner that registered has to be able to stop being the
	 * owner. A slot with no way out is what let a torn-down feed's late
	 * `onclose` write `false` into a live component's state after its
	 * replacement had already reported `true`.
	 *
	 * One slot, not a set: the connection is one fact about one socket
	 * and the app shows it in one place. Registering a second callback
	 * replaces the first.
	 */
	onConnectionChange(cb: (connected: boolean) => void): () => void {
		this.#onConnectionChange = cb;
		return () => {
			if (this.#onConnectionChange === cb) {
				this.#onConnectionChange = null;
			}
		};
	}

	/**
	 * Hear about a failure this feed cannot recover from on its own, such as an
	 * invalid sturdyref or a failed dial/enliven. Returns an
	 * unsubscribe. Subscribers registered before `connect()` hear the
	 * dial's own refusal, which is why `startLiveMode` takes the
	 * callback as an option rather than letting its caller attach one
	 * afterwards.
	 */
	onError(cb: (error: EngineError) => void): () => void {
		this.#errorSubscribers.add(cb);
		return () => {
			this.#errorSubscribers.delete(cb);
		};
	}

	#emitError(error: EngineError): void {
		if (this.#errorSubscribers.size === 0) {
			console.error("LiveFeed:", error.detail);
			return;
		}
		for (const sub of this.#errorSubscribers) sub(error);
	}
}
