// The Session tab: who keeps this workspace, whether messages are retained, and
// the explicit moves that replace or export that data owner.
//
// Capability custody is deliberately absent: session access, archive peers,
// room authority, and operations capabilities live together under Holdings.
//
// Attaching a session and replacing stored state open cards of their own. A
// bearer link needs a line to itself and a sentence about what it hands over;
// durable operations waiting for a decision remain application work, surfaced
// by the persistent review notice rather than filed as a preference.

import { useState } from "react";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { useRoomsController } from "../controller/browser.ts";
import { CopyField } from "../Copy.tsx";
import { useRoomsState, useSessionPaused } from "../hooks.ts";
import { Icon } from "../icons.tsx";
import { useOpenModal } from "../modal.ts";
import { HistorySettings } from "./History.tsx";
import { SessionDataModal } from "./SessionData.tsx";
import { SessionMoves } from "./SessionMoves.tsx";
import { effectiveRoomsSessionAccess } from "../controller/access.ts";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";
import { sessionShareLinkCopy } from "../../../lib/text/settings.ts";
import {
	currentSessionAdmin,
	currentSessionAttached,
	currentSessionAttachedHint,
	currentSessionAttachedTag,
	currentSessionExport,
	currentSessionExportOrReset,
	currentSessionHosted,
	currentSessionHostedHint,
	currentSessionHostedTag,
	currentSessionInteract,
	currentSessionLocal,
	currentSessionLocalHint,
	currentSessionLocalTag,
	currentSessionObserve,
	currentSessionPaused,
	currentSessionTitle,
} from "../../../lib/text/session_settings.ts";

export function SessionSettings(
	{ keepHistory, archiveTarget }: { keepHistory: boolean; archiveTarget: ArchiveTargetView },
) {
	const openModalFrom = useOpenModal();
	const sessionAccess = useRoomsState((state) => state.sessionAccess);
	const paused = useSessionPaused();
	const controller = useRoomsController();
	const hosting = controller.kind === "hosted";
	const shared = sharedRoomsSession(controller);
	const sharedSession = shared != null;
	const canAdminister = effectiveRoomsSessionAccess(controller, sessionAccess) === "admin";
	const [dataOpen, setDataOpen] = useState(false);
	// Read only is what the last arm here means, so a capability carrying nothing
	// has to be answered before it. While paused, this said the link was read
	// only, its future state rather than its present one.
	const accessSaid = paused
		? currentSessionPaused
		: sessionAccess === "admin"
		? currentSessionAdmin
		: sessionAccess === "interact"
		? currentSessionInteract
		: currentSessionObserve;
	return (
		<>
			<h3 className="well-title overline" id="currentSessionLegend">{currentSessionTitle}</h3>
			<div className="group well" role="group" aria-labelledby="currentSessionLegend">
				<div className="launch">
					<span className="launch-mark" aria-hidden="true">
						<Icon name="session" size={18} />
					</span>
					<div className="launch-copy">
						<p className="launch-title">
							<span>
								{hosting
									? currentSessionHosted
									: sharedSession
									? currentSessionAttached
									: currentSessionLocal}
							</span>
							<span className="tag">
								{hosting
									? currentSessionHostedTag
									: sharedSession
									? currentSessionAttachedTag
									: currentSessionLocalTag}
							</span>
						</p>
						<p className="hint">
							{hosting
								? currentSessionHostedHint
								: sharedSession
								? currentSessionAttachedHint(accessSaid)
								: currentSessionLocalHint}
						</p>
					</div>
				</div>
				{
					/* The link is the point of sharing, so it belongs here where the
					   share was made, not only under Holdings with the rest of what
					   this session holds. */
				}
				{hosting && shared != null && (
					<CopyField
						id="hostedSessionLink"
						text={shared.sturdyref}
						label={sessionShareLinkCopy}
					/>
				)}
				<div className="actions" data-stack-narrow>
					<Button
						id="sessionDataOpen"
						type="button"
						variant="quiet"
						onClick={(event) => openModalFrom(event.currentTarget, () => setDataOpen(true))}
					>
						{canAdminister ? currentSessionExportOrReset : currentSessionExport}
					</Button>
				</div>
			</div>
			{
				/* Where messages live sits with where the session lives: one tab
				   answers "who keeps my things". A shared session's history is the
				   session's to change, so only an administering capability sees it. */
			}
			{(!sharedSession || canAdminister) && (
				<HistorySettings
					keepHistory={keepHistory}
					archiveTarget={archiveTarget}
				/>
			)}
			<SessionMoves sessionKind={controller.kind === "none" ? "local" : controller.kind} />
			<SessionDataModal
				open={dataOpen}
				sharedSession={sharedSession}
				canAdminister={canAdminister}
				onClose={() => setDataOpen(false)}
			/>
		</>
	);
}
