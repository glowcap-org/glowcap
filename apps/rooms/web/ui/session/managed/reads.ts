// Read workers retain their wrappers until they drain. Retirement stops new
// reads. The session closes its application before waiting for these workers.
import { LOCAL_LIMITS } from "./local_gestures.ts";

/** Key sharing one in-flight read across concurrent callers asking for the
 * same subject at the same workspace revision. A revision change is a new
 * key, so a stale snapshot never answers a fresh read. */
export function revisionReadKey(kind: string, subject: unknown, revision: string | undefined): string {
	return JSON.stringify([kind, subject, revision]);
}

/** Key that never joins another in-flight read. A wrapper that cannot be
 * shared, a scoped Rust reader freed by its own caller, runs alone. */
export function privateReadKey(description: string): symbol {
	return Symbol(description);
}

export class ManagedReads {
	readonly #tasks = new Map<unknown, Promise<unknown>>();
	#stopped = false;
	get active(): number {
		return this.#tasks.size;
	}
	run<T>(key: unknown, work: () => Promise<T>): Promise<T> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		const existing = this.#tasks.get(key);
		if (existing != null) return existing as Promise<T>;
		if (this.#tasks.size >= LOCAL_LIMITS.reads) {
			return Promise.reject(new Error("Finish another read before requesting more workspace data"));
		}
		const task = Promise.resolve().then(work).finally(() => this.#tasks.delete(key));
		this.#tasks.set(key, task);
		return task;
	}
	stop(): void {
		this.#stopped = true;
	}
	async close(): Promise<void> {
		this.stop();
		await Promise.allSettled(this.#tasks.values());
	}
}
