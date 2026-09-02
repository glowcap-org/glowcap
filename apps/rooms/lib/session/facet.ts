// Minting a live attenuated facet of a session, and the way to take it back.
//
// Unlike a durable grant, this one lasts only as long as the connection that
// asked for it: there is no ledger row and no sturdyref, so nothing survives a
// restart and nothing has to be revoked afterwards to be safe.

import { Ref, type Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { ROOMS_SESSION_FACET, ROOMS_SESSION_REVOKE } from "./verbs.ts";
import type { RoomsSessionFacet } from "./grants.ts";

/** A live facet and the way to take it back. Generic in what the caller wraps
 * the facet in, so this module need not import the client it is a facet of —
 * which would import this one back. */
export interface RoomsSessionGrantOf<Client> {
	readonly session: Client;
	revoke(): Promise<void>;
}

export async function mintRoomsSessionFacet<Client>(
	session: Session,
	capability: Ref,
	rights: RoomsSessionFacet,
	client: (facet: Ref) => Client,
): Promise<RoomsSessionGrantOf<Client>> {
	const raw = await ask(
		session,
		capability,
		ROOMS_SESSION_FACET,
		[rights],
		"the Rooms session did not mint the requested facet",
	);
	if (!Array.isArray(raw) || raw.length !== 2 || !(raw[0] instanceof Ref) || !(raw[1] instanceof Ref)) {
		throw new Error("the Rooms session did not answer with a facet and revoker");
	}
	const facet = raw[0];
	const revoker = raw[1];
	return {
		session: client(facet),
		revoke: async () => {
			await ask(session, revoker, ROOMS_SESSION_REVOKE, [], "the Rooms session facet was not revoked");
		},
	};
}
