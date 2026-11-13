/// <reference path="../../virtual-glowcap-web.d.ts" />

/**
 * Live capability consumer, CapTP peer, reconnect, and the inbox that
 * feeds `feed.ts`. The viewer writes only the capability protocol:
 * it enlivens the announced trace capability, hosts an inbox, and asks
 * to subscribe. It never writes a trace record or gains authority over
 * the observed room.
 *
 * The bounded record payload is the same JSON string the producer/schema
 * path already uses. There is one parser and one converter, CapTP is
 * only the capability transport around that authority.
 */

import type { LiveConnectionState } from "./status.ts";
import type { TimelineEvent } from "../timeline.ts";
import type { EngineError } from "../errors.ts";
import type { BrowserRuntime, GlowcapWebModule } from "./glowcap-web-api.ts";
import { makeBaseEventConverter } from "./feed.ts";
import { numberFromWire, parseWireRecord } from "./record.ts";
import { localNetworkBlock, outOfReach, traceSocketUrl } from "./reach.ts";

/** The first reconnect waits this long, doubling to `RECONNECT_MAX_MS`. */
export const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 5_000;
export const MAX_TRACE_RECORD_BYTES = 1 << 20;

/** Whether `line` encodes to more than `MAX_TRACE_RECORD_BYTES` of UTF-8.
 *  A UTF-16 string of length n encodes to at most 3n bytes, so a line that
 *  short is within the bound without being encoded. */
function exceedsRecordBound(line: string): boolean {
	if (line.length * 3 <= MAX_TRACE_RECORD_BYTES) return false;
	return new TextEncoder().encode(line).byteLength > MAX_TRACE_RECORD_BYTES;
}

function retirementError(cause: unknown): EngineError {
	return {
		code: "internal",
		title: "Live connection did not close cleanly",
		detail: cause instanceof Error ? cause.message : String(cause),
		recovery: "Reload the viewer before reconnecting from Live.",
		cause,
	};
}

/** A dial the browser blocked before any socket opened. */
function blockedByBrowser(cause: unknown): EngineError {
	return {
		code: "validation",
		title: "The browser is keeping this page from your computer",
		detail: "This site is not allowed to reach devices on your local network, and a trace on this computer is one.",
		recovery: "Allow local network access for this site in the browser's site settings, then wait for reconnect.",
		cause,
	};
}

/** What to try when the browser has not been answered, where a blocked socket
 * and a server that is not running fail alike. */
const UNANSWERED_RECOVERY =
	"Check the sturdyref and the rooms server. If the browser asks whether this site may reach devices on your local network, allow it. Then wait for reconnect.";

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
	signal: AbortSignal,
) => Promise<LivePeer>;

class PeerSetupRetirementError extends AggregateError {
	constructor(primary: unknown, readonly retirement: unknown) {
		super([primary, retirement], retirement instanceof Error ? retirement.message : String(retirement), {
			cause: primary,
		});
	}
}

class BrowserRuntimeStartupError extends Error {
	constructor(cause: unknown) {
		super(cause instanceof Error ? cause.message : String(cause), { cause });
	}
}

let browserRuntimePromise: Promise<BrowserRuntime> | null = null;

/** The wasm Host sits beside the entry document, at whatever path the page
 * is served from. */
function wasmUrl(): string {
	const configured = globalThis.__OCV_GLOWCAP_WASM_URL;
	return typeof configured === "string" ? configured : new URL("glowcap_host.wasm", document.baseURI).href;
}

async function browserRuntime(): Promise<BrowserRuntime> {
	if (browserRuntimePromise !== null) return await browserRuntimePromise;
	browserRuntimePromise = (async () => {
		const override = globalThis.__OCV_GLOWCAP_WEB_LOADER;
		const web: GlowcapWebModule = typeof override === "function"
			? await override()
			: await import("virtual:glowcap-web");
		// `init` is identity-sensitive. Keep this one options object
		// for the page, so remounting Live mode does not attempt a second runtime.
		return await web.init({
			wasm: fetch(wasmUrl()),
			// A test runs with no document, and nothing there forbids a host.
			wsUrl: (host, port) => traceSocketUrl(globalThis.document?.location.protocol ?? "", host, port),
		});
	})().catch((error) => {
		browserRuntimePromise = null;
		throw new BrowserRuntimeStartupError(error);
	});
	return await browserRuntimePromise;
}

