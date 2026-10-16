// The link between the two entries and the mycelium under the page.
// ground.js starts the mycelium and holds it here, and page.js tells it when
// the page loses its connections and when one comes back. Both entries
// import this module, so the bundle shares one copy of it, and the
// mycelium's own code stays out of page.js.

import type { PageProjection } from "./store/core.ts";
import type { DirId, DirView } from "./types.ts";

/** What the page needs of the mycelium (`Mycelium` in ui/mycelium.ts). The
 * mycelium owns whether it is dimmed: it ignores `dim()` while dimmed and
 * `regrow()` unless dimmed, so a caller may repeat either. */
export interface Ground {
	dim(): void;
	regrow(): void;
}

/** How long every connection must stay lost before the threads dim, in ms,
 * so a blip the reader never noticed shows nothing. */
export const DIM_AFTER_MS = 2500;

let held: Ground | null = null;

/** Hold the page's mycelium, or null if the browser could not draw one. */
export function holdGround(mycelium: Ground | null): void {
	held = mycelium;
}

const heldGround: Ground = {
	dim: () => held?.dim(),
	regrow: () => held?.regrow(),
};

/** Dim the threads once every directory this page has seen connected has
 * stayed lost for `dimAfterMs`, and ask them to regrow whenever one is
 * connected.
 * A directory that has never connected counts for neither, because the
 * arrival already grew the network for the first connection. A page that
 * has forgotten every directory it saw is not lost. Returns the unsubscribe. */
export function bindGroundToConnections(
	projection: PageProjection,
	ground: Ground = heldGround,
	dimAfterMs = DIM_AFTER_MS,
): () => void {
	// Each directory seen connected, and whether it is connected now.
	const seen = new Map<DirId, boolean>();
	let dirs: ReadonlyMap<DirId, DirView> | null = null;
	let dimming: ReturnType<typeof setTimeout> | undefined;
	const look = () => {
		const next = projection.get().dirs;
		if (next === dirs) return;
		dirs = next;
		for (const id of seen.keys()) if (!next.has(id)) seen.delete(id);
		for (const [id, dir] of next) {
			const connected = dir.session === "connected";
			if (connected || seen.has(id)) seen.set(id, connected);
		}
		const lost = seen.size > 0 && ![...seen.values()].some(Boolean);
		if (lost) {
			dimming ??= setTimeout(() => ground.dim(), dimAfterMs);
			return;
		}
		clearTimeout(dimming);
		dimming = undefined;
		ground.regrow();
	};
	look();
	const stop = projection.subscribe(look);
	return () => {
		stop();
		clearTimeout(dimming);
	};
}
