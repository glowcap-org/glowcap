import { INVALID_ARGUMENT } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import type { LoopChannel } from "../session.ts";
import type { DriverLoop } from "../driver_loop.ts";

/** The loop-backed `Channel` a loop-minted `Session` rides: no byte verbs (the
 * native loop owns the wire), one closed event the serve promise and teardown
 * share, and the `driverLoop` back-reference `Session`'s loop arms dispatch
 * on. */
export class LoopTransport implements LoopChannel {
	readonly driverLoop: DriverLoop;
	readonly #closed: Promise<void>;
	#markClosed!: () => void;
	#markFailed!: (error: GlowcapError) => void;
	#settled = false;

	constructor(driverLoop: DriverLoop) {
		this.driverLoop = driverLoop;
		this.#closed = new Promise<void>((resolve, reject) => {
			this.#markClosed = resolve;
			this.#markFailed = reject;
		});
		// A session may close after its event is committed but before the
		// application adopts and serves it. Keep the rejection observable later
		// without making that ownership window an unhandled rejection.
		void this.#closed.catch(() => {});
	}

	/** Never read by the loop arms; resolves the clean EOF at close so a
	 * stray pump read cannot park forever. */
	read(): Promise<Uint8Array | null> {
		return this.#closed.then(() => null);
	}

	write(_data: Uint8Array): Promise<void> {
		return Promise.reject(
			new GlowcapError(INVALID_ARGUMENT, "the native loop owns this session's wire"),
		);
	}

	close(): void {
		this.finishClosed(null);
	}

	finishClosed(error: GlowcapError | null): void {
		if (this.#settled) return;
		this.#settled = true;
		if (error == null) this.#markClosed();
		else this.#markFailed(error);
	}

	waitClosed(): Promise<void> {
		return this.#closed;
	}
}
