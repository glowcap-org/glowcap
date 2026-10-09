// The CapTP host — multi-session CapTP product over the byte-fed host archive
// (libglowcap_host, ADR-0072). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns — never
// a single-type equation. The `GlowcapHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and explicitly installed byte-channel connectors. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import {
	HOST_DURABLE_ENTROPY_LEN,
	HOST_DURABLE_SWISS_LEN,
	INVALID_ARGUMENT,
	NOT_FOUND,
	SESSION_LIMIT_OPTIONS_ABI_VERSION,
} from "@glowcap/abi";
import { refStruct } from "../abi_value.ts";
import { checkHost, GlowcapError } from "../errors.ts";
import { hostS } from "../internal/ffi/host.ts";
import { L } from "../internal/layout.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab, outPointer } from "../internal/seam.ts";
import { type Locator, withOwnedLocator } from "../locator.ts";
import { asLiveRef } from "../promise.ts";
import { Session } from "../session.ts";
import {
	type BehaviorEntry,
	hostedFreePointer,
	type NativeBehaviorOwner,
	registerBehavior,
	trampolinePointer,
	unregisterBehavior,
} from "../trampoline.ts";
import type { Connector } from "../transport.ts";
import { type Argument, type Behavior, type CaptpVersion, captpVersionId, Ref } from "../value.ts";
import { HostLifecycle } from "./lifecycle.ts";

// One encoder/decoder pair for the whole module: both are stateless here.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** Selective overrides copied into sessions minted after the call. Omitted or
 * zero fields preserve the Host's current value. */
export interface SessionLimitOptions {
	readonly maxFrameBytes?: bigint | number;
	readonly queueCap?: bigint | number;
	readonly outboundHighWaterBytes?: bigint | number;
	readonly maxRetainedSentAnswerBytes?: bigint | number;
}

export abstract class HostApplication extends HostLifecycle implements NativeBehaviorOwner {
	installConnectors(connectors: readonly Connector[]): void {
		const pending = new Map<string, Connector>();
		for (const connector of connectors) {
			for (const transport of connector.transports) {
				if (transport.length === 0) {
					throw new GlowcapError(
						INVALID_ARGUMENT,
						"connector transport symbols must not be empty",
					);
				}
				const installed = pending.get(transport) ?? this._connectors.get(transport);
				if (installed != null && installed !== connector) {
					throw new GlowcapError(
						INVALID_ARGUMENT,
						`host already has a different connector for transport ${JSON.stringify(transport)}`,
					);
				}
				pending.set(transport, connector);
			}
		}
		for (const [transport, connector] of pending) {
			this._connectors.set(transport, connector);
		}
	}

	/** The explicitly installed byte-fed connector for `transport`, if any. */
	connectorFor(transport: string): Connector | null {
		return this._connectors.get(transport) ?? null;
	}

	/** Enliven a canonical persistent sturdyref without naming a session (ADR-0098): the
	 * host enlivens it over a live session it already dialed to that peer, or
	 * dials one itself through this host's own DIAL action and finishes when
	 * the dial reports. The session-scoped `Session.enliven` is the narrower
	 * verb — it never dials, and refuses a sturdyref for another peer. */
	async enliven(sturdyref: string, captpVersion?: CaptpVersion): Promise<Ref> {
		const raw = this.raw;
		const swiss = utf8Encoder.encode(sturdyref);
		const out = new Uint8Array(8);
		checkHost(
			captpVersion === undefined
				? hostS.glowcap_host_enliven(raw, ab(swiss), BigInt(swiss.length), ab(out))
				: hostS.glowcap_host_enliven_for_version(
					raw,
					captpVersionId(captpVersion),
					ab(swiss),
					BigInt(swiss.length),
					ab(out),
				),
		);
		return await this.#awaitHostCapability(new DataView(out.buffer).getBigUint64(0, true), sturdyref);
	}

	/** Fetch a named publication at `locator`, selecting an existing session or
	 * asking the Host's Node to realize its concrete route. The Host's configured
	 * profile owns CapTP version, codec, and private route admission. */
	async fetchAt(locator: Locator, name: string): Promise<Ref> {
		const raw = this.raw;
		const encodedName = utf8Encoder.encode(name);
		const out = new Uint8Array(8);
		withOwnedLocator(locator, (owned) =>
			checkHost(
				hostS.glowcap_host_fetch_at(
					raw,
					owned.borrowView(),
					ab(encodedName),
					BigInt(encodedName.length),
					ab(out),
				),
			));
		return await this.#awaitHostCapability(new DataView(out.buffer).getBigUint64(0, true), name);
	}

