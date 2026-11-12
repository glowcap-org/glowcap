/**
 * Typed access to the per-kind maps in `doc.entities`.
 *
 * `ENTITIES_KEY` names the key for a kind, but indexing `doc.entities`
 * with that union loses the per-key value type. These two functions do the
 * dispatch once, as a switch the compiler checks, so cascade, extract,
 * and paste read and replace a kind's map without a cast.
 */

import type { MessageDefinition, PeerDefinition, SessionDefinition, TimelineDocument } from "../timeline.ts";
import type { EntityKind } from "./refs.ts";

export type EntityDef = PeerDefinition | SessionDefinition | MessageDefinition;

/** The `peers` / `sessions` / `messages` maps of a doc or a clipboard
 *  payload, which share one shape. */
type EntityMaps = {
	readonly peers?: Readonly<Record<string, PeerDefinition>> | undefined;
	readonly sessions?: Readonly<Record<string, SessionDefinition>> | undefined;
	readonly messages?: Readonly<Record<string, MessageDefinition>> | undefined;
};

/** The map of definitions for `kind` in `entities`, or undefined when it
 *  holds none. */
export function entityMapIn(
	entities: EntityMaps | undefined,
	kind: EntityKind,
): Readonly<Record<string, EntityDef>> | undefined {
	switch (kind) {
		case "peer":
			return entities?.peers;
		case "session":
			return entities?.sessions;
		case "message":
			return entities?.messages;
	}
}

/** The map of definitions for `kind`, or undefined when the doc holds none. */
export function entityMapOf(
	doc: TimelineDocument,
	kind: EntityKind,
): Readonly<Record<string, EntityDef>> | undefined {
	return entityMapIn(doc.entities, kind);
}

/** Replace `kind`'s map with what `edit` returns. Returning the map it was
 *  given leaves the doc as it is; returning an empty map drops the key, and
 *  `entities` becomes undefined when no map is left. A doc with no map for
 *  `kind` is returned as is, without calling `edit`. Pure. */
export function editEntityMap(
	doc: TimelineDocument,
	kind: EntityKind,
	edit: <D extends object>(map: Record<string, D>) => Record<string, D>,
): TimelineDocument {
	const entities = doc.entities;
	if (entities === undefined) return doc;
	const next: NonNullable<TimelineDocument["entities"]> = { ...entities };
	switch (kind) {
		case "peer": {
			const map = entities.peers;
			if (map === undefined) return doc;
			const edited = edit(map);
			if (edited === map) return doc;
			if (Object.keys(edited).length > 0) next.peers = edited;
			else delete next.peers;
			break;
		}
		case "session": {
			const map = entities.sessions;
			if (map === undefined) return doc;
			const edited = edit(map);
			if (edited === map) return doc;
			if (Object.keys(edited).length > 0) next.sessions = edited;
			else delete next.sessions;
			break;
		}
		case "message": {
			const map = entities.messages;
			if (map === undefined) return doc;
			const edited = edit(map);
			if (edited === map) return doc;
			if (Object.keys(edited).length > 0) next.messages = edited;
			else delete next.messages;
			break;
		}
	}
	const hasAny = Object.values(next).some((v) => v !== undefined);
	return { ...doc, entities: hasAny ? next : undefined };
}
