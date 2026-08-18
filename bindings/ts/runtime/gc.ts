// Distributed GC (ADR-0063), opt-in and off by default. Owns the Host-wide
// `HostGc` state, recursive application-value tracking / verb-head `drainGc`, and
// `pancake_host_ref_release`. Session keeps `withGc` as a thin opt-in; Host
// owns the finalizer state.

import { hostS } from "./internal/ffi/host.ts";
import type { Ptr } from "./internal/ffi/runtime.ts";
import { checkHost } from "./errors.ts";
import { refStruct } from "./abi_value.ts";
import { ab } from "./internal/seam.ts";
import { type Argument, isReference, PSet, PStruct, Ref, refFromId, Tagged } from "./value.ts";

/** Host callbacks HostGc needs without importing Host. */
export interface GcHandle {
	readonly released: boolean;
	readonly hostRaw: Ptr;
	kick(): void;
	recordFailure(failure: unknown): void;
	/** Park a drain on the event loop (finalizer path must not call host FFI). */
	scheduleDrain(run: () => void): void;
}

/** Host-wide GC state. A projected Ref may be homed on a sibling session, and it
 * may outlive the session through which it arrived, so neither the finalizer
 * registry nor its release queue may belong to a Session. */
export class HostGc {
	#registry: FinalizationRegistry<bigint> | null = null;
	readonly pending: bigint[] = [];
	#h: GcHandle | null = null;

	/** Bind the live Host once so track/drain can schedule progress. */
	bind(h: GcHandle): void {
		this.#h = h;
	}

	/** Register one projected capability occurrence selected by a GC-enabled
	 * session. The id is an opaque Host-scoped identity (ADR-0096) — the
	 * application projection seam scopes tracking, never an id-range branch —
	 * and the host resolves it
	 * to its home connection and real wire import when the release fires. The
	 * finalizer captures only the bare id bigint, never the `Ref`, so it
	 * cannot resurrect the handle whose death it waits on. */
	trackRef(ref: Ref): Ref {
		const h = this.#h;
		if (h === null) return ref;
		if (this.#registry === null) {
			this.#registry = new FinalizationRegistry<bigint>((token) => {
				// Park only: ref_release never runs from the finalizer callback.
				// The release rides out on the connection's next verb, or on the
				// scheduled drain below (its own event-loop task).
				this.pending.push(token);
				h.scheduleDrain(() => this.#drainScheduled());
			});
		}
		this.#registry.unregister(ref);
		this.#registry.register(ref, ref.id, ref);
		return ref;
	}

	/** Attach one finalizer unit to every capability occurrence in a value the
	 * native Host has just projected. Containers stay intact; equal ids in two
	 * leaves remain two guards because native projection minted two retains. */
	trackArgument(value: Argument): Argument {
		if (isReference(value)) return this.trackRef(value);
		if (Array.isArray(value)) {
			for (const item of value) this.trackArgument(item);
		} else if (value instanceof PSet) {
			for (const item of value.items) this.trackArgument(item);
		} else if (value instanceof Tagged) {
			for (const item of value.value) this.trackArgument(item);
		} else if (value instanceof PStruct) {
			for (const [, item] of value.entries) this.trackArgument(item);
		}
		return value;
	}

	trackArguments(values: Argument[]): Argument[] {
		for (const value of values) this.trackArgument(value);
		return values;
	}

	/** Disarm a tracked ref after deterministic release committed. */
	disarm(ref: Ref): void {
		this.#registry?.unregister(ref);
	}

	/** Drain parked GC releases: one release delta per reclaimed token, then
	 * a kick so the op:gc-exports flushes. A token leaves the queue only after
	 * its native release commits. A scheduled drain has no immediate caller,
	 * so its exact failure is retained and raised by the next observable drain. */
	drainGc(): void {
		const h = this.#h;
		if (h === null || this.pending.length === 0 || h.released) return;
		let committed = 0;
		try {
			for (const token of this.pending) {
				checkHost(
					hostS.pancake_host_ref_release(
						h.hostRaw,
						ab(refStruct(refFromId(token))),
						1n,
					),
				);
				committed += 1;
			}
		} finally {
			this.pending.splice(0, committed);
		}
		h.kick();
	}

	#drainScheduled(): void {
		try {
			this.drainGc();
		} catch (failure) {
			this.#h?.recordFailure(failure);
		}
	}
}

/** Release one import deterministically, because the application says it is
 * done with the capability rather than because a collector reclaimed it.
 *
 * Lives here beside the finalizer path because both release the same opaque
 * Host identity; the Host resolves whether any wire GC is required. */
export function releaseRef(hostRaw: Ptr, ref: Ref): void {
	checkHost(hostS.pancake_host_ref_release(hostRaw, ab(refStruct(ref)), 1n));
}
