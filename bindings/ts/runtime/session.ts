// The application surface over the byte-fed host (libglowcap_host):
// `Session` and its methods (`fetch`, `send`, `tell`, `spawn`,
// `publish`, `enliven`, `serve`, `close`), plus the mint and handshake
// entry points (`establishDialedLocator`, `establishAccepted`). The host owns
// routing, redemption, gift origination, and far vows.

import { HANDSHAKE_TIMEOUT_MS, NOT_FOUND } from "@glowcap/abi";
import { checkHost, GlowcapError, retainCleanupFailures } from "./errors.ts";
import { Host } from "./host.ts";
import { hostS } from "./internal/ffi/host.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outU64 } from "./internal/seam.ts";
import { type CloseOptions } from "./lifecycle.ts";
import { type Locator, withOwnedLocator } from "./locator.ts";
import { openAccepted, openDialed } from "./session/open.ts";
import { readPartnerIdentity } from "./session/metadata.ts";
import { SessionState } from "./session/state.ts";
import type { AcceptedTransport, Channel, LoopChannel } from "./session/channel.ts";
export type { AcceptedTransport, Channel, DriverLoopHandle, LoopChannel } from "./session/channel.ts";
import {
	attenuateProxy,
	caretakerProxy,
	currentTurnSession,
	dispatchSend,
	dispatchTell,
	publishHosted,
	spawnHosted,
} from "./trampoline.ts";
import { type Argument, type Behavior, Ref, refFromId, type SessionProfile } from "./value.ts";
import { releaseRef } from "./gc.ts";
import { fetchLike, listenFar, RemotePromise } from "./promise.ts";
import { type PartnerIdentity } from "./session/identity.ts";
import type { AbortDetail } from "./errors.ts";

// Encoder for establish/fetch swiss bytes.
const utf8Encoder = new TextEncoder();

export {
	durableIdentityAuthenticated,
	type DurableProvenance,
	type PartnerIdentity,
	provenanceFromAbi,
} from "./session/identity.ts";

/** How long a partner has to finish the keyed handshake once the byte channel
 * is open, on both halves: what `connect` allows a dialed partner, and what a
 * listener allows an accepted one.
 *
 * Matches the CLI's own product default. Something finite is the point: this
 * project's rule for CapTP waits is that an unbounded one is a hang rather than
 * a slow success, and neither half of a connection is exempt. It bounds the
 * handshake alone, never opening the channel: a TCP connect keeps the runtime's
 * own timeout, and an iroh dial-by-id is one transport attempt, both spent
 * before the handshake starts. */
export { HANDSHAKE_TIMEOUT_MS };

/** Result of {@link Session.sendRedeeming}: the ordinary send reply plus the
 * direct exporter session selected by that reply's route, when one exists. */
export interface SendRedeemingResult {
	reply: Argument;
	via: Session | null;
}

/** A live CapTP session with one OCapN partner, the one object an application
 * holds, over one byte-fed `GlowcapHostSession` the shared `Host` minted.
 *
 *   await using runtime = await Runtime.open({ providers: [tcp.provider()] });
 *   await using session = await runtime.connect(tcp.locator("127.0.0.1", 9099));
 *   session.serve().catch((e) => console.error(e));
 *   const room = await session.fetch("room");
 *   const inbox = session.spawn((verb, args) => { ...; });
 *   await session.send(room, "subscribe", ["alice", inbox]);
 */
export class Session {
	readonly #state: SessionState;
	private constructor(ptr: Ptr, host: Host, transport: Channel) {
		this.#state = new SessionState(ptr, host, transport, this);
		host.registerSession(ptr, this);
	}

	/** The raw GlowcapHostSession handle. Binding-internal: the host's DIAL arm
	 * reports it through `glowcap_host_dialed`. */
	get raw(): Ptr {
		return this.#state.ptr;
	}

	/** The session's shared host, its retained identity and handoff router.
	 * Shared by every session of one host, so the gifter half of a handoff
	 * can reach a sibling session's session keys. An application reads it to
	 * publish host-publications (`Host.publish`), share one identity
	 * across dials, or set the redeem posture. */
	get host(): Host {
		return this.#state.hostOwner;
	}

