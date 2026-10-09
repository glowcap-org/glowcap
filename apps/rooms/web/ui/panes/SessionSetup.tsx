// The first screen: where this browser's session lives, decided before a
// workspace opens.
//
// Two doors, each a launch row in one card: keep everything on this device, or
// attach to a session another device or a server keeps. The advanced
// disclosure under the card holds the two acts that take saved state away,
// each behind the ordinary confirm. A refusal lands beside what asked for it:
// a capability the session would not take stays under its own field, and
// anything else stands under the card.

import { useRef, useState } from "react";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { Icon, Wordmark } from "../icons.tsx";
import { Said } from "../Said.tsx";
import { ErrorDetail } from "./ErrorDetail.tsx";
import { actionRefusal, locatorRefusal, sessionCapabilityRefusal } from "../error_text.ts";
import {
	sessionAdvanced,
	sessionChangeLabel,
	sessionConfirmKeep,
	sessionDeleteAsk,
	sessionDeleteCommit,
	sessionDeleteSay,
	sessionLocalCommit,
	sessionLocalHint,
	sessionLocalTitle,
	sessionResetAsk,
	sessionResetCommit,
	sessionResetSay,
	sessionSetupLead,
	sessionSetupTitle,
	sessionSharedCommit,
	sessionSharedFieldHint,
	sessionSharedFieldLabel,
	sessionSharedHint,
	sessionSharedTitle,
	sessionSignInHint,
	sessionSignInState,
	sessionSignInTitle,
	sturdyrefPlaceholder,
} from "../../../lib/text/mod.ts";
import { useRoomsState } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { refusalText } from "../../../lib/text/failure.ts";

