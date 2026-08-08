/**
 * `AuthoringContext` — the narrow surface the document-authoring
 * subsystem needs from the Engine. The Engine creates one Context
 * in its constructor and passes it to every authoring function.
 *
 * Why a context rather than `Engine`: authoring operations don't
 * need subscribers, the error channel, transactions, the tick loop,
 * or the validate API. The context exposes only the state container
 * + post-mutation orchestration (`seekTo`) + the id-minter. Future
 * authoring operations (rename / paste / duplicate) land as
 * additions to `authoring/*.ts` without touching Engine.
 */

import type { Clock } from "../clock.ts";
import type { TimelineDocument } from "../timeline.ts";
import type { GameWorld } from "../world.ts";
import type { KeyframeLayoutSystem } from "../systems/keyframe-layout-system.ts";
import type { EngineError } from "../errors.ts";

export interface AuthoringContext {
  /** Mutable. Authoring functions write `doc.entities` /
   *  `doc.recording` / `doc.duration` / `doc.rowOrder` directly. */
  readonly doc: TimelineDocument;
  /** ECS world — rebuilt by `seekTo` after doc mutations. A few
   *  authoring paths read it for validation (does the peer exist?). */
  readonly world: GameWorld;
  /** Read for `clock.t` (the "now" used as the default timestamp
   *  for authored events). Written by `growDurationToFit` to keep
   *  the playable range covering authored events. */
  readonly clock: Clock;
  /** Still exposed for reads (e.g. keyframes in tests). Mutations that
   *  need a fresh solve go through {@link recomputeLayout} so a
   *  transaction can coalesce many writes into one anneal. */
  readonly layout: KeyframeLayoutSystem;
  /** Mint a monotonically-increasing integer for authored ids
   *  (`peer-1`, `session-1`, `msg-1`, `auth-...`). Owned by the
   *  Engine so the counter survives transactions and the doc round-
   *  trip. */
  mintId(): number;
  /**
   * Re-derive keyframe layout from the document. Inside an open
   * transaction this only marks the layout dirty; `endTransaction`
   * runs one `recompute` for the whole gesture (Unpin all, batched
   * deletes).
   */
  recomputeLayout(): void;
  /** Rebuild the world from the doc's recording layer and seek the
   *  clock to `targetT`. Authoring functions call this after mutation
   *  so the renderer reflects the new doc on the next paint. Inside a
   *  transaction the seek is deferred to `endTransaction`. */
  seekTo(targetT: number): void;
  /** Wake React-side subscribers (`useEngineVersion`) without a
   *  seek. Used by mutations that don't change observations
   *  themselves (row reorder) — the renderer reads the affected
   *  field directly each paint and just needs to know to repaint. */
  notify(): void;
  /** Surface a user-visible error through the engine's error
   *  channel. Authoring functions that reject invalid input (out-of-
   *  range duration, peer-not-in-doc, ordering violation, …) call
   *  this with a `validationError` so the UI toast/inline surfaces
   *  pick it up — fail-loud over silent-recovery. */
  emitError(error: EngineError): void;
}
