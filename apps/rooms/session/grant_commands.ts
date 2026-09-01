// CapTP command admission for administering a session's durable access links.
//
// Issuing one, changing what it carries, and taking it back for good are one
// subject: they are the three things an administrator does to a link, and each
// answers with the grant as the ledger now holds it rather than with what the
// caller asked for.

import { type Argument, type Behavior, type Session } from "@pancake/runtime";
import {
	ROOMS_SESSION_ISSUE_GRANT,
	ROOMS_SESSION_REVOKE_GRANT,
	ROOMS_SESSION_SET_GRANT_POLICY,
	type RoomsSessionAccess,
} from "../lib/session/client.ts";
import type { RoomsSessionGrantAuthority } from "./grants.ts";

export const GRANT_COMMAND_UNHANDLED = Symbol("grant verb not handled");

export interface GrantCommandOwner {
	readonly grants: RoomsSessionGrantAuthority;
	/** Tell whoever is holding this link that what it carries has changed. */
	reproject(id: string): void;
}

export function dispatchGrantCommand(
	rights: RoomsSessionAccess,
	verb: string,
	args: Argument[],
	session: Session,
	owner: GrantCommandOwner,
): ReturnType<Behavior> | typeof GRANT_COMMAND_UNHANDLED {
	if (
		verb !== ROOMS_SESSION_ISSUE_GRANT && verb !== ROOMS_SESSION_SET_GRANT_POLICY &&
		verb !== ROOMS_SESSION_REVOKE_GRANT
	) return GRANT_COMMAND_UNHANDLED;
	if (verb === ROOMS_SESSION_ISSUE_GRANT) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot issue durable grants");
		if (
			args.length !== 4 || typeof args[0] !== "string" ||
			(args[1] !== "observe" && args[1] !== "interact" && args[1] !== "admin") ||
			typeof args[2] !== "string" || typeof args[3] !== "boolean"
		) throw new Error("issueGrant takes an id, rights, a label, and whether it may read earlier messages");
		// The whole view, not just the link: a grant answers for its access,
		// its history, and whether it is suspended, and a caller that
		// rebuilt those from what it asked for would be describing its
		// request rather than the grant.
		return owner.grants.issue(args[0], args[1], args[2], args[3], session).then((grant) =>
			JSON.stringify(grant)
		) as ReturnType<Behavior>;
	}
	if (verb === ROOMS_SESSION_SET_GRANT_POLICY) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot administer durable grants");
		if (
			args.length !== 5 || typeof args[0] !== "string" ||
			(args[1] !== null && args[1] !== "observe" && args[1] !== "interact" && args[1] !== "admin") ||
			(args[2] !== null && typeof args[2] !== "boolean") ||
			(args[3] !== null && typeof args[3] !== "boolean") ||
			(args[4] !== null && typeof args[4] !== "string")
		) throw new Error("setGrantPolicy takes an id, rights, history, suspended, and a note");
		return owner.grants.setPolicy(args[0], {
			rights: args[1],
			history: args[2],
			suspended: args[3],
			note: args[4],
		}, session).then((grant) => {
			// Whoever is holding this link right now is the reason to change
			// it, so they are told before the caller is answered.
			owner.reproject(args[0] as string);
			return JSON.stringify(grant);
		}) as ReturnType<Behavior>;
	}
	if (verb === ROOMS_SESSION_REVOKE_GRANT) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot revoke durable grants");
		if (args.length !== 1 || typeof args[0] !== "string") throw new Error("revokeGrant takes one grant id");
		return owner.grants.revoke(args[0]).then(() => null) as ReturnType<Behavior>;
	}
	return GRANT_COMMAND_UNHANDLED;
}
