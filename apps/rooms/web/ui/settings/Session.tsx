// The Data tab: where the things this session keeps are kept, and who else
// can reach them.
//
// Two subjects, in the same shape, because a reader arrives with one question
// in two halves. Rooms and settings are kept by this browser or by a session
// peer; messages are kept by this browser or by an archive peer. Each says
// which in a sentence, then offers the acts that change it at its foot.
//
// The acts that take a pasted capability — attaching a session, choosing an
// archive peer, issuing access, replacing the stored state — open cards of
// their own. A bearer link needs a line to itself and a sentence about what it
// hands over, and four such forms stacked on one tab is a wall rather than an
// answer. Anything unfinished comes first, above both subjects, because it is
// the only thing here that is waiting on the reader.

import { useState } from "react";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { CopyField } from "../Copy.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import { useRoomsState } from "../hooks.ts";
import { Icon } from "../icons.tsx";
import { openModalFrom } from "../modal.ts";
import { HistorySettings } from "./History.tsx";
import { SessionAccessModal } from "./SessionAccess.tsx";
import { SessionDataModal } from "./SessionData.tsx";
import { SessionMoves } from "./SessionMoves.tsx";
import { effectiveRoomsSessionAccess } from "../controller/access.ts";

export function SessionSettings(
	{ keepHistory, archiveTarget }: { keepHistory: boolean; archiveTarget: ArchiveTargetView },
) {
	const browser = useRoomsBrowser();
	const sessionAccess = useRoomsState((state) => state.sessionAccess);
	const grants = useRoomsState((state) => state.sessionGrants);
	const controller = browser.roomsController();
	const sharedSession = controller.kind === "attached";
	const canAdminister = effectiveRoomsSessionAccess(controller, sessionAccess) === "admin";
	const [dataOpen, setDataOpen] = useState(false);
	const [accessOpen, setAccessOpen] = useState(false);
	const accessSaid = sessionAccess === "admin"
		? "This capability can administer it."
		: sessionAccess === "interact"
		? "This capability can interact with it."
		: "This capability is read only.";
	return (
		<>
			<SessionRecovery sharedSession={sharedSession} />
			<h3 className="well-title overline" id="currentSessionLegend">Rooms and settings</h3>
			<div className="group well" role="group" aria-labelledby="currentSessionLegend">
				<div className="launch">
					<span className="launch-mark" aria-hidden="true">
						<Icon name="session" size={18} />
					</span>
					<div className="launch-copy">
						<p className="launch-title">
							<span>{sharedSession ? "Attached session" : "Local session"}</span>
							<span className="tag">{sharedSession ? "Session capability" : "This browser"}</span>
						</p>
						<p className="hint">
							{sharedSession
								? `A durable session peer keeps this workspace, so every browser attached to it sees the same rooms and settings. ${accessSaid}`
								: "This browser keeps this workspace. Its rooms and settings stay on this device."}
						</p>
					</div>
				</div>
				{sharedSession && controller.kind === "attached" && (
					<>
						<p className="field-label">Attached capability</p>
						<CopyField
							compact
							id="currentSessionCapability"
							text={controller.sturdyref}
							label="Copy the attached session capability"
						/>
						<p className="hint">
							Anyone who has this link gets the same access to this session. Hand it only to people who
							should have it.
						</p>
					</>
				)}
				{sharedSession && canAdminister && (
					<p className="hint" id="sessionGrantCount">
						{grants.length === 0
							? "No separately revocable access has been issued."
							: `${grants.length} ${
								grants.length === 1 ? "grant" : "grants"
							} can attach to this session.`}
					</p>
				)}
				<div className="actions" data-stack-narrow>
					{sharedSession && canAdminister && (
						<Button
							id="sessionAccessOpen"
							type="button"
							variant="quiet"
							onClick={(event) => openModalFrom(event.currentTarget, () => setAccessOpen(true))}
						>
							Manage access…
						</Button>
					)}
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
					sharedSession={sharedSession}
				/>
			)}
			<SessionMoves sharedSession={sharedSession} />
			<SessionDataModal
				open={dataOpen}
				sharedSession={sharedSession}
				canAdminister={canAdminister}
				onClose={() => setDataOpen(false)}
			/>
			<SessionAccessModal open={accessOpen} onClose={() => setAccessOpen(false)} />
		</>
	);
}

/** Operations that reached a durable boundary without a final answer. Nothing
 * here is routine, so it stands above the tab's own subjects while it exists
 * and disappears entirely when it does not. */
function SessionRecovery({ sharedSession }: { sharedSession: boolean }) {
	const session = useRoomsSession();
	const effects = useRoomsState((state) => state.sessionEffects);
	const [busy, setBusy] = useState<string | null>(null);
	const [why, setWhy] = useState<Readonly<Record<string, string>>>({});
	const [confirming, setConfirming] = useState<{ id: string; outcome: "committed" | "abandoned" } | null>(null);
	if (!sharedSession || effects.length === 0) return null;
	const act = async (id: string, request: () => Promise<string>) => {
		setBusy(id);
		setWhy((prior) => ({ ...prior, [id]: "" }));
		try {
			const refused = await request();
			if (refused !== "") setWhy((prior) => ({ ...prior, [id]: refused }));
			else setConfirming(null);
		} finally {
			setBusy(null);
		}
	};
	return (
		<>
			<h3 className="well-title overline" id="sessionRecoveryLegend">Waiting on you</h3>
			<div className="group well" role="group" aria-labelledby="sessionRecoveryLegend">
				<p className="hint">
					These operations reached a durable boundary without a final answer. Resume one that has a recovery
					path, or explicitly settle an ambiguous external effect.
				</p>
				<ul className="entries" id="sessionRecoveryList">
					{effects.map((effect) => (
						<li className="entry" key={effect.id} data-phase={effect.phase}>
							<div className="entry-head">
								<span className="entry-name">{effect.subject}</span>
								<span className="entry-meta">{effect.phase}</span>
								<div className="actions">
									{(effect.kind === "external" || effect.phase === "prepared") && (
										<Button
											variant="quiet"
											onClick={() => setConfirming({ id: effect.id, outcome: "abandoned" })}
										>
											Abandon…
										</Button>
									)}
									{effect.kind === "external" && (
										<Button
											variant="quiet"
											onClick={() => setConfirming({ id: effect.id, outcome: "committed" })}
										>
											Mark completed…
										</Button>
									)}
									{effect.kind !== "external" && (
										<Button
											busy={busy === effect.id}
											onClick={() =>
												void act(effect.id, () => session.resumeSessionEffect(effect.id))}
										>
											Resume
										</Button>
									)}
								</div>
							</div>
							{confirming?.id === effect.id && (
								<Confirm
									label="Resolve session operation"
									tone={confirming.outcome === "committed" ? "primary" : "danger"}
									say={confirming.outcome === "committed"
										? "Use this only when the external effect is known to have completed. The session will not perform it again."
										: "The session will record that this operation must not be resumed. Any external effect that happened is left as it stands."}
									keep="Keep it"
									commit={confirming.outcome === "committed" ? "Mark completed" : "Abandon operation"}
									busy={busy === effect.id}
									onKeep={() => setConfirming(null)}
									onCommit={() =>
										void act(
											effect.id,
											() => session.resolveSessionEffect(effect.id, confirming.outcome),
										)}
								/>
							)}
							{why[effect.id] !== "" && why[effect.id] != null && (
								<Said kind="failure">{why[effect.id]}</Said>
							)}
						</li>
					))}
				</ul>
			</div>
		</>
	);
}
