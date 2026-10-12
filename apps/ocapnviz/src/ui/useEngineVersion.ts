/**
 * Subscribe to ANY engine notification. Use this when you read
 * `engine.world` / `engine.doc` / `engine.queries` and need to
 * re-render on any mutation. Use `useClockSnapshot` when you
 * specifically care about playhead-shaped state.
 *
 * Cost: re-renders at ~60 Hz during playback, because it promises to catch any
 * mutation at all and a playing clock mutates the world every frame. Keep the
 * consumer small. The Stage doesn't need it: its PixiJS ticker repaints every
 * frame already.
 *
 * A component that reads what the DOCUMENT says rather than what the world is
 * doing wants `useDocVersion` instead, which stays quiet while a clock runs.
 */

import { useCallback, useSyncExternalStore } from "react";
import type { Engine } from "../engine/engine.ts";

export function useEngineVersion(engine: Engine): number {
	const subscribe = useCallback(
		(cb: () => void) => engine.subscribe(cb),
		[engine],
	);
	const get = useCallback(() => engine.version, [engine]);
	return useSyncExternalStore(subscribe, get);
}
