import { managedSessionText as managedText } from "../../../lib/text/managed_session.ts";
// What a browser is told while its access to a shared session is paused.
//
// A pause is a standing fact about the link, not an event that happened once. A
// toast is the wrong instrument for it twice over: a reader who looked away
// misses it, and a reader who arrives afterwards (a reload, a new tab, a
// browser opened tomorrow) is never told at all, because there was no event to
// deliver. What they get instead is a workspace with nothing in it and no
// account of why, which is the shape of a broken application rather than a
// paused one.
//
// So this says it for as long as it is true, and it is the only surface that
// says why. The lists, the roster, and the card the page falls back to each say
// which emptiness theirs is and leave the reason here, so a page in this state
// explains itself once.

import { useRoomsState, useSessionPaused } from "../hooks.ts";
import { sessionPausedSaid } from "../../../lib/text/page.ts";

export function SessionPausedNotice() {
	const paused = useSessionPaused();
	const status = useRoomsState((state) => state.managedAccess.status);
	if (!paused) return null;
	return (
		<div className="session-effect-notice session-paused-notice" role="status" aria-live="polite">
			<p>
				{status === "paused"
					? sessionPausedSaid
					: status === "revoked"
					? managedText.revoked
					: managedText.outOfScope}
			</p>
		</div>
	);
}
