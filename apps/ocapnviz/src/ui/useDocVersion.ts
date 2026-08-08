/**
 * Subscribe to changes in the DOCUMENT, and to nothing else.
 *
 * Use this when a component reads what the document says — its source, its
 * title, whether a peer id is taken, whether there is an edit to undo — rather
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
 * `useEngineVersion` for anything that follows the world — the entities on
 * stage, a message in flight, a session's current state. `useClockSnapshot`
 * for playhead-shaped state specifically.
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
