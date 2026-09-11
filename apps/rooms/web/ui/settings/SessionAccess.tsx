// Who else may attach to this session: the durable grants an administering
// capability can issue, copy, and revoke, on a card of their own.
//
// The card is all this file owns. Holdings keeps its door; issuing one is a
// form with a name, an access level, and a
// bearer link to carry away, which is a card's worth of work rather than a
// row's.

import { useState } from "react";
import { MAX_SESSION_GRANT_LABEL } from "../limits.ts";
import type { RoomsSessionFacet } from "../../../lib/session/client.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { Confirm } from "../Confirm.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { useRoomsState } from "../hooks.ts";
import { useRoomsBrowser, useRoomsController } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import {
	ACCESS_DESCRIPTION,
	ACCESS_LABEL,
	ACCESS_LEVELS,
	ACCESS_TONE,
	HISTORY_LABEL,
	HISTORY_SAID,
	SessionGrantEditModal,
} from "./SessionGrantEdit.tsx";

export function SessionAccessModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const browser = useRoomsBrowser();
	const commitments = useCommitments();
	const session = useRoomsSession();
	const grants = useRoomsState((state) => state.sessionGrants);
	// Which of these links this browser is attached through, if it is attached
	// through one at all. An administering link lists itself, so revoking is
	// one press away from locking this browser out of the session it is
	// reading the list on. Matched on the capability text, which is what the
	// reader copied out of this very card, so a miss only costs the marker.
	const controller = useRoomsController();
	const held = sharedRoomsSession(controller)?.sturdyref ?? null;
	const [label, setLabel] = useState("");
	const [rights, setRights] = useState<RoomsSessionFacet>("interact");
	/** Not `history`: that is a global in a browser, and a link's reading of the
	 * past is not the page's own back and forward. */
	const [mayReadHistory, setMayReadHistory] = useState(false);
	const [operationId, setOperationId] = useState<string | null>(null);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState("");
	const [confirming, setConfirming] = useState<string | null>(null);
	const [revoking, setRevoking] = useState<string | null>(null);
	const [revokeWhy, setRevokeWhy] = useState<Readonly<Record<string, string>>>({});
	/** Which link is being edited on a card of its own, by id. */
	const [editing, setEditing] = useState<string | null>(null);
	/** Whether that card is up, kept apart from which link it is about. Clearing
	 * the link on close would take the card's subject away in the same frame the
	 * close was asked for, and it would vanish rather than leave the way every
	 * other card here leaves. */
	const [editorOpen, setEditorOpen] = useState(false);
	/** Bumped on each opening, so the card is a fresh one every time it is opened
	 * and never wears a half-typed reason from the last time. It is not bumped on
	 * closing, which is what keeps the card whole while it leaves. */
	const [editorOpening, setEditorOpening] = useState(0);
	const commit = useCommitSettling();
	useChangeGroup("settings-session-access", {
		dirty: label !== "" || rights !== "interact" || mayReadHistory,
		discard: () => {
			if (busy) throw new Error("Wait for the access link to finish being created.");
			setLabel("");
			setRights("interact");
			setMayReadHistory(false);
			setOperationId(null);
			setError("");
		},
		settling: commit.current,
	});
	const changeIntent = () => {
		setOperationId(null);
		setError("");
	};
	const issue = async () => {
		commit.begin();
		const id = operationId ?? crypto.randomUUID();
		setOperationId(id);
		setBusy(true);
		setError("");
		try {
			const why = await session.issueSessionGrant(id, rights, label, mayReadHistory);
			setError(why);
			if (why === "") {
				browser.toast("success", `Created ${ACCESS_LABEL[rights].toLowerCase()} access for ${label}.`);
				setLabel("");
				setRights("interact");
				setMayReadHistory(false);
				setOperationId(null);
			}
		} finally {
			setBusy(false);
			commit.finish();
		}
	};
	const revoke = async (id: string, name: string) => {
		setRevoking(id);
		setRevokeWhy((prior) => ({ ...prior, [id]: "" }));
		try {
			const why = await session.revokeSessionGrant(id);
			setRevokeWhy((prior) => ({ ...prior, [id]: why }));
			if (why === "") {
				setConfirming(null);
				browser.toast("success", `Revoked session access for ${name}.`);
			}
		} finally {
			setRevoking(null);
		}
	};
	return (
		<Submodal
			title="Session access"
			titleId="sessionAccessTitle"
			className="session-access-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: ["settings-session-access"] })}
		>
			<p className="lead">
				Create a separately revocable link for each person, device, or integration that shares this session.
			</p>
			<div className="session-access-columns">
				<section className="session-access-column">
					<h3 className="well-title overline" id="sessionGrantIssueTitle">New access link</h3>
					<form
						className="group well session-access-form"
						role="group"
						aria-labelledby="sessionGrantIssueTitle"
						onSubmit={(event) => {
							event.preventDefault();
							void issue();
						}}
					>
						<Field id="sessionGrantLabel" label="Who or what is this for?">
							{(wiring) => (
								<input
									id={wiring.id}
									className="field"
									value={label}
									maxLength={MAX_SESSION_GRANT_LABEL}
									disabled={busy}
									onChange={(event) => {
										setLabel(event.currentTarget.value);
										changeIntent();
									}}
									placeholder="Kitchen display"
								/>
							)}
						</Field>
						<div className="question">
							<p className="group-label" id="sessionGrantRightsLabel">Access</p>
							<div
								className="choices"
								role="radiogroup"
								aria-labelledby="sessionGrantRightsLabel"
							>
								{ACCESS_LEVELS.map((level) => (
									<label className="choice" key={level}>
										<input
											type="radio"
											name="sessionGrantRights"
											value={level}
											checked={rights === level}
											disabled={busy}
											onChange={() => {
												setRights(level);
												// The level suggests an answer to the question under it;
												// the box still decides. An administering link that cannot
												// read the session's own archive is an odd thing to hand
												// somebody, and before this question existed one always could.
												setMayReadHistory(level === "admin");
												changeIntent();
											}}
										/>
										<span>
											<strong>{ACCESS_LABEL[level]}</strong>
											{ACCESS_DESCRIPTION[level]}
										</span>
									</label>
								))}
							</div>
						</div>
						<label className="check-row">
							<Checkbox
								id="sessionGrantHistory"
								checked={mayReadHistory}
								disabled={busy}
								onChange={() => {
									setMayReadHistory(!mayReadHistory);
									changeIntent();
								}}
							/>
							<span>
								<strong>{HISTORY_LABEL}</strong>
								{HISTORY_SAID}
							</span>
						</label>
						{error !== "" && <Said kind="failure">{error}</Said>}
						<div className="actions">
							<Button type="submit" busy={busy} disabled={busy || label === ""}>
								Create access link
							</Button>
						</div>
					</form>
				</section>
				<section className="session-access-column">
					<h3 className="well-title overline" id="sessionGrantListTitle">Active access links</h3>
					<div className="group well" role="group" aria-labelledby="sessionGrantListTitle">
						{grants.length === 0
							? <p className="empty">Nobody holds a separate access link to this session yet.</p>
							: (
								<ul className="entries">
									{grants.map((grant) => {
										const inUse = grant.sturdyref === held;
										return (
											<li className="entry session-grant" key={grant.id}>
												<div className="entry-head" data-one-line>
													<span className="entry-name">{grant.label}</span>
													<span className="tag" data-tone={ACCESS_TONE[grant.rights]}>
														{ACCESS_LABEL[grant.rights]}
													</span>
													{inUse && <span className="tag">This browser</span>}
													{grant.suspended && (
														<span className="tag" data-tone="warn">Paused</span>
													)}
													{grant.history && (
														<span className="tag" data-tone="quiet">Earlier messages</span>
													)}
													{confirming !== grant.id && (
														<div className="actions session-grant-actions">
															<Button
																variant="quiet"
																onClick={() => {
																	setEditing(grant.id);
																	setEditorOpening((was) => was + 1);
																	setEditorOpen(true);
																}}
															>
																Edit…
															</Button>
															<Button
																variant="quiet"
																onClick={() => setConfirming(grant.id)}
															>
																Revoke…
															</Button>
														</div>
													)}
												</div>
												{confirming === grant.id && (
													<Confirm
														label={`Revoke access for ${grant.label}`}
														say={inUse
															? "This is the link this browser is using. Revoking it cuts this browser off as well, and coming back needs another link. Everyone holding it loses access immediately, and it stays revoked after restart."
															: "Existing holders lose access immediately, and this access link stays revoked after restart."}
														keep="Keep access"
														commit="Revoke access"
														busy={revoking === grant.id}
														onKeep={() => setConfirming(null)}
														onCommit={() => void revoke(grant.id, grant.label)}
													/>
												)}
												{grant.suspended && grant.note !== "" && (
													<Said kind="warning">Paused: {grant.note}</Said>
												)}
												<CopyField
													text={grant.sturdyref}
													label={`Copy session access for ${grant.label}`}
												/>
												{revokeWhy[grant.id] != null && revokeWhy[grant.id] !== "" && (
													<Said kind="failure">{revokeWhy[grant.id]}</Said>
												)}
											</li>
										);
									})}
								</ul>
							)}
					</div>
				</section>
			</div>
			{
				/* Keyed by which link and which opening, so every opening is a fresh
				   card and none of them wears a half-typed reason or a refusal from the
				   last link it was opened on. The key does not change on closing, which
				   is what leaves the card whole while it goes. */
			}
			<SessionGrantEditModal
				key={`${editing ?? ""}-${editorOpening}`}
				grant={grants.find((grant) => grant.id === editing) ?? null}
				inUse={grants.some((grant) => grant.id === editing && grant.sturdyref === held)}
				open={editorOpen}
				onClose={() => setEditorOpen(false)}
			/>
		</Submodal>
	);
}
