// The Session tab: who keeps this workspace, whether messages are retained, and
// the explicit moves that replace or export that data owner.
//
// Independently held session management remains available to local owners and
// observers. Archive peers, room authority and operations live under Holdings.
//
// Attaching a session and replacing stored state open cards of their own. A
// bearer link needs a line to itself and a sentence about what it hands over.
// Operations needing a decision are promoted by the persistent notice, which
// Settings covers, and retained receipts the notice does not count stay
// reachable here, so the unfinished-changes list is offered while it has rows.

import { useState } from "react";
import type { ArchiveTargetView } from "../archive_model.ts";
import { useRoomsController } from "../controller/browser.ts";
import { CopyField } from "../Copy.tsx";
import { EntryAct, EntryActs } from "../EntryAct.tsx";
import { useSessionPaused } from "../hooks.ts";
import { Icon } from "../icons.tsx";
import { useOpenModal } from "../modal.ts";
import { HistorySettings } from "./History.tsx";
import { SessionDataModal } from "./SessionData.tsx";
import { SessionMoves } from "./SessionMoves.tsx";
import { SessionAccessModal } from "./SessionAccess.tsx";
import { SessionRecoveryModal } from "../panes/SessionRecovery.tsx";
import { useManagedSession } from "../session/managed/context.tsx";
import { useOpenChanges } from "../session/managed/open_changes.ts";
import { useSessionPermission } from "../hooks.ts";
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
	sessionAccessAct,
	sessionAccessName,
	sessionChangesAct,
	sessionChangesName,
	sessionDataName,
} from "../../../lib/text/session_settings.ts";

export function SessionSettings(
	{ keepHistory, archiveTarget }: { keepHistory: boolean; archiveTarget: ArchiveTargetView },
) {
	const openModalFrom = useOpenModal();
	const canInteract = useSessionPermission("interactWorkspace");
	const canReplace = useSessionPermission("replaceWorkspace");
	const canManageCustody = useSessionPermission("manageCustody");
	const paused = useSessionPaused();
	const controller = useRoomsController();
	const hosting = controller.kind === "hosted";
	const shared = sharedRoomsSession(controller);
	const sharedSession = shared != null;
	const canAdminister = canReplace && canManageCustody;
	const [dataOpen, setDataOpen] = useState(false);
	const [accessOpen, setAccessOpen] = useState(false);
	const [recoveryOpen, setRecoveryOpen] = useState(false);
	const canResolve = useSessionPermission("resolvePending");
	// The list's own rows decide whether it is offered, and a read that failed
	// is offered too, so the card can say what it could not read.
	const session = useManagedSession();
	const open = useOpenChanges(session, canResolve);
	const unfinished = open.changes.length > 0 || open.failure !== "";
	// Read only is what the last arm here means, so a capability carrying nothing
	// has to be answered before it. While paused, this said the link was read
	// only, its future state rather than its present one.
	const accessSaid = paused
		? currentSessionPaused
		: canAdminister
		? currentSessionAdmin
		: canInteract
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
				<EntryActs busy={canResolve && open.rows == null && open.failure === ""}>
					{canResolve && unfinished && (
						<EntryAct
							name={sessionChangesName}
							id="sessionChangesOpen"
							act={sessionChangesAct}
							onClick={(event) => openModalFrom(event.currentTarget, () => setRecoveryOpen(true))}
						/>
					)}
					<EntryAct
						name={sessionAccessName}
						id="sessionAccessOpen"
						act={sessionAccessAct}
						onClick={(event) => openModalFrom(event.currentTarget, () => setAccessOpen(true))}
					/>
					<EntryAct
						name={sessionDataName}
						id="sessionDataOpen"
						act={canAdminister ? currentSessionExportOrReset : currentSessionExport}
						onClick={(event) => openModalFrom(event.currentTarget, () => setDataOpen(true))}
					/>
				</EntryActs>
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
			<SessionAccessModal open={accessOpen} onClose={() => setAccessOpen(false)} />
			<SessionRecoveryModal open={recoveryOpen} onClose={() => setRecoveryOpen(false)} dismissWhenEmpty={false} />
			<SessionDataModal
				open={dataOpen}
				sharedSession={sharedSession}
				canAdminister={canAdminister}
				onClose={() => setDataOpen(false)}
			/>
		</>
	);
}
