// Capability-argument admission for durable Rooms session facets.

import { type Argument, Ref, type Session } from "@pancake/runtime";
import { hasCapabilityArguments, refuseCapabilityArguments } from "../lib/argument_custody.ts";
import { ROOMS_SESSION_FILES, ROOMS_SESSION_REFILE, ROOMS_SESSION_WATCH } from "../lib/session/client.ts";

/** Only these three verbs transfer capabilities into a durable session. Every
 * other verb is scalar/JSON protocol and returns any injected occurrences. */
export function admitSessionFacetArguments(session: Session, verb: string, args: Argument[]): void {
	if (verb === ROOMS_SESSION_WATCH || verb === ROOMS_SESSION_FILES || verb === ROOMS_SESSION_REFILE) return;
	if (hasCapabilityArguments(args)) {
		refuseCapabilityArguments(session, args, `${verb} does not take capability arguments`);
	}
}

export function takeSessionObserver(session: Session, args: Argument[]): Ref {
	if (args.length !== 1 || !(args[0] instanceof Ref)) {
		refuseCapabilityArguments(session, args, "session watch takes one observer");
	}
	return args[0];
}
