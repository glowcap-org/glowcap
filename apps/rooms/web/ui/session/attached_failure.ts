// The application owns session-opening advice. Preserve unknown thrown text.
// A break in the transport on the way names the Rooms server this browser
// goes through, because every dial passes it, so it is the cause a person can
// do something about. `server` is the one in use, or null on a static page
// that chose none.
import { attachmentFailureAdvice } from "../application.ts";
import { failureView, renderFailure, transportBreak } from "../../../lib/text/failure.ts";
import { sessionServerUnreachable } from "../../../lib/text/session.ts";

export function attachedSessionFailureText(error: unknown, server: { readonly base: string } | null): string {
	const broke = transportBreak(error);
	if (broke !== null && server != null) return sessionServerUnreachable(new URL(server.base).host, broke);
	const fallback = failureView(error);
	const advice = attachmentFailureAdvice(fallback.detail);
	return advice === null ? renderFailure(fallback) : renderFailure({ ...advice, detail: fallback.detail });
}