	/** Whether local transport teardown has begun. Binding-internal pump seam. */
	get closing(): boolean {
		return this.#state.closing;
	}

	/** Nonzero once the keyed handshake has completed and the session is open. */
	get sessionOpen(): boolean {
		return this.#state.sessionOpen;
	}

	/** The version, codec, and feature set this live session settled with its
	 * partner. No Host preference is inferred at this layer. */
	get profile(): SessionProfile {
		return this.#state.profile;
	}

	/** The exact netlayer symbol this connection was opened through. */
	get transportName(): string {
		return this.#state.transportName;
	}

	/** Run the inbound loop: read transport packets, hand them to the Host
	 * transport seam (behaviors run and vow completions queue inside the feed),
	 * and drain the action queue. Resolves when the connection closes cleanly;
	 * rejects on a transport or protocol error. Started once; calling again
	 * returns the same promise.
	 *
	 * A loop-backed session (ADR-0024) has no byte pump of its own: the
	 * driver loop reads, feeds, and drains. Its serve promise only awaits
	 * the session's closure, keeping the resolves-on-close contract. */
	serve(): Promise<void> {
		return this.#state.serve();
	}

	/** Run `listener` exactly once when this session's transport retires.
	 * Registration after retirement runs it immediately. The callback is a
	 * lifecycle signal only; `serve()` remains the typed failure channel.
	 * The Host retains a failure from an asynchronous notification. */
	onClose(listener: () => void): () => void {
		return this.#state.onClose(listener);
	}

	/** The typed cause of this CapTP session's most recent local dispatch failure,
	 * or null when none has been recorded. The flat per-feed error code names
	 * the failure family; this names the member. */
	lastAbort(): AbortDetail | null {
		return this.#state.lastAbort();
	}

	/** Wake this session's writer, how a FLUSH action lands. Returns before
	 * any byte is written. Binding-internal. */
	requestFlush(): number {
		return this.#state.requestFlush();
	}

	/** Have the writer drain what the core queued ahead of a CLOSE action, then
	 * retire the session and settle an explicit close with `result`.
	 * Binding-internal. */
	closeAfterFlush(result: number): void {
		return this.#state.closeAfterFlush(result);
	}

	/** Close this session's connection and nothing else. A running `serve()`
	 * resolves cleanly; pending vows settle with the typed CLOSED.
	 *
	 * It does not reach a sibling session, and it does not reach the
	 * connections the host opened by itself to redeem a handoff: the `via`
	 * from `sendRedeeming()` is one of those. `Runtime.close()` ends the
	 * Runtime's Host and those sessions. */
	close(options: CloseOptions = {}): Promise<void> {
		return this.#state.close(options);
	}

	/** Commit wrapper retirement after the FFI owner released the whole Host
	 * or loop. No per-session FFI call is valid beyond this boundary. */
	ffiOwnerDidRelease(): Promise<void> {
		return this.#state.ffiOwnerDidRelease();
	}

	/** Project one FFI SESSION_CLOSED event onto this wrapper before release.
	 * Binding-internal: the loop owns classification; Session owns only promise
	 * and listener settlement. */
	ffiTransportDidClose(error: GlowcapError | null): Promise<void> {
		return this.#state.ffiTransportDidClose(error);
	}

