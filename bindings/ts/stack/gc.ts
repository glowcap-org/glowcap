// Distributed GC (ADR-0063), opt-in and off by default. Owns the per-connection
// `ConnGc` state, fetch `trackImport` / verb-head `drainGc` choreography, and
// `pancake_host_gc_release`. Session keeps `withGc` as a thin CapTP verb and
// calls `trackImport` / `drainGc` through a bound handle. Binding spine Pass 3b.

import { driverS } from "./internal/ffi/driver.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
import { checkHost } from "./errors.ts";
import { REDEEMED_TOKEN_BASE } from "./internal/abi.ts";
import type { Ref } from "./value.ts";

/** Session callbacks ConnGc needs without importing Session. */
export interface GcHandle {
	readonly released: boolean;
	readonly hostRaw: Ptr;
	kick(): void;
	/** Park a drain on the event loop (finalizer path must not call host FFI). */
	scheduleDrain(run: () => void): void;
}

/** Per-connection GC state. */
export class ConnGc {
	enabled = false;
	#registry: FinalizationRegistry<bigint> | null = null;
	readonly pending: bigint[] = [];
	#h: GcHandle | null = null;

	/** Bind the live Session once so track/drain can kick without Session
	 * wrappers. */
	bind(h: GcHandle): void {
		this.#h = h;
	}

	/** Opt in. Session's `withGc` returns `this` for chaining. */
	enable(): void {
		this.enabled = true;
	}

	/** Register a fetched capability for GC when enabled. The `Ref` holds a
	 * node-unique token (ADR-0069) — only ids in the token range are tracked —
	 * and the host resolves the token to its home connection and real wire
	 * import when the release fires. The finalizer captures only the bare token
	 * bigint, never the `Ref`, so it cannot resurrect the handle whose death it
	 * waits on. */
	trackImport(ref: Ref): Ref {
		const h = this.#h;
		if (h === null) return ref;
		const wire = ref.reference;
		if (this.enabled && wire.kind === "far" && wire.id >= REDEEMED_TOKEN_BASE) {
			if (this.#registry === null) {
				this.#registry = new FinalizationRegistry<bigint>((token) => {
					// Park only: gc_release never runs from the finalizer callback.
					// The release rides out on the connection's next verb, or on the
					// scheduled drain below (its own event-loop task).
					this.pending.push(token);
					h.scheduleDrain(() => this.drainGc());
				});
			}
			this.#registry.register(ref, wire.id);
		}
		return ref;
	}

	/** Drain parked GC releases: one release delta per reclaimed token, then
	 * a kick so the op:gc-exports flushes. Best-effort — a refused release
	 * strands a partner export reclaimed at teardown, never a fault. */
	drainGc(): void {
		const h = this.#h;
		if (h === null || this.pending.length === 0 || h.released) return;
		for (const token of this.pending.splice(0)) {
			try {
				checkHost(driverS.pancake_host_gc_release(h.hostRaw, token, 1n));
			} catch {
				// best-effort: a refused release strands a partner export only.
			}
		}
		h.kick();
	}
}
