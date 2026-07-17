// The application surface over the byte-fed host (libpancake_driver,
// ADR-0072): `Session` and its verbs (`fetch`/`send`/`tell`/`spawn`/
// `publish`/`enliven`/`serve`/`close`), plus mint/handshake
// (`establishDialedLocator` / `establishAccepted`). The dial executor and
// `connect` live in `dial.ts`; Server/`listen` live in `listen.ts`. The
// `RemotePromise` handle, fetch/enliven mint→await, far-send `sendFar` /
// `promiseFor`, live in `promise.ts`. Spawn/publish hosting, ADR-0064
// proxies, and near/far send·tell dispatch live in `trampoline.ts`. The
// byte-fed embedder pump — handshake,
// read raw bytes, feed, drain, flush — lives in `pump.ts`. The host owns
// everything else: routing, redemption, gift origination, far vows. `mod.ts`
// re-exports the public members.

import {
	attenuateProxy,
	caretakerProxy,
	dispatchSend,
	dispatchTell,
	type HostingHandle,
	insideTurn,
	publishHosted,
	spawnHosted,
	unregisterBehavior,
} from "./trampoline.ts";
import { type AppValue, type Behavior, Ref } from "./value.ts";
import { parseLocator } from "./locator.ts";
import { Host } from "./host.ts";
import {
	fetchLike,
	type MintAwaitHandle,
	type PromiseFactoryHandle,
	RemotePromise,
} from "./promise.ts";
import { ConnGc } from "./gc.ts";
import {
	flushOutbound as pumpFlushOutbound,
	lastAbort as pumpLastAbort,
	type PumpHandle,
	runHandshake,
	serveLoop,
} from "./pump.ts";
import { driverS } from "./internal/ffi/driver.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, readBytes } from "./internal/seam.ts";
import { type AbortDetail, checkHost, PancakeError } from "./errors.ts";
import {
	ACCEPT_PLAN_DESIGNATOR_LEN_OFF,
	ACCEPT_PLAN_DESIGNATOR_OFF,
	ACCEPT_PLAN_DIRECT_ADDRESSES_HINT_LEN_OFF,
	ACCEPT_PLAN_DIRECT_ADDRESSES_HINT_OFF,
	ACCEPT_PLAN_SIZE,
	CLOSED,
} from "./internal/abi.ts";

// Encoder for establish/fetch swiss bytes.
const utf8Encoder = new TextEncoder();

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
	close(): void;
}

/** A live CapTP session with one OCapN partner, the one object an application
 * holds, over one byte-fed `PancakeHostSession` the shared `Host` minted.
 *
 *   const conn = await connect(tcpLocator("127.0.0.1", 9099));
 *   conn.serve().catch((e) => console.error(e));
 *   const room = await conn.fetch("room");
 *   const inbox = conn.spawn((verb, args) => { ...; });
 *   await conn.send(room, "subscribe", ["alice", inbox]);
 */
export class Session {
	#ptr: Ptr;
	readonly #host: Host;
	readonly #transport: Channel;
	// Inbound bytes read from the wire but not yet consumed by the core's
	// stream delimiter (the unconsumed tail of the last feed). Owned by the
	// pump via `#pump`.
	#inbox: Uint8Array = new Uint8Array(0);
	#serving: Promise<void> | null = null;
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the FAIL completions the break queues classify as the
	// typed CLOSED instead of partner breaks, and so a read cancelled by our
	// own close is a clean shutdown.
	#closing = false;
	#released = false;
	// Serializes transport writes. `flushOutbound` runs from the action drain,
	// the feed-failure choreography, and teardown; chaining each flush behind
	// the last keeps every frame whole and in submission order.
	#writing: Promise<void> = Promise.resolve();
	// Live accessors into the private fields above — what `pump.ts` drives.
	readonly #pump: PumpHandle;
	// Export position -> trampoline ctx id for the objects this session
	// hosts, so a `Forward` whose target this side hosts composes in process.
	readonly #hosted = new Map<bigint, bigint>();

	/** True for an exporter session the host's action drain dialed to redeem
	 * a handoff, so `close()` can sweep it. Binding-internal. */
	hostDialed = false;

	// Distributed GC (ADR-0063), opt-in and off by default — see `gc.ts`.
	readonly #gc = new ConnGc();

