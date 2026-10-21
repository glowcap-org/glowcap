/**
 * Cascade operations: pure functions over `TimelineDocument` that walk
 * the schema's reference graph to delete or rewrite an entity and all
 * its references.
 *
 * `cascadeDelete` uses a worklist algorithm, removing a peer queues
 * any session that referenced it for cascade-delete, which in turn
 * queues its messages, etc. A `visited` set guards against cycles
 * (which the current schema can't produce but cheap insurance for
 * future schema changes).
 *
 * `cascadeRewrite` is a single-pass rewrite, every reference to
 * `oldId` becomes `newId`, including the entity definition's own key.
 *
 * Both functions return new documents. The input is not mutated.
 * The engine wraps a snapshot/rollback transaction around the call.
 * `deletePeer` / `deleteSession` / `deleteMessage` dispatch through
 * `cascadeDelete`, `rekeyEntity` through `cascadeRewrite`.
 *
 * See `docs/schema-driven-transactions.md`.
 */

import type { MessageDefinition, PeerDefinition, SessionDefinition, TimelineDocument } from "../timeline.ts";
import { collisionError, type EngineResult, err, ok } from "../errors.ts";
import type { EntityKind } from "./refs.ts";
import { ENTITY_EDGES, EVENT_EDGES, readEdgeRef, writeEdgeRef } from "./edges.ts";
import { DOC_INDEX_EDGES, docIndexesForTarget } from "./doc-index.ts";
import { assertNoRefsTo, ENTITIES_KEY, findEntityRefs } from "./walk.ts";

type EntityDef = PeerDefinition | SessionDefinition | MessageDefinition;
type EntityMap = Record<string, EntityDef>;

/** Strip a single entity from `doc.entities` and clean up empty maps so
 * `entities` becomes `undefined` when nothing is left. Pure. */
function removeEntity(
	doc: TimelineDocument,
	kind: EntityKind,
	id: string,
): TimelineDocument {
	const entitiesKey = ENTITIES_KEY[kind];
	const map = doc.entities?.[entitiesKey] as EntityMap | undefined;
	if (!map || !Object.prototype.hasOwnProperty.call(map, id)) return doc;
	const nextMap: EntityMap = { ...map };
	delete nextMap[id];
	const nextEntities: Record<string, EntityMap | undefined> = {
		...(doc.entities ?? {}),
	};
	if (Object.keys(nextMap).length > 0) {
		nextEntities[entitiesKey] = nextMap;
	} else {
		delete nextEntities[entitiesKey];
	}
	const hasAny = Object.values(nextEntities).some((v) => v !== undefined);
	return {
		...doc,
		entities: hasAny ? (nextEntities as TimelineDocument["entities"]) : undefined,
	};
}

/** Whether one observation belongs to the entity being deleted,
 *  its creation, its end, or its per-entity keyframes. References
 *  FROM other entities' observations (a message naming a session)
 *  are not matched here. The cascade queue visits those entities
 *  and each purges its own. */
function observationBelongsTo(
	ev: { kind: string } & Record<string, unknown>,
	kind: EntityKind,
	id: string,
): boolean {
	switch (kind) {
		case "peer":
			return (ev.kind === "peer-joined" || ev.kind === "peer-updated" ||
				ev.kind === "peer-left") && ev.peerId === id;
		case "session":
			// Every moment on the session's own trajectory belongs to it,
			// the state changes and the ends attaching alike, so a deleted
			// session takes its whole row rather than stranding half of it.
			return (ev.kind === "session-opened" ||
				ev.kind === "session-closed" ||
				ev.kind === "session-state-changed" ||
				ev.kind === "session-endpoint-attributed") &&
				ev.sessionId === id;
		case "message":
			return (ev.kind === "message-sent" ||
				ev.kind === "message-delivered") &&
				ev.messageId === id;
	}
}

