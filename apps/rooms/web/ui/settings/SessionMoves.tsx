// Moving this browser to another session, or off the one it is on.
//
// One question with two or three answers, and each answer is a line: what it
// is, and the act that takes it. No answer explains itself here, because every
// one of them explains itself in full a press later — the attach card leads
// with what a session peer keeps, and the other two open the question that
// says what they cost. Saying it twice is what made this well long.
//
// Three acts that all change which session this browser answers to, kept
// together so the card above them can stay about the session it is on. Two of
// them are one press and a question. The third takes a capability link, which
// is a paste rather than a press, so it opens a card of its own: a link long
// enough to need its own line, with a sentence about what attaching does to
// what is already here, is a form and not a row.

import { useRef, useState } from "react";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { locatorRefusal, sessionCapabilityRefusal } from "../error_text.ts";
import { useOpenModal } from "../modal.ts";
import { Said } from "../Said.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments } from "../commitment.tsx";

export function SessionMoves(
	{ sessionKind }: { sessionKind: "local" | "attached" | "hosted" },
) {
	const openModalFrom = useOpenModal();
	const browser = useRoomsBrowser();
	const commitments = useCommitments();
	const [open, setOpen] = useState(false);
	const [asking, setAsking] = useState<"leave" | "local-copy" | "share" | null>(null);
	const [leaveError, setLeaveError] = useState("");
	const [sharing, setSharing] = useState(false);
	const sharedSession = sessionKind === "attached" || sessionKind === "hosted";
	const hosting = sessionKind === "hosted";
	return (
		<>
			<h3 className="well-title overline" id="switchSessionLegend">Where this browser works</h3>
			<div className="group well session-moves" role="group" aria-labelledby="switchSessionLegend">
				{asking === "share"
					? (
						<Confirm
							label="Share this session"
							tone="primary"
							say="This browser hosts the session. Join a room on this page's directory first. Other browsers attach with a capability copied from Holdings, including from a different Rooms page. Closing or reloading this tab ends sharing for everyone."
							keep="Keep it local"
							commit="Share this session"
							busy={sharing}
							onKeep={() => setAsking(null)}
							onCommit={() =>
								commitments.request(async () => {
									setSharing(true);
									try {
										const why = await browser.shareRoomsSession();
										setLeaveError(why);
										if (why === "") setAsking(null);
									} catch (error) {
										setLeaveError(error instanceof Error ? error.message : String(error));
									} finally {
										setSharing(false);
									}
								})}
						/>
					)
					: asking === "local-copy"
					? (
						<Confirm
							label="Continue with a local session copy"
							tone="primary"
							say="This browser keeps a copy of the rooms and settings and works from it. The shared session keeps running. Names stay with it, so rooms here are for reading until you join under a name of your own. Coming back needs that link again."
							keep="Stay attached"
							commit="Continue locally"
							onKeep={() => setAsking(null)}
							onCommit={() => commitments.request(() => setLeaveError(browser.useLocalRoomsSession()))}
						/>
					)
					: asking === "leave"
					? (
						<Confirm
							label="Leave current Rooms session"
							say={hosting
								? "This browser stops hosting. Everyone attached to it loses the session. Rooms and settings stay saved here."
								: sharedSession
								? "This browser leaves the shared session. That session keeps running for everyone else attached to it. Names stay with it, so rooms here are for reading until you join under a name of your own. Coming back needs that link again."
								: "This browser goes back to choosing a session. Its rooms, settings, and message archive stay saved here."}
							keep="Stay"
							commit={hosting ? "Stop hosting" : sharedSession ? "Detach browser" : "Leave workspace"}
							onKeep={() => setAsking(null)}
							onCommit={() => commitments.request(() => setLeaveError(browser.leaveRoomsSession()))}
						/>
					)
					: (
						<>
							<ul className="entries">
								<li className="entry">
									<div className="entry-head" data-one-line>
										<span className="entry-name">Another session</span>
										<div className="actions">
											<Button
												id="sessionAttachOpen"
												type="button"
												onClick={(event) =>
													openModalFrom(event.currentTarget, () => setOpen(true))}
											>
												Attach…
											</Button>
										</div>
									</div>
								</li>
								{sessionKind === "local" && (
									<li className="entry">
										<div className="entry-head" data-one-line>
											<span className="entry-name">This session</span>
											<div className="actions">
												<Button
													id="sessionShareAsk"
													type="button"
													variant="quiet"
													onClick={() => setAsking("share")}
												>
													Share…
												</Button>
											</div>
										</div>
									</li>
								)}
								{sessionKind === "attached" && (
									<li className="entry">
										<div className="entry-head" data-one-line>
											<span className="entry-name">This browser</span>
											<div className="actions">
												<Button
													id="sessionLocalCopyAsk"
													type="button"
													variant="quiet"
													onClick={() => setAsking("local-copy")}
												>
													Continue locally…
												</Button>
											</div>
										</div>
									</li>
								)}
								<li className="entry">
									<div className="entry-head" data-one-line>
										<span className="entry-name">Start over</span>
										<div className="actions">
											<Button
												id="sessionLeaveAsk"
												type="button"
												variant="quiet"
												onClick={() => setAsking("leave")}
											>
												Return to setup…
											</Button>
										</div>
									</div>
								</li>
							</ul>
						</>
					)}
				{leaveError !== "" && <Said kind="failure">{leaveError}</Said>}
			</div>
			<AttachModal
				open={open}
				sharedSession={sharedSession}
				hosting={hosting}
				onClose={() => setOpen(false)}
			/>
		</>
	);
}