	async #awaitHostCapability(vow: bigint, subject: string): Promise<Ref> {
		this.vowMinted(vow);
		try {
			await this.kickActions();
			return asLiveRef(await this.awaitVow(vow), subject);
		} finally {
			this._gc.parkVow(vow);
		}
	}

	/** Retain and select this Host's complete acceptable location. Later
	 * sessions advertise it regardless of their transport; existing sessions
	 * retain the locator their hello signed. */
	setAdvertisedLocator(locator: Locator): void {
		withOwnedLocator(
			locator,
			(owned) => checkHost(hostS.glowcap_host_set_advertised_locator(this._raw, owned.borrowView())),
		);
	}

	/** Remove this Host's retained locator for `transport`. */
	removeAdvertisedLocator(transport: string): void {
		const bytes = utf8Encoder.encode(transport);
		checkHost(hostS.glowcap_host_remove_advertised_locator(
			this._raw,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	/** Apply selective limits to peers minted after this call. The durable
	 * sent-answer budget is separate from transient outbound flow pressure. */
	setSessionLimits(options: SessionLimitOptions = {}): void {
		const maxFrameBytes = sessionLimit("maxFrameBytes", options.maxFrameBytes);
		const queueCap = sessionLimit("queueCap", options.queueCap);
		const outboundHighWaterBytes = sessionLimit(
			"outboundHighWaterBytes",
			options.outboundHighWaterBytes,
		);
		const maxRetainedSentAnswerBytes = sessionLimit(
			"maxRetainedSentAnswerBytes",
			options.maxRetainedSentAnswerBytes,
			0xffff_ffffn,
		);
		const raw = new Uint8Array(L.SESSION_LIMIT_OPTIONS_SIZE);
		const view = new DataView(raw.buffer);
		view.setUint32(
			L.SESSION_LIMIT_OPTIONS_ABI_VERSION_OFF,
			SESSION_LIMIT_OPTIONS_ABI_VERSION,
			true,
		);
		L.setUsize(view, L.SESSION_LIMIT_OPTIONS_STRUCT_SIZE_OFF, raw.length);
		L.setUsize(view, L.SESSION_LIMIT_OPTIONS_MAX_FRAME_BYTES_OFF, maxFrameBytes);
		L.setUsize(view, L.SESSION_LIMIT_OPTIONS_QUEUE_CAP_OFF, queueCap);
		L.setUsize(
			view,
			L.SESSION_LIMIT_OPTIONS_OUTBOUND_HIGH_WATER_BYTES_OFF,
			outboundHighWaterBytes,
		);
		L.setUsize(
			view,
			L.SESSION_LIMIT_OPTIONS_MAX_RETAINED_SENT_ANSWER_BYTES_OFF,
			maxRetainedSentAnswerBytes,
		);
		checkHost(hostS.glowcap_host_set_session_limits(
			this._raw,
			ab(raw),
		));
	}

	/** Configure queue bounds before any session or eventual send. Byte bounds
	 * include message spines and queue rows. No payload storage is allocated. */
	setIngressLimits(options: { maxPendingTurns: number; maxPendingBytes: number; maxChunkBytes: number }): void {
		const values = [options.maxPendingTurns, options.maxPendingBytes, options.maxChunkBytes];
		if (values.some((value) => !Number.isInteger(value) || value <= 0 || value > 0xffff_ffff)) {
			throw new GlowcapError(INVALID_ARGUMENT, "ingress limits must be positive uint32 integers");
		}
		checkHost(hostS.glowcap_host_set_ingress_limits(this._raw, values[0], values[1], values[2]));
	}

	/** The canonical key designator (64 lowercase hex digits) for this host's
	 * identity seed — what a keyed-tcp locator names as its designator
	 * (ADR-0075). */
	designator(): string {
		const out = new Uint8Array(64);
		checkHost(hostS.glowcap_host_designator_from_seed(
			ab(this._seed),
			32n,
			ab(out),
			BigInt(out.length),
		));
		return utf8Decoder.decode(out);
	}

	/** Host `behavior` once and bind `name` as a Host-wide alias. Fetch lazily
	 * projects the actor onto a session; a deposited gift keeps that exact actor
	 * when a recipient withdraws over its own exporter session (ADR-0009).
	 * Returns nothing; the gift's `Ref` is what the gifter passes on. */
	publish(name: string, behavior: Behavior): void {
		// A Host publication is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null }, true);
		const bytes = utf8Encoder.encode(name);
		try {
			checkHost(hostS.glowcap_host_publish(
				this._raw,
				ab(bytes),
				BigInt(bytes.length),
				trampolinePointer(),
				ctx,
				hostedFreePointer(),
			));
		} catch (err) {
			// Nothing else drops a trampoline row, so a refused publish has to
			// take its own back or it pins the behavior for the process's life.
			this.unregisterHostedBehavior(ctx);
			throw err;
		}
		// Replacement moves discovery only. Existing capabilities and deposited
		// gifts can still call the old actor.
		this._publications.set(name, ctx);
		this.scheduleKick();
	}

	/** Publish `behavior` under a freshly minted durable swiss name and return
	 * that name — the swiss to place in a sturdyref beside this host's own
	 * locator (ADR-0098). Unpredictable, never reassigned, structurally
	 * disjoint from every mutable alias, removable only through
	 * {@link unpublishDurable}. When supplied, `entropy` lets an embedder retain
	 * and reproduce the same durable name; otherwise this method draws it. */
	publishDurable(behavior: Behavior, entropy?: Uint8Array): string {
		const entropyBytes = entropy == null
			? crypto.getRandomValues(new Uint8Array(HOST_DURABLE_ENTROPY_LEN))
			: new Uint8Array(entropy);
		if (entropyBytes.length !== HOST_DURABLE_ENTROPY_LEN) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				`durable entropy must be exactly ${HOST_DURABLE_ENTROPY_LEN} bytes`,
			);
		}
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null }, true);
		const swiss = new Uint8Array(HOST_DURABLE_SWISS_LEN);
		let written: number;
		try {
			written = hostS.glowcap_host_publish_durable(
				this._raw,
				ab(entropyBytes),
				BigInt(entropyBytes.length),
				trampolinePointer(),
				ctx,
				hostedFreePointer(),
				ab(swiss),
				BigInt(swiss.length),
			);
			if (written <= 0) checkHost(written);
		} catch (err) {
			this.unregisterHostedBehavior(ctx);
			throw err;
		}
		const name = utf8Decoder.decode(swiss.subarray(0, written));
		this._publications.set(name, ctx);
		this.scheduleKick();
		return name;
	}

	/** Retain one callback entry for this Host's native lifetime. */
	registerHostedBehavior(entry: BehaviorEntry, nativeOwned = false): bigint {
		const ctx = registerBehavior(entry, nativeOwned ? this : undefined);
		this._behaviorEntries.set(ctx, entry);
		this._finalizerState.behaviorIds.add(ctx);
		return ctx;
	}

	/** Native `HostedActor.free`: forget the JS owner exactly when its actor's
	 * final alias/export/gift root is gone. */
	nativeBehaviorReleased(ctx: bigint): void {
		this._behaviorEntries.delete(ctx);
		this._finalizerState.behaviorIds.delete(ctx);
		for (const [name, held] of this._publications) {
			if (held === ctx) this._publications.delete(name);
		}
	}

	/** Undo a refused callback mint before it joins Host authority. */
	unregisterHostedBehavior(ctx: bigint): void {
		this._behaviorEntries.delete(ctx);
		this._finalizerState.behaviorIds.delete(ctx);
		unregisterBehavior(ctx);
	}

	/** Publish exact held authority. The name owns its own root until removal;
	 * after removal, the same entropy restores the name; live collisions refuse. */
	publishReference(reference: Ref, entropy?: Uint8Array): string {
		const seed = entropy ?? crypto.getRandomValues(new Uint8Array(HOST_DURABLE_ENTROPY_LEN));
		if (seed.length !== HOST_DURABLE_ENTROPY_LEN) {
			throw new GlowcapError(INVALID_ARGUMENT, "invalid durable entropy length");
		}
		const out = new Uint8Array(HOST_DURABLE_SWISS_LEN);
		const written = hostS.glowcap_host_publish_reference(
			this._raw,
			ab(refStruct(reference)),
			ab(seed),
			BigInt(seed.length),
			ab(out),
			BigInt(out.length),
		);
		if (written <= 0) checkHost(written);
		if (written !== out.length) throw new Error("publication returned an invalid name length");
		this.scheduleKick();
		return utf8Decoder.decode(out);
	}

	/** Remove a minted durable publication (ADR-0098): the old sturdyref
	 * misses from now on, while issued `Ref`s and deposited gifts keep the
	 * exact actor. Returns false when no such durable name exists. */
	unpublishDurable(swiss: string): boolean {
		const bytes = utf8Encoder.encode(swiss);
		const rc = hostS.glowcap_host_remove_durable(this._raw, ab(bytes), BigInt(bytes.length));
		if (rc === NOT_FOUND) return false;
		checkHost(rc);
		this._publications.delete(swiss);
		this.scheduleKick();
		return true;
	}

	/** Remove the Host-wide alias `name` (alias-only): a later fetch misses on
	 * every session, while issued `Ref`s and deposited gifts keep the exact
	 * actor. Its JS behavior is released with that actor's final native root.
	 * Returns false when no such alias exists. */
	unpublish(name: string): boolean {
		const bytes = utf8Encoder.encode(name);
		const rc = hostS.glowcap_host_unpublish(this._raw, ab(bytes), BigInt(bytes.length));
		if (rc === NOT_FOUND) return false;
		checkHost(rc);
		this._publications.delete(name);
		this.scheduleKick();
		return true;
	}

	/** The trampoline ctx of the Host publication published under `name`, or undefined
	 * when this host published none. Binding-internal: `Session.publishedRef`
	 * uses it to record the Host identity a session surfaced for the Host publication,
	 * so a local send to that identity composes in process. */
	publicationCtx(name: string): bigint | undefined {
		return this._publications.get(name);
	}

	/** Track a live session by its session address. Binding-internal: the
	 * `Session` constructor calls it. */
	registerSession(ptr: Ptr, session: Session): void {
		this._sessions.set(ptr, session);
	}

	/** Retain one physical channel-close barrier independently of the native
	 * Session address. Binding-internal: Session registers exactly once when it
	 * creates the close promise. */
	trackSessionRetirement(retirement: Promise<void>): void {
		// A standalone Session close has its own caller and remains authoritative.
		// Host/loop teardown starts by setting this latch; only then does the Host
		// become the surviving owner that must join an unregistered session.
		if (!this._releaseStarted) return;
		this._sessionRetirements.add(retirement);
		// The close barrier claims the result below. Mark it handled meanwhile so
		// a synchronous rejection cannot become a process-global runtime event.
		void retirement.catch(() => {});
	}

	/** Stop tracking this released wrapper. Native addresses may be recycled;
	 * stale teardown must never delete a newer Session registered at the same
	 * address. Binding-internal. */
	unregisterSession(ptr: Ptr, session: Session): void {
		if (this._sessions.get(ptr) === session) this._sessions.delete(ptr);
	}

	/** Look up a live session by its session address. Binding-internal: the
	 * action drain's FLUSH/CLOSE arms route through it. */
	getSession(ptr: Ptr): Session | undefined {
		return this._sessions.get(ptr);
	}

	/** Project the ingress session a callback turn names onto its public wrapper.
	 * A driver may have opened the session without an application-facing shell,
	 * so loop-owned sessions are adopted lazily. Binding-internal. */
	turnSession(ptr: Ptr): Session | null {
		const existing = this._sessions.get(ptr);
		if (existing !== undefined) return existing;
		return this._driverLoop?.adoptSession(ptr) ?? null;
	}

	/** Apply the ingress Session's distributed-GC opt-in before application
	 * behavior receives newly projected arguments. Binding-internal. */
	trackTurnArguments(session: object | null, args: Argument[]): void {
		if (!(session instanceof Session)) return;
		for (const value of args) session.trackGcArgument(value);
	}

	/** The live `Session` homing remote `ref`, or null for a local, stale,
	 * foreign-Host, or closed-session capability. Deterministic (ADR-0088): the reply's
	 * own token carries its route, so `Session.sendRedeeming` resolves the exact
	 * exporter session it should host its back-channel on — no capture window,
	 * no dependence on which dial completed first, and it finds an exporter that
	 * a prior redeem already dialed (a cache hit that mints no new dial at all).
	 * `Session.sendRedeeming` suppresses its own sending session and surfaces
	 * only a different exporter. Binding-internal. */
	exporterFor(ref: Ref): Session | null {
		const refBuf = refStruct(ref);
		let ptr: Ptr;
		if (this._driverLoop != null) {
			ptr = this._driverLoop.claimReferenceExporter(refBuf) ?? NULL;
		} else {
			const out = new Uint8Array(8);
			checkHost(hostS.glowcap_host_reference_exporter(this._raw, ab(refBuf), ab(out)));
			ptr = outPointer(out);
		}
		if (ptr === NULL) return null;
		const found = this._sessions.get(ptr) ?? null;
		if (found == null && this._driverLoop != null) {
			// A loop-owned Host redeems inside its own steps (ADR-0112), so the
			// exporter session it dialed exists with no wrapper yet. Wrap it
			// lazily — adoption registers it, so a repeat lookup returns this
			// same object — and the loop stays its release authority.
			return this._driverLoop.adoptSession(ptr);
		}
		return found;
	}
}

function sessionLimit(name: string, value: bigint | number | undefined, ceiling?: bigint): bigint {
	if (value === undefined) return 0n;
	if (typeof value === "number" && (!Number.isSafeInteger(value) || value < 0)) {
		throw new GlowcapError(INVALID_ARGUMENT, `${name} must be a non-negative safe integer or bigint`);
	}
	const exact = BigInt(value);
	const max = ceiling ?? (L.ptrSize === 4 ? 0xffff_ffffn : 0xffff_ffff_ffff_ffffn);
	if (exact < 0n || exact > max) {
		throw new GlowcapError(INVALID_ARGUMENT, `${name} exceeds this target's supported range`);
	}
	return exact;
}
