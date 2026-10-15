// Deno's WebRTC provider and listener: the driver loop dials a `webrtc` locator
// and answers inbound offers through the C library's netlayer, and this module
// carries the signaling the application owns. It opens
// `libglowcap_net_transport_webrtc`, so only Deno programs import it. The
// browser surface in `mod.ts` never does.

import { GlowcapError, type Host, TRANSPORT_WEBRTC } from "@glowcap/runtime";
import {
	DriverListener,
	type DriverLoop,
	type DriverProvider,
	DriverServer,
	ensureRuntimeReady,
	listenerLoopUnavailable,
	loopTierAvailable,
	prepareListenerLoop,
	retainCleanupFailures,
} from "@glowcap/runtime/transport";
import {
	ab,
	CLOSED,
	ffi,
	INVALID_ARGUMENT,
	IO,
	NULL,
	OK,
	outPointer,
	type Ptr,
	readErrorSlot,
	TRANSPORT_PROVIDER_SIZE,
	WEBRTC_CONFIG_ICE_SERVER_COUNT_OFF,
	WEBRTC_CONFIG_ICE_SERVERS_OFF,
	WEBRTC_CONFIG_INCLUDE_LOOPBACK_CANDIDATES_OFF,
	WEBRTC_CONFIG_SIGNALING_OFF,
	WEBRTC_CONFIG_SIZE,
	WEBRTC_ICE_SERVER_CREDENTIAL_OFF,
	WEBRTC_ICE_SERVER_SIZE,
	WEBRTC_ICE_SERVER_URL_COUNT_OFF,
	WEBRTC_ICE_SERVER_URLS_OFF,
	WEBRTC_ICE_SERVER_USERNAME_OFF,
	WEBRTC_SIGNALING_DONE_OFF,
	WEBRTC_SIGNALING_SEND_ANSWER_OFF,
	WEBRTC_SIGNALING_SEND_CANDIDATE_OFF,
	WEBRTC_SIGNALING_SEND_OFFER_OFF,
	WEBRTC_STRING_VIEW_LEN_OFF,
	WEBRTC_STRING_VIEW_PTR_OFF,
	WEBRTC_STRING_VIEW_SIZE,
} from "@glowcap/runtime/ffi";
import type { SignalingAuthority, SignalingTarget } from "./exchange.ts";
import { webrtcS } from "./ffi.ts";

export type { SignalingAuthority, SignalingTarget } from "./exchange.ts";

/** One WebRTC netlayer's configuration. */
export type DriverConfig = {
	/** STUN and TURN servers the dial offers candidates through. Omitted or
	 * empty gathers host candidates only, which reach a peer on the same
	 * network and no other. */
	iceServers?: RTCIceServer[];
	/** Offer loopback addresses too, for two peers on one machine. */
	includeLoopbackCandidates?: boolean;
};

/** What the exchange book hands the far peer's offer, answer, and candidates
 * to, and tells when signaling has failed an exchange. Each returns the C
 * library's result code, and `lastError` says why the call just refused. */
export interface ExchangeSink {
	provideOffer(designator: string, sdp: string): { readonly code: number; readonly exchange: bigint };
	provideAnswer(exchange: bigint, sdp: string): number;
	provideCandidate(exchange: bigint, ice: string): number;
	failExchange(exchange: bigint): number;
	lastError(): string | null;
}

type Exchange = {
	dispose: (() => void) | null;
	/** Set once the exchange has been given up, so `failExchange` runs once. */
	failed: boolean;
};

/** The exchanges in flight, dialed or accepted, keyed by the library's
 * exchange id. It maps the C library's four signaling callbacks onto a
 * `SignalingAuthority` and is the only way an answer or candidate reaches
 * `provide_*`. An exchange leaves the book when `done` fires, so a late answer
 * or candidate for a finished exchange is dropped here and never reaches a
 * netlayer the driver may have released. A dial is given up at most once,
 * whether signaling failed or the library refused its answer. */
export class ExchangeBook {
	readonly #signaling: SignalingAuthority;
	readonly #sink: ExchangeSink;
	readonly #host: Pick<Host, "recordCallerlessBindingFailure">;
	readonly #exchanges = new Map<bigint, Exchange>();

