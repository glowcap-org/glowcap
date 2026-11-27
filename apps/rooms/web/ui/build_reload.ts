// Reloads the page when its server starts serving another build, once a
// reload destroys nothing.
//
// Every directory session rides the server's relay, so a restart takes every
// connection the page has. The page asks for the served build when it loses
// them all and when one comes back, and on a beat while it has none, which
// includes the wait for a first connection. Checks may overlap.
//
// A reload waits while it would destroy work the page alone holds: picked
// files, or what the session it shows says a reload drops (`ReloadLoss`).

import type { PageProjection } from "./store/projection.ts";
import { watchConnections } from "./connection_watch.ts";
import type { PageBuild } from "./served_build.ts";

const RECHECK_MS = 5_000;

/** What a reload would destroy: an edit the session holds no write of, picked
 * files, a change still being prepared. Work the session holds a record of is
 * not on it, because the reloaded page adopts that work again. */
export interface ReloadLoss {
	/** Whether a reload now would destroy something. */
	loses(): boolean;
	/** Call `listener` whenever that may have changed. Returns the stop. */
	subscribe(listener: () => void): () => void;
}

/** What a reload loss reads of a session the page shows. */
interface ReloadingSession {
	/** Whether a reload now would drop what the person did there. */
	readonly reloadLoses: boolean;
	subscribe(listener: () => void): () => void;
}

/** What a reload loss reads of the page: its drafts, and the session it shows
 * now, if any. */
interface ReloadingPage {
	readonly projection: PageProjection;
	readonly managedSession: ReloadingSession | null;
}

export function reloadLosesWork(page: ReloadingPage): boolean {
	return page.managedSession?.reloadLoses === true ||
		[...page.projection.get().drafts.values()].some((draft) => draft.files.length > 0);
}

/** What a reload of `page` would destroy: picked files, and what its session
 * says it would drop. The session is heard as it is now, including one opened
 * after the wait began. */
export function pageReloadLoss(page: ReloadingPage): ReloadLoss {
	return {
		loses: () => reloadLosesWork(page),
		subscribe: (listener) => {
			let session = page.managedSession;
			let stopSession = session?.subscribe(listener) ?? null;
			const stopProjection = page.projection.subscribe(() => {
				if (page.managedSession !== session) {
					stopSession?.();
					session = page.managedSession;
					stopSession = session?.subscribe(listener) ?? null;
				}
				listener();
			});
			return () => {
				stopProjection();
				stopSession?.();
			};
		},
	};
}

/** Calls `tick` on every beat until the returned stop. */
export type Beat = (tick: () => void) => () => void;

/** The one owner of a build reload. */
export interface BuildReload {
	/** Ask for the served build now, as when a connection to a session
	 * returned. The check and any wait for the loss to clear run on their own,
	 * so the caller never waits on a reload decision. */
	check(): void;
	stop(): void;
}

/** Reload into the first other build the server names, once a reload loses
 * nothing, whichever way the page learned of the build. One wait runs at a
 * time: a build named twice adds no second reload.
 * Returns the owner's `check` and `stop`. */
export function bindReloadToBuild(
	projection: PageProjection,
	build: PageBuild,
	loss: ReloadLoss,
	beat: Beat = beatEvery(RECHECK_MS),
): BuildReload {
	let stopped = false;
	let stopBeat: (() => void) | null = null;
	let lost = false;
	let waiting = false;
	// The server did not answer when a wait for a loss-free reload ended, so
	// the build it named is asked for again on the beat.
	let asking = false;
	let offline = false;
	const beatWanted = () => {
		if (!stopped && (asking || offline)) stopBeat ??= beat(() => void check());
		else {
			stopBeat?.();
			stopBeat = null;
		}
	};
	/** Ends the wait for a reload to lose nothing, and stops listening for it. */
	let endWait: (() => void) | null = null;
	const check = async () => {
		const served = await build.served();
		if (stopped || served == null || waiting) return;
		if (served === build.current) {
			asking = false;
			beatWanted();
			return;
		}
		waiting = true;
		let target: string | null = served;
		try {
			while (!stopped && target != null && target !== build.current && loss.loses()) {
				await new Promise<void>((resume) => {
					const stopListening = loss.subscribe(() => {
						if (!loss.loses()) endWait?.();
					});
					endWait = () => {
						endWait = null;
						stopListening();
						resume();
					};
				});
				// The served build may have changed during the wait, and a new
				// edit may begin while the server answers.
				target = stopped ? null : await build.served();
			}
		} finally {
			waiting = false;
		}
		asking = !stopped && target == null;
		beatWanted();
		if (!stopped && target != null && target !== build.current && build.reload(target)) stop();
	};
	const stopWatching = watchConnections(projection, ({ total, seen, connected }) => {
		// Every connection the page had is gone, or one is back.
		const lostNow = seen > 0 && connected === 0;
		if (lostNow !== lost) {
			lost = lostNow;
			void check();
		}
		offline = total > 0 && connected === 0;
		beatWanted();
	});
	function stop() {
		stopped = true;
		stopWatching();
		stopBeat?.();
		endWait?.();
	}
	return { check: () => void check(), stop };
}

function beatEvery(ms: number): Beat {
	return (tick) => {
		const id = setInterval(tick, ms);
		return () => clearInterval(id);
	};
}
