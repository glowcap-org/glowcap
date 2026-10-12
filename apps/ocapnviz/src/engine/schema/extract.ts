/**
 * Extract a `ClipboardPayload` from a doc given a selection.
 *
 * Driven entirely by the edge maps (`EVENT_EDGES`, `ENTITY_EDGES`)
 * so adding a new event kind or entity field automatically extends
 * what extraction can handle.
 *
 * Pure. See `clipboard.ts` for the closure rules.
 */

import type {
	MessageDefinition,
	PeerDefinition,
	SessionDefinition,
	TimelineDocument,
	TimelineEvent,
} from "../timeline.ts";
import type { EntityKind } from "./refs.ts";
import { ENTITY_EDGES, EVENT_EDGES, readEdgeRef } from "./edges.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { type ClipboardEntities, type ClipboardPayload, type ExternalRef } from "./clipboard.ts";
import { ENTITIES_KEY } from "./walk.ts";

/** Selection input: which entity ids are being copied, by kind. */
export type Selection = {
	readonly peers?: ReadonlySet<string>;
	readonly sessions?: ReadonlySet<string>;
	readonly messages?: ReadonlySet<string>;
};

/** Build a closed payload from `doc` + `selection`. */
export function extractClipboardPayload(
	doc: TimelineDocument,
	selection: Selection,
): ClipboardPayload {
	const sel: Record<EntityKind, ReadonlySet<string>> = {
		peer: selection.peers ?? new Set(),
		session: selection.sessions ?? new Set(),
		message: selection.messages ?? new Set(),
	};

	// 1. Collect entity definitions for each selected id. Per-kind
	//    expansion via a single typed-key loop, adding a new entity
	//    kind extends ENTITIES_KEY + EntityKind and this picks it up.
	const entities: ClipboardEntities = {};
	for (const kind of ["peer", "session", "message"] as const) {
		const sourceKey = ENTITIES_KEY[kind];
		const map = doc.entities?.[sourceKey] as
			| Record<
				string,
				PeerDefinition | SessionDefinition | MessageDefinition
			>
			| undefined;
		const ids = sel[kind];
		if (!map || ids.size === 0) continue;
		const out: Record<string, unknown> = {};
		for (const id of ids) {
			if (map[id]) out[id] = map[id];
		}
		if (Object.keys(out).length > 0) {
			(entities as Record<string, unknown>)[sourceKey] = out;
		}
	}

	// 2. Collect events referencing any selected entity via class-1.
	//    An event is included if ANY of its ref fields points at a
	//    selected entity of the matching kind.
	const events: TimelineEvent[] = [];
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		const edges = EVENT_EDGES[ev.kind];
		let include = false;
		for (const edge of edges) {
			const value = readEdgeRef(
				ev as unknown as Record<string, unknown>,
				edge,
			);
			if (typeof value !== "string") continue;
			if (sel[edge.target].has(value)) {
				include = true;
				break;
			}
		}
		if (include) events.push(ev);
	}

	// 3. Discover external refs: every ref site in the payload whose
	//    target is NOT in the payload's entity selection.
	const seen = new Set<string>();
	const externalRefs: ExternalRef[] = [];
	const consider = (kind: EntityKind, id: string): void => {
		if (sel[kind].has(id)) return;
		const key = `${kind}:${id}`;
		if (seen.has(key)) return;
		seen.add(key);
		externalRefs.push({ kind, id });
	};
	// Class-1: events in the payload.
	for (const ev of events) {
		for (const edge of EVENT_EDGES[ev.kind]) {
			const value = readEdgeRef(
				ev as unknown as Record<string, unknown>,
				edge,
			);
			if (typeof value !== "string") continue;
			consider(edge.target, value);
		}
	}
	// Class-2: entity refs in the payload entities.
	for (const entityKind of ["peer", "session", "message"] as const) {
		const targetEdges = ENTITY_EDGES[entityKind];
		if (targetEdges.length === 0) continue;
		const map = entities[ENTITIES_KEY[entityKind]];
		if (!map) continue;
		for (const def of Object.values(map)) {
			for (const edge of targetEdges) {
				const value = readEdgeRef(
					def as unknown as Record<string, unknown>,
					edge,
				);
				if (typeof value !== "string") continue;
				consider(edge.target, value);
			}
		}
	}

	// 4. Cache the earliest event t for paste-at-playhead offset.
	let minT = 0;
	if (events.length > 0) {
		minT = Infinity;
		for (const ev of events) if (ev.t < minT) minT = ev.t;
	}

	return { entities, events, externalRefs, minT };
}