	private constructor(ptr: Ptr, host: Host, transport: Channel) {
		this.#ptr = ptr;
		this.#host = host;
		this.#transport = transport;
		this.#pump = this.#makePump();
		// deno-lint-ignore no-this-alias -- GcHandle closes over Session `#` fields
		const s = this;
		this.#gc.bind({
			get released() {
				return s.#released;
			},
			get hostRaw() {
				return s.#host.raw;
			},
			kick: () => {
				void s.#host.kickActions();
			},
			scheduleDrain: (run) => {
				setTimeout(run, 0);
			},
		});
		// Join the host's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		host.registerSession(ptr, this);
	}

	/** Bind `#pump` getters/setters onto this Session's private fields. */
	#makePump(): PumpHandle {
		// deno-lint-ignore no-this-alias -- object-literal getters cannot see Session `#` fields without a closed-over instance
		const s = this;
		return {
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
			get inbox() {
				return s.#inbox;
			},
			set inbox(v: Uint8Array) {
				s.#inbox = v;
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
			drainGc: () => s.#gc.drainGc(),
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

	/** The session's shared host, its retained identity and gift registry.
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
			driverS.pancake_host_session_session_open(this.#ptr) === 1;
	}

	// ── Construction: establish, dial, accept ──────────────────────────────────

	/** Mint the dialing half from already-parsed locator pieces (transport +
	 * designator). A DIAL action's binding half borrows the pending URI first.
	 * Binding-internal. */
	static establishDialedLocator(
		host: Host,
		transportName: string,
		designator: string,
		transport: Channel,
	): Promise<Session> {
		const t = utf8Encoder.encode(transportName);
		const d = utf8Encoder.encode(designator);
		const out = new Uint8Array(8);
		checkHost(driverS.pancake_host_session_open_dialed_locator(
			host.raw,
			ab(t),
			BigInt(t.length),
			ab(d),
			BigInt(d.length),
			ab(out),
		));
		const conn = new Session(
			new DataView(out.buffer).getBigUint64(0, true),
			host,
			transport,
		);
		return conn.#establish();
	}

	/** Mint the accepting half over a connection the caller's own listener
	 * produced. `serverDesignator` is the listener's signing designator (key for
	 * keyed-tcp/iroh; unused for tcp); `acceptedLocalAddr` is what accept
	 * reported. Signing designator/hint come from `pancake_host_plan_accept`
	 * (ADR-0078) — no binding-side accept policy. Binding-internal. */
	static establishAccepted(
		host: Host,
		transportName: string,
		serverDesignator: string,
		transport: Channel,
		acceptedLocalAddr = "",
	): Promise<Session> {
		const t = utf8Encoder.encode(transportName);
		const server = utf8Encoder.encode(serverDesignator);
		const local = utf8Encoder.encode(acceptedLocalAddr);
		const planBuf = new Uint8Array(ACCEPT_PLAN_SIZE);
		checkHost(driverS.pancake_host_plan_accept(
			ab(t),
			BigInt(t.length),
			ab(server),
			BigInt(server.length),
			ab(local),
			BigInt(local.length),
			ab(planBuf),
		));
		// Plan views borrow t/server/local (or the static unreachable
		// placeholder). Deno/Bun BufferSource FFI needs a JS TypedArray, so
		// materialize those views once here — named session-mint FFI cost, not
		// a second policy encoding (Rust/Python/Racket pass the C pointers).
		const dv = new DataView(planBuf.buffer);
		const view = (off: number, lenOff: number): Uint8Array => {
			const len = Number(dv.getBigUint64(lenOff, true));
			if (len === 0) return new Uint8Array(0);
			return readBytes(dv.getBigUint64(off, true), BigInt(len));
		};
		const designator = view(ACCEPT_PLAN_DESIGNATOR_OFF, ACCEPT_PLAN_DESIGNATOR_LEN_OFF);
		const hint = view(
			ACCEPT_PLAN_DIRECT_ADDRESSES_HINT_OFF,
			ACCEPT_PLAN_DIRECT_ADDRESSES_HINT_LEN_OFF,
		);
		const out = new Uint8Array(8);
		checkHost(driverS.pancake_host_session_open_accepted(
			host.raw,
			ab(t),
			BigInt(t.length),
			ab(designator),
			BigInt(designator.length),
			ab(hint),
			BigInt(hint.length),
			ab(out),
		));
		const conn = new Session(
			new DataView(out.buffer).getBigUint64(0, true),
			host,
			transport,
		);
		return conn.#establish();
	}

	// Drive the freshly opened connection's keyed handshake to an open session,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one accept, never the listener. The read/feed loop
	// lives in `pump.runHandshake`.
	async #establish(): Promise<Session> {
		try {
			await runHandshake(this.#pump);
			return this;
		} catch (err) {
			this.closeTransport();
			throw err;
		}
	}

	// ── The pump (choreography in pump.ts) ──────────────────────────────────────

	/** Run the inbound loop: read raw bytes, hand them to the core's stream
	 * delimiter (behaviors run and vow completions queue inside the feed), and
	 * drain the action queue. Resolves when the connection closes cleanly;
	 * rejects on a transport or protocol error. Started once; calling again
	 * returns the same promise. */
	serve(): Promise<void> {
		if (this.#serving === null) this.#serving = serveLoop(this.#pump);
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
	 * frames stay whole and in submission order. Binding-internal. */
	async flushOutbound(): Promise<void> {
		await pumpFlushOutbound(this.#pump);
	}

	// ── Teardown ────────────────────────────────────────────────────────────────

	/** Close the session and every exporter connection its host dialed for
	 * handoffs. A running `serve()` resolves cleanly; pending vows settle with
	 * the typed CLOSED. */
	close(): void {
		this.#closing = true;
		this.#host.closeExporters();
		this.closeTransport();
	}

	/** Close just this session, without touching the host's other sessions:
	 * stop the transport first, then retire the host's entry and
	 * free the host handle (its still-parked far vows break inside the release,
	 * classified as closure), so no foreign call touches a freed session.
	 * A release refused inside a behavior callback is parked for the next
	 * drain, never dropped. Binding-internal. */
	closeTransport(): void {
		this.#closing = true;
		try {
			this.#transport.close();
		} catch {
			// already closed
		}
		if (this.#released) return;
		this.#released = true;
		this.#host.unregisterSession(this.#ptr);
		// The host can never deliver to this session's hosted objects again;
		// drop their trampoline entries so the registry does not pin dead
		// behaviors. Host-wide giftables live on the host, untouched here.
		for (const ctx of this.#hosted.values()) {
			unregisterBehavior(ctx);
		}
		this.#hosted.clear();
		const ptr = this.#ptr;
		this.#ptr = NULL;
		if (insideTurn()) {
			this.#host.parkRelease(() => driverS.pancake_host_session_release(ptr));
		} else {
			driverS.pancake_host_session_release(ptr);
		}
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		void this.#host.kickActions();
	}

	[Symbol.dispose](): void {
		this.close();
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
			turnOwner: s,
		};
	}

	/** Spawn a local actor and return a capability to it. The `Ref`
	 * auto-marshals when passed as a `send` argument, so handing a partner a
	 * callback is just `send(target, verb, [..., conn.spawn(behavior)])`. The
	 * position comes from the session's one export allocator, so it can never
	 * alias a bootstrap or resolver export. Callable from inside a served turn
	 * (a factory's `create` minting the task it replies with). */
	spawn(behavior: Behavior): Ref {
		return spawnHosted(this.#makeHosting(), behavior);
	}

	/** Publish an actor so a partner can `fetch` it by `name`. The name is a
	 * swiss-number: a readable string for a discoverable service, a
	 * cryptographic secret where the name itself is the authorization. */
	publish(name: string, behavior: Behavior): Ref {
		return publishHosted(this.#makeHosting(), name, behavior);
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
			driverS.pancake_host_session_fetch,
		);
		return this.#gc.trackImport(ref);
	}

	/** Enliven a sturdyref against this session (ADR-0012): bring the
	 * durable `(peer, swissnum)` to life as a live `Ref`. Parses `sturdyref`
	 * for its swissnum, then fetches it through the host's dedup cache — a
	 * repeat enliven of the same swissnum on this session short-circuits with
	 * no wire traffic (its completion is queued before the minting call
	 * returns). The session must already be open to the sturdyref's peer;
	 * the sans-io core tracks no remote locator and never dials. Rejects with
	 * `VowBroken` when the partner breaks the enliven, and with `FetchFailed`
	 * when it fulfills with something that is not a capability. */
	enliven(sturdyref: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(
			parseLocator(sturdyref, true).swissnum,
		);
		// Unlike `fetch`, the result is not GC-tracked: the host's dedup cache
		// owns an enlivened capability, outside the finalizer seam (ADR-0063).
		return fetchLike(
			this.#makeMintAwait(),
			swiss,
			sturdyref,
			driverS.pancake_host_session_enliven,
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
	 * redeemed handoff token routes to the exporter connection that hosts it,
	 * transparently.
	 *
	 * The deliver is queued now; its bytes leave the wire when the returned
	 * handle — or any send pipelined behind it — is first awaited, so a
	 * pipelined batch travels together. */
	send(
		target: Ref | RemotePromise,
		verb: string,
		args: AppValue[] = [],
	): RemotePromise {
		this.#guardOpen();
		this.#gc.drainGc();
		return dispatchSend(
			this.#hosted,
			this.#makePromiseFactory(),
			target,
			verb,
			args,
			(t, v, a) => this.send(t, v, a),
		);
	}

	/** Send `verb(args)` to `target` without awaiting a reply, the
	 * fire-and-forget eventual-send (Goblins `<-np`). No answer is allocated
	 * and none comes back, so it is the right call for a notification or a
	 * broadcast: it costs one deliver, not a deliver plus a reply. Flushes
	 * immediately. */
	async tell(target: Ref, verb: string, args: AppValue[] = []): Promise<void> {
		this.#guardOpen();
		this.#gc.drainGc();
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

	/** Record the verbatim exporter-location bytes (from `encodePeerLocator`)
	 * the gifter embeds when *this* connection is the exporter side of a
	 * handoff this host originates. Needed when the partner's signed location
	 * is not dialable on its own — an iroh partner signs only its node id, so a
	 * gifter that learned the exporter's `direct-addresses` out of band sets
	 * the full locator here. Unset, origination falls back to the partner's
	 * signed location. */
	setExporterLocator(rawLocator: Uint8Array): void {
		this.#guardOpen();
		checkHost(driverS.pancake_host_session_set_exporter_location(
			this.#ptr,
			ab(rawLocator),
			BigInt(rawLocator.length),
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
		this.#gc.enable();
		return this;
	}
}
