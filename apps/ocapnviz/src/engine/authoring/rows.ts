/**
 * Timeline row order. Pure view-state: the renderer reads `doc.rowOrder`
 * each paint, so a write only needs to notify. Lives beside the other
 * authoring ops because dispatch routes `reorder-row` through the same
 * context, not because it changes observations.
 */

import type { AuthoringContext } from "./context.ts";
import type { TimelineDocument } from "../timeline.ts";

export function reorderRow(
  ctx: AuthoringContext,
  category: "peers" | "sessions" | "messages",
  order: string[],
): void {
  const next = { ...(ctx.doc.rowOrder ?? {}) };
  if (order.length === 0) {
    delete next[category];
  } else {
    next[category] = [...order];
  }
  const anyEntry = next.peers !== undefined ||
    next.sessions !== undefined ||
    next.messages !== undefined;
  (ctx.doc as TimelineDocument).rowOrder = anyEntry ? next : undefined;
  // Pure view-state — no clock seek needed (the renderer reads
  // `doc.rowOrder` directly each paint). But we DO need to
  // notify React-side subscribers (`useEngineVersion`) so the
  // Scrubber re-renders immediately; without this, the gutter
  // paint lags one engine tick behind the dispatch (Stage is
  // unaffected because its ticker reads `engine.doc` directly).
  ctx.notify();
}
