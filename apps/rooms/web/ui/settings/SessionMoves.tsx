// Moving this browser to another session, or off the one it is on.
//
// One question with two or three answers, and each answer is a line: what it
// is, and the act that takes it. No answer explains itself here, because every
// one of them explains itself in full a press later: the attach card leads
// with what a session peer keeps, and the other two open the question that
// says what they cost. Saying it twice would make this well long.
//
// Three acts that all change which session this browser answers to, kept
// together so the card above them can stay about the session it is on. Two of
// them are one press and a question. The third takes a capability link, which
// is a paste rather than a press, so it opens a card of its own: a link long
// enough to need its own line, with a sentence about what attaching does to
// what is already here, is a form and not a row.

import { LocalRefusal } from "../../../lib/text/failure.ts";
import { useRef, useState } from "react";
import {
	sessionCapabilityLabel,
	sessionContinueLocally,
	sessionGoLocalSay,
	sessionKeepLocal,
	sessionLeaveLabel,
	sessionLocalCopyLabel,
	sessionShareLabel,
	sessionShareSay,
	sessionStayAttached,
} from "../../../lib/text/settings.ts";
import {
	sessionAttachAnotherTitle,
	sessionAttachCommit,
	sessionAttachHostingHint,
	sessionAttachHostingLead,
	sessionAttachLocalHint,
	sessionAttachLocalLead,
	sessionAttachSharedHint,
	sessionAttachSharedLead,
	sessionAttachTitle,
	sessionContinueLocallyAsk,
	sessionDetachBrowser,
	sessionLeaveHostingSay,
	sessionLeaveKeep,
	sessionLeaveLocalSay,
	sessionLeaveSharedSay,
	sessionLeaveWorkspace,
	sessionMoveAnother,
	sessionMovesTitle,
	sessionMoveThis,
	sessionMoveThisBrowser,
	sessionReturnToSetupAsk,
	sessionStartOver,
	sessionStopHosting,
} from "../../../lib/text/session_settings.ts";
import { Button } from "../Button.tsx";
import { EntryAct, EntryActs } from "../EntryAct.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { addressField } from "../field.ts";
import { actionRefusal, sessionCapabilityRefusal } from "../error_text.ts";
import { useOpenModal } from "../modal.ts";
import { useServerGate } from "../hooks.ts";
import { linkNeedsServer } from "../application.ts";
import { withSessionOffer } from "../server_choice.ts";
import { serverNeedAddress, serverNeedLink } from "../../../lib/text/session.ts";
import { Said } from "../Said.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments } from "../commitment.tsx";
import { useAsyncAction } from "../async_action.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";
import { Input } from "../Input.tsx";

