/**
 * Message-level authoring operations. Each function takes the
 * `AuthoringContext` as its first argument.
 */

import { patchMessageDefinition } from "../entities.ts";
import {
  messageEffective,
  sessionEffective,
} from "../temporal/doc-resolver.ts";
import { cascadeDelete } from "../schema/cascade.ts";
import { restoreSnapshotInto, takeSnapshot } from "../snapshot.ts";
import { explicitBound, implicitBound } from "../temporal/bound.ts";
import { clearStart, setDuration, setStart } from "../temporal/time-span.ts";
import { notFoundError, validationError } from "../errors.ts";
import type { AuthoringContext } from "./context.ts";
import { commitEntityAuthoring } from "./events.ts";

// Messages always have explicit duration once defined. Default
// here matches DEFAULT_MESSAGE_FLIGHT_MS — same as the engine's
// add-message intent default.
const DEFAULT_FLIGHT = 500;
function defaultMessageTiming() {
  return { start: implicitBound(0), duration: explicitBound(DEFAULT_FLIGHT) };
}

// Each sync helper writes through a `time-span.ts` authoring op —
// the one vocabulary that produces authored spans (a derived span
// loses its marker here, so projection stops re-deriving it).

function syncMessageStart(
  ctx: AuthoringContext,
  messageId: string,
  startT: number,
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) return;
  def.timing = setStart(def.timing ?? defaultMessageTiming(), startT);
}

function syncMessageStartCleared(
  ctx: AuthoringContext,
  messageId: string,
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) return;
  def.timing = clearStart(def.timing ?? defaultMessageTiming());
}

function syncMessageDuration(
  ctx: AuthoringContext,
  messageId: string,
  duration: number,
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) return;
  def.timing = setDuration(def.timing ?? defaultMessageTiming(), duration);
}

/** Remove a `message-sent` and its paired `message-delivered` (plus
 * any eternal definition). Cascades through `cascadeDelete`. */
export function deleteMessage(
  ctx: AuthoringContext,
  messageId: string,
): void {
  const next = cascadeDelete(ctx.doc, "message", messageId);
  restoreSnapshotInto(ctx.doc, takeSnapshot(next));
  ctx.seekTo(ctx.clock.t);
}

/** Patch message-level fields. Mutates `doc.entities.messages` —
 *  the identity source of truth. Timing edits (sentT / arrivalT)
 *  belong to the timeline-drag pass — not here. */
export function updateMessage(
  ctx: AuthoringContext,
  messageId: string,
  patch: {
    label?: string;
    sessionId?: string;
    swapDirection?: true;
  },
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) return;
  const defPatch: {
    label?: string;
    sessionId?: string;
    from?: string;
    to?: string;
  } = {};
  if (patch.label !== undefined) defPatch.label = patch.label;
  if (patch.sessionId !== undefined && patch.sessionId !== def.sessionId) {
    // Validate: target session's endpoints must include both
    // sender and receiver. Otherwise the message is malformed.
    const target = ctx.doc.entities?.sessions?.[patch.sessionId];
    // An end holds an endpoint, not a peer id: comparing the two would be
    // legal TypeScript and always false, so every move would be refused.
    const targetA = target?.a.peer;
    const targetB = target?.b.peer;
    if (
      target &&
      ((targetA === def.from && targetB === def.to) ||
        (targetA === def.to && targetB === def.from))
    ) {
      defPatch.sessionId = patch.sessionId;
    } else {
      ctx.emitError(validationError(
        `Session ${patch.sessionId} does not connect ${def.from} and ${def.to}.`,
        "Pick a session whose endpoints match this message's peers.",
      ));
    }
  }
  if (patch.swapDirection === true) {
    defPatch.from = def.to;
    defPatch.to = def.from;
  }
  if (Object.keys(defPatch).length > 0) {
    patchMessageDefinition(ctx.doc, messageId, defPatch);
    ctx.seekTo(ctx.clock.t);
  }
}

/** Set the message's send time: pins `timing.start` explicit at
 * `t`. Identity from `doc.entities.messages[messageId]`. Validates
 * against session bounds:
 * `session.effectiveStart <= t <= session.effectiveEnd`. */
export function setMessageStart(
  ctx: AuthoringContext,
  messageId: string,
  t: number,
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) {
    ctx.emitError(notFoundError("message", messageId));
    return;
  }
  const sessionRange = sessionEffective(ctx.doc, def.sessionId);
  const sessionStart = sessionRange.start;
  const sessionEnd = Number.isFinite(sessionRange.end)
    ? sessionRange.end
    : ctx.doc.duration;
  if (t < sessionStart || t > sessionEnd) {
    ctx.emitError(validationError(
      `Message start (${t}) is outside its session window [${sessionStart}, ${sessionEnd}].`,
      "Drag the message inside the session's lifetime, or extend the session first.",
    ));
    return;
  }
  syncMessageStart(ctx, messageId, t);
  const flight = def.timing?.duration.value ?? 0;
  commitEntityAuthoring(ctx, t + flight);
}

/** Restore implicit start (inherits `session.effectiveStart`). */
export function clearMessageStart(
  ctx: AuthoringContext,
  messageId: string,
): void {
  syncMessageStartCleared(ctx, messageId);
  commitEntityAuthoring(ctx);
}

/** Set the message's flight duration. Mutates entity.timing.duration
 *  directly — storage-shaped, matching the TimeSpan model. Validated
 *  against the message's own start and the carrying session's
 *  effective end (arrival must land within the session). Messages
 *  always carry explicit duration (flight is a semantic property), so
 *  there is no `clearMessageDuration` counterpart. */
export function setMessageDuration(
  ctx: AuthoringContext,
  messageId: string,
  duration: number,
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) {
    ctx.emitError(notFoundError("message", messageId));
    return;
  }
  if (!(duration >= 0)) {
    ctx.emitError(validationError(
      `Message flight duration must be ≥ 0 (got ${duration}).`,
      "Drag the arrival handle forward, or type a non-negative value.",
    ));
    return;
  }
  // The arrival the user sees is the painted (effective) start plus
  // the flight — an implicit start inherits the session's painted
  // start and its retained stored value is not the anchor.
  const arrivalT = messageEffective(ctx.doc, messageId).start + duration;
  const sessionRange = sessionEffective(ctx.doc, def.sessionId);
  const sessionEnd = Number.isFinite(sessionRange.end)
    ? sessionRange.end
    : ctx.doc.duration;
  if (arrivalT > sessionEnd) {
    ctx.emitError(validationError(
      `Message arrival (${arrivalT}) lands after the session ends at ${sessionEnd}.`,
      "Shorten the flight, or extend the session's lifetime first.",
    ));
    return;
  }
  syncMessageDuration(ctx, messageId, duration);
  commitEntityAuthoring(ctx, arrivalT);
}

/** End-flavored wrapper. Translates `arrivalT` to a flight duration
 *  off the message's painted (effective) start — the same anchor
 *  `setPeerEnd` / `setSessionEnd` use — then defers to
 *  `setMessageDuration`. */
export function setMessageEnd(
  ctx: AuthoringContext,
  messageId: string,
  arrivalT: number,
): void {
  const def = ctx.doc.entities?.messages?.[messageId];
  if (!def) {
    ctx.emitError(notFoundError("message", messageId));
    return;
  }
  const start = messageEffective(ctx.doc, messageId).start;
  if (arrivalT < start) {
    ctx.emitError(validationError(
      `Message arrival (${arrivalT}) is before its send time (${start}).`,
      "Move arrival after the send, or move the send earlier.",
    ));
    return;
  }
  setMessageDuration(ctx, messageId, arrivalT - start);
}
