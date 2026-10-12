/**
 * Discovery primitives for the cascade subsystem.
 *
 * Three pure functions over `EVENT_EDGES`, `ENTITY_EDGES`, and
 * `DOC_INDEX_EDGES`: given a target entity, find every ref site that
 * points at it. The cascade operations in `cascade.ts` consume these
 * primitives to implement delete and rewrite.
 *
 * No mutation. No engine dependency. Tests live in `walk.test.ts`.
 *
 * See `docs/schema-driven-transactions.md` for the design.
 */

import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import type { EntityKind } from "./refs.ts";
import { ENTITY_EDGES, EVENT_EDGES, readEdgeRef } from "./edges.ts";
import { DOC_INDEX_EDGES, type DocIndexEdge } from "./doc-index.ts";

/** `doc.entities` keys parallel to the three entity kinds. */
export const ENTITIES_KEY = {
	peer: "peers",
	session: "sessions",
	message: "messages",
} as const satisfies Record<EntityKind, "peers" | "sessions" | "messages">;

/** A site where an event references a target entity. The field name is
 *  type-erased to `string` because the call site aggregates across
 *  every event kind. The precise per-kind narrowing isn't useful when
 *  the consumer needs to act uniformly. */
export type EventRefSite = {
	readonly event: TimelineEvent;
	readonly field: string;
};

/** Every event in `events` that references `(targetKind, targetId)`
 *  via any of its class-1 edges. */
export function findEventRefs(
	events: readonly TimelineEvent[],
	targetKind: EntityKind,
	targetId: string,
): EventRefSite[] {
	const out: EventRefSite[] = [];
	for (const event of events) {
		const edges = EVENT_EDGES[event.kind];
		for (const edge of edges) {
			if (edge.target !== targetKind) continue;
			const value = readEdgeRef(
				event as unknown as Record<string, unknown>,
				edge,
			);
			if (value === targetId) {
				out.push({ event, field: edge.field as string });
			}
		}
	}
	return out;
}

/** A site where an entity definition references a target entity. */
export type EntityRefSite = {
	readonly entityKind: EntityKind;
	readonly entityId: string;
	readonly field: string;
};

/** Every entity in `doc.entities` that references `(targetKind,
 *  targetId)` via any of its class-2 edges. */
export function findEntityRefs(
	doc: TimelineDocument,
	targetKind: EntityKind,
	targetId: string,
): EntityRefSite[] {
	const out: EntityRefSite[] = [];
	for (const entityKind of ["peer", "session", "message"] as const) {
		const edges = ENTITY_EDGES[entityKind];
		const targetEdges = edges.filter((e) => e.target === targetKind);
		if (targetEdges.length === 0) continue;
		const map = doc.entities?.[ENTITIES_KEY[entityKind]];
		if (!map) continue;
		for (const [id, def] of Object.entries(map)) {
			for (const edge of targetEdges) {
				const value = readEdgeRef(
					def as unknown as Record<string, unknown>,
					edge,
				);
				if (value === targetId) {
					out.push({
						entityKind,
						entityId: id,
						field: edge.field as string,
					});
				}
			}
		}
	}
	return out;
}

/** A site where a doc-level id-list contains the target id. */
export type DocIndexRefSite = {
	readonly edge: DocIndexEdge;
	readonly indexInList: number;
};

/** Every doc-level id-list that contains `targetId` and is registered
 *  as targeting `targetKind`. */
export function findDocIndexRefs(
	doc: TimelineDocument,
	targetKind: EntityKind,
	targetId: string,
): DocIndexRefSite[] {
	const out: DocIndexRefSite[] = [];
	for (const edge of DOC_INDEX_EDGES) {
		if (edge.target !== targetKind) continue;
		const list = edge.read(doc);
		if (!list) continue;
		const idx = list.indexOf(targetId);
		if (idx === -1) continue;
		out.push({ edge, indexInList: idx });
	}
	return out;
}

/** Throw if `doc` still has any ref to `(kind, id)` via class-2
 * (entity-to-entity) or class-3 (doc-index). Used by cascadeRewrite as
 * a post-pass straggler check, if it fires, an edge declaration is
 * missing in `ENTITY_EDGES` / `DOC_INDEX_EDGES`. `label` identifies the
 * call site.
 *
 * Class-1 (observation events in doc.recording.sources) is
 * excluded: observations are an immutable append-only
 * history that cascade operations never mutate. A rekey leaves the old
 * id in observation payloads and that is correct, the observation
 * faithfully records what the simulator saw at that moment. */
export function assertNoRefsTo(
	label: string,
	doc: TimelineDocument,
	kind: EntityKind,
	id: string,
): void {
	const ent = findEntityRefs(doc, kind, id);
	const idx = findDocIndexRefs(doc, kind, id);
	if (ent.length === 0 && idx.length === 0) return;
	throw new Error(
		`${label}: unregistered ref site for ${kind} "${id}" — ` +
			`entities=${ent.length} docIndexes=${idx.length}. ` +
			`Indicates a missing entry in ENTITY_EDGES / DOC_INDEX_EDGES.`,
	);
}
