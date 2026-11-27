// The first screen: where this browser's session lives, decided before a
// workspace opens.
//
// A saved workspace can be resumed here. Otherwise the browser keeps a local
// session or attaches to a shared one. A link needing a Rooms server stays
// filled while that server is chosen. Advanced confirms deletion of all the
// data this page keeps in this browser profile.

import { type ReactNode, useRef, useState } from "react";
import { chooseWorkspace } from "../workspace_choice.ts";
import { reloadNow } from "../boot.ts";
import { useOpenModal } from "../modal.ts";
import { withSessionOffer } from "../session_offer.ts";
import { type ServerChoosing, SessionServer } from "./SessionServer.tsx";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { addressField } from "../field.ts";
import { Icon, Wordmark } from "../icons.tsx";
import { Said } from "../Said.tsx";
import { ErrorDetail } from "./ErrorDetail.tsx";
import { actionRefusal, sessionCapabilityRefusal } from "../error_text.ts";
import { linkNeedsServer } from "../application.ts";
import {
	separateWorkspace,
	sessionAdvanced,
	sessionChangeLabel,
	sessionConfirmKeep,
	sessionDeleteAsk,
	sessionDeleteCommit,
	sessionDeleteSay,
	sessionLocalCommit,
	sessionLocalHint,
	sessionLocalTitle,
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
	sessionUnreadableSay,
} from "../../../lib/text/session.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";
import { useRoomsState } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { Input } from "../Input.tsx";

export function SessionSetup(
	{ initialCapability = "", initialError = "", renderSavedWorkspaces }: {
		initialCapability?: string;
		initialError?: string;
		renderSavedWorkspaces?: (disabled: boolean, primary: boolean) => ReactNode;
	},
) {
	const browser = useRoomsBrowser();
	const errorDetail = useRoomsState((state) => state.errorDetail);
	const unreadable = useRoomsState((state) => state.savedSessionUnreadable);
	const [capability, setCapability] = useState(initialCapability);
	const [busy, setBusy] = useState<SetupAct | null>(null);
	// Two homes for a refusal: the attach field's own, and the card's.
	const [attachError, setAttachError] = useState("");
	const [error, setError] = useState(initialError);
	const [confirmDelete, setConfirmDelete] = useState(false);
	const running = useRef<SetupAct | null>(null);
	// The server the opening session takes: the kept choice at load, and the
	// one saved here after.
	const [server, setServer] = useState(() => browser.server());
	const [choosing, setChoosing] = useState<ServerChoosing>(null);
	const attachButton = useRef<HTMLButtonElement>(null);
	const openModalFrom = useOpenModal();
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
		// The session is reached at the address its link names. A link this
		// browser cannot open on its own needs a Rooms server, so with none,
		// choosing one comes first, and saving it comes back here.
		if (browser.server() == null && linkNeedsServer(candidate)) {
			if (attachButton.current != null) openModalFrom(attachButton.current, () => setChoosing("attach"));
			return;
		}
		running.current = "attach";
		setBusy("attach");
		try {
			setAttachError(await actionRefusal(() => browser.attachRoomsSession(candidate)));
		} finally {
			running.current = null;
			setBusy(null);
		}
	};
	// A session that has opened keeps its server, so a choice made after a
	// failed attempt reloads the page, and the link rides along in its address.
	// Otherwise the choice holds in place.
	const held = browser.serverHeld();
	const serverSaved = () => {
		if (held) {
			const kept = capability.trim();
			if (kept !== "") {
				globalThis.history.replaceState(
					globalThis.history.state,
					"",
					withSessionOffer(new URL(location.href), kept),
				);
			}
			reloadNow();
			return;
		}
		const then = choosing;
		setServer(browser.server());
		setChoosing(null);
		if (then === "attach") void attach();
	};
	const deleteBrowserData = async () => {
		if (running.current !== null) return;
		running.current = "delete";
		setError("");
		setBusy("delete");
		try {
			const why = await actionRefusal(() => browser.deleteBrowserData());
			setError(why);
			if (why !== "") setConfirmDelete(false);
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
				{unreadable && (
					<SessionUnreadable
						busy={busy != null}
						onSeparate={() => {
							const refused = chooseWorkspace(null);
							if (refused) setError(refusalText(refused));
						}}
					/>
				)}
				<div className="session-setup-choices">
					{renderSavedWorkspaces?.(busy != null, capability.trim() === "")}
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
							variant={!renderSavedWorkspaces && capability.trim() === "" ? "primary" : "quiet"}
							busy={busy === "local"}
							disabled={busy != null || unreadable}
							aria-describedby={unreadable ? "sessionUnreadableSay" : undefined}
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
									<Input
										id={wiring.id}
										value={capability}
										{...addressField}
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
								ref={attachButton}
								id="sessionAttach"
								type="submit"
								size="large"
								busy={busy === "attach"}
								disabled={busy != null || unreadable || capability.trim() === ""}
								aria-describedby={unreadable ? "sessionUnreadableSay" : undefined}
							>
								{sessionSharedCommit}
							</Button>
						</div>
					</form>
					{
						/* The third door is drawn shut. Signing in to a session a server
						    keeps, so it can be reached from any device without carrying a
						    capability, is not built. The row says so as a state rather
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
				<SessionServer
					server={server}
					held={held}
					busy={busy != null}
					choosing={choosing}
					onChoosing={setChoosing}
					onSaved={serverSaved}
				/>
				{error !== "" && <Said kind="failure">{error}</Said>}

				<SetupAdvanced
					asking={confirmDelete}
					busy={busy != null}
					onAsk={() => setConfirmDelete(true)}
					onKeep={() => setConfirmDelete(false)}
					onCommit={() => void deleteBrowserData()}
				/>
			</div>
			<ErrorDetail
				title={errorDetail?.title ?? null}
				text={errorDetail?.text ?? null}
			/>
		</main>
	);
}

/** The acts setup offers. */
type SetupAct = "local" | "attach" | "delete";

/** What setup says while this browser's saved session can't be read, over the
 * option to open a separate workspace. */
export function SessionUnreadable({ busy, onSeparate }: { busy: boolean; onSeparate: () => void }) {
	return (
		<div className="session-setup-unreadable">
			<p id="sessionUnreadableSay">{sessionUnreadableSay}</p>
			<div className="actions">
				<Button
					id="sessionUnreadableSeparate"
					size="large"
					disabled={busy}
					aria-describedby="sessionUnreadableSay"
					onClick={onSeparate}
				>
					{separateWorkspace}
				</Button>
			</div>
		</div>
	);
}

/** Device-wide deletion is available even when no workspace can be opened. */
export function SetupAdvanced(
	{ asking, busy, onAsk, onKeep, onCommit }: {
		asking: boolean;
		busy: boolean;
		onAsk(): void;
		onKeep(): void;
		onCommit(): void;
	},
) {
	return (
		<details className="disclosure session-setup-advanced" data-align="center">
			<summary>{sessionAdvanced}</summary>
			{asking
				? (
					<Confirm
						label={sessionChangeLabel}
						say={sessionDeleteSay}
						keep={sessionConfirmKeep}
						commit={sessionDeleteCommit}
						busy={busy}
						onKeep={onKeep}
						onCommit={onCommit}
					/>
				)
				: (
					<div className="actions">
						<Button id="sessionDeleteAsk" variant="quiet" disabled={busy} onClick={onAsk}>
							{sessionDeleteAsk}
						</Button>
					</div>
				)}
		</details>
	);
}
