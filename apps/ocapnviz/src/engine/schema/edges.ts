/**
 * The reference graph of the doc, expressed as compile-time-checked
 * edge maps. Two classes are covered here:
 *
 *   - `EVENT_EDGES`: for each event kind, the fields that hold ids
 *     pointing at an entity. Class 1 in the design doc.
 *
 *   - `ENTITY_EDGES`: for each entity kind in `doc.entities`, the
 *     definition fields that hold ids pointing at another entity.
 *     Class 2 in the design doc.
 *
 * Class 3 (doc-level id-list indexes) lives in `doc-index.ts` because
 * it has a different shape and a different exhaustiveness story.
 *
 * The cascade operations in `cascade.ts` iterate these maps to find
 * every reference site of a target entity, then applies the
 * per-intent policy at each site. No other code in the engine should
 * encode "which fields reference what". If it does, it has gone
 * around the schema and will rot.
 *
 * Compile-time guarantees:
 *
 *   - `EVENT_EDGES` is a mapped type keyed by every variant of
 *     `TimelineEvent`. Adding a new event kind without declaring its
 *     ref fields here is a compile error.
 *
 *   - Each field name listed must actually be a required key on the
 *     variant. Typos and references to optional fields are compile
 *     errors. (Optional refs are forbidden by invariant 2 in the
 *     design doc, if the schema ever grows one, this constraint
 *     surfaces the design question.)
 *
 * See `docs/schema-driven-transactions.md`.
 */

import type { MessageDefinition, PeerDefinition, SessionDefinition, TimelineEvent } from "../timeline.ts";
import type { EntityKind } from "./refs.ts";

/** Keys of `T` whose value type cannot be `undefined`. Used to forbid status-allow: purpose clause
 * optional refs from appearing in the edge maps. Every declared ref
 * must always be present on its variant. */
type RequiredKeys<T> = {
	[K in keyof T]-?: undefined extends T[K] ? never : K;
}[keyof T];

/** A single ref site on an event variant: which field, pointing at
 * which entity kind. */
export type EventEdgeSpec<K extends TimelineEvent["kind"]> = {
	readonly field: RequiredKeys<Extract<TimelineEvent, { kind: K }>>;
	readonly target: EntityKind;
	/** Where inside the field the id sits, when the field is a structure
	 *  rather than the id itself. A session's end is an endpoint, and the peer
	 *  it is attached to is one property of it. So the reference is at
	 *  `a.peer`, not at `a`. Declaring that here keeps this table the one
	 *  place that knows where references live. The walker, the rewriter, and
	 *  the extractor all read through `readEdgeRef`. */
	readonly nested?: string;
};

/** Per-kind ref declarations. Mapped over every variant so omissions
 * are compile errors. Empty arrays are valid (no refs to declare). */
export type EventEdges = {
	readonly [K in TimelineEvent["kind"]]: ReadonlyArray<EventEdgeSpec<K>>;
};

export const EVENT_EDGES: EventEdges = {
	"peer-joined": [
		{ field: "peerId", target: "peer" },
	],
	"peer-updated": [
		{ field: "peerId", target: "peer" },
	],
	"peer-unobserved": [
		{ field: "peerId", target: "peer" },
	],
	"peer-left": [
		{ field: "peerId", target: "peer" },
	],
	"session-opened": [
		{ field: "sessionId", target: "session" },
		{ field: "a", target: "peer", nested: "peer" },
		{ field: "b", target: "peer", nested: "peer" },
	],
	"session-state-changed": [
		{ field: "sessionId", target: "session" },
	],
	"session-endpoint-attributed": [
		{ field: "sessionId", target: "session" },
		{ field: "peerId", target: "peer" },
	],
	"session-unobserved": [
		{ field: "sessionId", target: "session" },
	],
	"session-closed": [
		{ field: "sessionId", target: "session" },
	],
	"message-sent": [
		{ field: "messageId", target: "message" },
		{ field: "sessionId", target: "session" },
		{ field: "from", target: "peer" },
		{ field: "to", target: "peer" },
	],
	"message-delivered": [
		{ field: "messageId", target: "message" },
	],
};

/** Definition shapes living under `doc.entities.{peers,sessions,messages}`,
 * taken from `timeline.ts` itself. A type-only import costs no runtime
 * dependency on zod, and a second declaration of the same shape is a copy
 * that drifts: this table's whole job is to be checked against the real
 * fields, and the copy it replaces still called a session's ends `string`
 * after they had become endpoint structures. */
type EntityDefByKind = {
	peer: PeerDefinition;
	session: SessionDefinition;
	message: MessageDefinition;
};

/** A single ref site on an entity definition. */
export type EntityEdgeSpec<K extends EntityKind> = {
	readonly field: RequiredKeys<EntityDefByKind[K]>;
	readonly target: EntityKind;
	/** See `EventEdgeSpec.nested`: where inside the field the id sits, when
	 *  the field is a structure rather than the id itself. */
	readonly nested?: string;
};

/** Per-entity-kind ref declarations. Same exhaustiveness contract as
 * `EventEdges`. */
export type EntityEdges = {
	readonly [K in EntityKind]: ReadonlyArray<EntityEdgeSpec<K>>;
};

export const ENTITY_EDGES: EntityEdges = {
	peer: [],
	session: [
		{ field: "a", target: "peer", nested: "peer" },
		{ field: "b", target: "peer", nested: "peer" },
	],
	message: [
		{ field: "sessionId", target: "session" },
		{ field: "from", target: "peer" },
		{ field: "to", target: "peer" },
	],
};

/** The id an edge points at, wherever that edge keeps it.
 *
 * An edge whose field IS the id reads the field. An edge that declares
 * `nested` reaches one level in. Every walker, rewriter, and extractor asks
 * here, so a reference that moves inside a structure moves in the table and
 * nowhere else. */
export function readEdgeRef(
	container: Record<string, unknown>,
	edge: { readonly field: unknown; readonly nested?: string },
): unknown {
	const value = container[edge.field as string];
	if (edge.nested === undefined) return value;
	return typeof value === "object" && value !== null ? (value as Record<string, unknown>)[edge.nested] : undefined;
}

/** Point `container`'s edge at `id`, in place, preserving whatever else the
 *  field's structure carries. An endpoint keeps its claim and what
 *  attributed it when the peer it names is rewritten. */
export function writeEdgeRef(
	container: Record<string, unknown>,
	edge: { readonly field: unknown; readonly nested?: string },
	id: unknown,
): void {
	const field = edge.field as string;
	if (edge.nested === undefined) {
		container[field] = id;
		return;
	}
	const current = container[field];
	const base = typeof current === "object" && current !== null ? current as Record<string, unknown> : {};
	container[field] = { ...base, [edge.nested]: id };
}
