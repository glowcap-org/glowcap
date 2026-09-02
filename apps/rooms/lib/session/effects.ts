// An external operation a session is waiting on: settling one, or picking it up
// again after the browser that started it went away.
//
// These are the two verbs that answer for work the session cannot finish by
// itself, so they read the same way and are kept together.

import type { Ref, Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { sessionRevision } from "./revision.ts";
import { ROOMS_SESSION_RESOLVE_EFFECT, ROOMS_SESSION_RESUME_EFFECT } from "./verbs.ts";

export async function resolveRoomsSessionEffect(
	session: Session,
	capability: Ref,
	operationId: string,
	outcome: "committed" | "abandoned",
): Promise<void> {
	await ask(
		session,
		capability,
		ROOMS_SESSION_RESOLVE_EFFECT,
		[operationId, outcome],
		"the Rooms session did not resolve the external effect",
	);
}

export async function resumeRoomsSessionEffect(
	session: Session,
	capability: Ref,
	operationId: string,
): Promise<number> {
	const raw = await ask(
		session,
		capability,
		ROOMS_SESSION_RESUME_EFFECT,
		[operationId],
		"the Rooms session did not resume the external effect",
	);
	return sessionRevision(raw, "resumed-effect");
}