	constructor(
		signaling: SignalingAuthority,
		sink: ExchangeSink,
		host: Pick<Host, "recordCallerlessBindingFailure">,
	) {
		this.#signaling = signaling;
		this.#sink = sink;
		this.#host = host;
	}

	/** Exchanges in flight. */
	get size(): number {
		return this.#exchanges.size;
	}

	/** Hand the library an inbound offer from the peer `designator` names. It
	 * answers through the authority before this returns, and the exchange id
	 * names the accept for `failExchange`. A refusal starts no exchange. */
	provideOffer(designator: string, sdp: string): bigint {
		const { code, exchange } = this.#sink.provideOffer(designator, sdp);
		if (code !== OK) throw this.#refusal(code, "provide offer");
		return exchange;
	}

	/** Give up on `exchange` because its signaling broke. A refusal means no
	 * such exchange is signaling, and nothing changed. */
	failExchange(exchange: bigint): void {
		const code = this.#sink.failExchange(exchange);
		if (code !== OK) throw this.#refusal(code, "fail exchange");
	}

	/** `send_offer`: 0 accepts the dial, anything else refuses it. */
	sendOffer(exchange: bigint, target: SignalingTarget, sdp: string): number {
		return this.#register(exchange, target, "webrtc.signaling.offer", (entry) => {
			void this.#signaling.offer(exchange, target, sdp).then(
				(text) => {
					if (this.#exchanges.get(exchange) !== entry) return;
					if (this.#attempt("webrtc.signaling.answer", () => this.#sink.provideAnswer(exchange, text))) {
						this.#giveUp(exchange, entry);
					}
				},
				(error) => this.#fail(exchange, entry, "webrtc.signaling.offer", error),
			);
		});
	}

	/** `send_answer`: 0 accepts the offer, anything else refuses it. A throw
	 * refuses the offer before `provideOffer` returns, and a rejected promise
	 * gives the accept up. */
	sendAnswer(exchange: bigint, target: SignalingTarget, sdp: string): number {
		return this.#register(exchange, target, "webrtc.signaling.answer.send", (entry) => {
			const sent = this.#signaling.answer(exchange, target, sdp);
			if (sent instanceof Promise) {
				void sent.catch((error: unknown) => this.#fail(exchange, entry, "webrtc.signaling.answer.send", error));
			}
		});
	}

	/** `send_candidate`: 0 accepts, anything else fails the exchange. */
	sendCandidate(exchange: bigint, ice: string): number {
		const entry = this.#exchanges.get(exchange);
		if (entry === undefined) return INVALID_ARGUMENT;
		try {
			const sent = this.#signaling.candidate(exchange, ice);
			if (sent instanceof Promise) {
				void sent.catch((error: unknown) =>
					this.#fail(exchange, entry, "webrtc.signaling.candidate.send", error)
				);
			}
			return OK;
		} catch (error) {
			this.#host.recordCallerlessBindingFailure("webrtc.signaling.candidate.send", error);
			return IO;
		}
	}

	/** `done`: the exchange ended, so forget it and end its subscription. Every
	 * exchange ends here, accepted or dialed, finished or refused. */
	done(exchange: bigint): void {
		this.#end(exchange);
	}

	// Record `exchange` for `target`, subscribe to the far peer's candidates,
	// then run `begin`. Any failure forgets the exchange and refuses it. The
	// operation names what to record, and a reused id is refused untouched.
	#register(
		exchange: bigint,
		target: SignalingTarget,
		operation: string,
		begin: (entry: Exchange) => void,
	): number {
		if (this.#exchanges.has(exchange)) return INVALID_ARGUMENT;
		const entry: Exchange = { dispose: null, failed: false };
		this.#exchanges.set(exchange, entry);
		try {
			entry.dispose = this.#signaling.onCandidate(exchange, target, (ice) => {
				if (this.#exchanges.get(exchange) !== entry) return;
				this.#attempt("webrtc.signaling.candidate", () => this.#sink.provideCandidate(exchange, ice));
			});
			begin(entry);
			return OK;
		} catch (error) {
			this.#end(exchange);
			this.#host.recordCallerlessBindingFailure(operation, error);
			return IO;
		}
	}

	// Signaling failed after the exchange began: keep the error and give it
	// up, so a dial fails at the driver's next step instead of its deadline.
	#fail(exchange: bigint, entry: Exchange, operation: string, error: unknown): void {
		this.#host.recordCallerlessBindingFailure(operation, error);
		this.#giveUp(exchange, entry);
	}

	// Tell the library to fail the exchange, once and only while it is still in
	// the book. A refusal as INVALID_ARGUMENT means it ended between the check
	// and the call, which is a finished exchange and not a fault.
	#giveUp(exchange: bigint, entry: Exchange): void {
		if (entry.failed || this.#exchanges.get(exchange) !== entry) return;
		entry.failed = true;
		try {
			this.failExchange(exchange);
		} catch (error) {
			if (!(error instanceof GlowcapError && error.code === INVALID_ARGUMENT)) {
				this.#host.recordCallerlessBindingFailure("webrtc.signaling.fail", error);
			}
		}
	}

	// The one place an exchange is forgotten and its subscription ended.
	#end(exchange: bigint): void {
		const entry = this.#exchanges.get(exchange);
		if (entry === undefined) return;
		this.#exchanges.delete(exchange);
		const dispose = entry.dispose;
		entry.dispose = null;
		try {
			dispose?.();
		} catch (error) {
			this.#host.recordCallerlessBindingFailure("webrtc.signaling.dispose", error);
		}
	}

	#refusal(code: number, operation: string): GlowcapError {
		return new GlowcapError(code, this.#sink.lastError() ?? `webrtc ${operation} failed (code ${code})`);
	}

	// Run one sink call and record a failure. A refusal of INVALID_ARGUMENT means
	// the exchange ended between the book's check and the call. That is a
	// finished exchange, not a fault. Returns whether the call failed.
	#attempt(operation: string, call: () => number): boolean {
		try {
			const code = call();
			if (code !== OK && code !== INVALID_ARGUMENT) throw this.#refusal(code, operation);
			return false;
		} catch (error) {
			this.#host.recordCallerlessBindingFailure(operation, error);
			return true;
		}
	}
}

