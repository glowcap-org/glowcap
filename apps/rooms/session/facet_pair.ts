// Transactional creation of an ephemeral Rooms facet and its revoker.

import { type Behavior, Ref, type Session } from "@pancake/runtime";
import { throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";

export function spawnFacetPair(session: Session, facet: Behavior, revoker: Behavior): [Ref, Ref] {
	const delegated = session.spawn(facet);
	try {
		return [delegated, session.spawn(revoker)];
	} catch (error) {
		throwAfterReleasingCapabilities(session, [delegated], error);
	}
}