/** The production browser peer. The socket is created by `@glowcap/runtime` from
 * the sturdyref's parsed locator. This function never interprets or forwards
 * CapTP bytes. */
export const browserPeerFactory: LivePeerFactory = async (
	sturdyref,
	onRecord,
	signal,
) => {
	const runtime = await browserRuntime();
	signal.throwIfAborted();
	const { locator } = runtime.parseSturdyRef(sturdyref, "v1_0");
	const session = await runtime.connect(locator, { signal });
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
	let cancelSetup!: () => void;
	const cancelled = new Promise<never>((_, reject) => {
		cancelSetup = () => reject(signal.reason);
	});
	const construct = async (): Promise<LivePeer> => {
		const inbox = session.spawn((verb, args) => {
			if (
				verb !== "record" || args.length !== 1 ||
				typeof args[0] !== "string"
			) {
				throw new Error("trace inbox expects one JSON string record");
			}
			if (exceedsRecordBound(args[0])) {
				void retire();
				throw new Error("trace record exceeds the viewer bound");
			}
			onRecord(args[0]);
			return null;
		});
		const trace = await session.enliven(sturdyref);
		signal.throwIfAborted();
		await session.send(trace, "subscribe", [inbox]);
		signal.throwIfAborted();
		return {
			closed: gone,
			close: () => {
				const started = retire();
				return pumpEnded ? started : gone;
			},
		};
	};
	try {
		signal.addEventListener("abort", cancelSetup, { once: true });
		signal.throwIfAborted();
		return await Promise.race([construct(), cancelled]);
	} catch (error) {
		let failure = signal.aborted ? signal.reason : error;
		try {
			await retire();
			// tolerant: a pump that ends in a fault is the session ending,
			// which the setup failure already reports. Only a refused close
			// is a failed retirement.
			await closed.catch(() => {});
		} catch (retirement) {
			failure = new PeerSetupRetirementError(failure, retirement);
		}
		throw failure;
	} finally {
		signal.removeEventListener("abort", cancelSetup);
	}
};

export class LiveFeed {
	#sturdyref: string;
	#peer: LivePeer | null = null;
	#factory: LivePeerFactory;
	#convert = makeBaseEventConverter();
	#subscribers = new Set<(ev: TimelineEvent) => void>();
	#errorSubscribers = new Set<(error: EngineError) => void>();
	/** Who hears this feed's connection state, or null when nobody
	 * owns it any more. A feed that has been disconnected clears the
	 * slot, because `ws.onclose` fires asynchronously AFTER `close()`
	 * returns: a slot left pointing at the last owner is how a
	 * replaced feed writes `connecting` over its successor's `connected`. */
	#onConnectionChange: ((state: LiveConnectionState) => void) | null = null;
	/** Highest live-tail producer `seq` applied. A reconnect's snapshot still
	 * passes through at old sequence numbers so it can reconcile current state.
	 * Ordinary live records at or below this are dropped. Scoped to the
	 * producer `#epoch`: a restarted producer restarts its seq, so
	 * the window resets with the epoch (the converter separately
	 * retires the dead epoch's topology). */
	#lastSeq = Number.NEGATIVE_INFINITY;
	#epoch: number | undefined = undefined;
	/** True after `disconnect()`. A deliberate close never
	 * reconnects. A dropped connection does, with capped backoff. */
	#closedByUser = false;
	#reconnectTimer: ReturnType<typeof setTimeout> | null = null;
	#reconnectDelayMs = RECONNECT_MIN_MS;
	#generation = 0;
	#dial: AbortController | null = null;
	#requiresReload = false;

	constructor(
		sturdyref: string,
		factory: LivePeerFactory = browserPeerFactory,
	) {
		this.#sturdyref = sturdyref;
		this.#factory = factory;
	}