// The calling thread's last error from the WebRTC library, which keeps its own
// slot apart from the core's `glowcap_last_error`.
function webrtcLastError(): string | null {
	return readErrorSlot(webrtcS().glowcap_webrtc_last_error);
}

function webrtcCheck(code: number, operation: string): void {
	if (code !== OK) {
		throw new GlowcapError(code, webrtcLastError() ?? `webrtc ${operation} failed (code ${code})`);
	}
}

const utf8 = new TextEncoder();
const utf8Decoder = new TextDecoder();

function readText(ptr: Ptr, len: number | bigint): string {
	const size = Number(len);
	if (ptr === NULL || size === 0) return "";
	return utf8Decoder.decode(ffi.readMemory(ptr, size));
}

function writePointer(view: DataView, offset: number, value: Ptr): void {
	view.setBigUint64(offset, value, true);
}

function writeStringView(view: DataView, offset: number, text: string | undefined, keep: Uint8Array[]): void {
	const bytes = utf8.encode(text ?? "");
	keep.push(bytes);
	writePointer(view, offset + WEBRTC_STRING_VIEW_PTR_OFF, ffi.pointerOf(bytes));
	view.setBigUint64(offset + WEBRTC_STRING_VIEW_LEN_OFF, BigInt(bytes.length), true);
}

// The buffers a config record borrows. `keep` holds them until the netlayer
// has copied what it needs.
function writeIceServers(
	view: DataView,
	servers: readonly RTCIceServer[],
	keep: Uint8Array[],
): void {
	if (servers.length === 0) return;
	const records = new Uint8Array(servers.length * WEBRTC_ICE_SERVER_SIZE);
	keep.push(records);
	const recordView = new DataView(records.buffer);
	servers.forEach((server, index) => {
		const base = index * WEBRTC_ICE_SERVER_SIZE;
		const urls = typeof server.urls === "string" ? [server.urls] : server.urls;
		const views = new Uint8Array(urls.length * WEBRTC_STRING_VIEW_SIZE);
		keep.push(views);
		const viewsView = new DataView(views.buffer);
		urls.forEach((url, urlIndex) => writeStringView(viewsView, urlIndex * WEBRTC_STRING_VIEW_SIZE, url, keep));
		writePointer(recordView, base + WEBRTC_ICE_SERVER_URLS_OFF, ffi.pointerOf(views));
		recordView.setBigUint64(base + WEBRTC_ICE_SERVER_URL_COUNT_OFF, BigInt(urls.length), true);
		writeStringView(recordView, base + WEBRTC_ICE_SERVER_USERNAME_OFF, server.username, keep);
		writeStringView(recordView, base + WEBRTC_ICE_SERVER_CREDENTIAL_OFF, server.credential, keep);
	});
	writePointer(view, WEBRTC_CONFIG_ICE_SERVERS_OFF, ffi.pointerOf(records));
	view.setBigUint64(WEBRTC_CONFIG_ICE_SERVER_COUNT_OFF, BigInt(servers.length), true);
}

