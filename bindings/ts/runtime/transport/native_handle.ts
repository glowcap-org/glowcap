import { ffi, NULL, type Ptr } from "../internal/ffi/runtime.ts";

/** Reject a blocking transport call when the active FFI runs on the JavaScript
 * event-loop thread. */
export function requireOffThreadFfi(transport: string, operation: string): void {
	if (ffi.offloadsBlockingCalls()) return;
	throw new Error(
		`glowcap ${transport} ${operation} requires native calls to run off the JavaScript event loop; ` +
			"this runtime's FFI executes synchronously",
	);
}

/** Admit one operation over a stateful native reader, writer, or listener.
 * Concurrent use has no useful ordering contract and is refused instead of
 * retaining an unbounded queue behind a potentially blocking FFI call. */
export class SingleFlight {
	#active = false;

	constructor(readonly label: string) {}

	run<T>(body: () => Promise<T>): Promise<T> {
		if (this.#active) {
			return Promise.reject(new Error(`${this.label} already has an operation in flight`));
		}
		this.#active = true;
		let result: Promise<T>;
		try {
			result = body();
		} catch (error) {
			this.#active = false;
			return Promise.reject(error);
		}
		return result.finally(() => {
			this.#active = false;
		});
	}
}

type CloseOutcome = { ok: true } | { ok: false; error: unknown };

/** Whether native release completed, plus the first shutdown/release failure.
 * A failed release means a borrowing parent must remain pinned. */
export type NativeRetirement = {
	released: boolean;
	outcome: CloseOutcome;
};

const noFailure = Symbol("noFailure");
type Failure = typeof noFailure | unknown;

class ConsumedReleaseFailure {
	constructor(readonly cause: unknown) {}
}

/** Mark a release failure whose native function nevertheless consumed the
 * handle. The close barrier still rejects with `error`, while borrowing
 * parents may retire their lease instead of pinning already-freed storage. */
export function consumedReleaseFailure(error: unknown): never {
	throw new ConsumedReleaseFailure(error);
}

/** Keep an opaque native handle alive across off-thread FFI calls. Closing
 * interrupts blocking work first and releases only after every lease returns. */
export class NativeHandle {
	#raw: Ptr;
	#leases = 0;
	#closing = false;
	#releaseStarted = false;
	#failure: Failure = noFailure;
	readonly #label: string;
	readonly #shutdown: ((raw: Ptr) => void) | undefined;
	readonly #release: (raw: Ptr) => void | Promise<void>;
	readonly #retired: (retirement: NativeRetirement) => void;
	readonly #closed: Promise<void>;
	readonly #resolveClosed: () => void;
	readonly #rejectClosed: (reason: unknown) => void;

