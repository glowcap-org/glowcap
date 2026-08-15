/**
 * Clipboard payload — the unit of copy/paste/duplicate.
 *
 * A `ClipboardPayload` is a closed subgraph of the source doc:
 * entities the user explicitly selected, plus every event that
 * references any of those entities. References to entities OUTSIDE
 * the selection (e.g. a session whose endpoint peer wasn't copied)
 * are *external* refs — recorded explicitly so paste can validate
 * them against the target doc.
 *
 * Closure rules:
 *   - Class-1 (event → entity): any event referencing a selected
 *     entity is in the payload.
 *   - Class-2 (entity → entity): NOT auto-pulled. If you copy a
 *     session, its endpoint peers do NOT come along unless you
 *     selected them too. Their ids appear in `externalRefs`.
 *   - Class-3 (doc-level index): not part of the payload. Pasted
 *     entities land at the end of any existing row order.
 *
 * Paste-time semantics live in `cascadePaste`. Selection-to-payload
 * extraction lives in `extractClipboardPayload`.
 *
 * See `docs/schema-driven-transactions.md`.
 */

import type { MessageDefinition, PeerDefinition, SessionDefinition, TimelineEvent } from "../timeline.ts";
import type { EntityKind } from "./refs.ts";

/** Subset of `Entities` carrying only the selected entities. */
export type ClipboardEntities = {
  peers?: Record<string, PeerDefinition>;
  sessions?: Record<string, SessionDefinition>;
  messages?: Record<string, MessageDefinition>;
};

/** A reference inside the payload that points at an entity NOT in
 * the payload. Paste validates these against the target doc and
 * blocks if any is missing. */
export type ExternalRef = {
  readonly kind: EntityKind;
  readonly id: string;
};

export type ClipboardPayload = {
  /** Entity definitions copied. Mirrors `doc.entities` shape. */
  readonly entities: ClipboardEntities;
  /** Events copied — every event that references at least one of
   *  the selected entities via a class-1 edge. */
  readonly events: ReadonlyArray<TimelineEvent>;
  /** Ids referenced by the payload but not present in
   *  `payload.entities`. Paste validates each against the target
   *  doc; missing ones block the paste. */
  readonly externalRefs: ReadonlyArray<ExternalRef>;
  /** Earliest `t` in `events`, captured at extraction time so
   *  paste can offset to playhead without rescanning. `0` when
   *  `events` is empty. */
  readonly minT: number;
};