/** Open a netlayer whose dials and accepts carry `signaling`, register it with
 * `loop`, and hand its construction reference to the driver's provider lease.
 * Returns the book the netlayer's callbacks and verbs run through. */
function installNetlayer(
	loop: DriverLoop,
	signaling: SignalingAuthority,
	config: DriverConfig,
): ExchangeBook {
	const host = loop.wrapperHost();
	// Set to NULL at teardown, when the driver is released and the library's
	// netlayer may be gone, so a late sink call refuses instead of calling C.
	let raw: Ptr = NULL;
	const book = new ExchangeBook(signaling, {
		provideOffer: (designator, sdp) => {
			if (raw === NULL) return { code: CLOSED, exchange: 0n };
			const peer = utf8.encode(designator);
			const offer = utf8.encode(sdp);
			const out = new Uint8Array(8);
			const code = webrtcS().glowcap_webrtc_netlayer_provide_offer(
				raw,
				ab(peer),
				BigInt(peer.length),
				ab(offer),
				BigInt(offer.length),
				out,
			);
			if (code === OK) loop.scheduleStep();
			return { code, exchange: code === OK ? new DataView(out.buffer).getBigUint64(0, true) : 0n };
		},
		provideAnswer: (exchange, sdp) => {
			if (raw === NULL) return INVALID_ARGUMENT;
			const bytes = utf8.encode(sdp);
			return webrtcS().glowcap_webrtc_netlayer_provide_answer(raw, exchange, ab(bytes), BigInt(bytes.length));
		},
		provideCandidate: (exchange, ice) => {
			if (raw === NULL) return INVALID_ARGUMENT;
			const bytes = utf8.encode(ice);
			return webrtcS().glowcap_webrtc_netlayer_provide_candidate(raw, exchange, ab(bytes), BigInt(bytes.length));
		},
		failExchange: (exchange) => {
			if (raw === NULL) return INVALID_ARGUMENT;
			const code = webrtcS().glowcap_webrtc_netlayer_fail_exchange(raw, exchange);
			if (code === OK) loop.scheduleStep();
			return code;
		},
		lastError: () => raw === NULL ? "the webrtc netlayer is not open" : webrtcLastError(),
	}, host);
	const callbacks: Array<{ readonly pointer: Ptr; close(): void }> = [];
	const closeAll = () => {
		for (const callback of callbacks) callback.close();
	};
	let installed = false;
	try {
		const sendOffer = ffi.makeCallback(
			{
				parameters: ["pointer", "u64", "pointer", "usize", "pointer", "usize", "pointer", "usize"],
				result: "i32",
			},
			(
				_ctx: Ptr,
				exchange: number | bigint,
				designator: Ptr,
				designatorLen: number | bigint,
				introducer: Ptr,
				introducerLen: number | bigint,
				sdp: Ptr,
				sdpLen: number | bigint,
			) => {
				try {
					const target: SignalingTarget = {
						designator: readText(designator, designatorLen),
						introducer: introducer === NULL && Number(introducerLen) === 0
							? null
							: readText(introducer, introducerLen),
					};
					return book.sendOffer(BigInt(exchange), target, readText(sdp, sdpLen));
				} catch (error) {
					host.recordCallerlessBindingFailure("webrtc.signaling.offer", error);
					return IO;
				}
			},
		);
		callbacks.push(sendOffer);
		const sendAnswer = ffi.makeCallback(
			{ parameters: ["pointer", "u64", "pointer", "usize", "pointer", "usize"], result: "i32" },
			(
				_ctx: Ptr,
				exchange: number | bigint,
				designator: Ptr,
				designatorLen: number | bigint,
				sdp: Ptr,
				sdpLen: number | bigint,
			) => {
				try {
					const target: SignalingTarget = {
						designator: readText(designator, designatorLen),
						introducer: null,
					};
					return book.sendAnswer(BigInt(exchange), target, readText(sdp, sdpLen));
				} catch (error) {
					host.recordCallerlessBindingFailure("webrtc.signaling.answer.send", error);
					return IO;
				}
			},
		);
		callbacks.push(sendAnswer);
		const sendCandidate = ffi.makeCallback(
			{ parameters: ["pointer", "u64", "pointer", "usize"], result: "i32" },
			(_ctx: Ptr, exchange: number | bigint, ice: Ptr, iceLen: number | bigint) => {
				try {
					return book.sendCandidate(BigInt(exchange), readText(ice, iceLen));
				} catch (error) {
					host.recordCallerlessBindingFailure("webrtc.signaling.candidate.send", error);
					return IO;
				}
			},
		);
		callbacks.push(sendCandidate);
		const done = ffi.makeCallback(
			{ parameters: ["pointer", "u64"], result: "void" },
			(_ctx: Ptr, exchange: number | bigint) => {
				try {
					book.done(BigInt(exchange));
				} catch (error) {
					host.recordCallerlessBindingFailure("webrtc.signaling.done", error);
				}
			},
		);
		callbacks.push(done);

		const record = new Uint8Array(WEBRTC_CONFIG_SIZE);
		const view = new DataView(record.buffer);
		const keep: Uint8Array[] = [];
		writeIceServers(view, config.iceServers ?? [], keep);
		view.setUint32(WEBRTC_CONFIG_INCLUDE_LOOPBACK_CANDIDATES_OFF, config.includeLoopbackCandidates ? 1 : 0, true);
		writePointer(view, WEBRTC_CONFIG_SIGNALING_OFF + WEBRTC_SIGNALING_SEND_OFFER_OFF, sendOffer.pointer);
		writePointer(view, WEBRTC_CONFIG_SIGNALING_OFF + WEBRTC_SIGNALING_SEND_ANSWER_OFF, sendAnswer.pointer);
		writePointer(view, WEBRTC_CONFIG_SIGNALING_OFF + WEBRTC_SIGNALING_SEND_CANDIDATE_OFF, sendCandidate.pointer);
		writePointer(view, WEBRTC_CONFIG_SIGNALING_OFF + WEBRTC_SIGNALING_DONE_OFF, done.pointer);

		const out = new Uint8Array(8);
		webrtcCheck(webrtcS().glowcap_webrtc_netlayer_new(ab(record), out), "open netlayer");
		raw = outPointer(out);
		// The netlayer has copied the config, so the borrowed buffers may go.
		keep.length = 0;
		// The driver's provider lease keeps the netlayer alive once the install
		// succeeds. On a failed install the release below drops the only
		// reference.
		try {
			const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
			webrtcCheck(webrtcS().glowcap_webrtc_transport_provider(raw, ab(packageBytes)), "build provider");
			loop.installProvider((register) => register(packageBytes));
			// The driver may call the callbacks until it is released, whether by
			// `close()` or a background failure, so they stay open until then.
			loop.retainUntilTeardown(() => {
				raw = NULL;
				closeAll();
			});
			installed = true;
		} finally {
			try {
				webrtcCheck(webrtcS().glowcap_webrtc_netlayer_release(raw), "release netlayer");
			} catch (error) {
				host.recordCallerlessBindingFailure("webrtc.netlayer.release", error);
			}
		}
		return book;
	} catch (error) {
		if (!installed) {
			raw = NULL;
			closeAll();
		}
		throw error;
	}
}

