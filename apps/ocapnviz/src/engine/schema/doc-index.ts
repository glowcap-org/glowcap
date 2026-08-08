/**
 * Class-3 references: doc-level id-list fields that point at entities.
 *
 * These don't fit the per-event-kind exhaustiveness model that
 * `EVENT_EDGES` and `ENTITY_EDGES` use, because they're top-level
 * doc fields rather than discriminated-union variants. Adding a new
 * doc-level id-list field is an edit to `TimelineDocument` itself,
 * and TypeScript can't force a static registry to track that
 * automatically.
 *
 * Mitigation: every entry here is keyed by entity kind, and the
 * post-commit schema check (forthcoming with the transaction API)
 * validates the doc against zod after every transaction. An
 * unregistered id-list will surface either as a stale-id collision
 * or as a zod parse failure — slow but guaranteed.
 *
 * Convention: any new top-level `string[]`-of-entity-ids field in
 * `TimelineDocument` MUST register here in the same PR that adds it.
 *
 * Each entry exposes:
 *
 *   - `pathName`: human-readable for error messages (e.g.
 *     `"rowOrder.peers"`).
 *   - `target`: the entity kind whose ids live in this list.
 *   - `read(doc)`: returns the current list, or `undefined` if the
 *     field is absent. Pure.
 *   - `replace(doc, next)`: produces an updated doc with the list
 *     replaced. Pure (returns a new doc; doesn't mutate).
 *
 * The cascade operations use `read` + `replace` uniformly: to drop a
 * dependent, it filters the list; to rewrite, it maps; to remap, it
 * maps via a lookup table.
 */

import type { TimelineDocument } from "../timeline.ts";
import type { EntityKind } from "./refs.ts";

export type DocIndexEdge = {
  readonly pathName: string;
  readonly target: EntityKind;
  readonly read: (doc: TimelineDocument) => readonly string[] | undefined;
  readonly replace: (
    doc: TimelineDocument,
    next: readonly string[] | undefined,
  ) => TimelineDocument;
};

/** Build the four-way (rowOrder + 3 rowHidden variants) × three-
 * category (peers/sessions/messages) registry. Each field is a
 * `{ peers?, sessions?, messages? }` object; this generates 12
 * `DocIndexEdge`s with the right read/replace closures. */
function makeRowIndexes(): DocIndexEdge[] {
  const fields = [
    "rowOrder",
    "rowHidden",
    "rowLabelHidden",
    "rowBodyHidden",
  ] as const;
  const cats: ReadonlyArray<
    { key: "peers" | "sessions" | "messages"; target: EntityKind }
  > = [
    { key: "peers", target: "peer" },
    { key: "sessions", target: "session" },
    { key: "messages", target: "message" },
  ];
  const out: DocIndexEdge[] = [];
  for (const field of fields) {
    for (const { key, target } of cats) {
      out.push({
        pathName: `${field}.${key}`,
        target,
        read: (doc) => doc[field]?.[key],
        replace: (doc, next) => {
          const cur = doc[field];
          const nextField = { ...(cur ?? {}) } as Record<
            string,
            readonly string[] | undefined
          >;
          if (next === undefined || next.length === 0) {
            delete nextField[key];
          } else {
            nextField[key] = [...next];
          }
          const hasAny = Object.keys(nextField).some((k) =>
            nextField[k] !== undefined
          );
          return {
            ...doc,
            [field]: hasAny
              ? (nextField as TimelineDocument[typeof field])
              : undefined,
          };
        },
      });
    }
  }
  return out;
}

export const DOC_INDEX_EDGES: ReadonlyArray<DocIndexEdge> = makeRowIndexes();

/** Lookup helper: every doc-index edge whose target is the given
 *  entity kind. Used by the walker to iterate only the indexes
 *  relevant to a cascading operation. */
export function docIndexesForTarget(
  target: EntityKind,
): ReadonlyArray<DocIndexEdge> {
  return DOC_INDEX_EDGES.filter((e) => e.target === target);
}
