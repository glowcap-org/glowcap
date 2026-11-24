// What a browser is told, for as long as it is true, while the shared session
// it shows cannot be reached. The page dials again by itself, so while it
// reconnects the notice asks nothing. An offline device, or a session the page
// keeps failing to reach, offers Try now. A session that refused the link says
// why, and offers Try now when its answer may change. Only a failure inside
// the page, which dialing again would repeat, offers a reload.

import { useSyncExternalStore } from "react";
import { Button } from "../Button.tsx";
import { reloadPage } from "../page_base.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import type { LinkNotice } from "../session/managed/link.ts";
import { failureView, renderFailure, tryNowCanHelp } from "../../../lib/text/failure.ts";
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
	const { said, offer } = told(notice, link.cause);
	return (
		<div className="session-effect-notice session-link-notice" role="status" aria-live="polite">
			<p>{said}</p>
			{offer === "tryNow" && (
				<Button
					id="sessionTryNow"
					variant="quiet"
					onClick={() => link.tryNow()}
				>
					{sessionTryNow}
				</Button>
			)}
			{offer === "reload" && (
				<Button id="sessionReload" variant="quiet" onClick={reloadPage}>
					{sessionReload}
				</Button>
			)}
		</div>
	);
}

/** What the notice says while `cause` keeps the session away, and the one
 * button it offers, or null when no button can help and its copy names the
 * step. */
export function told(notice: LinkNotice, cause: unknown): { said: string; offer: "tryNow" | "reload" | null } {
	switch (notice) {
		case "reconnecting":
			return { said: sessionReconnecting, offer: null };
		case "offline":
			return { said: sessionOffline, offer: "tryNow" };
		case "stuck":
			return { said: sessionStuck, offer: "tryNow" };
		case "failed":
			// A failure inside the page offers only a reload, so its own advice goes.
			return { said: renderFailure({ ...failureView(cause), action: null }), offer: "reload" };
		case "refused": {
			const refusal = failureView(cause);
			return { said: renderFailure(refusal), offer: tryNowCanHelp(refusal) ? "tryNow" : null };
		}
	}
}