/** Configure a WebRTC provider for `connect`. A `webrtc` locator dials the peer
 * its designator names: the C library makes the offer and gathers candidates
 * inside the driver loop, and `signaling` carries them to the peer and brings
 * back its answer and candidates. A Host that should also answer offers uses
 * `listen` instead. Needs the WebRTC C library (`zig build webrtc-abi`).
 *
 * A dial whose answer never arrives fails at the driver's handshake deadline.
 * When `offer` or `candidate` rejects, the error is retained as a callerless
 * binding failure on the loop's host and the dial is given up, so it fails at
 * the driver's next step with `SignalingFailed`. An answer the library refuses
 * is retained the same way and also gives the dial up. A `candidate` or
 * `offer` that throws before returning refuses the dial at once. */
export function provider(signaling: SignalingAuthority, config: DriverConfig = {}): DriverProvider {
	return {
		install(loop) {
			installNetlayer(loop, signaling, { ...config });
			return Promise.resolve();
		},
	};
}

/** Where a listener's Host identity comes from. With neither field the Host is
 * new. Pass at most one. */
export type ListenOptions =
	| {
		/** Restore a Host's key from this 32-byte Ed25519 secret. */
		readonly seed?: Uint8Array;
		readonly host?: never;
	}
	| {
		/** Share this Host, so its sessions and publications stay. */
		readonly host: Host;
		readonly seed?: never;
	};