	/** Close just this session, without touching the host's other sessions:
	 * stop the transport first, then retire the host's entry and
	 * free the host handle (the core settles any still-parked far vows during
	 * release), so no foreign call touches a freed session.
	 * A release refused inside a behavior callback is parked for the next
	 * drain, never dropped. Binding-internal. */
	closeTransport(): Promise<void> {
		return this.#state.closeTransport();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}

	// ── Construction: establish, dial, accept ──────────────────────────────────

	/** Mint the dialing half over a byte channel the caller already realized
	 * for `locator`. The locator travels whole; the host retains its own dial
	 * default for the transport and keys duplicate-dial refusal on the
	 * designator, so no locator policy lives here. The handshake is bounded by
	 * `handshakeTimeoutMs` (`HANDSHAKE_TIMEOUT_MS` on every dial the binding
	 * performs; `0` or `null` waits unbounded), and overrunning it rejects
	 * with `GlowcapError` carrying `TIMEOUT`. `verifiedChannelKey` is the
	 * partner key the transport itself authenticated (a WebRTC designator the
	 * DTLS handshake bound, an iroh node id), bound before the first partner
	 * byte, or `null` for a transport with no channel proof. Every caller
	 * states it, so a transport with a proof cannot drop it in silence.
	 * Binding-internal. */
	static async establishDialedLocator(
		host: Host,
		locator: Locator,
		transport: Channel,
		handshakeTimeoutMs: number | null,
		verifiedChannelKey: string | null,
	): Promise<Session> {
		let session: Session | null = null;
		try {
			session = new Session(openDialed(host.raw, locator), host, transport);
			// Before the first partner byte, which is the only window a realizer's
			// proof can be weighed in.
			if (verifiedChannelKey) session.bindVerifiedChannelKey(verifiedChannelKey);
			await session.#state.establish(handshakeTimeoutMs);
			return session;
		} catch (error) {
			await retainCleanupFailures(error, [() => session == null ? transport.close() : session.closeTransport()]);
			throw error;
		}
	}

	/** Mint the accepting half over a connection the caller's own listener
	 * produced. `accepted` carries the provider's transport metadata and byte
	 * channel as one value; the host resolves what this accept signs and
	 * retains it without displacing an explicitly selected advertised locator
	 * (ADR-0029), with no locator policy in this binding layer. The handshake
	 * is bounded by `handshakeTimeoutMs` (`HANDSHAKE_TIMEOUT_MS` in every
	 * accept loop here; `0` or `null` waits unbounded, which a caller parking
	 * a registration rather than running an accept loop wants), and
	 * overrunning it rejects with `GlowcapError` carrying `TIMEOUT`, which an
	 * accept loop treats as any other bad partner. Binding-internal. */
	static async establishAccepted(
		host: Host,
		accepted: AcceptedTransport,
		handshakeTimeoutMs: number | null,
	): Promise<Session> {
		const { channel: transport, verifiedChannelKey } = accepted;
		let session: Session | null = null;
		try {
			session = new Session(openAccepted(host.raw, accepted), host, transport);
			// Before the first partner byte, which is the only window a realizer's
			// proof can be weighed in.
			if (verifiedChannelKey) session.bindVerifiedChannelKey(verifiedChannelKey);
			await session.#state.establish(handshakeTimeoutMs);
			return session;
		} catch (error) {
			await retainCleanupFailures(error, [() => session == null ? transport.close() : session.closeTransport()]);
			throw error;
		}
	}

	static adoptLoopSession(ptr: Ptr, host: Host, transport: LoopChannel): Session {
		return new Session(ptr, host, transport);
	}
	/** Listen on a far capability this session holds (CapTP `op:listen`,
	 * ADR-0003): the returned handle settles with the listen notification,
	 * which may be any value, not only a capability. In 1.0, the target may be
	 * a far promise or live far object; in glowcap-next, the target must be a
	 * promise. A re-gifted promise routes to its exporter session
	 * transparently. */
	listen(target: Ref): RemotePromise {
		this.#state.guardOpen();
		return listenFar(this.#state, target);
	}

	/** Spawn a local actor and return a capability to it. The `Ref`
	 * auto-marshals when passed as a `send` argument, so handing a partner a
	 * callback is just `send(target, verb, [..., session.spawn(behavior)])`. The
	 * returned identity is opaque and Host-scoped; wire export positions stay
	 * inside glowcap. Callable from inside a served turn (a factory's `create`
	 * minting the task it replies with). */
	spawn(behavior: Behavior): Ref {
		return spawnHosted(this.#state, behavior);
	}

	/** Publish an actor so a partner can `fetch` it by `name`. The name is a
	 * swiss-number: a readable string for a discoverable service, a
	 * cryptographic secret where the name itself is the authorization. */
	publish(name: string, behavior: Behavior): Ref {
		return publishHosted(this.#state, name, behavior);
	}

	/** A {@link Ref} for the object published under `name` on this session, or
	 * null when nothing is published there.
	 *
	 * {@link publish} returns its own `Ref`, so this is for the other publisher:
	 * {@link Host.publish} hosts one actor under a Host-wide alias and
	 * returns nothing. Reading its Host identity lazily projects it onto this
	 * session so an application can pass it as an ordinary capability argument;
	 * no enrollment step exists.
	 *
	 * A `send` to the returned `Ref` runs the behavior in process rather than over
	 * the wire, and a Host publication registered no session, so `currentSession()` inside
	 * it is null. Pass it on as a capability argument; a behavior
	 * written to answer over the connection its call arrived on will not answer a
	 * local send. */
	publishedRef(name: string): Ref | null {
		this.#state.guardOpen();
		const bytes = utf8Encoder.encode(name);
		const out = new Uint8Array(8);
		const code = hostS.glowcap_host_session_published_ref(
			this.#state.ptr,
			ab(bytes),
			BigInt(bytes.length),
			ab(out),
		);
		if (code === NOT_FOUND) return null;
		checkHost(code);
		const ref = refFromId(outU64(out));
		// Join the Host publication to the identity this session surfaced, so a
		// later local send to the returned Ref composes in process. Skipped when the
		// identity is already known: `publish` on this session recorded its own.
		if (!this.#state.hosted.has(ref.id)) {
			const ctx = this.#state.hostOwner.publicationCtx(name);
			if (ctx !== undefined) {
				this.#state.hosted.set(ref.id, ctx);
			}
		}
		return ref;
	}

	/** Wrap `target` (local or far) in a revocable caretaker (ADR-0016).
	 * Returns the proxy capability to hand a partner and a `revoke` lever;
	 * every call through the proxy forwards to `target` until `revoke()`,
	 * after which each breaks with `Revoked`. `target` may be a capability
	 * imported over the wire (the proxy forwards transparently), so this
	 * hands out a revocable view of authority you do not own locally. */
	caretaker(target: Ref): { proxy: Ref; revoke: () => void } {
		return caretakerProxy((behavior) => this.spawn(behavior), target);
	}

	/** Wrap `target` (local or far) in an attenuator (ADR-0016): a proxy that
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
	 * token (ADR-0026) before the completion is queued, so a return re-gifts
	 * the right home. Drives the inbound loop itself, so a `fetch` straight
	 * after `connect` works without a separate `serve()` call. Rejects with
	 * `VowBroken` when the partner breaks the fetch, and with `FetchFailed`
	 * when it fulfills with something that is not a live capability. */
	async fetch(name: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(name);
		const ref = await fetchLike(
			this.#state,
			swiss,
			name,
			hostS.glowcap_host_session_fetch,
			true,
		);
		return ref;
	}

	/** Enliven a sturdyref against this session (ADR-0007): bring the
	 * durable `(peer, swissnum)` to life as a live `Ref`. `sturdyref` uses the
	 * canonical persistent URI form, independent of this live session's CapTP
	 * profile. The host verifies it against this session before
	 * consulting its dedup cache. A
	 * repeat enliven of the same swissnum on this session short-circuits with
	 * no wire traffic (its completion is queued before the minting call
	 * returns). The session must already be open to the sturdyref's peer;
	 * this session-level call never dials. Rejects with
	 * `VowBroken` when the partner breaks the enliven, and with `FetchFailed`
	 * when it fulfills with something that is not a capability. */
	async enliven(sturdyref: string): Promise<Ref> {
		// Fresh and cached results each project an application retain. The
		// session's GC opt-in applies independently to every occurrence.
		return await fetchLike(
			this.#state,
			utf8Encoder.encode(sturdyref),
			sturdyref,
			hostS.glowcap_host_session_enliven,
			true,
		);
	}

	/** Apply this Session's opt-in to an FFI-projected application value.
	 * Binding-internal: the trampoline uses it for delivered arguments. */
	trackGcArgument(value: Argument): Argument {
		return this.#state.gcEnabled ? this.#state.hostOwner.trackGcArgument(value) : value;
	}

	/** Eventual-send `verb(args)` to `target` and return a `RemotePromise` for
	 * the reply. `await` it for the value (a `Ref` if the partner returned a
	 * capability; rejects with `VowBroken` on a partner break).
	 *
	 * `target` is a capability `Ref` *or* a `RemotePromise` from an earlier status-allow: event or source ordering
	 * send: passing the latter pipelines (ADR-0003). The call is addressed at
	 * the answer that send will resolve, so a dependent chain costs one round
	 * trip instead of one per link. `args` may contain `Ref`s. A `Ref` this
	 * session spawned runs in process; a partner's rides the wire, and a
	 * redeemed handoff token routes to the exporter session that hosts it,
	 * transparently.
	 *
	 * The deliver schedules Host progress now. Synchronous dependent sends join
	 * the same event-loop-turn batch; awaiting observes the result rather than
	 * deciding whether the operation leaves the process. */
	send(
		target: Ref | RemotePromise,
		verb: string | null,
		args: Argument[] = [],
	): RemotePromise {
		// A send that cannot be issued comes back as a failed handle, not a
		// throw. `send` must return synchronously so a caller can pipeline at
		// the answer before it settles (ADR-0004), so it cannot be `async`,
		// but a promise-returning method whose failure arrives synchronously is
		// a trap: the obvious `session.send(…).catch(…)` never sees it, and a
		// caller who cleared a dead route in that handler kept using it.
		try {
			this.#state.guardOpen();
			this.#state.hostOwner.drainGc();
			return dispatchSend(
				this.#state.hosted,
				this.#state,
				target,
				verb,
				args,
				(t, v, a) => this.send(t, v, a),
			);
		} catch (err) {
			// Everything, not only typed refusals: the contract is that `send`
			// reports through the handle, and a channel that is mixed depending
			// on the error is the trap again in a narrower form.
			return RemotePromise.failed(err);
		}
	}

	/** Eventual-send `verb(args)` to `target`, await the reply, and also surface
	 * the direct `Session` a three-party-handoff redeem opened to answer it.
	 *
	 * When `target` answers with a `desc:handoff-give` (a rooms `introduce`, say),
	 * the binding redeems it by dialing the exporter, and the reply resolves to a
	 * capability that routes over a fresh direct session. The byte connection is
	 * otherwise internal. This returns the session as `via`, so a caller can host
	 * objects in the same session as the redeemed capability. It is the one
	 * place a reply capability handed back to the exporter is valid, since an
	 * OCapN near export names a position in one specific session. `via`
	 * is resolved from the reply's own route (the token carries which exporter
	 * session it lives in), so it is correct with several redeems in flight at
	 * once and it finds an exporter a prior redeem already dialed (a cache hit
	 * that opens no new session). `via` is null when the reply is not a
	 * redeemed-handoff capability (an ordinary far reply) or its exporter
	 * session is already gone.
	 *
	 *   const { reply, via } = await session.sendRedeeming(directory, "introduce", [nick]);
	 *   const inbox = (via ?? session).spawn(replyBehavior);   // hosted where the reply lives
	 *   await (via ?? session).send(reply as Ref, "dm", [text, inbox]);
	 */
	async sendRedeeming(
		target: Ref | RemotePromise,
		verb: string | null,
		args: Argument[] = [],
	): Promise<SendRedeemingResult> {
		this.#state.guardOpen();
		const reply = await this.send(target, verb, args);
		let via = reply instanceof Ref ? this.#state.hostOwner.exporterFor(reply) : null;
		if (via === this) via = null;
		return { reply, via };
	}

	/** Send `verb(args)` to `target` without awaiting a reply, the
	 * fire-and-forget eventual-send (Goblins `<-np`). No answer is allocated
	 * and none comes back, so it is the right call for a notification or a
	 * broadcast: it costs one deliver, not a deliver plus a reply. Returns once
	 * the deliver is queued, and the session's writer sends it. */
	async tell(target: Ref | RemotePromise, verb: string | null, args: Argument[] = []): Promise<void> {
		this.#state.guardOpen();
		this.#state.hostOwner.drainGc();
		await dispatchTell(
			this.#state.hosted,
			this.#state,
			target,
			verb,
			args,
			(t, v, a) => this.tell(t, v, a),
			(error) => this.#state.hostOwner.recordCallerlessFailure("tell.behavior", error),
		);
		this.#state.throwWireFailure();
	}

	/** Record the complete exporter locator the gifter embeds when *this*
	 * session is the exporter side of a
	 * handoff this host originates. Needed when the partner's signed location
	 * is not dialable on its own (an iroh partner signs only its node id), so a
	 * gifter that learned the exporter's `direct-addresses` out of band sets
	 * the full locator here. Unset, origination falls back to the partner's
	 * signed location. */
	setExporterLocator(locator: Locator | null): void {
		this.#state.guardOpen();
		if (locator === null) {
			checkHost(hostS.glowcap_host_session_set_exporter_location(this.#state.ptr, NULL));
			return;
		}
		withOwnedLocator(
			locator,
			(owned) =>
				checkHost(hostS.glowcap_host_session_set_exporter_location(
					this.#state.ptr,
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
	 * key yet, and it throws on a session opened without a verified hello status-allow: pending state or quoted runtime label
	 * signature. This verification does not change an unauthenticated locator
	 * claim into durable identity proof.
	 *
	 * The bytes are copied out of the session, so the returned values are yours
	 * and stay valid once the session is gone. */
	partnerIdentity(): PartnerIdentity {
		this.#state.guardOpen();
		return readPartnerIdentity(this.#state.ptr);
	}

	/** Testify what proved this connection's far end, when your own transport
	 * proved one.
	 *
	 * glowcap does not open your sockets, so it cannot see what opening them
	 * established. An iroh connection completes only with the holder of the
	 * node id you dialed or accepted, and that is a stronger fact than anything
	 * a partner can claim about itself, but only you hold it. Pass the node id
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
		this.#state.guardOpen();
		const bytes = utf8Encoder.encode(designator);
		checkHost(hostS.glowcap_host_session_bind_verified_channel_key(
			this.#state.ptr,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	// ── Distributed GC (ADR-0025), opt-in and off by default ───────────────────

	/** Opt this session into distributed GC (ADR-0025), off by default. Every
	 * capability occurrence projected through {@link fetch}, a fulfilled far
	 * operation, or a recursively nested delivered argument releases its Host
	 * retain when the runtime reclaims its `Ref`. The Host routes any required
	 * `op:gc-exports` to the import's actual home. Collection is scheduled by
	 * `FinalizationRegistry`; once parked, a release remains Host-owned until
	 * FFI commit. Fresh and cached `enliven` results each own a retain. Returns
	 * `this` for chaining. */
	withGc(): this {
		this.#state.gcEnabled = true;
		return this;
	}

	/** Give a capability back to the partner, now, because this application is
	 * done holding it.
	 *
	 * Releases one application retain. For a remote capability the Host emits
	 * any required `op:gc-exports`; a local capability needs no wire message.
	 * {@link withGc} does this best-effort for every capability occurrence
	 * projected by an opted-in session; this is deterministic and also works
	 * for a handle outside that automatic seam.
	 *
	 * `ref` is spent afterwards and every use of it throws. The Host generation
	 * makes the stale id fail closed; the binding rejects it before crossing the
	 * ABI.
	 *
	 * A reference from another Host, or one already released, is a caller error
	 * and throws. */
	release(ref: Ref): void {
		if (ref.released) {
			throw new Error("glowcap: capability already released");
		}
		releaseRef(this.#state.hostOwner.raw, ref);
		this.#state.hostOwner.disarmGc(ref);
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
 *   host.publish("dm", (verb, args) => {
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