function AttachModal(
	{ open, sharedSession, hosting, onClose }: {
		open: boolean;
		sharedSession: boolean;
		hosting: boolean;
		onClose(): void;
	},
) {
	const browser = useRoomsBrowser();
	const commitments = useCommitments();
	const [link, setLink] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	useChangeGroup("settings-session-attach", {
		dirty: link !== "",
		discard: () => {
			if (busy) throw new Error("Wait for the session attachment to finish.");
			setLink("");
			setWhy("");
		},
	});
	// A ref rather than the busy flag, because two presses can reach this
	// before React has redrawn the button that the flag disables, and attaching
	// twice is two attempts to move this browser at once.
	const running = useRef(false);
	const attach = async () => {
		if (running.current) return;
		const candidate = link.trim();
		const shape = sessionCapabilityRefusal(candidate);
		if (shape !== "") {
			setWhy(shape);
			return;
		}
		running.current = true;
		setBusy(true);
		setWhy("");
		try {
			const refusal = locatorRefusal(await browser.attachRoomsSession(candidate), "session capability link");
			setWhy(refusal);
			// Emptied once it has been used, because a filled field is a pending
			// change and this one is spent. A capability that moves this browser
			// reloads the page and takes the form with it, so this is invisible
			// there; one that names the session already in hand changes nothing and
			// deliberately does not reload, and left filled it is a form that looks
			// unsubmitted and stops the reader on the way out to ask about work that
			// is already done.
			if (refusal === "") setLink("");
		} finally {
			running.current = false;
			setBusy(false);
		}
	};
	return (
		<Submodal
			title={sharedSession ? "Attach to another session" : "Attach a session"}
			titleId="sessionAttachTitle"
			className="session-attach-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: ["settings-session-attach"] })}
		>
			<p className="lead">
				{hosting
					? "This browser stops hosting. Everyone attached to it loses this session. Then this browser shows the session the capability names."
					: sharedSession
					? "This browser moves to the session the capability names, and shows what that session keeps."
					: "A session peer keeps your rooms and settings, so every browser you attach sees the same workspace."}
			</p>
			<form
				className="group well"
				onSubmit={(event) => {
					event.preventDefault();
					commitments.request(attach, { except: ["settings-session-attach"] });
				}}
			>
				<Field
					id="sharedSessionCapability"
					label="Session capability"
					hint={hosting
						? "A capability for another session ends hosting for everyone attached here. A capability for this same session leaves hosting as it is."
						: sharedSession
						? "A capability for another session moves this browser to it, and the session it is on now keeps running for everyone else. A second capability for that same session only changes which one this browser uses."
						: "An empty session takes this browser's rooms and settings with it. One that already keeps rooms and settings shows those instead."}
					said={why}
				>
					{(wiring) => (
						<input
							id={wiring.id}
							className="field"
							type="text"
							{...identifierField}
							value={link}
							disabled={busy}
							aria-describedby={wiring.describedBy}
							aria-invalid={wiring.invalid}
							onChange={(event) => {
								setLink(event.currentTarget.value);
								setWhy("");
							}}
							placeholder="ocapn://…/s/…"
						/>
					)}
				</Field>
				<div className="actions" data-fill>
					<Button
						id="sessionAttachGo"
						type="submit"
						size="large"
						busy={busy}
						disabled={busy || link.trim() === ""}
					>
						Attach this browser
					</Button>
				</div>
			</form>
		</Submodal>
	);
}
