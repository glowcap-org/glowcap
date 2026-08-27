// Moving this browser to another session, or off the one it is on.
//
// Three acts that all change which session this browser answers to, kept
// together so the card above them can stay about the session it is on. Two of
// them are one press and a question. The third takes a capability link, which
// is a paste rather than a press, so it opens a card of its own: a link long
// enough to need its own line, with a sentence about what attaching does to
// what is already here, is a form and not a row.

import { useState } from "react";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { locatorRefusal } from "../error_text.ts";
import { openModalFrom } from "../modal.ts";
import { Said } from "../Said.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { SettingsSubmodal } from "./Submodal.tsx";

export function SessionMoves({ sharedSession }: { sharedSession: boolean }) {
	const browser = useRoomsBrowser();
	const [open, setOpen] = useState(false);
	const [asking, setAsking] = useState<"leave" | "local-copy" | null>(null);
	const [leaveError, setLeaveError] = useState("");
	return (
		<>
			<h3 className="well-title overline" id="switchSessionLegend">
				{sharedSession ? "Move this browser" : "Use another session"}
			</h3>
			<div className="group well" role="group" aria-labelledby="switchSessionLegend">
				<p className="hint">
					{sharedSession
						? "The shared session keeps running for everyone else attached to it, whichever of these you choose."
						: "A session peer keeps your rooms and settings for every browser you attach to it."}
				</p>
				{asking === "local-copy"
					? (
						<Confirm
							label="Continue with a local session copy"
							tone="primary"
							say="This browser keeps a copy of the shared session's rooms and settings and works from that copy. Changes here stop reaching the shared session, which keeps running."
							keep="Stay attached"
							commit="Continue locally"
							onKeep={() => setAsking(null)}
							onCommit={() => setLeaveError(browser.useLocalRoomsSession())}
						/>
					)
					: asking === "leave"
					? (
						<Confirm
							label="Leave current Rooms session"
							say={sharedSession
								? "This browser leaves the shared session, which keeps running for everyone else attached to it."
								: "This browser goes back to choosing a session. Its rooms, settings, and message archive stay saved here."}
							keep="Stay"
							commit={sharedSession ? "Detach browser" : "Leave workspace"}
							onKeep={() => setAsking(null)}
							onCommit={() => setLeaveError(browser.leaveRoomsSession())}
						/>
					)
					: (
						<div className="actions" data-stack-narrow>
							{sharedSession && (
								<Button
									id="sessionLocalCopyAsk"
									type="button"
									variant="quiet"
									onClick={() => setAsking("local-copy")}
								>
									Continue as local copy…
								</Button>
							)}
							<Button
								id="sessionLeaveAsk"
								type="button"
								variant="quiet"
								onClick={() => setAsking("leave")}
							>
								{sharedSession ? "Detach…" : "Return to setup…"}
							</Button>
							<Button
								id="sessionAttachOpen"
								type="button"
								onClick={(event) => openModalFrom(event.currentTarget, () => setOpen(true))}
							>
								{sharedSession ? "Attach to another…" : "Attach a session…"}
							</Button>
						</div>
					)}
				{leaveError !== "" && <Said kind="failure">{leaveError}</Said>}
			</div>
			<AttachModal open={open} sharedSession={sharedSession} onClose={() => setOpen(false)} />
		</>
	);
}

function AttachModal(
	{ open, sharedSession, onClose }: { open: boolean; sharedSession: boolean; onClose(): void },
) {
	const browser = useRoomsBrowser();
	const [link, setLink] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const attach = async () => {
		setBusy(true);
		setWhy("");
		try {
			setWhy(locatorRefusal(await browser.attachRoomsSession(link), "session capability link"));
		} finally {
			setBusy(false);
		}
	};
	return (
		<SettingsSubmodal
			title={sharedSession ? "Attach to another session" : "Attach a session"}
			titleId="sessionAttachTitle"
			className="session-attach-modal"
			open={open}
			onClose={onClose}
		>
			<p className="lead">
				{sharedSession
					? "This browser moves to the session the capability names, and shows what that session keeps."
					: "A session peer keeps your rooms and settings, so every browser you attach sees the same workspace."}
			</p>
			<form
				className="group well"
				onSubmit={(event) => {
					event.preventDefault();
					void attach();
				}}
			>
				<Field
					id="sharedSessionCapability"
					label="Session capability"
					hint={sharedSession
						? "Attaching leaves the session this browser is on. That session keeps running for everyone else attached to it."
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
					<Button id="sessionAttachGo" type="submit" size="large" busy={busy} disabled={busy || link === ""}>
						Attach this browser
					</Button>
				</div>
			</form>
		</SettingsSubmodal>
	);
}
