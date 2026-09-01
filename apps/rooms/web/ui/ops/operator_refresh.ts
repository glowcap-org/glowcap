/** Serialize operator snapshots while giving every caller the promise for the
 * read it requested. Notices coalesce, and the newest explicit filter wins the
 * queued read. */
export class OperatorRefreshQueue<Filter> {
	readonly #read: (filter: Filter | undefined, current: () => boolean) => Promise<void>;
	#active: Promise<void> | null = null;
	#queued = false;
	#wanted: Filter | undefined;
	#waiters: Array<PromiseWithResolvers<void>> = [];
	#generation = 0;

	constructor(read: (filter: Filter | undefined, current: () => boolean) => Promise<void>) {
		this.#read = read;
	}

	request(filter?: Filter): Promise<void> {
		if (filter != null) {
			this.#wanted = filter;
			this.#generation += 1;
		}
		if (this.#active == null) return this.#start();
		this.#queued = true;
		const waiter = Promise.withResolvers<void>();
		this.#waiters.push(waiter);
		return waiter.promise;
	}

	#start(): Promise<void> {
		const wanted = this.#wanted;
		this.#wanted = undefined;
		const generation = this.#generation;
		const run = this.#read(wanted, () => generation === this.#generation);
		this.#active = run;
		void run.then(() => this.#advance(), () => this.#advance());
		return run;
	}

	#advance(): void {
		this.#active = null;
		if (!this.#queued) return;
		this.#queued = false;
		const waiters = this.#waiters.splice(0);
		void this.#start().then(
			() => waiters.forEach(({ resolve }) => resolve()),
			(error) => waiters.forEach(({ reject }) => reject(error)),
		);
	}
}
