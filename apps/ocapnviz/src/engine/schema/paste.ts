/**
 * `cascadePaste` — merge a `ClipboardPayload` into a target doc.
 *
 * Algorithm:
 *
 *   1. Validate external refs against the target doc. Any payload
 *      external ref whose id is missing from the target blocks the
 *      paste with a validation error.
 *
 *   2. Build an id-remap table. For each entity id in the payload,
 *      if it collides with an existing id in the target, mint a
 *      suffixed id (`peer-1` → `peer-1-copy`, `-copy-2`, ...) until
 *      it's unique. Engine-minted; the user never sees the suffix
 *      machinery, only the result. Non-colliding ids pass through.
 *
 *   3. Compute a time offset: `clockT - payload.minT`. Pasted
 *      events shift uniformly so the earliest event lands at the
 *      current playhead (Adobe-style paste-at-cursor).
 *
 *   4. Rewrite the payload through the remap table — entity keys,
 *      class-2 entity refs, class-1 event refs — and apply the
 *      time offset to every event. Then merge into the target doc
 *      (entities by key insert; events by sorted append).
 *
 *   5. Run the post-pass straggler check: every ref in the merged
 *      payload region must resolve to an entity in the target doc.
 *      Any missing ref is a schema bug (unregistered edge) and
 *      throws.
 *
 *   6. Return the new doc plus the remap table so the caller can
 *      select the pasted entities post-paste.
 *
 * Pure. See `docs/schema-driven-transactions.md`.
 */

import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { type EngineError, type EngineResult, err, ok, validationError } from "../errors.ts";
import type { EntityKind } from "./refs.ts";
import { ENTITY_EDGES, EVENT_EDGES, readEdgeRef, writeEdgeRef } from "./edges.ts";
import { type ClipboardEntities, type ClipboardPayload } from "./clipboard.ts";
import { ENTITIES_KEY } from "./walk.ts";

/** Per-kind id remap. Keys are payload ids; values are target ids
 * (same when no collision, suffixed when collided). */
export type IdRemap = {
  readonly peer: ReadonlyMap<string, string>;
  readonly session: ReadonlyMap<string, string>;
  readonly message: ReadonlyMap<string, string>;
};

export type CascadePasteResult = {
  readonly doc: TimelineDocument;
  readonly remap: IdRemap;
};

/** Insert pasted entities into the target. Returns the new doc. */
export function cascadePaste(
  doc: TimelineDocument,
  payload: ClipboardPayload,
  clockT: number,
): EngineResult<CascadePasteResult> {
  // 1. Validate external refs.
  const missing = validateExternalRefs(doc, payload);
  if (missing) return err(missing);

  // 2. Build remap with collision suffixing.
  const remap = buildIdRemap(doc, payload);

  // 3. Time offset (clockT - earliest payload event t). Empty
  //    payload-events → no offset.
  const offsetT = payload.events.length > 0 ? clockT - payload.minT : 0;

  // 4a. Apply remap to payload entities.
  const remappedEntities = remapEntities(payload.entities, remap);

  // 4b. Apply remap + time-offset to payload events. Event ids answer
  //     the same uniqueness question the entity ids just did, against
  //     the ids the target already holds.
  const usedEventIds = new Set(
    (observationsOf(doc) as readonly TimelineEvent[]).map((ev) => ev.id),
  );
  const remappedEvents = remapEvents(
    payload.events,
    remap,
    offsetT,
    usedEventIds,
  );

  // 4c. Merge into target doc.
  const merged = mergeIntoDoc(doc, remappedEntities, remappedEvents);

  // 5. Straggler check: every ref in the pasted region must resolve.
  //    A missing ref here is a schema bug (we built the remap from
  //    the edge maps, so every declared edge should have been
  //    rewritten or already pointed at an external entity that
  //    validateExternalRefs proved exists).
  const stragglers = findStragglers(merged, remappedEntities, remappedEvents);
  if (stragglers.length > 0) {
    throw new Error(
      `cascadePaste: post-merge stragglers — ${stragglers.join(", ")}. ` +
        `Indicates a missing entry in EVENT_EDGES / ENTITY_EDGES.`,
    );
  }

  return ok({ doc: merged, remap });
}

