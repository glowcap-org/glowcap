// What a browser is told while the shared session it shows cannot be reached.
//
// Losing the session is a standing fact about the page, like a pause. Each
// control that needs the session reports its own failure when it is used, and
// none of them says what they have in common. This says it once, for as long
// as it is true. The page dials the session again by itself, so the one act it
// offers is to try now. Only a failure inside the page, which dialing again
// would repeat, offers a reload.

import { useSyncExternalStore } from "react";
import { Button } from "../Button.tsx";
import { reloadPage } from "../page_base.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import {
	sessionOffline,
	sessionReconnecting,
	sessionReload,
	sessionStuck,
	sessionTryNow,
} from "../../../lib/text/page.ts";

export function SessionLinkNotice() {
	const session = useManagedSession();
	const link = session.link;
	const notice = useSyncExternalStore(session.subscribe, () => link?.notice ?? null);
	if (link == null || notice == null) return null;
	const said = notice === "reconnecting"
		? sessionReconnecting
		: notice === "offline"
		? sessionOffline
		: notice === "stuck"
		? sessionStuck
		: refusalText(link.cause);
	return (
		<div className="session-effect-notice session-link-notice" role="status" aria-live="polite">
			<p>{said}</p>
			{(notice === "stuck" || notice === "offline") && (
				<Button
					id="sessionTryNow"
					variant="quiet"
					onClick={() => link.tryNow()}
				>
					{sessionTryNow}
				</Button>
			)}
			{notice === "failed" && (
				<Button id="sessionReload" variant="quiet" onClick={reloadPage}>
					{sessionReload}
				</Button>
			)}
		</div>
	);
}
