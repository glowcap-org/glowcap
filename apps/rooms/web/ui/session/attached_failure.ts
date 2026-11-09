// The application owns session-opening advice. Preserve unknown thrown text.
// A break in the transport on the way names what the dial went through,
// because that is the cause a person can do something about: the Rooms server
// when this browser has one, since every dial passes it, and otherwise the
// relay door of the link being attached, which this browser opened by itself.
// `server` is the one in use, or null on a static page that chose none, and
// `link` is the capability being attached, when the act has one.
import { attachmentFailureAdvice, capabilityDoors } from "../application.ts";
import { doorUnreachable, failureView, renderFailure, transportBreak } from "../../../lib/text/failure.ts";
import { sessionServerUnreachable } from "../../../lib/text/session.ts";

export function attachedSessionFailureText(
	error: unknown,
	server: { readonly base: string } | null,
	link: string | null = null,
): string {
	const broke = transportBreak(error);
	if (broke !== null && server != null) return sessionServerUnreachable(new URL(server.base).host, broke);
	if (broke !== null && link != null) {
		const relay = capabilityDoors(link)?.relay;
		if (relay != null) return doorUnreachable("session", relay.host, broke);
	}
	const fallback = failureView(error);
	const advice = attachmentFailureAdvice(fallback.detail);
	return advice === null ? renderFailure(fallback) : renderFailure({ ...advice, detail: fallback.detail });
}
