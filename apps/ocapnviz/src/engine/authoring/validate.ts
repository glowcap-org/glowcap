/**
 * Pre-flight an intent without mutating the engine.
 *
 * `Engine.validate` is the door; this module is the check. Today it
 * covers rename collisions and a user-supplied `add-peer` id, which
 * the ToolOptionsBar surfaces inline before the drop. Paste still
 * validates inside `cascadePaste`.
 */

import { collisionError, type EngineResult, err, ok } from "../errors.ts";
import type { BuilderIntent, EngineIntent } from "../intents.ts";
import type { TimelineDocument } from "../timeline.ts";
import { checkRekeyCollision } from "./identity.ts";

export function validateIntent(
  doc: TimelineDocument,
  intent: BuilderIntent | EngineIntent,
): EngineResult<void> {
  if (
    intent.kind === "rename-peer" ||
    intent.kind === "rename-session" ||
    intent.kind === "rename-message"
  ) {
    if (intent.oldId === intent.newId) return ok(undefined);
    const category = intent.kind === "rename-peer" ? "peer" : intent.kind === "rename-session" ? "session" : "message";
    return checkRekeyCollision(doc, category, intent.newId);
  }
  // add-peer with a user-supplied id: pre-flight the collision so
  // the ToolOptionsBar can surface the error inline (via
  // `<FieldError>`) before the click that drops the peer.
  if (
    intent.kind === "add-peer" &&
    intent.id !== undefined && intent.id.length > 0
  ) {
    if (doc.entities?.peers?.[intent.id] !== undefined) {
      return err(collisionError("peer", intent.id));
    }
  }
  return ok(undefined);
}
