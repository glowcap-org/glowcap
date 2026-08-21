// The CapTP host — multi-session CapTP product over the byte-fed host archive
// (libpancake_host, ADR-0072). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns — never
// a single-type equation. The `PancakeHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and explicitly installed byte-channel connectors. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { HOST_DURABLE_ENTROPY_LEN, HOST_DURABLE_SWISS_LEN, INVALID_ARGUMENT, NOT_FOUND } from "@pancake/abi";
import { refStruct } from "../abi_value.ts";
import { checkHost, PancakeError } from "../errors.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab, outPointer } from "../internal/seam.ts";
import { type Locator, withOwnedLocator } from "../locator.ts";
import { asLiveRef } from "../promise.ts";
import { Session } from "../session.ts";
import { type BehaviorEntry, registerBehavior, trampolinePointer, unregisterBehavior } from "../trampoline.ts";
import type { Connector } from "../transport.ts";
import { type Argument, type Behavior, Ref } from "../value.ts";
import { HostLifecycle } from "./lifecycle.ts";

// One encoder/decoder pair for the whole module: both are stateless here.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

export abstract class HostApplication extends HostLifecycle {
	installConnectors(connectors: readonly Connector[]): void {
		const pending = new Map<string, Connector>();
		for (const connector of connectors) {
			for (const transport of connector.transports) {
				if (transport.length === 0) {
					throw new PancakeError(
						INVALID_ARGUMENT,
						"connector transport symbols must not be empty",
					);
				}
				const installed = pending.get(transport) ?? this._connectors.get(transport);
				if (installed != null && installed !== connector) {
					throw new PancakeError(
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

	/** Enliven a complete sturdyref without naming a session (ADR-0098): the
	 * host enlivens it over a live session it already dialed to that peer, or
	 * dials one itself through this host's own DIAL action and finishes when
	 * the dial reports. The session-scoped `Session.enliven` is the narrower
	 * verb — it never dials, and refuses a sturdyref for another peer. */
	async enliven(sturdyref: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(sturdyref);
		const out = new Uint8Array(8);
		checkHost(hostS.pancake_host_enliven(
			this._raw,
			ab(swiss),
			BigInt(swiss.length),
			ab(out),
		));
		const vow = new DataView(out.buffer).getBigUint64(0, true);
		this.vowMinted(vow);
		await this.kickActions();
		const result = await this.awaitVow(vow);
		return asLiveRef(result, sturdyref);
	}

	/** Retain and select this Host's complete acceptable location. Later
	 * sessions advertise it regardless of their transport; existing sessions
	 * retain the locator their hello signed. */
	setAdvertisedLocator(locator: Locator): void {
		withOwnedLocator(
			locator,
			(owned) => checkHost(hostS.pancake_host_set_advertised_locator(this._raw, owned.borrowView())),
		);
	}

	/** Remove this Host's retained locator for `transport`. */
	removeAdvertisedLocator(transport: string): void {
		const bytes = utf8Encoder.encode(transport);
		checkHost(hostS.pancake_host_remove_advertised_locator(
			this._raw,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	/** Selective session-limit knobs (ADR-0082). Pass `0n` / `0` to leave a
	 * field unchanged. Affects peers minted after this call. */
	setSessionLimits(
		maxFrameBytes: bigint | number = 0,
		queueCap: bigint | number = 0,
		outboundHighWaterBytes: bigint | number = 0,
	): void {
		checkHost(hostS.pancake_host_set_session_limits(
			this._raw,
			BigInt(maxFrameBytes),
			BigInt(queueCap),
			BigInt(outboundHighWaterBytes),
		));
	}

	/** The canonical key designator (64 lowercase hex digits) for this host's
	 * identity seed — what a keyed-tcp locator names as its designator
	 * (ADR-0075). */
	designator(): string {
		const out = new Uint8Array(64);
		checkHost(hostS.pancake_host_designator_from_seed(
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
	publishGiftable(name: string, behavior: Behavior): void {
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null });
		const bytes = utf8Encoder.encode(name);
		try {
			checkHost(hostS.pancake_host_publish(
				this._raw,
				ab(bytes),
				BigInt(bytes.length),
				trampolinePointer(),
				ctx,
				NULL,
			));
		} catch (err) {
			// Nothing else drops a trampoline row, so a refused publish has to
			// take its own back or it pins the behavior for the process's life.
			this.unregisterHostedBehavior(ctx);
			throw err;
		}
		// Replacement moves discovery only. Existing capabilities and deposited
		// gifts can still call the old actor.
		const prior = this._giftables.get(name);
		if (prior !== undefined) this._displacedGiftables.push(prior);
		this._giftables.set(name, ctx);
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
			throw new PancakeError(
				INVALID_ARGUMENT,
				`durable entropy must be exactly ${HOST_DURABLE_ENTROPY_LEN} bytes`,
			);
		}
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null });
		const swiss = new Uint8Array(HOST_DURABLE_SWISS_LEN);
		let written: number;
		try {
			written = hostS.pancake_host_publish_durable(
				this._raw,
				ab(entropyBytes),
				BigInt(entropyBytes.length),
				trampolinePointer(),
				ctx,
				NULL,
				ab(swiss),
				BigInt(swiss.length),
			);
			if (written <= 0) checkHost(written);
		} catch (err) {
			this.unregisterHostedBehavior(ctx);
			throw err;
		}
		const name = utf8Decoder.decode(swiss.subarray(0, written));
		this._giftables.set(name, ctx);
		this.scheduleKick();
		return name;
	}

	/** Retain one callback entry for this Host's native lifetime. */
	registerHostedBehavior(entry: BehaviorEntry): bigint {
		const ctx = registerBehavior(entry);
		this._behaviorEntries.set(ctx, entry);
		this._finalizerState.behaviorIds.add(ctx);
		return ctx;
	}

	/** Undo a refused callback mint before it joins Host authority. */
	unregisterHostedBehavior(ctx: bigint): void {
		this._behaviorEntries.delete(ctx);
		this._finalizerState.behaviorIds.delete(ctx);
		unregisterBehavior(ctx);
	}

	/** Remove a minted durable publication (ADR-0098): the old sturdyref
	 * misses from now on, while issued `Ref`s and deposited gifts keep the
	 * exact actor. Returns false when no such durable name exists. */
	unpublishDurable(swiss: string): boolean {
		const bytes = utf8Encoder.encode(swiss);
		const rc = hostS.pancake_host_remove_durable(this._raw, ab(bytes), BigInt(bytes.length));
		if (rc === NOT_FOUND) return false;
		checkHost(rc);
		const prior = this._giftables.get(swiss);
		if (prior !== undefined) {
			this._displacedGiftables.push(prior);
			this._giftables.delete(swiss);
		}
		this.scheduleKick();
		return true;
	}

	/** Remove the Host-wide alias `name` (alias-only): a later fetch misses on
	 * every session, while issued `Ref`s and deposited gifts keep the exact
	 * actor, whose behavior stays hosted for the Host's life. Returns false
	 * when no such alias exists. */
	unpublishGiftable(name: string): boolean {
		const bytes = utf8Encoder.encode(name);
		const rc = hostS.pancake_host_unpublish(this._raw, ab(bytes), BigInt(bytes.length));
		if (rc === NOT_FOUND) return false;
		checkHost(rc);
		// The alias is gone but the actor is not: its trampoline row moves to
		// the displaced list, exactly as a replacement displaces one.
		const prior = this._giftables.get(name);
		if (prior !== undefined) {
			this._displacedGiftables.push(prior);
			this._giftables.delete(name);
		}
		this.scheduleKick();
		return true;
	}

	/** The trampoline ctx of the giftable published under `name`, or undefined
	 * when this host published none. Binding-internal: `Session.publishedRef`
	 * uses it to record the Host identity a session surfaced for the giftable,
	 * so a local send to that identity composes in process. */
	giftableCtx(name: string): bigint | undefined {
		return this._giftables.get(name);
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
			checkHost(hostS.pancake_host_reference_exporter(this._raw, ab(refBuf), ab(out)));
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
