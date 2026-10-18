// Holds the mycelium under the page and dims it while the page is offline.
// ground.js holds the mycelium here and page.js binds it to the connections,
// so the mycelium's code stays out of page.js.

import type { PageProjection } from "../store/core.ts";
import { watchConnections } from "../connection_watch.ts";

/** What the page needs of `Mycelium` (live.ts). Both calls are idempotent:
 * the mycelium owns whether it is dimmed. */
export interface Ground {
	dim(): void;
	regrow(): void;
}

/** How long the page stays offline before the threads dim, so a blip shows
 * nothing. */
const DIM_AFTER_MS = 2500;

/** A one-shot timer: call `fire` once, unless the returned cancel comes first. */
export type Delay = (fire: () => void) => () => void;

function after(ms: number): Delay {
	return (fire) => {
		const id = setTimeout(fire, ms);
		return () => clearTimeout(id);
	};
}

// The mycelium starts once the page's GPU device answers, so a request can
// arrive first. Each one waits on the same promise, so they land in order.
let held: Promise<Ground | null> = Promise.resolve(null);

/** Hold the page's mycelium as it starts. It resolves to null if the browser
 * could not draw one. */
export function holdGround(mycelium: Promise<Ground | null>): void {
	held = mycelium;
}

const heldGround: Ground = {
	dim: () => void held.then((ground) => ground?.dim()),
	regrow: () => void held.then((ground) => ground?.regrow()),
};

/** Dim `ground` once every directory the page has seen connected stays lost
 * past `delay`, and regrow it when one connects. Returns the unsubscribe. */
export function bindGroundToConnections(
	projection: PageProjection,
	{ ground = heldGround, delay = after(DIM_AFTER_MS) }: { ground?: Ground; delay?: Delay } = {},
): () => void {
	let cancelDim: (() => void) | null = null;
	const stop = watchConnections(projection, ({ seen, connected }) => {
		if (seen > 0 && connected === 0) {
			cancelDim ??= delay(() => ground.dim());
			return;
		}
		cancelDim?.();
		cancelDim = null;
		ground.regrow();
	});
	return () => {
		stop();
		cancelDim?.();
	};
}
