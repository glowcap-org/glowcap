// The application surface over the byte-fed host (libpancake_host,
// ADR-0072): `Session` and its verbs (`fetch`/`send`/`tell`/`spawn`/
// `publish`/`enliven`/`serve`/`close`), plus mint/handshake
// (`establishDialedLocator` / `establishAccepted`). The dial executor and
// `connect` live in `dial.ts`; Server/`listen` live in `listen.ts`. The
// `RemotePromise` handle, fetch/enliven mint→await, far-send `sendFar` /
// `promiseFor`, live in `promise.ts`. Spawn/publish hosting, ADR-0064
// proxies, and Host-reference send·tell dispatch live in `trampoline.ts`. The
// byte-fed embedder pump — handshake,
// read raw bytes, feed, drain, flush — lives in `pump.ts`. The host owns
// everything else: routing, redemption, gift origination, far vows. `mod.ts`
// re-exports the public members.

import {
	DESIGNATOR_SCHEME_ADDRESS,
	DESIGNATOR_SCHEME_KEY,
	DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
} from "@pancake/abi";
import {
	attenuateProxy,
	caretakerProxy,
	currentTurnSession,
	dispatchSend,
	dispatchTell,
	type HostingHandle,
	insideTurn,
	publishHosted,
	spawnHosted,
} from "./trampoline.ts";
import { type Argument, type Behavior, Ref, refFromId } from "./value.ts";
import { Host } from "./host.ts";
import {
	fetchLike,
	listenFar,
	type MintAwaitHandle,
	type PromiseFactoryHandle,
	RemotePromise,
} from "./promise.ts";
import { releaseRef } from "./gc.ts";
import {
	flushOutbound as pumpFlushOutbound,
	lastAbort as pumpLastAbort,
	type PumpHandle,
	runHandshake,
	serveLoop,
} from "./pump.ts";
import { hostS } from "./internal/ffi/host.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer, outU64, readBytes } from "./internal/seam.ts";
import { type AbortDetail, checkHost, PancakeError } from "./errors.ts";
import { L } from "./internal/layout.ts";
import { CLOSED, HANDSHAKE_TIMEOUT_MS, INVALID_ARGUMENT, NOT_FOUND, TIMEOUT } from "@pancake/abi";
import { HINT_DIRECT_ADDRESSES, type Locator, withOwnedLocator } from "./locator.ts";

// Encoder for establish/fetch swiss bytes.
const utf8Encoder = new TextEncoder();
// Decoder for the partner designator, which is text on every transport.
const utf8Decoder = new TextDecoder();

/** What a CapTP handshake reports about its partner, as
 * {@link Session.partnerIdentity} returns it.
 *
 * The verified hello signature proves control of the fresh session key and
 * binds that key to the locator the partner claimed. It does not by itself
 * prove control of the locator's durable designator; `provenance` reports
 * whether the realized channel supplied that proof. */
export interface PartnerIdentity {
	/** The partner's session public key. Always present. */
	readonly sessionKey: Uint8Array;
	/** The designator the partner claimed under its session signature, as text:
	 * its key in hex on a
	 * key-designator transport, a `host:port` on an address transport. It is
	 * `""` when the signed location carried no designator. */
	readonly designator: string;
	/** The verbatim location record the key and the designator were read from,
	 * empty when the handshake captured none. */
	readonly locatorRecord: Uint8Array;
	/** How the durable identity in {@link PartnerIdentity.designator} was
	 * authenticated, if at all. Session identity, durable identity, and this
	 * provenance are three separate facts (ADR-0097, ADR-0105): a caller that
	 * requires a proved durable peer reads this. The fresh session key and the
	 * durable designator are independent values. */
	readonly provenance: DurableProvenance;
}

/** How a partner's advertised durable identity was authenticated, the third
 * fact {@link PartnerIdentity} reports beside session key and designator.
 *
 * The answer is a property of the connection rather than of its transport name
 * (ADR-0105): the same transport symbol reaches this peer over code that can
 * prove something and code that cannot, so no list of transports belongs here.
 *
 * `authenticated-transport` means the code that realized this connection
 * verified the far end of the byte channel holds a durable key, and the partner
 * claimed that same key. `unauthenticated` means no durable identity was
 * proved. */
export type DurableProvenance =
	| "authenticated-transport"
	| "unauthenticated";

/** Whether this identity's durable name was authenticated by the realized
 * channel. */
export function durableIdentityAuthenticated(id: PartnerIdentity): boolean {
	return id.provenance !== "unauthenticated";
}

/** Convert one ABI provenance value to its public name. Exported because the
 * trace surface reports the same fact about the same partner, and two mappings
 * for one answer could drift apart. */
export function provenanceFromAbi(raw: number): DurableProvenance {
	switch (raw) {
		case DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT:
			return "authenticated-transport";
		default:
			return "unauthenticated";
	}
}

/** How long a partner has to finish the keyed handshake once the byte channel
 * is open, on both halves: what `connect` allows a dialed partner, and what a
 * listener allows an accepted one.
 *
 * Matches the CLI's own product default. Something finite is the point: this
 * project's rule for CapTP waits is that an unbounded one is a hang rather than
 * a slow success, and neither half of a connection is exempt. It bounds the
 * handshake alone, never opening the channel: a TCP connect keeps the runtime's
 * own timeout, and an iroh dial-by-id keeps its discovery retry budget
 * (ADR-0082), both spent before the handshake starts. */
