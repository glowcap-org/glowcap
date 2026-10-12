// Cancellation supplies the decision for an uncertain admission. Its receipt
// owner continues once automatically. A failed continuation remains reviewable.
export class CancellationRecovery {
	#attempted = false;
	readonly #cancel = () => {
		this.changed();
		this.idle();
	};
	constructor(
		readonly signal: AbortSignal | undefined,
		readonly ready: () => boolean,
		readonly recover: () => Promise<unknown>,
		readonly changed: () => void,
	) {
		signal?.addEventListener("abort", this.#cancel, { once: true });
	}
	get pending(): boolean {
		return this.signal?.aborted === true && !this.#attempted;
	}
	idle(): Promise<unknown> | undefined {
		if (!this.pending || !this.ready()) return undefined;
		this.#attempted = true;
		const task = this.recover();
		// recover() registers its worker at the receipt owner before returning.
		void task.catch(() => {
			// tolerant: the original lifecycle retains and discloses this failure.
		});
		return task;
	}
	dispose(): void {
		this.signal?.removeEventListener("abort", this.#cancel);
	}
}