/** A Host answering WebRTC offers. The driver loop owns the netlayer, the
 * listener, the accept handshake, and every accepted session. Iterate the
 * server for each accepted `Session`, whose partner identity names the
 * offerer. This type adds the one verb WebRTC needs, `provideOffer`, and its
 * give-up, `failExchange`. */
export class Server extends DriverServer {
	readonly #book: ExchangeBook;

	constructor(bound: { listener: DriverListener; ownedLoop?: DriverLoop }, book: ExchangeBook) {
		super(bound);
		this.#book = book;
	}

	/** Hand in an SDP offer from the peer whose designator is `designator`. The
	 * library answers it through the authority's `answer` before this returns,
	 * and the returned exchange id names the accept for `failExchange`. A
	 * `GlowcapError` means no exchange was started: the listener is closed, the
	 * offerer's key is not a key, too many accepts are in flight, or the
	 * authority threw from `answer`. A promise `answer` returns that rejects gives the accept up.
	 *
	 * An accept has no deadline of its own. One whose offerer goes quiet holds
	 * its place until the application calls `failExchange`. */
	provideOffer(designator: string, sdp: string): bigint {
		return this.#book.provideOffer(designator, sdp);
	}

	/** Give up on the accept `exchange` because its signaling broke or its
	 * offerer went quiet. It ends without a session and its candidate
	 * subscription is disposed. A `GlowcapError` means no such accept is in
	 * progress or its channel has already opened, and nothing changed. */
	failExchange(exchange: bigint): void {
		this.#book.failExchange(exchange);
	}
}

/** Compose a WebRTC netlayer into the Host `options` names, open its listener,
 * and select it as the Host's advertised location. Needs the WebRTC C library
 * (`zig build webrtc-abi`).
 *
 * A WebRTC peer is reachable only as its key, so the listener's designator is
 * the Host's own. The same netlayer dials: a `Runtime` that adopts
 * `server.host` connects to a `locator` through it. Each inbound offer reaches
 * the library through `Server.provideOffer`, the offerer's candidates through
 * the `onCandidate` sink the authority was given, and iterating the server
 * yields the session once the channel opens. */
export async function listen(
	signaling: SignalingAuthority,
	config: DriverConfig = {},
	options: ListenOptions = {},
): Promise<Server> {
	await ensureRuntimeReady();
	if (!loopTierAvailable()) throw listenerLoopUnavailable();
	const { loop, ownsLoop } = prepareListenerLoop(options.host, options.seed, undefined);
	let listener: DriverListener | null = null;
	try {
		const book = installNetlayer(loop, signaling, config);
		// An empty designator asks the library for the Host's own key.
		listener = await DriverListener.open(loop, TRANSPORT_WEBRTC, "");
		listener.select();
		const server = new Server({ listener, ownedLoop: ownsLoop ? loop : undefined }, book);
		listener = null;
		return server;
	} catch (error) {
		const cleanups: Array<() => void | Promise<void>> = [];
		const failedListener = listener;
		if (failedListener != null) cleanups.push(() => failedListener.close());
		if (ownsLoop) cleanups.push(() => loop.close());
		await retainCleanupFailures(error, cleanups);
		throw error;
	}
}