export { HANDSHAKE_TIMEOUT_MS };

/** Race one connection's keyed handshake against `ms`, the bound both halves
 * of `#establish` reach. A falsy budget is the caller's explicit opt-in to
 * waiting without one. `Promise.race` keeps a handler on the losing handshake,
 * so the rejection it raises once the abandoned read unparks is not an
 * unhandled one. */
function withHandshakeBound(handshake: Promise<void>, ms: number | null): Promise<void> {
	if (!ms) return handshake;
	let timer: ReturnType<typeof setTimeout> | undefined;
	const bound = new Promise<never>((_resolve, reject) => {
		timer = setTimeout(
			() =>
				reject(
					new PancakeError(
						TIMEOUT,
						`the partner did not finish the OCapN handshake within ${ms}ms`,
					),
				),
			ms,
		);
	});
	return Promise.race([handshake, bound]).finally(() => clearTimeout(timer));
}

/** How bytes move for one connection — the byte-channel seam the byte-fed pump
 * reads and the FLUSH drain writes. The core supplies the TCP wrapper below
 * over the runtime's own sockets; the `@pancake/iroh` companion supplies the
 * iroh one, so the iroh artifact stays out of this core module entirely.
 * Framing is never the channel's job: the host's stream delimiter owns it.
 * This is the low-level byte stream, distinct from a netlayer transport
 * that opens one for a locator scheme. */
export interface Channel {
	/** The next chunk of inbound bytes, or `null` at a clean end of stream. */
	read(): Promise<Uint8Array | null>;
	/** Write every byte of `data`, awaiting the runtime's flush/backpressure. */
	write(data: Uint8Array): Promise<void>;
	/** Stop I/O immediately. A returned promise is the native release barrier. */
	close(): void | Promise<void>;
}

/** Generic metadata an embedder-owned listener supplies with one accepted byte
 * channel. The provider, not the binding core, declares how its designator is
 * interpreted; adding a transport therefore adds no name dispatch here. */
export interface AcceptedTransport {
	readonly transport: string;
	readonly designatorScheme:
		| typeof DESIGNATOR_SCHEME_ADDRESS
		| typeof DESIGNATOR_SCHEME_KEY;
	readonly serverDesignator: string;
	readonly channel: Channel;
	readonly localAddress?: string;
	readonly verifiedChannelKey?: string | null;
}

/** Result of {@link Session.sendRedeeming}: the ordinary send reply plus the
 * direct exporter session selected by that reply's route, when one exists. */
export interface SendRedeemingResult {
	reply: Argument;
	via: Session | null;
}

/** What a loop-minted `Session` needs from the native loop that owns it
 * (ADR-0112). Declared here — implemented by `driver_loop.ts`'s `DriverLoop` —
 * so the Session arms can dispatch on it without importing the loop tier. */
export interface DriverLoopHandle {
	/** One zero-timeout step plus an event dispatch, on the driving thread. */
	stepNow(): void;
	/** Schedule one step soon — a kick that is legal from inside a turn. */
	scheduleStep(): void;
	/** Release one loop-owned session through the loop's own verb. */
	nativeSessionRelease(ptr: Ptr): void;
	/** Release the loop and everything it owns, to the native barrier. */
	close(): Promise<void>;
	/** Wrap a loop-minted session handle as the public `Session`. */
	adoptSession(ptr: Ptr): Session;
}

/** The loop-backed `Channel` (ADR-0112): the native loop owns the wire, so it
 * carries no byte verbs the pump would drive — only the closed event the serve
 * promise awaits and the loop back-reference the Session arms dispatch on. */
export interface LoopChannel extends Channel {
	readonly driverLoop: DriverLoopHandle;
	waitClosed(): Promise<void>;
}

/** Whether `transport` is loop-backed — the branch `serve`, `flushOutbound`,
 * and teardown dispatch on. */
function isLoopChannel(transport: Channel): transport is LoopChannel {
	return (transport as { driverLoop?: unknown }).driverLoop != null;
}

/** A live CapTP session with one OCapN partner, the one object an application
 * holds, over one byte-fed `PancakeHostSession` the shared `Host` minted.
 *
 *   const session = await connect(tcpLocator("127.0.0.1", 9099));
 *   session.serve().catch((e) => console.error(e));
 *   const room = await session.fetch("room");
 *   const inbox = session.spawn((verb, args) => { ...; });
 *   await session.send(room, "subscribe", ["alice", inbox]);
 */
export class Session {
	#ptr: Ptr;
	readonly #host: Host;
	readonly #transport: Channel;
	#serving: Promise<void> | null = null;
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the FAIL completions the break queues classify as the
	// typed CLOSED instead of partner breaks, and so a read cancelled by our
	// own close is a clean shutdown.
	#closing = false;
	#released = false;
	#transportClose: Promise<void> | null = null;
	// Serializes transport writes. `flushOutbound` runs from the action drain,
	// the feed-failure choreography, and teardown; chaining each flush behind
	// the last keeps every frame whole and in submission order.
	#writing: Promise<void> = Promise.resolve();
	// Live accessors into the private fields above — what `pump.ts` drives.
	readonly #pump: PumpHandle;
	// Opaque Host capability id -> trampoline ctx id for objects this session
	// hosts, so a `Forward` whose target this side hosts composes in process.
	readonly #hosted: Map<bigint, bigint>;
	// Set when this session created the host it runs on, which `connect()` does
	// when the caller supplies none. Such a host has no other reachable owner,
	// so closing the session releases it; a caller-supplied host is never
	// released here, because other sessions may still be using it.
	ownsHost = false;

