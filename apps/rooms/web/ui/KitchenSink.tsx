// Every rooms control, in one place. Reached from Help's title: a pointer
// double-clicks it, a keyboard Tabs to it and presses Enter.
//
// Not a product surface: nothing here is how a reader does a job. It exists so
// a change to a button, a tone, or a notice can be seen next to its siblings
// without hunting through Settings, the rail, and the log.

import { type ReactNode, useState } from "react";
import { Avatar, PresenceAvatar } from "./Avatar.tsx";
import { JOIN_DEFAULT_NICK, JOIN_DEFAULT_ROOM, JOIN_LOCATOR_SHAPE } from "./joining.ts";
import { Button } from "./Button.tsx";
import { WorkingAction } from "./WorkingAction.tsx";
import { JoinField, JoinPrefix } from "./JoinField.tsx";
import { CopyButton, CopyField } from "./Copy.tsx";
import { PHASE_SAID } from "./text.ts";
import { CrashCard } from "./ErrorBoundary.tsx";
import { Icon, iconNames } from "./icons.tsx";
import { IconButton, type IconButtonTone } from "./IconButton.tsx";
import { usePeer } from "./peer.ts";
import { Said } from "./Said.tsx";
import { Switch } from "./Switch.tsx";
import { Checkbox } from "./Checkbox.tsx";
import { ToastCard } from "./Toast.tsx";
import type { SessionPhase } from "./types.ts";

const swatches = [
	["ink", "--ink"],
	["ink-soft", "--ink-soft"],
	["paper", "--paper"],
	["paper-raised", "--paper-raised"],
	["accent", "--accent"],
	["teal", "--teal"],
	["danger", "--danger"],
	["warn", "--warn"],
	["rule", "--rule"],
] as const;

const typeRamp = [
	["display", "--type-display"],
	["title", "--type-title"],
	["body", "--type-body"],
	["ui", "--type-ui"],
	["caption", "--type-caption"],
	["tiny", "--type-tiny"],
] as const;

const iconTones: readonly IconButtonTone[] = [
	"neutral",
	"accent",
	"teal",
	"danger",
	"inverse",
	"on-accent",
];

const phases: readonly SessionPhase[] = [
	"connected",
	"connecting",
	"reconnecting",
	"disconnected",
];

function Sample({ label, note, children }: { label: string; note?: string; children: ReactNode }) {
	return (
		<section className="kitchen-sample">
			<h3>{label}</h3>
			{note !== undefined ? <p className="kitchen-note">{note}</p> : null}
			{children}
		</section>
	);
}

function Row({ plate, children }: { plate?: "accent" | "dark"; children: ReactNode }) {
	return <div className={plate === undefined ? "kitchen-row" : "kitchen-row kitchen-plate-" + plate}>{children}</div>;
}