export function SessionSetup(
	{ initialCapability = "", initialError = "" }: {
		initialCapability?: string;
		initialError?: string;
	},
) {
	const browser = useRoomsBrowser();
	const errorDetail = useRoomsState((state) => state.errorDetail);
	const [capability, setCapability] = useState(initialCapability);
	const [busy, setBusy] = useState<"local" | "attach" | "reset" | "delete" | null>(null);
	// Two homes for a refusal: the attach field's own, and the card's.
	const [attachError, setAttachError] = useState(initialError);
	const [error, setError] = useState("");
	const [confirmAction, setConfirmAction] = useState<"reset" | "delete" | null>(null);
	const running = useRef<"local" | "attach" | "reset" | "delete" | null>(null);
	const useLocal = async () => {
		if (running.current !== null) return;
		running.current = "local";
		setError("");
		setBusy("local");
		try {
			const why = await browser.useLocalRoomsSession();
			if (why !== "") setError(why);
		} catch (error) {
			setError(refusalText(error));
		} finally {
			setBusy(null);
			running.current = null;
		}
	};
	const attach = async () => {
		if (running.current !== null) return;
		const candidate = capability.trim();
		const shape = sessionCapabilityRefusal(candidate);
		if (shape !== "") {
			setAttachError(shape);
			return;
		}
		setAttachError("");
		running.current = "attach";
		setBusy("attach");
		try {
			setAttachError(locatorRefusal(
				await actionRefusal(() => browser.attachRoomsSession(candidate)),
				"session capability link",
			));
		} finally {
			running.current = null;
			setBusy(null);
		}
	};
	const forgetWorkspace = async () => {
		if (running.current !== null) return;
		running.current = "reset";
		setError("");
		setBusy("reset");
		try {
			const why = await actionRefusal(() => browser.resetBrowserWorkspace());
			if (why !== "") {
				setError(why);
				setConfirmAction(null);
			}
		} finally {
			running.current = null;
			setBusy(null);
		}
	};
	const deleteBrowserData = async () => {
		if (running.current !== null) return;
		running.current = "delete";
		setError("");
		setBusy("delete");
		try {
			const why = await actionRefusal(() => browser.deleteBrowserData());
			setError(why);
			if (why !== "") setConfirmAction(null);
		} finally {
			running.current = null;
			setBusy(null);
		}
	};
	return (
		<main className="session-setup card-plane" id="sessionSetup">
			<div className="session-setup-inner">
				<header className="session-setup-brand brand-lockup">
					<Icon name="mark" size={56} />
					<Wordmark />
				</header>
				<div className="session-setup-heading">
					<h1>{sessionSetupTitle}</h1>
					<p>{sessionSetupLead}</p>
				</div>
				<div className="session-setup-choices">
					<section className="launch session-setup-choice" aria-labelledby="localSessionTitle">
						<span className="launch-mark" aria-hidden="true">
							<Icon name="session" size={20} />
						</span>
						<div className="launch-copy">
							<h2 className="launch-title" id="localSessionTitle">{sessionLocalTitle}</h2>
							<p className="hint">{sessionLocalHint}</p>
						</div>
						<Button
							id="sessionUseLocal"
							size="large"
							busy={busy === "local"}
							disabled={busy != null}
							onClick={useLocal}
						>
							{sessionLocalCommit}
						</Button>
					</section>
					<form
						className="launch session-setup-choice"
						aria-labelledby="attachedSessionTitle"
						onSubmit={(event) => {
							event.preventDefault();
							void attach();
						}}
					>
						<span className="launch-mark" aria-hidden="true">
							<Icon name="group" size={20} />
						</span>
						<div className="launch-copy">
							<h2 className="launch-title" id="attachedSessionTitle">{sessionSharedTitle}</h2>
							<p className="hint">{sessionSharedHint}</p>
						</div>
						<div className="field-row">
							<Field
								id="sessionSetupCapability"
								label={sessionSharedFieldLabel}
								hint={sessionSharedFieldHint}
								said={attachError}
							>
								{(wiring) => (
									<input
										id={wiring.id}
										className="field"
										value={capability}
										{...identifierField}
										disabled={busy != null}
										aria-describedby={wiring.describedBy}
										aria-invalid={wiring.invalid}
										onChange={(event) => {
											setCapability(event.currentTarget.value);
											setAttachError("");
										}}
										placeholder={sturdyrefPlaceholder}
									/>
								)}
							</Field>
							<Button
								id="sessionAttach"
								type="submit"
								size="large"
								busy={busy === "attach"}
								disabled={busy != null || capability.trim() === ""}
							>
								{sessionSharedCommit}
							</Button>
						</div>
					</form>
					{
						/* The third door is drawn shut. Signing in to a session a server
						    keeps, so it can be reached from any device without carrying a
						    capability, is not built; the row says so as a state rather
						    than offering a button that refuses, and it stands here so
						    the shape of the choice is already the shape it will have. */
					}
					<section
						className="launch session-setup-choice"
						id="sessionSignIn"
						aria-labelledby="signInSessionTitle"
						data-unavailable="true"
					>
						<span className="launch-mark" aria-hidden="true">
							<Icon name="direct" size={20} />
						</span>
						<div className="launch-copy">
							<h2 className="launch-title" id="signInSessionTitle">{sessionSignInTitle}</h2>
							<p className="hint">{sessionSignInHint}</p>
						</div>
						<span className="tag" id="signInSessionState">{sessionSignInState}</span>
					</section>
				</div>
				{error !== "" && <Said kind="failure">{error}</Said>}
				<details className="disclosure session-setup-advanced" data-align="center">
					<summary>{sessionAdvanced}</summary>
					{confirmAction != null
						? (
							<Confirm
								label={sessionChangeLabel}
								say={confirmAction === "reset" ? sessionResetSay : sessionDeleteSay}
								keep={sessionConfirmKeep}
								commit={confirmAction === "reset" ? sessionResetCommit : sessionDeleteCommit}
								busy={busy === confirmAction}
								onKeep={() => setConfirmAction(null)}
								onCommit={() =>
									void (confirmAction === "reset" ? forgetWorkspace() : deleteBrowserData())}
							/>
						)
						: (
							<div className="actions">
								<Button
									id="sessionResetAsk"
									variant="quiet"
									disabled={busy != null}
									onClick={() => setConfirmAction("reset")}
								>
									{sessionResetAsk}
								</Button>
								<Button
									id="sessionDeleteAsk"
									variant="quiet"
									disabled={busy != null}
									onClick={() => setConfirmAction("delete")}
								>
									{sessionDeleteAsk}
								</Button>
							</div>
						)}
				</details>
			</div>
			<ErrorDetail
				title={errorDetail?.title ?? null}
				text={errorDetail?.text ?? null}
			/>
		</main>
	);
}
