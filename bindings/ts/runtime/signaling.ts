/** Own asynchronous signaling sends started by a callback. Every admitted send
 * remains joined until it settles; bounded admission turns a stalled signaling
 * carrier into one explicit bring-up failure instead of retained promises. */
export class SignalingSendOwner {
	static readonly maxPending = 256;
	#admitting = true;
	#failed: Error | null = null;
	readonly #inFlight = new Set<Promise<void>>();

	constructor(
		readonly label: string,
		readonly onFailure: (error: Error) => void,
	) {}

	get failure(): Error | null {
		return this.#failed;
	}

	/** Admit one send while bring-up is live. Synchronous throws and rejected
	 * promises take the same failure path and never escape the source callback. */
	admit(send: () => void | Promise<void>): void {
		if (!this.#admitting) return;
		if (this.#inFlight.size >= SignalingSendOwner.maxPending) {
			this.#recordFailure(new Error(`${this.label}: too many pending signaling sends`));
			return;
		}
		let result: void | Promise<void>;
		try {
			result = send();
		} catch (error) {
			this.#recordFailure(error);
			return;
		}
		// Wrap even an existing promise so each admission owns a distinct row; an
		// adapter may legitimately return the same carrier promise more than once.
		const pending = Promise.resolve().then(() => result);
		this.#inFlight.add(pending);
		void pending.then(
			() => this.#inFlight.delete(pending),
			(error) => {
				this.#inFlight.delete(pending);
				this.#recordFailure(error);
			},
		);
	}

	stopAdmission(): void {
		this.#admitting = false;
	}

	/** Join every send admitted before the gate closed. */
	async join(): Promise<void> {
		this.stopAdmission();
		while (this.#inFlight.size !== 0) {
			await Promise.allSettled([...this.#inFlight]);
		}
	}

	#recordFailure(error: unknown): void {
		if (this.#failed != null) return;
		this.#failed = error instanceof Error ? error : new Error(String(error));
		this.#admitting = false;
		this.onFailure(this.#failed);
	}
}