// ─── Helpers ─────────────────────────────────────────────────────

function validateExternalRefs(
  doc: TimelineDocument,
  payload: ClipboardPayload,
): EngineError | null {
  const missing: string[] = [];
  for (const ref of payload.externalRefs) {
    const map = doc.entities?.[ENTITIES_KEY[ref.kind]];
    if (!map || !Object.prototype.hasOwnProperty.call(map, ref.id)) {
      missing.push(`${ref.kind} "${ref.id}"`);
    }
  }
  if (missing.length === 0) return null;
  return validationError(
    `Paste references entities that don't exist in the target document: ${missing.join(", ")}.`,
    "Include the referenced entities in your selection before copying, " +
      "or add them to the destination first.",
  );
}

function buildIdRemap(
  doc: TimelineDocument,
  payload: ClipboardPayload,
): IdRemap {
  return {
    peer: remapForKind(payload.entities.peers, doc.entities?.peers),
    session: remapForKind(payload.entities.sessions, doc.entities?.sessions),
    message: remapForKind(payload.entities.messages, doc.entities?.messages),
  };
}

/** A name for `id` that nothing in `used` already answers to, and
 *  `used` grows to hold it.
 *
 *  One question, one answer. Entity ids and event ids both have to
 *  come out of a paste unique, and they had two answers: this loop for
 *  entities, and an unconditional single `-copy` for events, which
 *  collides the second time the same clipboard is pasted. A collided
 *  event id is worse than a collided entity id, because nothing
 *  refuses it — `moveEvent` takes the first match, so dragging the
 *  second copy retimed the first. */
function uniqueId(id: string, used: Set<string>): string {
  let candidate = id;
  if (used.has(candidate)) {
    candidate = `${id}-copy`;
    let n = 2;
    while (used.has(candidate)) {
      candidate = `${id}-copy-${n}`;
      n += 1;
    }
  }
  used.add(candidate);
  return candidate;
}

function remapForKind(
  payloadMap: Record<string, unknown> | undefined,
  targetMap: Record<string, unknown> | undefined,
): Map<string, string> {
  const out = new Map<string, string>();
  if (!payloadMap) return out;
  // Suffix collisions against the target AND against ids we've
  // already minted in this paste (so two pasted entities both named
  // "peer-1" don't both become "peer-1-copy").
  const used = new Set<string>(targetMap ? Object.keys(targetMap) : []);
  for (const id of Object.keys(payloadMap)) {
    out.set(id, uniqueId(id, used));
  }
  return out;
}

function rewriteId(remap: IdRemap, kind: EntityKind, id: string): string {
  return remap[kind].get(id) ?? id;
}

/** Rewrite an entity definition's class-2 ref fields through the
 * remap. Walks `ENTITY_EDGES[entityKind]` rather than hand-coding
 * which fields exist — adding a new ref field to an entity
 * definition automatically gets handled here once it's declared in
 * the schema. */
function remapEntityDef<T>(
  entityKind: EntityKind,
  def: T,
  remap: IdRemap,
): T {
  const edges = ENTITY_EDGES[entityKind];
  if (edges.length === 0) return def;
  const source = def as unknown as Record<string, unknown>;
  let next: Record<string, unknown> | null = null;
  for (const edge of edges) {
    const value = readEdgeRef(source, edge);
    if (typeof value !== "string") continue;
    const rewritten = rewriteId(remap, edge.target, value);
    if (rewritten === value) continue;
    if (!next) next = { ...source };
    writeEdgeRef(next, edge, rewritten);
  }
  return (next ?? source) as unknown as T;
}

function remapEntities(
  entities: ClipboardEntities,
  remap: IdRemap,
): ClipboardEntities {
  const out: Record<string, Record<string, unknown>> = {};
  for (const kind of ["peer", "session", "message"] as const) {
    const sourceKey = ENTITIES_KEY[kind];
    const map = (entities as Record<string, unknown>)[sourceKey] as
      | Record<string, unknown>
      | undefined;
    if (!map) continue;
    const next: Record<string, unknown> = {};
    for (const [oldId, def] of Object.entries(map)) {
      next[rewriteId(remap, kind, oldId)] = remapEntityDef(kind, def, remap);
    }
    out[sourceKey] = next;
  }
  return out as unknown as ClipboardEntities;
}

