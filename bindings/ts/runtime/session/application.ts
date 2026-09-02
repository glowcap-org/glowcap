// Internal application-verb and capability-projection owner for Session.

import { INVALID_ARGUMENT, NOT_FOUND } from "@glowcap/abi";
import { checkHost, GlowcapError } from "../errors.ts";
import { releaseRef } from "../gc.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL } from "../internal/ffi/runtime.ts";
import { L } from "../internal/layout.ts";
import { ab, outU64, readBytes } from "../internal/seam.ts";
import { type Locator, withOwnedLocator } from "../locator.ts";
import { fetchLike, listenFar, RemotePromise } from "../promise.ts";
import type { SendRedeemingResult } from "../session.ts";
import {
	attenuateProxy,
	caretakerProxy,
	dispatchSend,
	dispatchTell,
	type HostingHandle,
	publishHosted,
	spawnHosted,
} from "../trampoline.ts";
import { type Argument, type Behavior, Ref, refFromId } from "../value.ts";
import { type PartnerIdentity, provenanceFromAbi } from "./identity.ts";
import { SessionLifecycle } from "./lifecycle.ts";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

export abstract class SessionApplication extends SessionLifecycle {
	#makeHosting(): HostingHandle {
		// deno-lint-ignore no-this-alias -- object-literal methods close over Session `#` fields
		const s = this;
		return {
			guardOpen: () => s.guardOpen(),
			get ptr() {
				return s.nativePtr;
			},
			get hosted() {
				return s.hostedActors;
			},
			registerBehavior: (entry) => s.hostOwner.registerHostedBehavior(entry),
			unregisterBehavior: (id) => s.hostOwner.unregisterHostedBehavior(id),
			hostOwner: s.hostOwner,
		};
	}

	/** Listen on a far capability this session holds (CapTP `op:listen`,
	 * ADR-0095): the returned handle settles with the listen notification,
	 * which may be any value, not only a capability. In 1.0, the target may be
	 * a far promise or live far object; in glowcap-next, the target must be a
	 * promise. A re-gifted promise routes to its exporter session
	 * transparently. */
	listen(target: Ref): RemotePromise {
		this.guardOpen();
		return listenFar(this.makePromiseFactory(), target);
	}

	/** Spawn a local actor and return a capability to it. The `Ref`
	 * auto-marshals when passed as a `send` argument, so handing a partner a
	 * callback is just `send(target, verb, [..., session.spawn(behavior)])`. The
	 * returned identity is opaque and Host-scoped; wire export positions stay
	 * inside glowcap. Callable from inside a served turn (a factory's `create`
	 * minting the task it replies with). */
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
		this.guardOpen();
		const bytes = utf8Encoder.encode(name);
		const out = new Uint8Array(8);
		const code = hostS.glowcap_host_session_published_ref(
			this.nativePtr,
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
		if (!this.hostedActors.has(ref.id)) {
			const ctx = this.hostOwner.giftableCtx(name);
			if (ctx !== undefined) {
				this.hostedActors.set(ref.id, ctx);
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
			this.makeMintAwait(),
			swiss,
			name,
			hostS.glowcap_host_session_fetch,
			true,
		);
		return ref;
	}

	/** Enliven a sturdyref against this session (ADR-0098): bring the
	 * durable `(peer, swissnum)` to life as a live `Ref`. `sturdyref` uses the
	 * canonical persistent URI form, independent of this live session's CapTP
	 * profile. The host verifies it against this session before
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
			this.makeMintAwait(),
			utf8Encoder.encode(sturdyref),
			sturdyref,
			hostS.glowcap_host_session_enliven,
			false,
		);
	}

	/** Apply this Session's opt-in to a native-projected application value.
	 * Binding-internal: the trampoline uses it for delivered arguments. */
	trackGcArgument(value: Argument): Argument {
		return this.distributedGcEnabled ? this.hostOwner.trackGcArgument(value) : value;
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
	 * The deliver schedules Host progress now. Synchronous dependent sends join
	 * the same event-loop-turn batch; awaiting observes the result rather than
	 * deciding whether the operation leaves the process. */
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
			this.guardOpen();
			this.hostOwner.drainGc();
			return dispatchSend(
				this.hostedActors,
				this.makePromiseFactory(),
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
				err instanceof GlowcapError ? err : new GlowcapError(INVALID_ARGUMENT, String(err)),
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
		this.guardOpen();
		const reply = await this.send(target, verb, args);
		let via = reply instanceof Ref ? this.hostOwner.exporterFor(reply) : null;
		if (via === this) via = null;
		return { reply, via };
	}

	/** Send `verb(args)` to `target` without awaiting a reply, the
	 * fire-and-forget eventual-send (Goblins `<-np`). No answer is allocated
	 * and none comes back, so it is the right call for a notification or a
	 * broadcast: it costs one deliver, not a deliver plus a reply. Flushes
	 * immediately. */
	async tell(target: Ref | RemotePromise, verb: string, args: Argument[] = []): Promise<void> {
		this.guardOpen();
		this.hostOwner.drainGc();
		await dispatchTell(
			this.hostedActors,
			this.makePromiseFactory(),
			target,
			verb,
			args,
			(t, v, a) => this.tell(t, v, a),
			(error) => this.hostOwner.recordCallerlessFailure("tell.behavior", error),
		);
		this.throwWireFailure();
	}

	/** Record the complete exporter locator the gifter embeds when *this*
	 * session is the exporter side of a
	 * handoff this host originates. Needed when the partner's signed location
	 * is not dialable on its own — an iroh partner signs only its node id, so a
	 * gifter that learned the exporter's `direct-addresses` out of band sets
	 * the full locator here. Unset, origination falls back to the partner's
	 * signed location. */
	setExporterLocator(locator: Locator | null): void {
		this.guardOpen();
		if (locator === null) {
			checkHost(hostS.glowcap_host_session_set_exporter_location(this.nativePtr, NULL));
			return;
		}
		withOwnedLocator(
			locator,
			(owned) =>
				checkHost(hostS.glowcap_host_session_set_exporter_location(
					this.nativePtr,
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
		this.guardOpen();
		const buf = new Uint8Array(L.PARTNER_IDENTITY_SIZE);
		checkHost(hostS.glowcap_host_session_partner_identity(this.nativePtr, ab(buf)));
		// The views the call filled in are session-owned and a later call can
		// invalidate them, so every field is copied here (`readBytes` owns its
		// result) before this returns.
		const dv = new DataView(buf.buffer);
		const view = (off: number, lenOff: number): Uint8Array => readBytes(L.getPtr(dv, off), L.getUsize(dv, lenOff));
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
	 * glowcap does not open your sockets, so it cannot see what opening them
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
		this.guardOpen();
		const bytes = utf8Encoder.encode(designator);
		checkHost(hostS.glowcap_host_session_bind_verified_channel_key(
			this.nativePtr,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	// ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

	/** Opt this session into distributed GC (ADR-0063), off by default. Every
	 * capability occurrence projected through {@link fetch}, a fulfilled far
	 * operation, or a recursively nested delivered argument releases its Host
	 * retain when the runtime reclaims its `Ref`. The Host routes any required
	 * `op:gc-exports` to the import's actual home. Collection is scheduled by
	 * `FinalizationRegistry`; once parked, a release remains Host-owned until
	 * native commit. An `enliven` result stays owned by its dedup cache. Returns
	 * `this` for chaining. */
	withGc(): this {
		this.distributedGcEnabled = true;
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
		releaseRef(this.hostOwner.raw, ref);
		this.hostOwner.disarmGc(ref);
		ref.markReleased();
	}
}
