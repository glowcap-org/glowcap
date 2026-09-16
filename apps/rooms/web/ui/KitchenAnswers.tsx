// The kitchen sink's second half: what the window says back. A page notice
// that leaves on its own, a reply that stays beside its control, a failure on
// the thing itself, an answer in the log, and the four words for a connection.

import { Button } from "./Button.tsx";
import {
	kitchenBesideControl,
	kitchenInTheLog,
	kitchenNotifyMention,
	kitchenOnThing,
	kitchenPageNotice,
	kitchenRetryFailed,
	kitchenRetryPicture,
	kitchenTryPictureAgain,
} from "../../lib/text/kitchen.ts";
import { CrashCard } from "./ErrorBoundary.tsx";
import { Field } from "./Field.tsx";
import { Icon } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import { useRoomsBrowser } from "./controller/browser.ts";
import { Said } from "./Said.tsx";
import { PHASE_SAID } from "./text.ts";
import { ToastCard } from "./Toast.tsx";
import type { SessionPhase } from "./types.ts";
import { Row, Sample } from "./KitchenSample.tsx";
import { useState } from "react";

const phases: readonly SessionPhase[] = [
	"connected",
	"connecting",
	"reconnecting",
	"disconnected",
];

export function KitchenAnswers() {
	const browser = useRoomsBrowser();
	const [dynamicRefusal, setDynamicRefusal] = useState("Waiting for the request.");
	return (
		<>
			<Sample
				label={kitchenPageNotice}
				note="A refusal with nowhere on the control to live. It leaves on its own. Press to see one live, above this card."
			>
				<div className="kitchen-toasts">
					<ToastCard kind="success" text="A success notice" onDismiss={() => undefined} />
					<ToastCard kind="failure" text="A failure notice" onDismiss={() => undefined} />
					<ToastCard
						kind="failure"
						text={"Could not reach ocapn://abcdefghijklmnopqrstuvwxyz0123456789.onion/s/" +
							"unreachableswissnum: the peer closed the session before the handshake finished."}
						onDismiss={() => undefined}
					/>
					<ToastCard kind="warning" text="A warning notice" onDismiss={() => undefined} />
				</div>
				<Row>
					<Button variant="quiet" onClick={() => browser.toast("success", "A success notice")}>
						Success
					</Button>
					<Button variant="quiet" onClick={() => browser.toast("failure", "A failure notice")}>
						Failure
					</Button>
					<Button variant="quiet" onClick={() => browser.toast("warning", "A warning notice")}>
						Warning
					</Button>
				</Row>
			</Sample>
			<Sample
				label={kitchenBesideControl}
				note="The field, the bell, or the meter still owns the answer. Danger marks a refusal. Warning marks a standing condition the reader can fix. A long reason stays two lines here. Show opens the rest."
			>
				<div className="kitchen-stack">
					<p className="kitchen-note">A field that would not take the value</p>
					<Field
						id="kitchenInvalid"
						label="Display name"
						said="That name is too long for this room (32 characters)."
					>
						{({ id, describedBy, invalid }) => (
							<input
								id={id}
								className="field"
								readOnly
								value="a name that will not fit"
								aria-invalid={invalid}
								aria-describedby={describedBy}
							/>
						)}
					</Field>
				</div>
				<div className="kitchen-stack">
					<p className="kitchen-note">A reason too long to keep beside the field</p>
					<Field
						id="kitchenLong"
						label="Locator"
						said={"Could not reach ocapn://abcdefghijklmnopqrstuvwxyz0123456789.onion/s/" +
							"unreachableswissnum: the peer closed the session before the handshake finished."}
					>
						{({ id, describedBy, invalid }) => (
							<input
								id={id}
								className="field"
								readOnly
								value="ocapn://…"
								aria-invalid={invalid}
								aria-describedby={describedBy}
							/>
						)}
					</Field>
				</div>
				<div className="kitchen-stack">
					<p className="kitchen-note">A standing condition on a control that stays</p>
					<Row>
						<IconButton icon="bell" label={kitchenNotifyMention} aria-pressed="true" />
					</Row>
					<Said kind="warning">
						Notifications are on here, but this browser is blocking them.
					</Said>
				</div>
				<div className="kitchen-stack">
					<p className="kitchen-note">A refusal that arrives after the action</p>
					<Row>
						<Button
							id="kitchenDynamicRefusalRun"
							variant="quiet"
							onClick={() =>
								setDynamicRefusal(
									"Could not reach ocapn://dynamic.example/s/unreachableswissnum: " +
										"the peer closed the session before the asynchronous request finished, " +
										"so none of the queued capability work was accepted and the operation remains pending " +
										"until a reachable route can be established.",
								)}
						>
							Run request
						</Button>
					</Row>
					<Said id="kitchenDynamicRefusal" kind="failure">{dynamicRefusal}</Said>
				</div>
				<div className="kitchen-stack">
					<p className="kitchen-note">The draft is past what this room will carry</p>
					<div className="hint room-cap over">12 bytes too long for this room</div>
				</div>
			</Sample>
			<Sample
				label={kitchenOnThing}
				note="The message, the file, or the pane that failed. Retry sits on it. A render that threw replaces only that pane."
			>
				<div className="kitchen-log">
					<div className="row mine">
						<div className="stack">
							<div className="bubble failed">
								hello
								<div className="delivery-failure" role="status">
									<span>Not sent</span>
									<IconButton
										icon="retry"
										label={kitchenRetryFailed}
										size="small"
										variant="ghost"
										tone="on-accent"
									/>
								</div>
							</div>
						</div>
					</div>
				</div>
				<div className="attach attach-media pending kitchen-tile" style={{ aspectRatio: "4 / 3" }}>
					<button type="button" className="act" aria-label={kitchenRetryPicture}>
						<Icon name="retry" />
						<span>Retry</span>
					</button>
					<span className="why" role="alert">The peer closed before those bytes arrived.</span>
				</div>
				<div className="kitchen-viewer">
					<span className="viewer-failure" role="alert">
						The peer closed before those bytes arrived.
						<IconButton
							icon="retry"
							label={kitchenTryPictureAgain}
							variant="ghost"
							tone="inverse"
						/>
					</span>
				</div>
				<CrashCard
					part="message log"
					message="Something in this part of the page went wrong."
					onRetry={() => undefined}
				/>
			</Sample>
			<Sample
				label={kitchenInTheLog}
				note="A conversation-local answer: a send that never left, a command this tab ran. Shared joins stay a centered pill. This tab's own answers sit in the dashed well."
			>
				<div className="kitchen-log">
					<div className="sys here">
						<div className="sys-aside">
							<span className="aside-mark" aria-hidden="true">Only you</span>
							<div className="sys-run">
								<span className="sys-line">
									{PHASE_SAID.disconnected + ". Your message was not sent."}
								</span>
							</div>
						</div>
					</div>
				</div>
			</Sample>
			<Sample
				label="Connection"
				note="The rail's dot and the directory card share these four. Color and shape carry the phase. The words are for a reader who has neither."
			>
				<Row>
					{phases.map((phase) => (
						<span key={phase} className="kitchen-person">
							<span className={"dot " + phase} aria-hidden="true" />
							{PHASE_SAID[phase]}
						</span>
					))}
				</Row>
			</Sample>
		</>
	);
}