/** Rewrite every observation field that names the entity, its own
 *  id field, and the cross-references other kinds' observations
 *  carry (a session's endpoints, a message's endpoints and
 *  session). The observation log is the authored document, and the
 *  projection synthesizes a definition for any id a creation
 *  observation mentions: an observation left on the old id would status-allow: replacement state identity
 *  resurrect a ghost there, while the renamed entity, matching no
 *  observations, would lose its derived timing.
 *
 *  Reads the reference sites out of `EVENT_EDGES` rather than
 *  listing field names, because a reference can sit INSIDE a field: a
 *  session's end is an endpoint structure and the peer it names is
 *  one property of it. A second list of field names here is exactly
 *  where that drifts from the table. */
function rewriteObservationIds(
	doc: TimelineDocument,
	kind: EntityKind,
	oldId: string,
	newId: string,
): TimelineDocument {
	const recording = doc.recording;
	if (!recording) return doc;
	let touched = false;
	const sources = recording.sources.map((src) => {
		let srcDirty = false;
		const next = src.observations.map((ev) => {
			let out: Record<string, unknown> | null = null;
			for (const edge of EVENT_EDGES[ev.kind]) {
				if (edge.target !== kind) continue;
				const row = (out ?? ev) as unknown as Record<string, unknown>;
				if (readEdgeRef(row, edge) !== oldId) continue;
				if (!out) {
					out = { ...(ev as unknown as Record<string, unknown>) };
				}
				writeEdgeRef(out, edge, newId);
			}
			if (!out) return ev;
			srcDirty = true;
			return out as unknown as typeof ev;
		});
		if (!srcDirty) return src;
		touched = true;
		return { ...src, observations: next };
	});
	if (!touched) return doc;
	return { ...doc, recording: { ...recording, sources } };
}

/** Strip the entity's own observations from every recording source.
 *  Pure. Returns the input doc when nothing matched. */
function removeObservations(
	doc: TimelineDocument,
	kind: EntityKind,
	id: string,
): TimelineDocument {
	const recording = doc.recording;
	if (!recording) return doc;
	let touched = false;
	const sources = recording.sources.map((src) => {
		const kept = src.observations.filter(
			(ev) =>
				!observationBelongsTo(
					ev as { kind: string } & Record<string, unknown>,
					kind,
					id,
				),
		);
		if (kept.length === src.observations.length) return src;
		touched = true;
		return { ...src, observations: kept };
	});
	if (!touched) return doc;
	return { ...doc, recording: { ...recording, sources } };
}

/** Cascade-delete a target entity and everything that references it.
 *
 * Steps per visited entity:
 *
 *   1. Remove the entity from `doc.entities`.
 *   2. Queue every entity whose class-2 ref targets it (cascade).
 *   3. Purge the id from every doc-level index (class-3).
 *
 * Observations are purged along with each visited entity. In Build
 * the observation log IS the document being authored, gestures
 * already move event times and identity edits rewrite payloads,
 * and the projection re-synthesizes a definition for any id a
 * creation observation still mentions, so a delete that spared the
 * observations would resurrect its ghost on the next re-projection.
 *
 * Pure. Returns the new doc.
 */
export function cascadeDelete(
	doc: TimelineDocument,
	kind: EntityKind,
	id: string,
): TimelineDocument {
	const visited = new Set<string>();
	const queue: Array<{ kind: EntityKind; id: string }> = [{ kind, id }];
	let result = doc;

	while (queue.length > 0) {
		const target = queue.shift()!;
		const visitKey = `${target.kind}:${target.id}`;
		if (visited.has(visitKey)) continue;
		visited.add(visitKey);

		// 1. Remove from doc.entities, and purge the observations that
		//    would re-synthesize it.
		result = removeEntity(result, target.kind, target.id);
		result = removeObservations(result, target.kind, target.id);

		// 2. Queue entities that reference the target (cascade).
		const entityRefs = findEntityRefs(result, target.kind, target.id);
		for (const ref of entityRefs) {
			const refKey = `${ref.entityKind}:${ref.entityId}`;
			if (!visited.has(refKey)) {
				queue.push({ kind: ref.entityKind, id: ref.entityId });
			}
		}

		// 3. Purge from doc-indexes.
		for (const idx of docIndexesForTarget(target.kind)) {
			const list = idx.read(result);
			if (!list) continue;
			const filtered = list.filter((x) => x !== target.id);
			if (filtered.length !== list.length) {
				result = idx.replace(result, filtered);
			}
		}
	}

	return result;
}

