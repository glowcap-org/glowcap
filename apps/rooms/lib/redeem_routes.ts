import { claimWithin, Unanswered } from "./deadline.ts";

type Waiter<Route extends object> = {
	route: Route;
	resolve: () => void;
	reject: (reason: unknown) => void;
	timer: ReturnType<typeof setTimeout>;
	signal: AbortSignal;
	abort: () => void;
};

function abortReason(signal: AbortSignal): unknown {
	return signal.reason ?? new Error("the directory connection ended");
}

/** Bound the caller's wait for a CapTP redeem. CapTP cannot cancel an accepted
 * send, so an answer that arrives after the deadline is transferred to
 * `abandon` instead of becoming an unclaimed capability. */
export async function claimRedeemWithin<T>(
	redemption: Promise<T>,
	what: string,
	waitMs: number,
	abandon: (late: T) => void,
): Promise<T> {
	return await claimWithin(redemption, what, waitMs, abandon);
}

/** Serialize route-sensitive handoff redemption without turning one stalled
 * directory into unbounded retained work. Redeems through one route may run
 * together. A different route waits FIFO until the active batch ends, because
 * the browser signaling authority can name exactly one directory at a time. */
export class RedeemRouteCoordinator<Route extends object> {
	readonly #active = new Map<Route, number>();
	readonly #waiting: Waiter<Route>[] = [];

	constructor(
		readonly maxOutstanding: number,
		readonly waitMs: number,
	) {
		if (!Number.isSafeInteger(maxOutstanding) || maxOutstanding < 1) {
			throw new Error("a redeem coordinator needs a positive outstanding-work bound");
		}
		if (!Number.isSafeInteger(waitMs) || waitMs < 1) {
			throw new Error("a redeem coordinator needs a positive wait deadline");
		}
	}

	/** The sole directory whose redeems are active, or null when none are. */
	current(): Route | null {
		for (const route of this.#active.keys()) return route;
		return null;
	}

	async run<T>(route: Route, signal: AbortSignal, operation: () => Promise<T>): Promise<T> {
		await this.#enter(route, signal);
		try {
			return await operation();
		} finally {
			this.#leave(route);
		}
	}

	#outstanding(): number {
		let count = this.#waiting.length;
		for (const active of this.#active.values()) count += active;
		return count;
	}

	#canEnter(route: Route): boolean {
		return this.#active.size === 0 || this.#active.has(route);
	}

	#activate(route: Route): void {
		this.#active.set(route, (this.#active.get(route) ?? 0) + 1);
	}

	#enter(route: Route, signal: AbortSignal): Promise<void> {
		if (signal.aborted) return Promise.reject(abortReason(signal));
		// Once somebody is queued, new work waits behind them even when it shares
		// the active route. Otherwise a busy directory could starve every other one.
		if (this.#waiting.length === 0 && this.#canEnter(route)) {
			if (this.#outstanding() >= this.maxOutstanding) return this.#full();
			this.#activate(route);
			return Promise.resolve();
		}
		if (this.#outstanding() >= this.maxOutstanding) return this.#full();
		return new Promise((resolve, reject) => {
			const waiter = {} as Waiter<Route>;
			waiter.route = route;
			waiter.resolve = resolve;
			waiter.reject = reject;
			waiter.signal = signal;
			waiter.abort = () => this.#refuse(waiter, abortReason(signal));
			waiter.timer = setTimeout(
				() =>
					this.#refuse(waiter, new Unanswered("a direct introduction waited too long for its redeem route")),
				this.waitMs,
			);
			this.#waiting.push(waiter);
			signal.addEventListener("abort", waiter.abort, { once: true });
		});
	}

	#full(): Promise<never> {
		return Promise.reject(
			new Error(`the browser may hold at most ${this.maxOutstanding} direct handoff redeems at once`),
		);
	}

	#refuse(waiter: Waiter<Route>, reason: unknown): void {
		const at = this.#waiting.indexOf(waiter);
		if (at < 0) return;
		this.#waiting.splice(at, 1);
		this.#retire(waiter);
		waiter.reject(reason);
		this.#drain();
	}

	#retire(waiter: Waiter<Route>): void {
		clearTimeout(waiter.timer);
		waiter.signal.removeEventListener("abort", waiter.abort);
	}

	#leave(route: Route): void {
		const remaining = (this.#active.get(route) ?? 1) - 1;
		if (remaining > 0) this.#active.set(route, remaining);
		else this.#active.delete(route);
		this.#drain();
	}

	#drain(): void {
		while (this.#waiting.length > 0) {
			const waiter = this.#waiting[0];
			if (!this.#canEnter(waiter.route)) return;
			this.#waiting.shift();
			this.#retire(waiter);
			if (waiter.signal.aborted) {
				waiter.reject(abortReason(waiter.signal));
				continue;
			}
			this.#activate(waiter.route);
			waiter.resolve();
		}
	}
}