export function KitchenSink() {
	const peer = usePeer();
	const [on, setOn] = useState(true);
	const [kept, setKept] = useState(true);
	return (
		<div id="kitchenSink" className="kitchen">
			<p className="lead">The parts this window is made of.</p>
			<Sample label="Colour">
				<Row>
					{swatches.map(([name, token]) => (
						<span key={name} className="kitchen-swatch">
							<span className="kitchen-chip" style={{ background: `var(${token})` }} />
							{name}
						</span>
					))}
				</Row>
			</Sample>
			<Sample label="Type">
				<Row>
					{typeRamp.map(([name, token]) => (
						<span key={name} className="kitchen-type" style={{ fontSize: `var(${token})` }}>
							{name}
						</span>
					))}
				</Row>
			</Sample>
			<Sample label="Icons">
				<Row>
					{iconNames.map((name) => (
						<span key={name} className="kitchen-icon" title={name}>
							<Icon name={name} size={18} />
						</span>
					))}
				</Row>
			</Sample>
			<Sample label="Icon buttons">
				<Row>
					<IconButton icon="gear" label="Outline" />
					<IconButton icon="gear" label="Ghost" variant="ghost" />
					<IconButton icon="gear" label="Solid" variant="solid" tone="accent" />
					<IconButton icon="gear" label="Small" size="small" />
					<IconButton icon="gear" label="Large" size="large" />
					<IconButton icon="gear" label="Circle" shape="circle" />
					<IconButton icon="bell" label="With a count" badge={3} />
					<IconButton icon="gear" label="Disabled" disabled />
					<IconButton icon="gear" label="Pressed" aria-pressed="true" />
				</Row>
				<Row plate="dark">
					<IconButton icon="close" label="inverse ghost" variant="ghost" tone="inverse" />
					<IconButton icon="expand" label="inverse solid" variant="solid" tone="inverse" size="small" />
				</Row>
				<Row plate="accent">
					<IconButton icon="close" label="on-accent ghost" variant="ghost" tone="on-accent" size="small" />
					<IconButton icon="retry" label="on-accent retry" variant="ghost" tone="on-accent" size="small" />
				</Row>
				<Row>
					{iconTones.filter((tone) => tone !== "inverse" && tone !== "on-accent").map((tone) => (
						<IconButton key={tone} icon="gear" label={tone} tone={tone} />
					))}
				</Row>
			</Sample>
			<Sample
				label="Buttons"
				note="A wait keeps saying what it is doing and is not a second press. The × beside it stops that wait, the same mark that stops a file send."
			>
				<Row>
					<Button>Join</Button>
					<Button variant="quiet">Close</Button>
					<Button busy>Saving</Button>
					<Button disabled>Disabled</Button>
				</Row>
				<div className="kitchen-stack">
					<WorkingAction busy stopLabel="Stop joining" onStop={() => undefined}>
						Joining…
					</WorkingAction>
				</div>
				<p className="kitchen-prose">
					Use <Button variant="link">this directory</Button> or{" "}
					<Button variant="link">a step sideways</Button>.
				</p>
				<Row>
					<Button variant="caption" className="rwhere">
						<Icon name="directory" size={12} />
						<span className="rwhere-said">in example</span>
					</Button>
				</Row>
			</Sample>
			<Sample label="Switch">
				<Row>
					<div className="switch-row">
						<p className="group-label" id="kitchenSwitch">A labeled on/off</p>
						<Switch
							checked={on}
							label="A labeled on/off"
							aria-labelledby="kitchenSwitch"
							onClick={() => setOn((was) => !was)}
						/>
					</div>
				</Row>
			</Sample>
			<Sample
				label="Checkbox"
				note="The switch's form-dwelling sibling: include this, inside a form that still has its own submit."
			>
				<Row>
					<label className="check-row">
						<Checkbox checked={kept} onChange={(event) => setKept(event.target.checked)} />
						<span>Remember on this device</span>
					</label>
				</Row>
			</Sample>
			<Sample label="Copy">
				<Row>
					<CopyButton text="ocapn://example" label="Copy the sample locator" />
				</Row>
				<CopyField id="kitchenLocator" text="ocapn://example" label="Copy the sample locator" />
			</Sample>
			<Sample label="Person">
				<Row>
					<Avatar name="Alice" />
					<Avatar name="Bob" />
					<span className="kitchen-person">
						<Avatar name="Alice" />
						Alice
					</span>
				</Row>
			</Sample>
			<Sample
				label="Person, present"
				note="The chip wearing its presence: filled when online, hollow when offline, away by weight. The ring borrows the surface behind it."
			>
				<Row>
					<PresenceAvatar name="Alice" state="online" />
					<PresenceAvatar name="Bob" state="away" reason="lunch" />
					<PresenceAvatar name="Carol" state="offline" />
				</Row>
			</Sample>
			<Sample
				label="Join field"
				note="A prefix that looks like a preview and is the control: the directory mark opens held locators, the hash becomes a lock when the room is private, and a picture of you will one day set one."
			>
				<div className="kitchen-stack" data-dir="home">
					<JoinField>
						<JoinPrefix className="join-prefix-dir" label="Choose a held directory">
							<Icon name="directory" size={18} />
						</JoinPrefix>
						<input readOnly placeholder={JOIN_LOCATOR_SHAPE} />
					</JoinField>
					<JoinField>
						<JoinPrefix label="Make this room private, so only people you hand it to can reach it">
							<span className="join-hash" aria-hidden="true">#</span>
						</JoinPrefix>
						<input readOnly placeholder={JOIN_DEFAULT_ROOM} />
					</JoinField>
					<JoinField>
						<JoinPrefix label="A picture of you. Choosing one is not offered yet.">
							<Avatar name={JOIN_DEFAULT_NICK} />
						</JoinPrefix>
						<input readOnly placeholder={JOIN_DEFAULT_NICK} />
					</JoinField>
				</div>
			</Sample>
			<Sample
				label="Session banner"
				note="Status of this conversation's session. It stays until the session says otherwise."
			>
				<div className="kitchen-stage">
					<div className="banner notice show">The room is quiet for a moment</div>
					<div className="banner working show">Reconnecting…</div>
					<div className="banner error show" role="alert">
						<span className="banner-mark" aria-hidden="true">
							<Icon name="fail" size={16} />
						</span>
						Could not reach this directory
					</div>
				</div>
			</Sample>
			<Sample
				label="Page notice"
				note="A refusal with nowhere on the control to live. It leaves on its own. Press to see one live, above this card."
			>
				<div className="kitchen-toasts">
					<ToastCard kind="success" text="A success notice" onDismiss={() => undefined} />
					<ToastCard kind="failure" text="A failure notice" onDismiss={() => undefined} />
					<ToastCard kind="warning" text="A warning notice" onDismiss={() => undefined} />
				</div>
				<Row>
					<Button variant="quiet" onClick={() => peer.toast("success", "A success notice")}>
						Success
					</Button>
					<Button variant="quiet" onClick={() => peer.toast("failure", "A failure notice")}>
						Failure
					</Button>
					<Button variant="quiet" onClick={() => peer.toast("warning", "A warning notice")}>
						Warning
					</Button>
				</Row>
			</Sample>
			<Sample
				label="Beside the control"
				note="The field, the bell, or the meter still owns the answer. Danger when it refused; warning when the standing condition is the reader's to fix."
			>
				<div className="kitchen-stack">
					<p className="kitchen-note">A field that would not take the value</p>
					<label className="group-label" htmlFor="kitchenInvalid">Display name</label>
					<input
						id="kitchenInvalid"
						className="field"
						readOnly
						value="a name that will not fit"
						aria-invalid="true"
						aria-describedby="kitchenInvalidWhy"
					/>
					<Said id="kitchenInvalidWhy" kind="failure">
						That name is too long for this room (32 characters).
					</Said>
				</div>
				<div className="kitchen-stack">
					<p className="kitchen-note">A standing condition on a control that stays</p>
					<Row>
						<IconButton icon="bell" label="Notify me when I'm mentioned" aria-pressed="true" />
					</Row>
					<Said kind="warning">
						Notifications are on here, but this browser is blocking them.
					</Said>
				</div>
				<div className="kitchen-stack">
					<p className="kitchen-note">The draft is past what this room will carry</p>
					<div className="hint room-cap over">12 bytes too long for this room</div>
				</div>
			</Sample>
			<Sample
				label="On the thing"
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
										label="Retry failed message"
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
					<button type="button" className="act" aria-label="Retry the sample picture">
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
							label="Try the sample picture again"
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
				label="In the log"
				note="A conversation-local answer: a send that never left, a command this tab ran. Shared joins stay a centred pill; this tab's own answers sit in the dashed well."
			>
				<div className="kitchen-log">
					<div className="sys here">
						<div className="sys-aside">
							<span className="aside-mark" aria-hidden="true">Only you</span>
							<div className="sys-run">
								<span className="sys-line">Not connected, your message was not sent</span>
							</div>
						</div>
					</div>
				</div>
			</Sample>
			<Sample
				label="Connection"
				note="The rail's dot and the directory card share these four. Colour and shape carry the phase; the words are for a reader who has neither."
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
		</div>
	);
}
