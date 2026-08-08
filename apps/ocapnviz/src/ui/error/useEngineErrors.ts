import { useEffect } from "react";
import type { Engine } from "../../engine/engine.ts";
import { pushError } from "./error-bus.ts";

/**
 * Forward an engine's `onError` channel onto the app-wide error bus.
 * Mount once per engine instance. Unmount detaches cleanly so a
 * re-created engine doesn't leak listeners.
 */
export function useEngineErrors(engine: Engine | null): void {
  useEffect(() => {
    if (!engine) return;
    return engine.onError((error) => {
      pushError({ error, source: "engine" });
    });
  }, [engine]);
}
