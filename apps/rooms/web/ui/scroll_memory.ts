// Last scroll offsets for conversations this tab still holds.

import { MAX_WORKSPACE_CONVERSATIONS } from "../../lib/rooms_state.ts";

/** The last scroll offset for recently visited conversations. Closed
 * conversations leave this browser's store, so this recency bound prevents a
 * long-running tab from retaining one key for every conversation ever opened. */
export class ScrollMemory {
	readonly #positions = new Map<string, number>();

	get size(): number {
		return this.#positions.size;
	}

	remember(key: string, position: number): void {
		// Refresh recency on every real scroll; Map.set alone preserves the old
		// insertion position and would evict an actively read conversation.
		this.#positions.delete(key);
		this.#positions.set(key, position);
		if (this.#positions.size <= MAX_WORKSPACE_CONVERSATIONS) return;
		const oldest = this.#positions.keys().next().value;
		if (oldest !== undefined) this.#positions.delete(oldest);
	}

	recall(key: string): number | undefined {
		const position = this.#positions.get(key);
		if (position === undefined) return undefined;
		this.#positions.delete(key);
		this.#positions.set(key, position);
		return position;
	}
}
