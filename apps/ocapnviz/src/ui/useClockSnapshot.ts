/**
 * Subscribe a component to the engine's playback clock. Called
 * LOCALLY by components that consume the clock (the Timeline) —
 * subscribing at the App root would re-reconcile the whole tree
 * on every Pixi tick during playback.
 *
 * `Clock.snapshot()` caches and only invalidates on mutation, so
 * referential equality holds while paused and React skips the
 * re-render.
 */

import { useCallback, useSyncExternalStore } from "react";
import type { ClockSnapshot } from "../engine/clock.ts";
import type { Engine } from "../engine/engine.ts";

export function useClockSnapshot(engine: Engine): ClockSnapshot {
	const subscribe = useCallback(
		(cb: () => void) => engine.subscribe(cb),
		[engine],
	);
	const getSnapshot = useCallback(
		() => engine.clock.snapshot(),
		[engine],
	);
	return useSyncExternalStore(subscribe, getSnapshot);
}
