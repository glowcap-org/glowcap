/**
 * Subscribe to changes in the DOCUMENT, and to nothing else.
 *
 * Use this when a component reads what the document says, its source, its
 * title, whether a peer id is taken, whether there is an edit to undo, rather
 * than where the playhead is or where a peer currently sits. Those facts change
 * when someone edits, opens, or records, which is a human act rather than a
 * frame.
 *
 * Cost: nothing while a clock runs. That is the whole point of it existing
 * beside `useEngineVersion`, which wakes at the frame rate during playback
 * because it promises to catch any mutation at all. A panel that reads
 * document-shaped state and subscribes there re-renders sixty times a second
 * to paint the same words.
 *
 * Inspector split (HUD vs live rows):
 *
 * - Section shells (`EntityDetails` / `EntityConnections`) use this plus
 *   `useClockSnapshot`, document edits and playhead, not mid-drag pins.
 * - Rows that track a pin or other mid-drag world coords use
 *   `useEngineVersion` locally (`PositionRow` wrappers). Session and message
 *   field panels do not: they have no pin to follow, and the shell's clock
 *   already covers playhead-shaped lifecycle.
 * - Do not put a whole Peer/Endpoint panel on `useEngineVersion`, that
 *   re-reconciles every field group on every drag step.
 */

import { useCallback, useSyncExternalStore } from "react";
import type { Engine } from "../engine/engine.ts";

export function useDocVersion(engine: Engine): number {
	const subscribe = useCallback(
		(cb: () => void) => engine.subscribe(cb),
		[engine],
	);
	const get = useCallback(() => engine.docVersion, [engine]);
	return useSyncExternalStore(subscribe, get);
}