function remapEvents(
  events: ReadonlyArray<TimelineEvent>,
  remap: IdRemap,
  offsetT: number,
  usedEventIds: Set<string>,
): TimelineEvent[] {
  return events.map((ev) => {
    const next: Record<string, unknown> = { ...ev };
    // Apply time offset.
    next.t = (ev.t as number) + offsetT;
    if ("arrivalT" in ev) {
      next.arrivalT = (ev.arrivalT as number) + offsetT;
    }
    // Through the same loop the entity ids went through, against the
    // ids the target holds and the ones this paste has already minted.
    next.id = uniqueId(ev.id, usedEventIds);
    // Rewrite every ref via the edge map.
    for (const edge of EVENT_EDGES[ev.kind]) {
      const value = readEdgeRef(ev as unknown as Record<string, unknown>, edge);
      if (typeof value !== "string") continue;
      writeEdgeRef(next, edge, rewriteId(remap, edge.target, value));
    }
    return next as unknown as TimelineEvent;
  });
}

function mergeIntoDoc(
  doc: TimelineDocument,
  entities: ClipboardEntities,
  events: ReadonlyArray<TimelineEvent>,
): TimelineDocument {
  // Merge entities.
  const nextEntities: NonNullable<TimelineDocument["entities"]> = {
    peers: { ...(doc.entities?.peers ?? {}), ...(entities.peers ?? {}) },
    sessions: {
      ...(doc.entities?.sessions ?? {}),
      ...(entities.sessions ?? {}),
    },
    messages: {
      ...(doc.entities?.messages ?? {}),
      ...(entities.messages ?? {}),
    },
  };
  for (
    const k of ["peers", "sessions", "messages"] as const
  ) {
    const v = nextEntities[k];
    if (v && Object.keys(v).length === 0) delete nextEntities[k];
  }

  // Merge events sorted by t into the canonical observation store
  // (recording.sources[0]). Lazy-creates the primary source if the
  // target doc has no recording yet.
  const existing = observationsOf(doc) as TimelineEvent[];
  const allEvents = [...existing, ...events];
  allEvents.sort((a, b) => a.t - b.t);

  const existingRecording = doc.recording ?? {
    sources: [{
      id: "primary",
      meta: { kind: "authored" as const },
      observations: [] as TimelineEvent[],
    }],
  };
  const sources = existingRecording.sources.map((src, i) => i === 0 ? { ...src, observations: allEvents } : src);
  return {
    ...doc,
    recording: { ...existingRecording, sources },
    entities: Object.keys(nextEntities).length > 0 ? nextEntities : undefined,
  };
}

function findStragglers(
  doc: TimelineDocument,
  pastedEntities: ClipboardEntities,
  pastedEvents: ReadonlyArray<TimelineEvent>,
): string[] {
  const stragglers: string[] = [];
  const has = (kind: EntityKind, id: string): boolean => {
    const map = doc.entities?.[ENTITIES_KEY[kind]];
    return !!map && Object.prototype.hasOwnProperty.call(map, id);
  };
  // Check class-2 refs in pasted entity defs.
  for (const entityKind of ["peer", "session", "message"] as const) {
    const map = pastedEntities[ENTITIES_KEY[entityKind]];
    if (!map) continue;
    for (const [defId, def] of Object.entries(map)) {
      for (const edge of ENTITY_EDGES[entityKind]) {
        const value = readEdgeRef(
          def as unknown as Record<string, unknown>,
          edge,
        );
        if (typeof value !== "string") continue;
        if (!has(edge.target, value)) {
          stragglers.push(
            `${entityKind} "${defId}".${edge.field} → ${edge.target} "${value}" (missing)`,
          );
        }
      }
    }
  }
  // Check class-1 refs in pasted events.
  for (const ev of pastedEvents) {
    for (const edge of EVENT_EDGES[ev.kind]) {
      const value = readEdgeRef(ev as unknown as Record<string, unknown>, edge);
      if (typeof value !== "string") continue;
      if (!has(edge.target, value)) {
        stragglers.push(
          `event ${ev.kind} "${ev.id}".${edge.field} → ${edge.target} "${value}" (missing)`,
        );
      }
    }
  }
  return stragglers;
}
