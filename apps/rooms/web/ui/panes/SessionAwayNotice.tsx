// What a browser is told while the shared session it shows cannot be reached.
//
// Losing the session is a standing fact about the page, like a pause. Each
// control that needs the session reports its own failure when it is used, and
// none of them says what they have in common. This says it once, for as long
// as it is true, with the one act that brings the session back.

import { useSyncExternalStore } from "react";
import { Button } from "../Button.tsx";
import { reloadPage } from "../page_base.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { sessionAwayReload, sessionAwaySaid } from "../../../lib/text/page.ts";

export function SessionAwayNotice() {
	const session = useManagedSession();
	const away = useSyncExternalStore(session.subscribe, () => session.away);
	if (!away) return null;
	return (
		<div className="session-effect-notice session-away-notice" role="status" aria-live="polite">
			<p>{sessionAwaySaid}</p>
			<Button id="sessionAwayReload" variant="quiet" onClick={reloadPage}>
				{sessionAwayReload}
			</Button>
		</div>
	);
}