	connect(): void {
		if (this.#peer !== null || this.#dial !== null || this.#requiresReload) return;
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
			this.#onConnectionChange?.("refused");
			return;
		}
		const generation = ++this.#generation;
		const dial = new AbortController();
		this.#dial = dial;
		void this.#factory(
			this.#sturdyref,
			(line) => this.#receive(generation, line),
			dial.signal,
		).then(
			(peer) => {
				if (this.#dial === dial) this.#dial = null;
				if (generation !== this.#generation || this.#closedByUser) {
					this.#observeRetirement(peer.close());
					return;
				}
				this.#peer = peer;
				this.#reconnectDelayMs = RECONNECT_MIN_MS;
				this.#onConnectionChange?.("connected");
				void peer.closed.then(
					() => this.#peerClosed(generation),
					(cause) => this.#peerClosed(generation, cause),
				);
			},
			(cause) => {
				if (this.#dial === dial) this.#dial = null;
				const cleanup = cause instanceof PeerSetupRetirementError ? cause : null;
				if (generation !== this.#generation || this.#closedByUser) {
					if (cleanup !== null) this.#emitError(retirementError(cleanup.retirement));
					return;
				}
				const primary = cleanup === null ? cause : cleanup.cause;
				if (cleanup !== null) this.#requiresReload = true;
				// The browser forbids this host from this page for as long as the
				// page is this one, so no later attempt differs.
				const forbidden = cleanup === null ? outOfReach(primary) : null;
				const startup = primary instanceof BrowserRuntimeStartupError;
				this.#onConnectionChange?.(
					forbidden !== null ? "refused" : cleanup !== null || startup ? "stopped" : "connecting",
				);
				// The application modal keeps the latest error. Report cleanup
				// separately, then keep both details visible with the primary.
				if (cleanup !== null) this.#emitError(retirementError(cleanup.retirement));
				if (forbidden !== null) {
					this.#emitError({
						code: "validation",
						title: "This page cannot reach that trace",
						detail: forbidden.message,
						recovery:
							"Paste a trace link for this computer, or run ocapnviz from a glowcap checkout with zig build ocapnviz-dev, which reaches a trace at any address.",
						cause: primary,
					});
					return;
				}
				const detail = primary instanceof Error ? primary.message : String(primary);
				const cleanupDetail = cleanup === null ? "" : `\n\nCleanup failed: ${cleanup.message}`;
				if (startup) {
					this.#emitError({
						code: "internal",
						title: "Live runtime could not start",
						detail: detail + cleanupDetail,
						recovery: "Reload the viewer. If startup still fails, check its browser assets.",
						cause: primary.cause,
					});
					return;
				}
				const unreachable: EngineError = {
					code: "internal",
					title: "Live capability unreachable",
					detail: detail + cleanupDetail,
					recovery: cleanup === null
						? "Check the sturdyref and the rooms server, then wait for reconnect."
						: "Automatic reconnect stopped because session cleanup failed. Reload the viewer before reconnecting.",
					cause: primary,
				};
				// A dial the browser blocked fails like a server that is not
				// running, so the browser is asked what it holds.
				const asked = cleanup === null ? localNetworkBlock() : null;
				if (asked === null) {
					this.#emitError(unreachable);
				} else {
					void asked.then((held) => {
						if (generation !== this.#generation || this.#closedByUser) return;
						this.#emitError(
							held === "denied"
								? blockedByBrowser(primary)
								: held === "prompt"
								? { ...unreachable, recovery: UNANSWERED_RECOVERY }
								: unreachable,
						);
					});
				}
				if (cleanup === null) this.#scheduleReconnect();
			},
		);
	}

	#receive(generation: number, line: string): void {
		if (generation !== this.#generation || this.#closedByUser) return;
		if (exceedsRecordBound(line)) return;
		try {
			const raw = parseWireRecord(line);
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

	/** The live peer ended. A clean close is the connection change alone. A
	 * fault is reported once with the reconnect as its recovery, so the
	 * person watching Live learns why the stage went quiet. */
	#peerClosed(generation: number, cause?: unknown): void {
		if (generation !== this.#generation || this.#closedByUser) return;
		this.#peer = null;
		this.#onConnectionChange?.("connecting");
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
		}, this.#reconnectDelayMs);
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
		this.#dial?.abort();
		this.#dial = null;
		this.#onConnectionChange = null;
		if (this.#reconnectTimer !== null) {
			clearTimeout(this.#reconnectTimer);
			this.#reconnectTimer = null;
		}
		if (this.#peer !== null) {
			this.#observeRetirement(this.#peer.close());
			this.#peer = null;
		}
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
	 * Hear this feed's connection state. Returns an unsubscribe, the
	 * way `subscribe` does, and for the same reason one level
	 * up: the owner that registered has to be able to stop being the
	 * owner. A slot with no way out is what let a torn-down feed's late
	 * `onclose` write `connecting` into a live component's state after its
	 * replacement had already reported `connected`.
	 *
	 * One slot, not a set: the connection is one fact about one socket
	 * and the app shows it in one place. Registering a second callback
	 * replaces the first.
	 */
	onConnectionChange(cb: (state: LiveConnectionState) => void): () => void {
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
