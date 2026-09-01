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
import { Button } from "./Button.tsx";
import { Confirm } from "./Confirm.tsx";
import { Field } from "./Field.tsx";
import { identifierField } from "./field.ts";
import { Icon, Wordmark } from "./icons.tsx";
import { Said } from "./Said.tsx";
import { ErrorDetail } from "./ErrorDetail.tsx";
import { locatorRefusal, sessionCapabilityRefusal } from "./error_text.ts";
import { useRoomsState } from "./hooks.ts";
import { useRoomsBrowser } from "./controller/browser.ts";

export function SessionSetup(
	{ initialCapability = "", initialError = "" }: {
		initialCapability?: string;
		initialError?: string;
	},
) {
	const browser = useRoomsBrowser();
	const errorDetail = useRoomsState((state) => state.errorDetail);
	const [capability, setCapability] = useState(initialCapability);
	const [busy, setBusy] = useState<"local" | "attach" | "delete" | null>(null);
	// Two homes for a refusal: the attach field's own, and the card's.
	const [attachError, setAttachError] = useState(initialError);
	const [error, setError] = useState("");
	const [confirmAction, setConfirmAction] = useState<"reset" | "delete" | null>(null);
	const running = useRef<"local" | "attach" | "delete" | null>(null);
	const useLocal = () => {
		if (running.current !== null) return;
		running.current = "local";
		setError("");
		setBusy("local");
		try {
			const why = browser.useLocalRoomsSession();
			if (why !== "") setError(why);
		} catch (error) {
			setError(error instanceof Error ? error.message : String(error));
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
			setAttachError(locatorRefusal(await browser.attachRoomsSession(candidate), "session capability link"));
		} finally {
			running.current = null;
			setBusy(null);
		}
	};
	const forgetWorkspace = () => {
		setError("");
		const why = browser.resetBrowserWorkspace();
		if (why !== "") {
			setError(why);
			setConfirmAction(null);
		}
	};
	const deleteBrowserData = async () => {
		if (running.current !== null) return;
		running.current = "delete";
		setError("");
		setBusy("delete");
		try {
			const why = await browser.deleteBrowserData();
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
					<Icon name="mark" size={44} />
					<Wordmark />
				</header>
				<div className="session-setup-heading">
					<h1>Choose a session</h1>
					<p>
						Rooms keeps your rooms, direct messages, and settings in a session. Pick where this browser's
						session lives.
					</p>
				</div>
				<div className="session-setup-choices">
					<section className="launch session-setup-choice" aria-labelledby="localSessionTitle">
						<span className="launch-mark" aria-hidden="true">
							<Icon name="session" size={20} />
						</span>
						<div className="launch-copy">
							<h2 className="launch-title" id="localSessionTitle">This browser</h2>
							<p className="hint">Keep everything on this device. Nothing leaves it.</p>
						</div>
						<Button
							id="sessionUseLocal"
							size="large"
							busy={busy === "local"}
							disabled={busy != null}
							onClick={useLocal}
						>
							Use this browser
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
							<h2 className="launch-title" id="attachedSessionTitle">Shared session</h2>
							<p className="hint">
								Attach to a session another device or a server keeps, using the capability it printed.
							</p>
						</div>
						<div className="field-row">
							<Field id="sessionSetupCapability" label="Session capability" said={attachError}>
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
										placeholder="ocapn://…/s/…"
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
								Attach
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
							<h2 className="launch-title" id="signInSessionTitle">Sign in</h2>
							<p className="hint">
								Start a session a server keeps and reach it from any device with an account, instead of
								carrying a capability.
							</p>
						</div>
						<span className="tag" id="signInSessionState">Coming soon</span>
					</section>
				</div>
				{error !== "" && <Said kind="failure">{error}</Said>}
				<details className="session-setup-advanced">
					<summary>Advanced</summary>
					{confirmAction != null
						? (
							<Confirm
								label="Change saved browser data"
								say={confirmAction === "reset"
									? "Forget the saved workspace and start this browser at this screen again? Its message archive stays."
									: "Delete this browser's workspace, remembered capabilities, and message archive? Sessions and archives kept elsewhere stay."}
								keep="Keep it"
								commit={confirmAction === "reset" ? "Reset workspace" : "Delete browser data"}
								busy={busy === "delete"}
								onKeep={() => setConfirmAction(null)}
								onCommit={confirmAction === "reset" ? forgetWorkspace : () => void deleteBrowserData()}
							/>
						)
						: (
							<div className="actions">
								<Button id="sessionResetAsk" variant="quiet" onClick={() => setConfirmAction("reset")}>
									Reset workspace…
								</Button>
								<Button
									id="sessionDeleteAsk"
									variant="quiet"
									onClick={() => setConfirmAction("delete")}
								>
									Delete browser data…
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