	// Distributed GC (ADR-0063), opt-in and off by default — see `gc.ts`.
	#gcEnabled = false;

	private constructor(ptr: Ptr, host: Host, transport: Channel) {
		this.#ptr = ptr;
		this.#host = host;
		this.#hosted = host.hosted;
		this.#transport = transport;
		this.#pump = this.#makePump();
		// Join the host's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		host.registerSession(ptr, this);
	}

	/** Bind `#pump` getters/setters onto this Session's private fields. */
	#makePump(): PumpHandle {
		// deno-lint-ignore no-this-alias -- object-literal getters cannot see Session `#` fields without a closed-over instance
		const s = this;
		return {
			deliverOwner: s,
			deliverHost: s.#host,
			get ptr() {
				return s.#ptr;
			},
			get released() {
				return s.#released;
			},
			get sessionOpen() {
				return s.sessionOpen;
			},
			get closingFlag() {
				return s.#closing;
			},
			set closingFlag(v: boolean) {
				s.#closing = v;
			},
			get closing() {
				return s.closing;
			},
			get writing() {
				return s.#writing;
			},
			set writing(p: Promise<void>) {
				s.#writing = p;
			},
			read: () => s.#transport.read(),
			write: (data) => s.#transport.write(data),
			drainParkedReleases: () => s.#host.drainParkedReleases(),
			kickActions: () => s.#host.kickActions(),
			closeTransport: () => s.closeTransport(),
		};
	}

	/** Bind the mint/await seam for `promise.fetchLike` without exporting
	 * private Session fields. */
	#makeMintAwait(): MintAwaitHandle {
		// deno-lint-ignore no-this-alias -- object-literal methods close over Session `#` fields
		const s = this;
		return {
			guardOpen: () => s.#guardOpen(),
			drainGc: () => s.#host.drainGc(),
			get ptr() {
				return s.#ptr;
			},
			vowMinted: (vow) => s.#host.vowMinted(vow, s),
			serve: () => {
				s.serve();
			},
			awaitVow: (vow) => s.#host.awaitVow(vow),
			kickActions: () => s.#host.kickActions(),
		};
	}

	/** Bind the far-send `promiseFor` factory without exporting private fields. */
	#makePromiseFactory(): PromiseFactoryHandle {
		// deno-lint-ignore no-this-alias -- object-literal methods close over Session `#` fields
		const s = this;
		return {
			serve: () => {
				s.serve();
			},
			awaitVow: (vow) => s.#host.awaitVow(vow),
			kickActions: () => s.#host.kickActions(),
			vowMinted: (vow) => s.#host.vowMinted(vow, s),
			get hostRaw() {
				return s.#host.raw;
			},
			get ptr() {
				return s.#ptr;
			},
		};
	}

	/** The raw PancakeHostSession handle. Binding-internal: the host's DIAL arm
	 * reports it through `pancake_host_dialed`. */
	get raw(): Ptr {
		return this.#ptr;
	}

	/** The session's shared host, its retained identity and handoff router.
	 * Shared by every session of one host, so the gifter half of a handoff
	 * can reach a sibling session's session keys. An application reads it to
	 * publish host-giftables (`Host.publishGiftable`), share one identity
	 * across dials, or set the redeem posture. */
	get host(): Host {
		return this.#host;
	}

	/** Whether teardown has begun. Binding-internal: the host's FAIL arm
	 * classifies a closing connection's breaks as the typed CLOSED. */
	get closing(): boolean {
		return this.#closing || this.#released;
	}

	/** Nonzero once the keyed handshake has completed and the session is open. */
	get sessionOpen(): boolean {
		return !this.#released &&
			hostS.pancake_host_session_is_open(this.#ptr) === 1;
	}

	// ── Construction: establish, dial, accept ──────────────────────────────────

	/** Mint the dialing half from already-parsed locator pieces (transport +
	 * designator). A DIAL action's binding half borrows the pending URI first.
	 * The handshake is bounded by `handshakeTimeoutMs` (`HANDSHAKE_TIMEOUT_MS`
	 * on every dial the binding performs; `0` or `null` waits unbounded), and
	 * overrunning it rejects with `PancakeError` carrying `TIMEOUT`.
	 * Binding-internal. */
	static async establishDialedLocator(
		host: Host,
		transportName: string,
		designator: string,
		transport: Channel,
		handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
		verifiedChannelKey: string | null = null,
	): Promise<Session> {
		let session: Session | null = null;
		try {
			const t = utf8Encoder.encode(transportName);
			const d = utf8Encoder.encode(designator);
			const out = new Uint8Array(8);
			host.ensureAdvertisedLocator(transportName);
			const openCode = hostS.pancake_host_session_open_dialed_locator(
				host.raw,
				ab(t),
				BigInt(t.length),
				ab(d),
				BigInt(d.length),
				ab(out),
			);
			checkHost(openCode);
			session = new Session(outPointer(out), host, transport);
			// Before the first partner byte, which is the only window a realizer's
			// proof can be weighed in.
			if (verifiedChannelKey) session.bindVerifiedChannelKey(verifiedChannelKey);
			return await session.#establish(handshakeTimeoutMs);
		} catch (error) {
			if (session == null) await transport.close();
			else await session.closeTransport();
			throw error;
		}
	}

	/** Mint the accepting half over a connection the caller's own listener
	 * produced. `accepted` carries the provider's transport metadata and byte
	 * channel as one value; signing designator/hint come from
	 * `pancake_host_plan_accept` (ADR-0078), with no transport-name policy in
	 * this binding layer. The handshake is bounded by
	 * `handshakeTimeoutMs` (`HANDSHAKE_TIMEOUT_MS` in every accept loop here;
	 * `0` or `null` waits unbounded, which a caller parking a registration
	 * rather than running an accept loop wants), and overrunning it rejects
	 * with `PancakeError` carrying `TIMEOUT`, which an accept loop treats as
	 * any other bad partner. Binding-internal. */
	static async establishAccepted(
		host: Host,
		accepted: AcceptedTransport,
		handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
	): Promise<Session> {
		const {
			transport: transportName,
			designatorScheme,
			serverDesignator,
			channel: transport,
			localAddress: acceptedLocalAddr = "",
			verifiedChannelKey = null,
		} = accepted;
		let session: Session | null = null;
		try {
			const server = utf8Encoder.encode(serverDesignator);
			const local = utf8Encoder.encode(acceptedLocalAddr);
			const planBuf = new Uint8Array(L.ACCEPT_PLAN_SIZE);
			checkHost(hostS.pancake_host_plan_accept(
				designatorScheme,
				ab(server),
				BigInt(server.length),
				ab(local),
				BigInt(local.length),
				ab(planBuf),
			));
			// Plan views borrow server/local (or the static unreachable
			// placeholder). Deno/Bun BufferSource FFI needs a JS TypedArray, so
			// materialize those views once here — named session-mint FFI cost, not
			// a second policy encoding (Rust/Python/Racket pass the C pointers).
			const dv = new DataView(planBuf.buffer);
			const view = (off: number, lenOff: number): Uint8Array => {
				const len = Number(L.getUsize(dv, lenOff));
				if (len === 0) return new Uint8Array(0);
				return readBytes(L.getPtr(dv, off), BigInt(len));
			};
			const designator = view(L.ACCEPT_PLAN_DESIGNATOR_OFF, L.ACCEPT_PLAN_DESIGNATOR_LEN_OFF);
			const hint = view(
				L.ACCEPT_PLAN_DIRECT_ADDRESSES_HINT_OFF,
				L.ACCEPT_PLAN_DIRECT_ADDRESSES_HINT_LEN_OFF,
			);
			const t = utf8Encoder.encode(transportName);
			host.setAdvertisedLocator({
				transport: transportName,
				designator: utf8Decoder.decode(designator),
				hints: hint.length === 0
					? new Map()
					: new Map([[HINT_DIRECT_ADDRESSES, utf8Decoder.decode(hint)]]),
				hintWireForm: hint.length === 0 ? "boolean-false" : "map",
			});
			const out = new Uint8Array(8);
			const openCode = hostS.pancake_host_session_open_accepted(
				host.raw,
				ab(t),
				BigInt(t.length),
				ab(out),
			);
			checkHost(openCode);
			session = new Session(
				outPointer(out),
				host,
				transport,
			);
			// Before the first partner byte, which is the only window a realizer's
			// proof can be weighed in.
			if (verifiedChannelKey) session.bindVerifiedChannelKey(verifiedChannelKey);
			return await session.#establish(handshakeTimeoutMs);
		} catch (error) {
			if (session == null) await transport.close();
			else await session.closeTransport();
			throw error;
		}
	}

	// Drive the freshly opened connection's keyed handshake to an open session,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one dial or one accept, never the caller. The read/feed
	// loop lives in `pump.runHandshake`.
	//
	// The one place both halves bound that handshake. A peer that opens the byte
	// channel and then says nothing is the case no failure check can catch —
	// nothing fails, the handshake simply waits — so unbounded it parks the
	// dialer forever, and on the accepting side every later connection behind
	// that one client. An elapsed budget takes the same abandon path a failed
	// handshake does, and closing the transport is what unparks the abandoned
	// read.
	async #establish(handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS): Promise<Session> {
		try {
			await withHandshakeBound(runHandshake(this.#pump), handshakeTimeoutMs);
			return this;
		} catch (err) {
			await this.closeTransport();
			throw err;
		}
	}

	/** Wrap a session the driver archive minted and already handshook
	 * (ADR-0112): the loop is the pump and the release authority, so no
	 * establish runs here. Binding-internal: `DriverLoop.adoptSession` calls
	 * it. */
	static adoptLoopSession(ptr: Ptr, host: Host, transport: LoopChannel): Session {
		return new Session(ptr, host, transport);
	}

	// ── The pump (choreography in pump.ts) ──────────────────────────────────────

	/** Run the inbound loop: read raw bytes, hand them to the core's stream
	 * delimiter (behaviors run and vow completions queue inside the feed), and
	 * drain the action queue. Resolves when the connection closes cleanly;
	 * rejects on a transport or protocol error. Started once; calling again
	 * returns the same promise.
	 *
	 * A loop-backed session (ADR-0112) has no byte pump of its own — the
	 * native loop reads, feeds, and drains — so its serve promise only awaits
	 * the session's closure, keeping the resolves-on-close contract. */
	serve(): Promise<void> {
		if (this.#serving === null) {
			const transport = this.#transport;
			this.#serving = isLoopChannel(transport)
				? transport.waitClosed()
				: serveLoop(this.#pump);
		}
		return this.#serving;
	}

	/** The typed cause of this CapTP session's most recent local dispatch failure,
	 * or null when none has been recorded. The flat per-feed error code names
	 * the failure family; this names the member. */
	lastAbort(): AbortDetail | null {
		return pumpLastAbort(this.#pump);
	}

	/** Drain every encoded outbound frame on this CapTP session and write it to
	 * the transport — how a FLUSH action lands. Writes are serialized, so
	 * frames stay whole and in submission order. On a loop-backed session one
	 * loop step is the flush. Binding-internal. */
	async flushOutbound(): Promise<void> {
		const transport = this.#transport;
		if (isLoopChannel(transport)) {
			transport.driverLoop.stepNow();
			return;
		}
		await pumpFlushOutbound(this.#pump);
	}

	// ── Teardown ────────────────────────────────────────────────────────────────

	/** Close this session's connection and nothing else. A running `serve()`
	 * resolves cleanly; pending vows settle with the typed CLOSED.
	 *
	 * It does not reach a sibling session, and it does not reach the
	 * connections the host opened by itself to redeem a handoff — the `via`
	 * from `sendRedeeming()` is one of those. `Host.release()` ends those.
	 *
	 * A session that had to make its own host — `connect(locator)` with no host
	 * passed, the ordinary case — closes that host with it, so single-session
	 * code needs no host call. */
	async close(): Promise<void> {
		this.#closing = true;
		const transport = this.#transport;
		const transportClosed = this.closeTransport();
		// A host this session created has no other owner, so it goes too, and
		// with it every connection it dialed for redeems. A caller-supplied
		// host stays: sibling sessions on it are still running, and closing
		// their exporters from here is not this session's call to make.
		if (this.ownsHost) {
			if (isLoopChannel(transport)) {
				// A bare loop-routed connect owns its whole stack: closing the
				// session closes the loop, which releases the adopted host and
				// any resident transports with it (ADR-0112).
				await Promise.all([transportClosed, transport.driverLoop.close()]);
			} else {
				this.#host.release();
				await Promise.all([transportClosed, this.#host.releaseAsync()]);
			}
		} else {
			await transportClosed;
		}
	}

	/** Close just this session, without touching the host's other sessions:
	 * stop the transport first, then retire the host's entry and
	 * free the host handle (its still-parked far vows break inside the release,
	 * classified as closure), so no foreign call touches a freed session.
	 * A release refused inside a behavior callback is parked for the next
	 * drain, never dropped. Binding-internal. */
	closeTransport(): Promise<void> {
		if (this.#transportClose != null) return this.#transportClose;
		this.#closing = true;
		let transportClose: Promise<void>;
		try {
			transportClose = Promise.resolve(this.#transport.close());
		} catch (error) {
			transportClose = Promise.reject(error);
		}
		void transportClose.catch(() => {});
		this.#transportClose = transportClose;
		if (this.#released) return transportClose;
		this.#released = true;
		this.#host.unregisterSession(this.#ptr);
		// Hosted actors belong to the Host Vat; sibling Ports may still carry
		// their capabilities. Host.release owns the trampoline sweep.
		const ptr = this.#ptr;
		this.#ptr = NULL;
		// The native loop owns loop-minted sessions: their release is the
		// loop's own verb, which also drops queued events naming them.
		const transport = this.#transport;
		const releaseNative = isLoopChannel(transport)
			? () => transport.driverLoop.nativeSessionRelease(ptr)
			: () => hostS.pancake_host_session_release(ptr);
		if (insideTurn()) {
			this.#host.parkRelease(releaseNative);
		} else {
			releaseNative();
		}
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		void this.#host.kickActions();
		return transportClose;
	}

	[Symbol.dispose](): void {
		void this.close();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}

	#guardOpen(): void {
		if (this.#released) {
			throw new PancakeError(CLOSED, "connection closed");
		}
	}

	// ── Hosting: spawn, publish, and the proxy verbs ───────────────────────────

	#makeHosting(): HostingHandle {
		// deno-lint-ignore no-this-alias -- object-literal methods close over Session `#` fields
		const s = this;
		return {
			guardOpen: () => s.#guardOpen(),
			get ptr() {
				return s.#ptr;
			},
			get hosted() {
				return s.#hosted;
			},
			registerBehavior: (entry) => s.#host.registerHostedBehavior(entry),
			unregisterBehavior: (id) => s.#host.unregisterHostedBehavior(id),
			hostOwner: s.#host,
		};
	}

	/** Spawn a local actor and return a capability to it. The `Ref`
	 * auto-marshals when passed as a `send` argument, so handing a partner a
	 * callback is just `send(target, verb, [..., session.spawn(behavior)])`. The
	 * returned identity is opaque and Host-scoped; wire export positions stay
	 * inside pancake. Callable from inside a served turn (a factory's `create`
	 * minting the task it replies with). */
	/** Listen on a far capability this session holds (CapTP `op:listen`,
	 * ADR-0095): the returned handle settles with the listen notification,
	 * which may be any value, not only a capability. In 1.0, the target may be
	 * a far promise or live far object; in pancake-next, the target must be a
	 * promise. A re-gifted promise routes to its exporter session
	 * transparently. */
	listen(target: Ref): RemotePromise {
		this.#guardOpen();
		return listenFar(this.#makePromiseFactory(), target);
	}

	spawn(behavior: Behavior): Ref {
		return spawnHosted(this.#makeHosting(), behavior);
	}

	/** Publish an actor so a partner can `fetch` it by `name`. The name is a
	 * swiss-number: a readable string for a discoverable service, a
	 * cryptographic secret where the name itself is the authorization. */
	publish(name: string, behavior: Behavior): Ref {
		return publishHosted(this.#makeHosting(), name, behavior);
	}

	/** A {@link Ref} for the object published under `name` on this session, or
	 * null when nothing is published there.
	 *
	 * {@link publish} returns its own `Ref`, so this is for the other publisher:
	 * {@link Host.publishGiftable} hosts one actor under a Host-wide alias and
	 * returns nothing. Reading its Host identity lazily projects it onto this
	 * session so an application can pass it as an ordinary capability argument;
	 * no enrollment step exists.
	 *
	 * A `send` to the returned `Ref` runs the behavior in process rather than over
	 * the wire, and a giftable registered no session, so `currentSession()` inside
	 * it is null. Pass it on as a capability argument; a behavior
	 * written to answer over the connection its call arrived on will not answer a
	 * local send. */
	publishedRef(name: string): Ref | null {
		this.#guardOpen();
		const bytes = utf8Encoder.encode(name);
		const out = new Uint8Array(8);
		const code = hostS.pancake_host_session_published_ref(
			this.#ptr,
			ab(bytes),
			BigInt(bytes.length),
			ab(out),
		);
		if (code === NOT_FOUND) return null;
		checkHost(code);
		const ref = refFromId(outU64(out));
		// Join the host's giftable to the identity this session surfaced, so a
		// later local send to the returned Ref composes in process. Skipped when the
		// identity is already known: `publish` on this session recorded its own.
		if (!this.#hosted.has(ref.id)) {
			const ctx = this.#host.giftableCtx(name);
			if (ctx !== undefined) {
				this.#hosted.set(ref.id, ctx);
			}
		}
		return ref;
	}

	/** Wrap `target` (local or far) in a revocable caretaker (ADR-0064).
	 * Returns the proxy capability to hand a partner and a `revoke` lever;
	 * every call through the proxy forwards to `target` until `revoke()`,
	 * after which each breaks with `Revoked`. `target` may be a capability
	 * imported over the wire — the proxy forwards transparently — so this
	 * hands out a revocable view of authority you do not own locally. */
	caretaker(target: Ref): { proxy: Ref; revoke: () => void } {
		return caretakerProxy((behavior) => this.spawn(behavior), target);
	}

	/** Wrap `target` (local or far) in an attenuator (ADR-0064): a proxy that
	 * forwards only the calls whose verb is in `verbs` and breaks every other
	 * with `Attenuated`. Returns the proxy capability to hand a partner. The
	 * proxy is a plain spawned actor. */
	attenuate(target: Ref, verbs: string[]): Ref {
		return attenuateProxy((behavior) => this.spawn(behavior), target, verbs);
	}

	// ── The application verbs ───────────────────────────────────────────────────

	/** Fetch a partner's published capability by `name`. Returns a `Ref` you
	 * can `send` to. The canonical fetch lives in the library: one call
	 * registers the bootstrap import, allocates the answer, and queues the
	 * deliver; the host enrolls the fulfilled capability under a node-unique
	 * token (ADR-0069) before the completion is queued, so a return re-gifts
	 * the right home. Drives the inbound loop itself, so a `fetch` straight
	 * after `connect` works without a separate `serve()` call. Rejects with
	 * `VowBroken` when the partner breaks the fetch, and with `FetchFailed`
	 * when it fulfills with something that is not a live capability. */
	async fetch(name: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(name);
		const ref = await fetchLike(
			this.#makeMintAwait(),
			swiss,
			name,
			hostS.pancake_host_session_fetch,
		);
		return this.#gcEnabled ? this.#host.trackGcImport(ref) : ref;
	}

	/** Enliven a sturdyref against this session (ADR-0098): bring the
	 * durable `(peer, swissnum)` to life as a live `Ref`. Passes `sturdyref`
	 * as a complete locator. The host verifies it against this session before
	 * consulting its dedup cache — a
	 * repeat enliven of the same swissnum on this session short-circuits with
	 * no wire traffic (its completion is queued before the minting call
	 * returns). The session must already be open to the sturdyref's peer;
	 * this session-level call never dials. Rejects with
	 * `VowBroken` when the partner breaks the enliven, and with `FetchFailed`
	 * when it fulfills with something that is not a capability. */
	async enliven(sturdyref: string): Promise<Ref> {
		// Unlike `fetch`, the result is not GC-tracked: the host's dedup cache
		// owns an enlivened capability, outside the finalizer seam (ADR-0063).
		return await fetchLike(
			this.#makeMintAwait(),
			utf8Encoder.encode(sturdyref),
			sturdyref,
			hostS.pancake_host_session_enliven,
		);
	}

	/** Eventual-send `verb(args)` to `target` and return a `RemotePromise` for
	 * the reply. `await` it for the value (a `Ref` if the partner returned a
	 * capability; rejects with `VowBroken` on a partner break).
	 *
	 * `target` is a capability `Ref` *or* a `RemotePromise` from an earlier
	 * send: passing the latter pipelines (ADR-0007) — the call is addressed at
	 * the answer that send will resolve, so a dependent chain costs one round
	 * trip instead of one per link. `args` may contain `Ref`s. A `Ref` this
	 * session spawned runs in process; a partner's rides the wire, and a
	 * redeemed handoff token routes to the exporter session that hosts it,
	 * transparently.
	 *
	 * The deliver is queued now; its bytes leave the wire when the returned
	 * handle — or any send pipelined behind it — is first awaited, so a
	 * pipelined batch travels together. */
	send(
		target: Ref | RemotePromise,
		verb: string,
		args: Argument[] = [],
	): RemotePromise {
		// A send that cannot be issued comes back as a failed handle, not a
		// throw. `send` must return synchronously so a caller can pipeline at
		// the answer before it settles (ADR-0050), so it cannot be `async` —
		// but a promise-returning method whose failure arrives synchronously is
		// a trap: the obvious `session.send(…).catch(…)` never sees it, and a
		// caller who cleared a dead route in that handler kept using it.
		try {
			this.#guardOpen();
			this.#host.drainGc();
			return dispatchSend(
				this.#hosted,
				this.#makePromiseFactory(),
				target,
				verb,
				args,
				(t, v, a) => this.send(t, v, a),
			);
		} catch (err) {
			// Everything, not only typed refusals: the contract is that `send`
			// reports through the handle, and a channel that is mixed depending
			// on the error is the trap again in a narrower form.
			return RemotePromise.failed(
				err instanceof PancakeError ? err : new PancakeError(INVALID_ARGUMENT, String(err)),
			);
		}
	}

	/** Eventual-send `verb(args)` to `target`, await the reply, and also surface
	 * the direct `Session` a three-party-handoff redeem opened to answer it.
	 *
	 * When `target` answers with a `desc:handoff-give` (a rooms `introduce`, say),
	 * the binding redeems it by dialing the exporter, and the reply resolves to a
	 * capability that routes over a fresh direct session. The byte connection is
	 * otherwise internal. This returns the session as `via`, so a caller can host
	 * objects in the same session as the redeemed capability — the one
	 * place a reply capability handed back to the exporter is valid, since an
	 * OCapN near export names a position in one specific session. `via`
	 * is resolved from the reply's own route (the token carries which exporter
	 * session it lives in), so it is correct with several redeems in flight at
	 * once and it finds an exporter a prior redeem already dialed — a cache hit
	 * that opens no new session. `via` is null when the reply is not a
	 * redeemed-handoff capability (an ordinary far reply) or its exporter
	 * session is already gone.
	 *
	 *   const { reply, via } = await session.sendRedeeming(directory, "introduce", [nick]);
	 *   const inbox = (via ?? session).spawn(replyBehavior);   // hosted where the reply lives
	 *   await (via ?? session).send(reply as Ref, "dm", [text, inbox]);
	 */
	async sendRedeeming(
		target: Ref | RemotePromise,
		verb: string,
		args: Argument[] = [],
	): Promise<SendRedeemingResult> {
		this.#guardOpen();
		const reply = await this.send(target, verb, args);
		let via = reply instanceof Ref ? this.#host.exporterFor(reply) : null;
		if (via === this) via = null;
		return { reply, via };
	}

	/** Send `verb(args)` to `target` without awaiting a reply, the
	 * fire-and-forget eventual-send (Goblins `<-np`). No answer is allocated
	 * and none comes back, so it is the right call for a notification or a
	 * broadcast: it costs one deliver, not a deliver plus a reply. Flushes
	 * immediately. */
	async tell(target: Ref, verb: string, args: Argument[] = []): Promise<void> {
		this.#guardOpen();
		this.#host.drainGc();
		await dispatchTell(
			this.#hosted,
			{
				ptr: this.#ptr,
				kickActions: () => this.#host.kickActions(),
			},
			target,
			verb,
			args,
			(t, v, a) => this.tell(t, v, a),
		);
	}

	/** Record the complete exporter locator the gifter embeds when *this*
	 * session is the exporter side of a
	 * handoff this host originates. Needed when the partner's signed location
	 * is not dialable on its own — an iroh partner signs only its node id, so a
	 * gifter that learned the exporter's `direct-addresses` out of band sets
	 * the full locator here. Unset, origination falls back to the partner's
	 * signed location. */
	setExporterLocator(locator: Locator | null): void {
		this.#guardOpen();
		if (locator === null) {
			checkHost(hostS.pancake_host_session_set_exporter_location(this.#ptr, NULL));
			return;
		}
		withOwnedLocator(
			locator,
			(owned) =>
				checkHost(hostS.pancake_host_session_set_exporter_location(
					this.#ptr,
					owned.borrowView(),
				)),
		);
	}

	// ── The partner's session identity and locator claim ───────────────────────

	/** Read this partner's verified session identity, locator claim, and durable
	 * identity provenance.
	 *
	 * A returned value always means the hello signature was checked. That
	 * signature proves control of `sessionKey` and binds the locator record to
	 * that session. It proves only that the session claimed `designator`, not
	 * that the partner controls the durable key or address it names. Read
	 * `provenance` before relying on a durable identity; only
	 * `authenticated-transport` records channel proof of that identity.
	 *
	 * It throws while the partner's `op:start-session` has not arrived with a
	 * key yet, and it throws on a session opened without a verified hello
	 * signature. This verification does not change an unauthenticated locator
	 * claim into durable identity proof.
	 *
	 * The bytes are copied out of the session, so the returned values are yours
	 * and stay valid once the session is gone. */
	partnerIdentity(): PartnerIdentity {
		this.#guardOpen();
		const buf = new Uint8Array(L.PARTNER_IDENTITY_SIZE);
		checkHost(hostS.pancake_host_session_partner_identity(this.#ptr, ab(buf)));
		// The views the call filled in are session-owned and a later call can
		// invalidate them, so every field is copied here (`readBytes` owns its
		// result) before this returns.
		const dv = new DataView(buf.buffer);
		const view = (off: number, lenOff: number): Uint8Array =>
			readBytes(L.getPtr(dv, off), L.getUsize(dv, lenOff));
		return {
			sessionKey: view(
				L.PARTNER_IDENTITY_SESSION_KEY_OFF,
				L.PARTNER_IDENTITY_SESSION_KEY_LEN_OFF,
			),
			designator: utf8Decoder.decode(view(
				L.PARTNER_IDENTITY_DESIGNATOR_OFF,
				L.PARTNER_IDENTITY_DESIGNATOR_LEN_OFF,
			)),
			locatorRecord: view(
				L.PARTNER_IDENTITY_LOCATOR_RECORD_OFF,
				L.PARTNER_IDENTITY_LOCATOR_RECORD_LEN_OFF,
			),
			provenance: provenanceFromAbi(
				dv.getUint32(L.PARTNER_IDENTITY_PROVENANCE_OFF, true),
			),
		};
	}

	/** Testify what proved this connection's far end, when your own transport
	 * proved one.
	 *
	 * pancake does not open your sockets, so it cannot see what opening them
	 * established. An iroh connection completes only with the holder of the
	 * node id you dialed or accepted, and that is a stronger fact than anything
	 * a partner can claim about itself — but only you hold it. Pass the node id
	 * here and {@link partnerIdentity} reports `authenticated-transport`;
	 * withhold it and the same session reports `unauthenticated`.
	 *
	 * `designator` is that identity as a locator writes it, which is exactly
	 * what the iroh transport's `remoteNodeId` hands you.
	 *
	 * Call it after opening the session and before feeding the first byte from
	 * the partner. It throws afterwards, because by then the handshake this
	 * evidence was for has already been judged. Naming a second, different
	 * identity throws too: one connection has one far end. Naming the same one
	 * twice is the same statement made twice and is fine. */
	bindVerifiedChannelKey(designator: string): void {
		this.#guardOpen();
		const bytes = utf8Encoder.encode(designator);
		checkHost(hostS.pancake_host_session_bind_verified_channel_key(
			this.#ptr,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	// ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

	/** Opt this session into distributed GC (ADR-0063), off by default. Once
	 * on, a far capability returned by {@link fetch} releases its import to the
	 * partner — a single `op:gc-exports` delta, routed through the host to the
	 * import's home connection — when the runtime reclaims the last `Ref` to
	 * it, so the partner can release the matching export. Collection is
	 * best-effort on the JS `FinalizationRegistry` schedule. Capabilities
	 * lifted elsewhere (a `send` reply, a delivered argument, an `enliven`
	 * result the dedup cache owns) are outside this seam. Returns `this` for
	 * chaining. */
	withGc(): this {
		this.#gcEnabled = true;
		return this;
	}

	/** Give a capability back to the partner, now, because this application is
	 * done holding it.
	 *
	 * Releases one application retain. For a remote capability the Host emits
	 * any required `op:gc-exports`; a local capability needs no wire message.
	 * {@link withGc} does this too, but only for a {@link fetch} result and
	 * only when the runtime gets round to it; this is deterministic and works
	 * for any far capability this session holds, including one lifted from a
	 * delivered argument or a reply.
	 *
	 * `ref` is spent afterwards and every use of it throws. The Host generation
	 * makes the stale id fail closed; the binding rejects it before crossing the
	 * ABI.
	 *
	 * A reference from another Host, or one already released, is a caller error
	 * and throws. */
	release(ref: Ref): void {
		if (ref.released) {
			throw new Error("pancake: capability already released");
		}
		releaseRef(this.#host.raw, ref);
		this.#host.disarmGc(ref);
		ref.markReleased();
	}
}

/** The live session whose inbound call is running right now, or null outside
 * any hosted turn.
 *
 * A hosted actor can answer calls arriving through any Port on its Host. When
 * behavior must reply to its caller (send to a reply capability it was handed,
 * or hand back a fresh one), it reads the arriving session here:
 *
 *   host.publishGiftable("dm", (verb, args) => {
 *     const from = String(args[0]), text = String(args[1]);
 *     const reply = args[2];                     // a Ref the caller passed
 *     const session = currentSession();          // the session it arrived through
 *     if (session && reply instanceof Ref) {
 *       session.send(reply, "ack", [from]);      // reply on the same session
 *     }
 *   });
 *
 * The reply capability is a far import in the arriving session, so it must be
 * sent in that same session. Capture the session synchronously inside the
 * turn (it is null once the turn returns) to reply on a later turn. */
export function currentSession(): Session | null {
	const s = currentTurnSession();
	return s instanceof Session ? s : null;
}
