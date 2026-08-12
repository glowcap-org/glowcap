// Distributed GC (ADR-0063), opt-in and off by default. Owns the Host-wide
// `HostGc` state, fetch `trackImport` / verb-head `drainGc` choreography, and
// `pancake_host_ref_release`. Session keeps `withGc` as a thin opt-in; Host
// owns the finalizer state. Binding spine Pass 3b.

import { hostS } from "./internal/ffi/host.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
import { checkHost } from "./errors.ts";
import { refStruct } from "./codec.ts";
import { ab } from "./internal/seam.ts";
import { Ref, refFromId } from "./value.ts";

/** Host callbacks HostGc needs without importing Host. */
export interface GcHandle {
	readonly released: boolean;
	readonly hostRaw: Ptr;
	kick(): void;
	/** Park a drain on the event loop (finalizer path must not call host FFI). */
	scheduleDrain(run: () => void): void;
}

/** Host-wide GC state. A fetched Ref may be homed on a sibling session, and it
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

	/** Register a fetched capability selected by a GC-enabled session. The id
	 * is an opaque Host-scoped identity (ADR-0096) — the fetch seam is what
	 * scopes tracking, not any id-range branch here — and the host resolves it
	 * to its home connection and real wire import when the release fires. The
	 * finalizer captures only the bare id bigint, never the `Ref`, so it
	 * cannot resurrect the handle whose death it waits on. */
	trackImport(ref: Ref): Ref {
		const h = this.#h;
		if (h === null) return ref;
		if (this.#registry === null) {
			this.#registry = new FinalizationRegistry<bigint>((token) => {
				// Park only: ref_release never runs from the finalizer callback.
				// The release rides out on the connection's next verb, or on the
				// scheduled drain below (its own event-loop task).
				this.pending.push(token);
				h.scheduleDrain(() => this.drainGc());
			});
		}
		this.#registry.unregister(ref);
		this.#registry.register(ref, ref.id, ref);
		return ref;
	}

	/** Disarm a tracked ref after deterministic release committed. */
	disarm(ref: Ref): void {
		this.#registry?.unregister(ref);
	}

	/** Drain parked GC releases: one release delta per reclaimed token, then
	 * a kick so the op:gc-exports flushes. Best-effort — a refused release
	 * strands a partner export reclaimed at teardown, never a fault. */
	drainGc(): void {
		const h = this.#h;
		if (h === null || this.pending.length === 0 || h.released) return;
		for (const token of this.pending.splice(0)) {
			try {
				checkHost(
					hostS.pancake_host_ref_release(
						h.hostRaw,
						ab(refStruct(refFromId(token))),
						1n,
					),
				);
			} catch {
				// best-effort: a refused release strands a partner export only.
			}
		}
		h.kick();
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
