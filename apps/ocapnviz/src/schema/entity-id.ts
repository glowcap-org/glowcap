/**
 * The ids a peer, session, or message may carry.
 *
 * A document keeps each kind's definitions in a plain record keyed by id, and
 * `__proto__` is the one key such a record cannot hold: assigning it replaces
 * the record's prototype, and parsing a record drops it. An id is accepted
 * exactly or refused, so this one is refused at every door an id enters by:
 * the schema below, the authoring intents that name an entity, and the live
 * feed.
 */

import { z } from "zod";

const RESERVED_ENTITY_ID = "__proto__";

/** Whether `id` is the one id no entity may carry. */
export function isReservedEntityId(id: string): boolean {
	return id === RESERVED_ENTITY_ID;
}

/** The sentence that names a refused id. */
export function reservedEntityIdMessage(id: string): string {
	return `The id "${id}" is reserved and cannot name a peer, session, or message.`;
}

/** A peer, session, or message id: non-empty and not reserved. */
export const EntityId = z.string().min(1).refine((id) => !isReservedEntityId(id), {
	message: reservedEntityIdMessage(RESERVED_ENTITY_ID),
});

/** A record of definitions keyed by entity id. Zod drops a `__proto__` key
 *  from a record before it checks any key, so the refusal reads the input. */
export function entityRecord<V extends z.ZodType>(definition: V) {
	return z.preprocess((input, ctx) => {
		if (typeof input === "object" && input !== null && Object.hasOwn(input, RESERVED_ENTITY_ID)) {
			ctx.issues.push({
				code: "custom",
				message: reservedEntityIdMessage(RESERVED_ENTITY_ID),
				input,
			});
		}
		return input;
	}, z.record(EntityId, definition));
}
