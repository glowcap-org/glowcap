// Work an owner started and its close waits for.

/** The jobs under way for one owner. Each is kept until it ends. */
export class TrackedJobs {
	readonly #jobs = new Set<Promise<unknown>>();

	/** Keep `job` until it ends, and return it. */
	track<T>(job: Promise<T>): Promise<T> {
		const tracked = job.finally(() => this.#jobs.delete(tracked));
		this.#jobs.add(tracked);
		return tracked;
	}
	get size(): number {
		return this.#jobs.size;
	}
	/** Every job under way now, each ending however it does. */
	settled(): Promise<unknown> {
		return Promise.allSettled([...this.#jobs]);
	}
}