	constructor(
		label: string,
		raw: Ptr,
		shutdown: ((raw: Ptr) => void) | undefined,
		release: (raw: Ptr) => void | Promise<void>,
		retired: (retirement: NativeRetirement) => void = () => {},
	) {
		requireOffThreadFfi(label, "native handle lifecycle");
		this.#label = label;
		this.#raw = raw;
		this.#shutdown = shutdown;
		this.#release = release;
		this.#retired = retired;
		let resolveClosed!: () => void;
		let rejectClosed!: (reason: unknown) => void;
		this.#closed = new Promise<void>((resolve, reject) => {
			resolveClosed = resolve;
			rejectClosed = reject;
		});
		// `close` is intentionally usable from synchronous disposal. The release
		// still starts, and an explicit `waitClosed` observes any failure without an
		// unhandled-rejection report when the caller only requests cancellation.
		void this.#closed.catch(() => {});
		this.#resolveClosed = resolveClosed;
		this.#rejectClosed = rejectClosed;
	}

	borrow(): Ptr {
		if (this.#closing || this.#raw === NULL) throw new Error(`${this.#label} handle is closed`);
		return this.#raw;
	}

	/** Retain this handle for a dependent native resource. Unlike `borrow`, this
	 * may transfer an already-running operation into a dependent after close was
	 * requested, but never after native release has started. */
	retain(): (() => void) | null {
		if (this.#releaseStarted || this.#raw === NULL) return null;
		this.#leases++;
		let retained = true;
		return () => {
			if (!retained) return;
			retained = false;
			this.#leases--;
			this.#finishClose();
		};
	}

	async use<T>(body: (raw: Ptr) => Promise<T>): Promise<T> {
		const raw = this.borrow();
		const releaseLease = this.retain();
		if (releaseLease == null) throw new Error(`${this.#label} handle is closed`);
		try {
			return await body(raw);
		} finally {
			releaseLease();
		}
	}

	close(): void {
		if (this.#closing) return;
		this.#closing = true;
		if (this.#raw !== NULL) {
			try {
				this.#shutdown?.(this.#raw);
			} catch (error) {
				this.#rememberFailure(error);
			}
		}
		this.#finishClose();
	}

	/** Request closure and wait until native release and its owner callback have
	 * both completed. Required when the release itself is dispatched off-thread. */
	waitClosed(): Promise<void> {
		this.close();
		return this.#closed;
	}

	#rememberFailure(error: unknown): void {
		if (this.#failure === noFailure) this.#failure = error;
	}

	#finishClose(): void {
		if (!this.#closing || this.#leases !== 0 || this.#releaseStarted) return;
		this.#releaseStarted = true;
		const raw = this.#raw;
		this.#raw = NULL;
		if (raw === NULL) {
			this.#finishRetirement(true);
			return;
		}
		try {
			const pending = this.#release(raw);
			if (pending == null) {
				this.#finishRetirement(true);
			} else {
				void pending.then(
					() => this.#finishRetirement(true),
					(error) => {
						const consumed = error instanceof ConsumedReleaseFailure;
						this.#rememberFailure(consumed ? error.cause : error);
						this.#finishRetirement(consumed);
					},
				);
			}
		} catch (error) {
			const consumed = error instanceof ConsumedReleaseFailure;
			this.#rememberFailure(consumed ? error.cause : error);
			this.#finishRetirement(consumed);
		}
	}

	#finishRetirement(released: boolean): void {
		const outcome: CloseOutcome = this.#failure === noFailure ? { ok: true } : { ok: false, error: this.#failure };
		try {
			this.#retired({ released, outcome });
		} catch (error) {
			this.#rememberFailure(error);
		}
		if (this.#failure === noFailure) {
			this.#resolveClosed();
		} else {
			this.#rejectClosed(this.#failure);
		}
	}
}

interface NativeDependent {
	close(): void;
}

/** Own a native backend and every child that borrows it. Each adopted child
 * contributes a retention lease, including a child produced by an operation
 * after parent close began. The backend is released only after successful
 * child retirement; a failed child release pins it and reports the failure. */
export class NativeParent<C extends NativeDependent> {
	readonly #native: NativeHandle;
	readonly #children = new Map<C, () => void>();
	#closing = false;
	#nativeSettled = false;
	#unsafeToRelease = false;
	#settled = false;
	#failure: Failure = noFailure;
	readonly #closed: Promise<void>;
	readonly #resolveClosed: () => void;
	readonly #rejectClosed: (reason: unknown) => void;

	constructor(
		label: string,
		raw: Ptr,
		shutdown: ((raw: Ptr) => void) | undefined,
		release: (raw: Ptr) => void | Promise<void>,
	) {
		this.#native = new NativeHandle(label, raw, shutdown, release);
		let resolveClosed!: () => void;
		let rejectClosed!: (reason: unknown) => void;
		this.#closed = new Promise<void>((resolve, reject) => {
			resolveClosed = resolve;
			rejectClosed = reject;
		});
		void this.#closed.catch(() => {});
		this.#resolveClosed = resolveClosed;
		this.#rejectClosed = rejectClosed;
	}

	borrow(): Ptr {
		return this.#native.borrow();
	}

	use<T>(body: (raw: Ptr) => Promise<T>): Promise<T> {
		return this.#native.use(body);
	}

	/** Adopt `child` even when close raced its construction. A rejected late
	 * child is closed here but remains retained until its native release settles. */
	adopt(child: C): boolean {
		const releaseLease = this.#native.retain();
		if (releaseLease == null) {
			child.close();
			return false;
		}
		this.#children.set(child, releaseLease);
		if (!this.#closing) return true;
		child.close();
		return false;
	}

	retire(child: C, retirement: NativeRetirement): void {
		const releaseLease = this.#children.get(child);
		if (releaseLease == null) return;
		if (!retirement.outcome.ok) this.#rememberFailure(retirement.outcome.error);
		if (retirement.released) {
			this.#children.delete(child);
			releaseLease();
		} else {
			// The child may still borrow the backend. Keep its lease forever rather
			// than turning a release failure into a parent use-after-free.
			this.#unsafeToRelease = true;
		}
		this.#finishClose();
	}

	close(): void {
		if (this.#closing) return;
		this.#closing = true;
		for (const child of [...this.#children.keys()]) child.close();
		this.#native.close();
		void this.#native.waitClosed().then(
			() => {
				this.#nativeSettled = true;
				this.#finishClose();
			},
			(error) => {
				this.#rememberFailure(error);
				this.#nativeSettled = true;
				this.#finishClose();
			},
		);
		this.#finishClose();
	}

	waitClosed(): Promise<void> {
		this.close();
		return this.#closed;
	}

	#rememberFailure(error: unknown): void {
		if (this.#failure === noFailure) this.#failure = error;
	}

	#finishClose(): void {
		if (this.#settled || !this.#closing) return;
		if (this.#unsafeToRelease) {
			this.#settled = true;
			this.#rejectClosed(
				this.#failure === noFailure ? new Error("native child release failed") : this.#failure,
			);
			return;
		}
		if (!this.#nativeSettled || this.#children.size !== 0) return;
		this.#settled = true;
		if (this.#failure === noFailure) {
			this.#resolveClosed();
		} else {
			this.#rejectClosed(this.#failure);
		}
	}
}
