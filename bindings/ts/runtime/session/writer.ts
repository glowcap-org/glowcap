// A session's one writer task. FLUSH and CLOSE actions wake it, and nothing
// that reads waits on a write, so a partner slow to read cannot stop this side
// reading. Passes are counted: a caller that must know its frames left waits
// for the first pass that began after its request, which takes every frame
// the core had queued by then.

import { CLOSED } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";

/** What the writer drives on its Session. */
export interface WriterOwner {
	/** Take and write every queued frame, resolving whether any left the core.
	 * A rejection has already retained its cause and retired the session. */
	flushOutbound(): Promise<boolean>;
	closeTransport(): Promise<void>;
	/** Settle an explicit close with the CLOSE action's result. */
	finishClose(result: number): void;
	/** Resume Host work that outbound backpressure parked. */
	scheduleKick(): void;
	/** Register the running writer so Host release waits for it. */
	trackWriter(writer: Promise<void>): void;
}

type Phase = "idle" | "running" | "closing" | "exited";

export class Outbound {
	readonly #owner: WriterOwner;
	#phase: Phase = "idle";
	#wanted = false;
	#wake: (() => void) | null = null;
	#stopped = false;
	#started = 0;
	#finished = 0;
	#progress: Array<() => void> = [];
	#closeResult: number | null = null;
	#exited: Promise<void> = Promise.resolve();

	constructor(owner: WriterOwner) {
		this.#owner = owner;
	}

	/** The core already ended this session. Reading is over, and the writer
	 * closes the transport after its final drain. */
	get closeDelivered(): boolean {
		return this.#closeResult !== null;
	}

	/** Resolves once no writer runs. */
	get exited(): Promise<void> {
		return this.#exited;
	}

	/** Wake the writer to drain the core's outbound frames, starting it on
	 * first use. Returns before any byte is written, with the number of the
	 * pass that takes every frame queued so far, for `written`. */
	request(): number {
		this.#wanted = true;
		this.#signal();
		const covering = this.#started + 1;
		if (this.#phase === "idle") {
			this.#phase = "running";
			// Deferred like a spawned task, so a CLOSE marks the phase before
			// the first pass reads it.
			this.#exited = Promise.resolve().then(() => this.#run());
			this.#owner.trackWriter(this.#exited);
		}
		return covering;
	}

	/** Wait until pass `covering` has finished. A writer that exited first
	 * closed the transport, so frames it had not taken never leave. */
	async written(covering: number): Promise<void> {
		while (this.#finished < covering) {
			if (this.#phase === "exited") {
				throw new GlowcapError(CLOSED, "the connection closed before its queued frames were written");
			}
			await new Promise<void>((resolve) => this.#progress.push(resolve));
		}
	}

	/** Close the transport once the writer has drained every frame the core
	 * queued ahead of this CLOSE, so a final abort or finish still reaches the
	 * partner. */
	closeAfterFlush(result: number): void {
		this.#closeResult = result;
		this.request();
		if (this.#phase === "running") {
			this.#phase = "closing";
		} else if (this.#phase === "exited") {
			void this.#owner.closeTransport().catch(() => {});
			this.#owner.finishClose(result);
		}
	}

	/** The transport closed under the writer: exit after any pass in flight. */
	stop(): void {
		this.#stopped = true;
		this.#signal();
	}

	#signal(): void {
		const wake = this.#wake;
		this.#wake = null;
		wake?.();
	}

	#notifyProgress(): void {
		const waiters = this.#progress;
		this.#progress = [];
		for (const resolve of waiters) resolve();
	}

	/** Each wake drains everything queued, so FLUSH actions coalesce. Taken
	 * frames lower the queue the core's backpressure measures, so a pass that
	 * wrote schedules a drain for the work that pressure parked. */
	async #run(): Promise<void> {
		try {
			while (!this.#stopped) {
				if (!this.#wanted) {
					await new Promise<void>((resolve) => this.#wake = resolve);
					continue;
				}
				this.#wanted = false;
				// Read before the pass: a CLOSE that lands during it also sets
				// `wanted`, so the next pass drains its frames and then closes.
				const closing = this.#phase === "closing";
				this.#started++;
				let wrote: boolean;
				try {
					wrote = await this.#owner.flushOutbound();
				} catch {
					// flushOutbound retained the exact cause and retired the session.
					break;
				} finally {
					this.#finished = this.#started;
					this.#notifyProgress();
				}
				if (closing) {
					void this.#owner.closeTransport().catch(() => {});
					break;
				}
				if (wrote) this.#owner.scheduleKick();
			}
		} finally {
			this.#phase = "exited";
			if (this.#closeResult !== null) this.#owner.finishClose(this.#closeResult);
			this.#notifyProgress();
		}
	}
}
