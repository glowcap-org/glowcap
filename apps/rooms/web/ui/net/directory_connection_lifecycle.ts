// Admission, invalidation, and retry timing for browser directory connections.

import type { DirId } from "../types.ts";
import type { RoomPolicy } from "../../../lib/room/policy.ts";

export interface DirectoryConnectionAttempt {
	/** The reader canceled this attempt, or gave the directory back after the
	 * request began. Checked after every asynchronous boundary that can produce
	 * a live transport or mutate presentation state. */
	stale(): boolean;
	/** The directory was given back after this request began. Unlike an AbortSignal,
	 * this invalidates every request that began in the older holding epoch. */
	left(): boolean;
}

type AttemptWork = (attempt: DirectoryConnectionAttempt) => Promise<string>;

function completionOf(work: Promise<unknown>): Promise<void> {
	// The original caller owns the result. Serialization needs only the fact
	// that the earlier attempt reached a terminal state.
	return work.then(() => {}, () => {});
}

/** One lifecycle per browser tab. A directory has at most one current opening,
 * one retry timer, and one holding epoch. Explicit opens wait for an earlier
 * attempt but never join it; Leave invalidates both the attempt in front and
 * every request already waiting behind it. One staged first join waits here
 * until a directory is up to enter it on. */
export class DirectoryConnectionLifecycle {
	readonly #limit: number;
	readonly #opening = new Map<DirId, Promise<string>>();
	readonly #left = new Set<DirId>();
	readonly #epochs = new Map<DirId, symbol>();
	readonly #reconnects = new Map<DirId, ReturnType<typeof setTimeout>>();
	#staged: { room: string; nick: string; policy: RoomPolicy } | null = null;
	#stagedSettle: ((message: string) => void) | null = null;

	constructor(limit: number) {
		if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("directory connection limit must be positive");
		this.#limit = limit;
	}

	open(
		id: DirId,
		heldCount: number,
		signal: AbortSignal | undefined,
		held: () => boolean,
		work: AttemptWork,
	): Promise<string> {
		const epoch = this.#epoch(id);
		const prior = this.#opening.get(id);
		if (prior == null && heldCount + this.#opening.size >= this.#limit) {
			this.#epochs.delete(id);
			return Promise.resolve(`This browser can hold or open at most ${this.#limit} directories.`);
		}
		this.#left.delete(id);
		this.#cancelReconnect(id);
		const attempt = this.#attempt(id, epoch, signal);
		const run = (async () => {
			if (prior != null) await completionOf(prior);
			if (attempt.stale() || held()) return "";
			return await work(attempt);
		})();
		return this.#track(id, run);
	}

	reopen(id: DirId, held: () => boolean, work: AttemptWork): Promise<string> {
		if (this.#left.has(id)) return Promise.resolve("");
		const epoch = this.#epoch(id);
		const prior = this.#opening.get(id);
		const attempt = this.#attempt(id, epoch);
		const run = (async () => {
			if (prior != null) await completionOf(prior);
			if (attempt.stale() || held()) return "";
			return await work(attempt);
		})();
		return this.#track(id, run);
	}

	leave(id: DirId): void {
		this.#invalidate(id);
	}

	forget(id: DirId): void {
		this.#invalidate(id);
	}

	/** Stop every opening and reconnect without forgetting saved holdings.
	 * DurableRoomsRuntime then reconnects as the same Host identity. */
	drainAll(): void {
		const ids = new Set<DirId>([
			...this.#opening.keys(),
			...this.#epochs.keys(),
			...this.#reconnects.keys(),
		]);
		for (const id of ids) this.leave(id);
	}

	schedule(id: DirId, delay: number, reopen: () => void): void {
		if (this.#left.has(id)) return;
		this.#cancelReconnect(id);
		const epoch = this.#epoch(id);
		this.#reconnects.set(
			id,
			setTimeout(() => {
				this.#reconnects.delete(id);
				if (this.#left.has(id) || this.#epochs.get(id) !== epoch) return;
				reopen();
			}, delay),
		);
	}

	#attempt(id: DirId, epoch: symbol, signal?: AbortSignal): DirectoryConnectionAttempt {
		const left = () => this.#left.has(id) || this.#epochs.get(id) !== epoch;
		return {
			stale: () => signal?.aborted === true || left(),
			left,
		};
	}

	#epoch(id: DirId): symbol {
		const current = this.#epochs.get(id);
		if (current != null) return current;
		const epoch = Symbol(id);
		this.#epochs.set(id, epoch);
		return epoch;
	}

	#invalidate(id: DirId): void {
		this.#left.add(id);
		this.#epochs.set(id, Symbol(id));
		this.#cancelReconnect(id);
		this.#pruneLeft(id);
	}

	#track(id: DirId, run: Promise<string>): Promise<string> {
		this.#opening.set(id, run);
		const finish = () => {
			if (this.#opening.get(id) !== run) return;
			this.#opening.delete(id);
			if (this.#left.has(id)) this.#pruneLeft(id);
			else if (!this.#reconnects.has(id)) this.#epochs.delete(id);
		};
		void run.then(finish, finish);
		return run;
	}

	#cancelReconnect(id: DirId): void {
		const timer = this.#reconnects.get(id);
		if (timer == null) return;
		clearTimeout(timer);
		this.#reconnects.delete(id);
	}

	#pruneLeft(id: DirId): void {
		if (!this.#left.has(id) || this.#opening.has(id) || this.#reconnects.has(id)) return;
		this.#left.delete(id);
		this.#epochs.delete(id);
	}

	/** Hold the room a reader asked for until a directory is up to enter it on. */
	stageJoin(room: string, nick: string, policy: RoomPolicy, signal?: AbortSignal): Promise<string> {
		this.settleStaged("");
		if (signal?.aborted) return Promise.resolve("");
		this.#staged = { room, nick, policy };
		return new Promise<string>((resolve) => {
			this.#stagedSettle = resolve;
			signal?.addEventListener("abort", () => this.abandonJoin(), { once: true });
		});
	}

	/** Take the room a reader asked for before this directory was up, if one is
	 * waiting. Read once: whoever takes it owns settling it. */
	takeStaged(): { room: string; nick: string; policy: RoomPolicy } | null {
		const wanted = this.#staged;
		this.#staged = null;
		return wanted;
	}

	settleStaged(message: string): void {
		const settle = this.#stagedSettle;
		this.#stagedSettle = null;
		settle?.(message);
	}

	abandonJoin(): void {
		this.#staged = null;
		this.settleStaged("");
	}
}
