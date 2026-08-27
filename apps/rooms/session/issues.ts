// Live connection and capability issues for one durable Rooms runtime.

export class RoomsRuntimeIssues {
	readonly #issues = new Map<string, string>();
	readonly #changed = new Set<() => void>();

	onChange(changed: () => void): () => void {
		this.#changed.add(changed);
		return () => this.#changed.delete(changed);
	}

	notify(): void {
		for (const changed of this.#changed) {
			try {
				changed();
			} catch (error) {
				console.error(
					`rooms session: a runtime issue observer failed after the issue changed: ${
						error instanceof Error ? error.message : error
					}`,
				);
			}
		}
	}

	list(): { subject: string; reason: string }[] {
		return [...this.#issues].map(([subject, reason]) => ({ subject, reason }));
	}

	subjects(): IterableIterator<string> {
		return this.#issues.keys();
	}

	set(subject: string, error: unknown | null): boolean {
		const reason = error == null ? null : error instanceof Error ? error.message : String(error);
		if (reason == null) {
			if (!this.#issues.delete(subject)) return false;
		} else {
			if (this.#issues.get(subject) === reason) return false;
			this.#issues.set(subject, reason);
		}
		this.notify();
		return true;
	}
}
