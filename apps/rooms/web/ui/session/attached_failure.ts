// The application owns session-opening advice. Preserve unknown thrown text.
// A break in the transport on the way names the server the dial went
// through, because that is the address a person can check: the Rooms server
// when this browser has one, since every dial passes it, and otherwise the
// relay door of the link being attached, which this browser opened by itself.
// `server` is the one in use, or null on a static page that chose none, and
// `link` is the capability being attached, when the act has one.
import { capabilityDoors } from "../application.ts";
import {
	doorUnreachable,
	type FailureNames,
	failureView,
	namedFailure,
	renderFailure,
	transportBreak,
} from "../../../lib/text/failure.ts";

/** An attach reaches for a session. */
const ATTACHING: FailureNames = new Map([
	["peer-unreachable", "session-unreachable"],
	["member-unreachable", "session-unreachable"],
]);

export function attachedSessionFailureText(
	error: unknown,
	server: { readonly base: string } | null,
	link: string | null = null,
): string {
	const broke = transportBreak(error);
	if (broke !== null) {
		const through = server != null
			? new URL(server.base).host
			: link == null
			? null
			: capabilityDoors(link)?.relay?.host ?? null;
		if (through != null) return doorUnreachable("session", through, broke);
	}
	return renderFailure(namedFailure(failureView(error), ATTACHING));
}
