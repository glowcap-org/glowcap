// One coordination record follows a retained request through all local workers.
// Losing observation is evidence about ownership, never evidence of rollback.
export type OperationPhase = "queued" | "preparing" | "admitting" | "settling" | "acquiring" | "completing";
export type OutcomeEvidence = "notAdmitted" | "unknown" | "pending" | "committed";

export class OperationLifecycle {
	readonly started = performance.now();
	readonly owners = new Set<symbol>();
	#phase: OperationPhase = "queued";
	#outcome: OutcomeEvidence = "notAdmitted";
	// Six phases plus retries; keep only the last eight transitions per bounded
	// active record. Neither arguments, text nor capabilities enter this trace.
	readonly #transitions: { phase: OperationPhase; outcome: OutcomeEvidence; ms: number }[] = [];
	#attempts = 0;
	get phase(): OperationPhase {
		return this.#phase;
	}
	set phase(value: OperationPhase) {
		if (value === this.#phase) return;
		this.#phase = value;
		this.#transition();
	}
	get outcome(): OutcomeEvidence {
		return this.#outcome;
	}
	set outcome(value: OutcomeEvidence) {
		if (value === this.#outcome || this.#outcome === "committed") return;
		this.#outcome = value;
		this.#transition();
	}
	#transition(): void {
		this.#transitions.push({
			phase: this.phase,
			outcome: this.outcome,
			ms: Math.round(performance.now() - this.started),
		});
		if (this.#transitions.length > 8) this.#transitions.shift();
	}
	inspect() {
		return {
			operation: this.id,
			phase: this.phase,
			outcome: this.outcome,
			elapsedMs: Math.round(performance.now() - this.started),
			owners: this.owners.size,
			attempts: this.#attempts,
			needsDecision: this.needsDecision,
			transitions: [...this.#transitions],
		};
	}
	needsDecision = false;
	failure: unknown = null;
	constructor(readonly id: string, readonly changed: () => void) {}

	/** A successful handoff keeps the original intent owned by its caller.
	 * Only an explicit abandoned worker or restored receipt asks for a decision. */
	own<T>(phase: OperationPhase, work: () => Promise<T>): Promise<T> {
		const owner = Symbol(phase);
		this.#attempts++;
		this.owners.add(owner);
		this.phase = phase;
		this.needsDecision = false;
		this.failure = null;
		let failed = false;
		const task = new Promise<T>((resolve) => resolve(work())).catch((error: unknown) => {
			failed = true;
			this.failure = error;
			throw error;
		}).finally(() => {
			this.owners.delete(owner);
			if (failed && this.owners.size === 0) this.needsDecision = true;
			this.changed();
		});
		return task;
	}
	orphan(error?: unknown): void {
		this.failure = error ?? null;
		if (this.owners.size === 0) this.needsDecision = true;
		this.changed();
	}
}
