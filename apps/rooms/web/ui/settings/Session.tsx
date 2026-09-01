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
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsState, useSessionPaused } from "../hooks.ts";
import { Icon } from "../icons.tsx";
import { useOpenModal } from "../modal.ts";
import { HistorySettings } from "./History.tsx";
import { SessionDataModal } from "./SessionData.tsx";
import { SessionMoves } from "./SessionMoves.tsx";
import { effectiveRoomsSessionAccess } from "../controller/access.ts";
import { sharedRoomsSession } from "../../../lib/rooms_state.ts";

export function SessionSettings(
	{ keepHistory, archiveTarget }: { keepHistory: boolean; archiveTarget: ArchiveTargetView },
) {
	const openModalFrom = useOpenModal();
	const browser = useRoomsBrowser();
	const sessionAccess = useRoomsState((state) => state.sessionAccess);
	const paused = useSessionPaused();
	const controller = browser.roomsController();
	const hosting = controller.kind === "hosted";
	const sharedSession = sharedRoomsSession(controller) != null;
	const canAdminister = effectiveRoomsSessionAccess(controller, sessionAccess) === "admin";
	const [dataOpen, setDataOpen] = useState(false);
	// Read only is what the last arm here means, so a capability carrying nothing
	// has to be answered before it: paused, this said the link was read only,
	// which is what it will be again and is not what it is.
	const accessSaid = paused
		? "This capability is paused."
		: sessionAccess === "admin"
		? "This capability can administer it."
		: sessionAccess === "interact"
		? "This capability can interact with it."
		: "This capability is read only.";
	return (
		<>
			<h3 className="well-title overline" id="currentSessionLegend">Rooms and settings</h3>
			<div className="group well" role="group" aria-labelledby="currentSessionLegend">
				<div className="launch">
					<span className="launch-mark" aria-hidden="true">
						<Icon name="session" size={18} />
					</span>
					<div className="launch-copy">
						<p className="launch-title">
							<span>
								{hosting ? "Hosted session" : sharedSession ? "Attached session" : "Local session"}
							</span>
							<span className="tag">
								{hosting
									? "This browser is hosting"
									: sharedSession
									? "Session capability"
									: "This browser"}
							</span>
						</p>
						<p className="hint">
							{hosting
								? "This browser is hosting this session. Other browsers attach with a capability copied from Holdings. Closing or reloading this tab ends sharing."
								: sharedSession
								? `A durable session peer keeps this workspace, so every browser attached to it sees the same rooms and settings. ${accessSaid}`
								: "This browser keeps this workspace. Its rooms and settings stay on this device."}
						</p>
					</div>
				</div>
				<div className="actions" data-stack-narrow>
					<Button
						id="sessionDataOpen"
						type="button"
						variant="quiet"
						onClick={(event) => openModalFrom(event.currentTarget, () => setDataOpen(true))}
					>
						{canAdminister ? "Export or reset…" : "Export a copy…"}
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
