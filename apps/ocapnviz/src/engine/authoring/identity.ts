/**
 * Rename / re-key authoring operations.
 *
 * `rekeyEntity` changes an entity's identity key (`peer-1` → `alice`)
 * across every reference site in the doc — entities map, cross-
 * category entity refs, every event, every doc-level index. The walk
 * itself is `cascadeRewrite` in `engine/schema/cascade.ts`; this
 * module wraps it with the engine concerns (apply-in-place into the
 * live doc, seek to rebuild the world).
 *
 * Collision policy: returns `{ ok: false, error: collisionError }`
 * if `newId` is already in use for the category. The engine's
 * `dispatch` snapshots before the call, so a collision leaves the
 * doc untouched. UI callers pre-flight via `engine.validate(intent)`
 * for inline `<FieldError>` feedback.
 */

import type { TimelineDocument } from "../timeline.ts";
import { collisionError, type EngineResult, err, ok } from "../errors.ts";
import { parseEndpointStageId } from "../../schema/session-end.ts";
import { cascadeRewrite } from "../schema/cascade.ts";
import { restoreSnapshotInto, takeSnapshot } from "../snapshot.ts";
import type { AuthoringContext } from "./context.ts";

export type RenameCategory = "peer" | "session" | "message";

function renameCategoryToEntitiesKey(
  category: RenameCategory,
): "peers" | "sessions" | "messages" {
  return category === "peer" ? "peers" : category === "session" ? "sessions" : "messages";
}

/** Validate-only: would `rekeyEntity(ctx, category, oldId, newId)`
 *  collide? Pure read; no mutation. Inspector inline edits call
 *  this on blur to gate the dispatch. */
export function checkRekeyCollision(
  doc: TimelineDocument,
  category: RenameCategory,
  newId: string,
): EngineResult<void> {
  const map = doc.entities?.[renameCategoryToEntitiesKey(category)];
  if (map && Object.prototype.hasOwnProperty.call(map, newId)) {
    return err(collisionError(category, newId));
  }
  // A peer and a session end nothing attributed are drawn as one node
  // each, out of one namespace, and `endpointStageId` spells an end's
  // name `session::side`. A peer answering to that spelling would be
  // the same node as that end: one place in the layout, one selection,
  // one position, where the picture holds two things. The author has
  // every other name available, so this one is refused here beside the
  // rest of the collision policy.
  if (category === "peer" && parseEndpointStageId(newId) !== undefined) {
    return err({
      code: "collision",
      title: "ID already in use",
      detail: `${newId} is how a session end nothing has attributed is named, ` +
        `so a peer cannot answer to it.`,
      recovery: "Pick an ID that does not end in “::a” or “::b”.",
    });
  }
  return ok(undefined);
}

/** Re-key an entity across the entire doc via `cascadeRewrite`.
 *  Returns the collision error (and leaves the doc untouched) when
 *  `newId` is already in use. On success, seeks so the renderer
 *  picks up the new identity. */
export function rekeyEntity(
  ctx: AuthoringContext,
  category: RenameCategory,
  oldId: string,
  newId: string,
): EngineResult<void> {
  const r = cascadeRewrite(ctx.doc, category, oldId, newId);
  if (!r.ok) return r;
  restoreSnapshotInto(ctx.doc, takeSnapshot(r.value));
  ctx.seekTo(ctx.clock.t);
  return ok(undefined);
}