export function SessionMoves(
	{ sessionKind }: { sessionKind: "local" | "attached" | "hosted" },
) {
	const openModalFrom = useOpenModal();
	const browser = useRoomsBrowser();
	const serverGate = useServerGate();
	const commitments = useCommitments();
	const [open, setOpen] = useState(false);
	const [asking, setAsking] = useState<"leave" | "local-copy" | "share" | null>(null);
	const [leaveError, setLeaveError] = useState("");
	// Each answer moves the whole browser, so one runs at a time and its
	// question stays up, busy, until the move lands or says why it did not.
	const move = useAsyncAction(async (_signal, act: () => Promise<string>) => {
		setLeaveError("");
		const why = await act();
		setLeaveError(why);
		if (why === "") setAsking(null);
	});
	const said = leaveError || move.why;
	const sharedSession = sessionKind === "attached" || sessionKind === "hosted";
	const hosting = sessionKind === "hosted";
	return (
		<>
			<h3 className="well-title overline" id="switchSessionLegend">{sessionMovesTitle}</h3>
			<div className="group well session-moves" role="group" aria-labelledby="switchSessionLegend">
				{asking === "share"
					? (
						<Confirm
							label={sessionShareLabel}
							tone="primary"
							say={sessionShareSay}
							keep={sessionKeepLocal}
							commit={sessionShareLabel}
							busy={move.busy}
							onKeep={() => setAsking(null)}
							onCommit={() => commitments.request(() => move.run(() => browser.shareRoomsSession()))}
						/>
					)
					: asking === "local-copy"
					? (
						<Confirm
							label={sessionLocalCopyLabel}
							tone="primary"
							say={sessionGoLocalSay}
							keep={sessionStayAttached}
							commit={sessionContinueLocally}
							busy={move.busy}
							onKeep={() => setAsking(null)}
							onCommit={() => commitments.request(() => move.run(() => browser.useLocalRoomsSession()))}
						/>
					)
					: asking === "leave"
					? (
						<Confirm
							label={sessionLeaveLabel}
							say={hosting
								? sessionLeaveHostingSay
								: sharedSession
								? sessionLeaveSharedSay
								: sessionLeaveLocalSay}
							keep={sessionLeaveKeep}
							commit={hosting
								? sessionStopHosting
								: sharedSession
								? sessionDetachBrowser
								: sessionLeaveWorkspace}
							busy={move.busy}
							onKeep={() => setAsking(null)}
							onCommit={() => commitments.request(() => move.run(() => browser.leaveRoomsSession()))}
						/>
					)
					: (
						<>
							<EntryActs>
								<EntryAct
									name={sessionMoveAnother}
									id="sessionAttachOpen"
									act="Attach…"
									variant="primary"
									onClick={(event) => openModalFrom(event.currentTarget, () => setOpen(true))}
								/>
								{sessionKind === "local" && (
									<EntryAct
										name={sessionMoveThis}
										id="sessionShareAsk"
										act="Share…"
										// The link sharing makes leads to this browser, which people
										// reach through its Rooms server, so the server comes first.
										onClick={() => {
											if (serverGate(serverNeedLink) != null) setAsking("share");
										}}
									/>
								)}
								{sessionKind === "attached" && (
									<EntryAct
										name={sessionMoveThisBrowser}
										id="sessionLocalCopyAsk"
										act={sessionContinueLocallyAsk}
										onClick={() => setAsking("local-copy")}
									/>
								)}
								<EntryAct
									name={sessionStartOver}
									id="sessionLeaveAsk"
									act={sessionReturnToSetupAsk}
									onClick={() => setAsking("leave")}
								/>
							</EntryActs>
						</>
					)}
				{said !== "" && <Said kind="failure">{said}</Said>}
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
	const serverGate = useServerGate();
	const commitments = useCommitments();
	const [link, setLink] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	useChangeGroup("settings-session-attach", {
		dirty: link !== "",
		discard: () => {
			if (busy) throw new LocalRefusal("settings-attach-busy");
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
		// The session is reached at the address its link names, so a link this
		// browser cannot open on its own needs the Rooms server first. The
		// reload a chosen server takes lands on session choice with the link
		// filled in, the way a link that offers a session does.
		if (
			linkNeedsServer(candidate) &&
			serverGate(serverNeedAddress, () => withSessionOffer(new URL(location.href), candidate).hash) == null
		) {
			return;
		}
		running.current = true;
		setBusy(true);
		setWhy("");
		try {
			const refusal = await actionRefusal(() => browser.attachRoomsSession(candidate));
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
			title={sharedSession ? sessionAttachAnotherTitle : sessionAttachTitle}
			titleId="sessionAttachTitle"
			className="session-attach-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: ["settings-session-attach"] })}
		>
			<p className="lead">
				{hosting ? sessionAttachHostingLead : sharedSession ? sessionAttachSharedLead : sessionAttachLocalLead}
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
					label={sessionCapabilityLabel}
					hint={hosting
						? sessionAttachHostingHint
						: sharedSession
						? sessionAttachSharedHint
						: sessionAttachLocalHint}
					said={why}
				>
					{(wiring) => (
						<Input
							id={wiring.id}
							{...addressField}
							value={link}
							disabled={busy}
							aria-describedby={wiring.describedBy}
							aria-invalid={wiring.invalid}
							onChange={(event) => {
								setLink(event.currentTarget.value);
								setWhy("");
							}}
							placeholder={sturdyrefPlaceholder}
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
						{sessionAttachCommit}
					</Button>
				</div>
			</form>
		</Submodal>
	);
}
