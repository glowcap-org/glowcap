/**
 * Keyboard verbs against the unified entity selection.
 *
 * Cmd-A selects every entity whose START event sits in the visible
 * window; Escape clears; Delete / Backspace bulk-deletes via the
 * host callback (which iterates entities, not events). Skipped when
 * typing into an input so the inspector text fields can carry their
 * own Backspace meaning.
 *
 * `TimelinePanel` owns the view and wires this; the policy lives here
 * so the panel is not also the key map.
 */

import { useEffect } from "react";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";
import { entityKey, type EntityRefKey } from "../../interactions/types.ts";
import { isTextInputTarget } from "../../interactions/text-input-target.ts";
import { eventEntityRef } from "./event-entity-ref.ts";

export function useTimelineSelectionKeys(
  {
    doc,
    windowStart,
    windowEnd,
    selectionSet,
    onSetSelection,
    onBulkDelete,
  }: {
    doc: TimelineDocument;
    windowStart: number;
    windowEnd: number;
    selectionSet: ReadonlySet<EntityRefKey>;
    onSetSelection: (entities: ReadonlySet<EntityRefKey>) => void;
    onBulkDelete?: ((entities: ReadonlySet<EntityRefKey>) => void) | undefined;
  },
): void {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTextInputTarget(e.target)) return;
      if (e.key === "Escape") {
        onSetSelection(new Set());
        return;
      }
      if (
        (e.key === "a" || e.key === "A") && (e.metaKey || e.ctrlKey)
      ) {
        e.preventDefault();
        const visible = new Set<EntityRefKey>();
        for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
          // Pairs: count the START end only — the END event has
          // the same entity ref so it would just re-add the same
          // key, but the visible-window check is more meaningful
          // against the start.
          if (
            ev.kind === "peer-left" ||
            ev.kind === "session-closed" ||
            ev.kind === "message-delivered"
          ) continue;
          if (ev.t < windowStart || ev.t > windowEnd) continue;
          visible.add(entityKey(eventEntityRef(ev)));
        }
        onSetSelection(visible);
        return;
      }
      if (
        (e.key === "Delete" || e.key === "Backspace") &&
        selectionSet.size > 0 &&
        onBulkDelete
      ) {
        e.preventDefault();
        onBulkDelete(selectionSet);
        onSetSelection(new Set());
        return;
      }
    };
    globalThis.addEventListener("keydown", onKey);
    return () => globalThis.removeEventListener("keydown", onKey);
  }, [
    selectionSet,
    onSetSelection,
    doc,
    windowStart,
    windowEnd,
    onBulkDelete,
  ]);
}