/** Cascade-rewrite every reference to `oldId` so it points at `newId`,
 *  including the entity definition's own key. Single-pass. No cascade
 *  recursion (the entity graph is the same shape afterwards, just with
 *  one key renamed).
 *
 *  Returns a collision error if `newId` is already in use within the
 *  same category. No-op (returns the input doc) when `oldId === newId`.
 *
 *  Pure.
 */
export function cascadeRewrite(
	doc: TimelineDocument,
	kind: EntityKind,
	oldId: string,
	newId: string,
): EngineResult<TimelineDocument> {
	if (oldId === newId) return ok(doc);

	const entitiesKey = ENTITIES_KEY[kind];
	const map = doc.entities?.[entitiesKey] as EntityMap | undefined;
	if (map && Object.prototype.hasOwnProperty.call(map, newId)) {
		return err(collisionError(kind, newId));
	}

	let result = doc;

	// 1. Move the entity definition under the new key, if it has one.
	if (map && Object.prototype.hasOwnProperty.call(map, oldId)) {
		const def = map[oldId]!;
		const nextMap: EntityMap = { ...map };
		delete nextMap[oldId];
		nextMap[newId] = def;
		result = {
			...result,
			entities: {
				...result.entities,
				[entitiesKey]: nextMap,
			} as TimelineDocument["entities"],
		};
	}

	// 2. Rewrite entity refs across all three entity kinds.
	for (const entityKind of ["peer", "session", "message"] as const) {
		const targetEdges = ENTITY_EDGES[entityKind].filter(
			(e) => e.target === kind,
		);
		if (targetEdges.length === 0) continue;
		const entityKey = ENTITIES_KEY[entityKind];
		const entityMap = result.entities?.[entityKey] as EntityMap | undefined;
		if (!entityMap) continue;

		let mapDirty = false;
		const nextMap: EntityMap = { ...entityMap };
		for (const [defId, def] of Object.entries(entityMap)) {
			let defDirty = false;
			let nextDef: Record<string, unknown> | null = null;
			for (const edge of targetEdges) {
				const value = readEdgeRef(
					def as unknown as Record<string, unknown>,
					edge,
				);
				if (value !== oldId) continue;
				if (!nextDef) {
					nextDef = {
						...(def as unknown as Record<string, unknown>),
					};
				}
				writeEdgeRef(nextDef, edge, newId);
				defDirty = true;
			}
			if (defDirty) {
				nextMap[defId] = nextDef as unknown as EntityDef;
				mapDirty = true;
			}
		}
		if (mapDirty) {
			result = {
				...result,
				entities: {
					...result.entities,
					[entityKey]: nextMap,
				} as TimelineDocument["entities"],
			};
		}
	}

	// 3. Rewrite doc-indexes.
	for (const idx of DOC_INDEX_EDGES) {
		if (idx.target !== kind) continue;
		const list = idx.read(result);
		if (!list || !list.includes(oldId)) continue;
		const nextList = list.map((x) => (x === oldId ? newId : x));
		result = idx.replace(result, nextList);
	}

	// 4. Rewrite the observations, so the projection derives for the
	//    new id instead of resurrecting the old one. status-allow: replacement state identity
	result = rewriteObservationIds(result, kind, oldId, newId);

	assertNoRefsTo("cascadeRewrite", result, kind, oldId);
	return ok(result);
}
