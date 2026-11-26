// A blocked session keeps its reason visible until access changes. With no
// conversation open, its recovery step takes the place of the join form.
import { managedSessionText } from "../../../lib/text/managed_session.ts";
import { openSessionSettings, sessionAccessNext, sessionPausedSaid } from "../../../lib/text/page.ts";
import { Button } from "../Button.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsState } from "../hooks.ts";

export function SessionPausedNotice({ card = false }: { card?: boolean }) {
	const status = useRoomsState((state) => state.managedAccess.status);
	const browser = useRoomsBrowser();
	if (status === "active") return null;
	const reason = status === "paused" ? sessionPausedSaid : managedSessionText[status];
	if (card) {
		return (
			<div className="join-wrap">
				<section className="join session-paused-notice" aria-labelledby="sessionAccessReason">
					<div role="status">
						<h2 id="sessionAccessReason">{reason}</h2>
						<p className="lead">{sessionAccessNext[status]}</p>
					</div>
					<Button
						variant="quiet"
						onClick={() => {
							browser.setSettingsTab("session");
							browser.openSettings();
						}}
					>
						{openSessionSettings}
					</Button>
				</section>
			</div>
		);
	}
	return (
		<div className="session-effect-notice session-paused-notice" role="status">
			<p>{reason} {sessionAccessNext[status]}</p>
		</div>
	);
}
