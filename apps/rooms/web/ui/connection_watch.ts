// Which of the page's directory connections it has had, and which it has now.
// The mycelium dims from this, and the page checks its build from it.

import type { PageProjection } from "./store/core.ts";
import type { DirId, DirView } from "./types.ts";

/** The page's connections after one change to its directories. A directory
 * counts once it has been seen connected, because the arrival already grew the
 * network for its first connection and a first dial that fails lost nothing.
 * A directory the page forgets stops counting. */
export interface Connections {
	/** All directories held, including those whose first connection is pending. */
	readonly total: number;
	/** Directories this page has seen connected and still holds. */
	readonly seen: number;
	/** How many of those are connected now. */
	readonly connected: number;
}

/** Call `onChange` with the page's connections now, then after every change to
 * its directories. Returns the unsubscribe. */
export function watchConnections(projection: PageProjection, onChange: (connections: Connections) => void): () => void {
	// Each directory seen connected, and whether it is connected now.
	const seen = new Map<DirId, boolean>();
	let dirs: ReadonlyMap<DirId, DirView> | null = null;
	const look = () => {
		const next = projection.get().dirs;
		if (next === dirs) return;
		dirs = next;
		for (const id of seen.keys()) if (!next.has(id)) seen.delete(id);
		for (const [id, dir] of next) {
			const connected = dir.session === "connected";
			if (connected || seen.has(id)) seen.set(id, connected);
		}
		let connected = 0;
		for (const now of seen.values()) if (now) connected += 1;
		onChange({ total: next.size, seen: seen.size, connected });
	};
	look();
	return projection.subscribe(look);
}
