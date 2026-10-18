// Reloads the page when its server starts serving another build.
//
// Every directory session rides the server's relay, so a restart takes every
// connection the page has. The page asks for the served build when it loses
// them all and when one comes back, and on a beat while it has none, which
// includes the wait for a first connection. Checks may overlap.

import type { PageProjection } from "./store/core.ts";
import { watchConnections } from "./connection_watch.ts";

const RECHECK_MS = 5_000;
const REQUEST_TIMEOUT_MS = 5_000;
const RELOADED_FOR_KEY = "rooms:reloaded-for-build";

/** The build this page runs, and how it reaches the server's. */
export interface PageBuild {
	readonly current: string;
	/** The build the server serves now, or null without an answer. */
	served(): Promise<string | null>;
	/** Whether navigation started. A refused reload keeps watching later builds. */
	reload(build: string): boolean;
}

/** Calls `tick` on every beat until the returned stop. */
export type Beat = (tick: () => void) => () => void;

/** Reload into the first other build the server names. Returns the stop. */
export function bindReloadToBuild(
	projection: PageProjection,
	build: PageBuild,
	beat: Beat = beatEvery(RECHECK_MS),
): () => void {
	let stopped = false;
	let stopBeat: (() => void) | null = null;
	let lost = false;
	const check = async () => {
		const served = await build.served();
		if (stopped || served == null || served === build.current) return;
		if (build.reload(served)) stop();
	};
	const stopWatching = watchConnections(projection, ({ total, seen, connected }) => {
		// Every connection the page had is gone, or one is back.
		const lostNow = seen > 0 && connected === 0;
		if (lostNow !== lost) {
			lost = lostNow;
			void check();
		}
		if (total > 0 && connected === 0) {
			stopBeat ??= beat(() => void check());
		} else {
			stopBeat?.();
			stopBeat = null;
		}
	});
	function stop() {
		stopped = true;
		stopWatching();
		stopBeat?.();
	}
	return stop;
}

function beatEvery(ms: number): Beat {
	return (tick) => {
		const id = setInterval(tick, ms);
		return () => clearInterval(id);
	};
}

/** Whether to reload for `build`. A tab does not retry its last reload target,
 * so a server whose page and `/ui-version` disagree cannot loop it on that
 * target. A different target still permits an update or rollback. */
export function firstReloadFor(build: string, storage: () => Pick<Storage, "getItem" | "setItem">): boolean {
	try {
		const kept = storage();
		if (kept.getItem(RELOADED_FOR_KEY) === build) return false;
		kept.setItem(RELOADED_FOR_KEY, build);
	} catch {
		// tolerant: a tab whose storage refuses reloads without the guard.
	}
	return true;
}

/** The build stamped on `document`, or null on a page without one. */
export function servedPageBuild(document: Document, location: Location): PageBuild | null {
	const current = document.documentElement.dataset.uiBuild;
	if (current == null) return null;
	return {
		current,
		async served() {
			try {
				const response = await fetch("/ui-version", {
					cache: "no-store",
					signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
				});
				return response.ok ? (await response.text()).trim() || null : null;
			} catch {
				// tolerant: an unanswered check waits for the next drop, return, or beat.
				return null;
			}
		},
		reload(build) {
			if (!firstReloadFor(build, () => sessionStorage)) return false;
			location.reload();
			return true;
		},
	};
}
