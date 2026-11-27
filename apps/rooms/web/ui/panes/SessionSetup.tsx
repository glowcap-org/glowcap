// The first screen: where this browser's session lives, decided before a
// workspace opens.
//
// Two doors, each a launch row in one card: keep everything on this device, or
// attach to a session another device or a server keeps. Under the card, the
// Rooms server the page reaches through what it cannot open on its own
// (SessionServer). Attach to a link that needs one, with none, asks for it
// first, and saving it attaches, so the link typed or offered is never lost
// on the way. The advanced disclosure under the card holds the two acts that
// take saved state away, each behind the ordinary confirm. A refusal lands
// beside what asked for it: a capability the session would not take stays
// under its own field, and anything else stands under the card. Saved data
// this version can't read refuses every act that opens it (`opensSaved`), so
// each of those is shut and described by a notice under the card, which says
// so and offers a separate workspace.

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
	const [confirmAction, setConfirmAction] = useState<SavedDataAct | null>(null);
	const [advancedOpen, setAdvancedOpen] = useState(false);
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
							disabled={busy != null || shut(unreadable, "local")}
							aria-describedby={shutBy(unreadable, "local")}
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
								disabled={busy != null || shut(unreadable, "attach") || capability.trim() === ""}
								aria-describedby={shutBy(unreadable, "attach")}
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
					open={advancedOpen}
					asking={confirmAction}
					busy={busy}
					unreadable={unreadable}
					onToggle={setAdvancedOpen}
					onAsk={setConfirmAction}
					onKeep={() => setConfirmAction(null)}
					onCommit={(act) => void (act === "reset" ? forgetWorkspace() : deleteBrowserData())}
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
type SetupAct = "local" | "attach" | "reset" | "delete";
/** The two acts that take saved state away. */
export type SavedDataAct = "reset" | "delete";
/** Whether each act opens this browser's saved session: both doors select a
 * session in it, and forgetting rooms and settings clears it. Deleting this
 * browser's data reloads without opening it. */
const opensSaved: Record<SetupAct, boolean> = { local: true, attach: true, reset: true, delete: false };
/** Whether `act` is shut because saved data is `unreadable`: every act that
 * opens it would meet the same refusal. */
const shut = (unreadable: boolean, act: SetupAct): boolean => unreadable && opensSaved[act];
/** What describes `act`: the notice that says why it is shut, when it is. */
const shutBy = (unreadable: boolean, act: SetupAct): string | undefined =>
	shut(unreadable, act) ? "sessionUnreadableSay" : undefined;

/** What setup says while this browser's saved session can't be read, over the
 * option to open a separate workspace. */
export function SessionUnreadable({ busy, onSeparate }: { busy: boolean; onSeparate: () => void }) {
	return (
		<div className="session-setup-unreadable">
			<p id="sessionUnreadableSay">{sessionUnreadableSay}</p>
			<div className="actions">
				<Button
					id="sessionUnreadableSeparate"
					variant="quiet"
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

/** The disclosure under the card: each act that takes saved state away, and
 * the ordinary confirm for the one `asking`, unless saved data `unreadable`
 * shuts it. */
export function SetupAdvanced(
	{ open, asking, busy, unreadable, onToggle, onAsk, onKeep, onCommit }: {
		open: boolean;
		asking: SavedDataAct | null;
		busy: string | null;
		unreadable: boolean;
		onToggle: (open: boolean) => void;
		onAsk: (act: SavedDataAct) => void;
		onKeep: () => void;
		onCommit: (act: SavedDataAct) => void;
	},
) {
	return (
		<details
			className="disclosure session-setup-advanced"
			data-align="center"
			open={open}
			onToggle={(event) => onToggle(event.currentTarget.open)}
		>
			<summary>{sessionAdvanced}</summary>
			{asking != null && !shut(unreadable, asking)
				? (
					<Confirm
						label={sessionChangeLabel}
						say={asking === "reset" ? sessionResetSay : sessionDeleteSay}
						keep={sessionConfirmKeep}
						commit={asking === "reset" ? sessionResetCommit : sessionDeleteCommit}
						busy={busy === asking}
						onKeep={onKeep}
						onCommit={() => onCommit(asking)}
					/>
				)
				: (
					<div className="actions">
						<Button
							id="sessionResetAsk"
							variant="quiet"
							disabled={busy != null || shut(unreadable, "reset")}
							aria-describedby={shutBy(unreadable, "reset")}
							onClick={() => onAsk("reset")}
						>
							{sessionResetAsk}
						</Button>
						<Button
							id="sessionDeleteAsk"
							variant="quiet"
							disabled={busy != null || shut(unreadable, "delete")}
							aria-describedby={shutBy(unreadable, "delete")}
							onClick={() => onAsk("delete")}
						>
							{sessionDeleteAsk}
						</Button>
					</div>
				)}
		</details>
	);
}
