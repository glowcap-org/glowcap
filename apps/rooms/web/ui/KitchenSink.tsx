// Every rooms control, in one place. Reached from Help's title: a pointer
// double-clicks it, a keyboard Tabs to it and presses Enter.
//
// Not a product surface: nothing here is how a reader does a job. It exists so
// a change to a button, a tone, or a notice can be seen next to its siblings
// without hunting through Settings, the rail, and the log.

import { useState } from "react";
import { Avatar, PresenceAvatar } from "./Avatar.tsx";
import { JOIN_DEFAULT_NICK, JOIN_DEFAULT_ROOM, JOIN_LOCATOR_SHAPE } from "./joining.ts";
import { Button } from "./Button.tsx";
import { Confirm } from "./Confirm.tsx";
import { Field } from "./Field.tsx";
import { WorkingAction } from "./WorkingAction.tsx";
import { JoinField, JoinPrefix } from "./cards/JoinField.tsx";
import { CopyButton, CopyField } from "./Copy.tsx";
import { Icon, iconNames } from "./icons.tsx";
import { IconButton, type IconButtonTone } from "./IconButton.tsx";
import { Said } from "./Said.tsx";
import { Switch } from "./Switch.tsx";
import { PHASE_SAID } from "./text.ts";
import { KitchenAnswers } from "./KitchenAnswers.tsx";
import { Row, Sample } from "./KitchenSample.tsx";
import { Checkbox } from "./Checkbox.tsx";
import { Segmented } from "./Segmented.tsx";

const swatches = [
	["ink", "--ink"],
	["ink-soft", "--ink-soft"],
	["paper", "--paper"],
	["paper-raised", "--paper-raised"],
	["accent", "--accent"],
	["teal", "--teal"],
	["irc", "--irc"],
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

export function KitchenSink() {
	const [on, setOn] = useState(true);
	const [kept, setKept] = useState(true);
	// The answers in force, which is the caller's job wherever a set of them is
	// drawn. Some start turned off, so the sink shows both faces of a cell at
	// once rather than a row that is all one thing.
	const [inView, setInView] = useState(new Set(["public", "here", "unread"]));
	const include = (value: string) =>
		setInView((was) => {
			const next = new Set(was);
			if (!next.delete(value)) next.add(value);
			return next;
		});
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
					<IconButton id="kitchenBusyIcon" icon="gear" label="Working" busy />
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
				note="Three boxed variants at two sizes. The commitment is amber, the commitment that takes something away is red, and the quiet way out is teal. Normal is the in-row height, large the field height. A wait keeps saying what it is doing and is not a second press. The × beside it stops that wait, the same mark that stops a file send."
			>
				<Row>
					<Button>Save</Button>
					<Button variant="danger">Delete</Button>
					<Button variant="quiet">Close</Button>
					<Button id="kitchenBusyButton" busy>Saving</Button>
					<Button disabled>Disabled</Button>
				</Row>
				<Row>
					<Button size="large">Join room</Button>
					<Button size="large" variant="danger">Leave</Button>
					<Button size="large" variant="quiet">Stay</Button>
				</Row>
				<div className="kitchen-stack">
					<WorkingAction size="large" block busy stopLabel="Stop joining" onStop={() => undefined}>
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
			<Sample
				label="A question"
				note="Label, refusal, control, sentence, on one rhythm: what you must act on stands over the box, what only informs sits under it. Beside a field, the act stands level with the control at the field height. On a phone it drops under it. Inline lays a short list of knobs on one name column."
			>
				<div className="kitchen-stack">
					<Field id="kitchenFieldPlain" label="Display name" hint="Shown beside what you say.">
						{(wiring) => (
							<input
								id={wiring.id}
								className="field"
								readOnly
								value="alice"
								aria-describedby={wiring.describedBy}
							/>
						)}
					</Field>
					<div className="field-row">
						<Field
							id="kitchenFieldRow"
							label="Session capability"
							said="Paste the session's ocapn:// capability link."
						>
							{(wiring) => (
								<input
									id={wiring.id}
									className="field"
									readOnly
									value="not a link"
									aria-describedby={wiring.describedBy}
									aria-invalid={wiring.invalid}
								/>
							)}
						</Field>
						<Button size="large">Attach</Button>
					</div>
					<Field id="kitchenFieldSelect" label="Access">
						{(wiring) => (
							<span className="select-wrap">
								<select id={wiring.id} className="field" defaultValue="interact">
									<option value="observe">Read only</option>
									<option value="interact">Can interact</option>
								</select>
							</span>
						)}
					</Field>
					<Field id="kitchenFieldInline" label="port" layout="inline">
						{(wiring) => (
							<input
								id={wiring.id}
								className="field"
								readOnly
								placeholder="an ephemeral port"
							/>
						)}
					</Field>
				</div>
			</Sample>
			<Sample
				label="Acts"
				note="At the end of the line they belong to, the commitment last. A card's own foot fills the width instead."
			>
				<div className="kitchen-stack">
					<div className="actions">
						<Button variant="quiet">Discard</Button>
						<Button>Save changes</Button>
					</div>
					<Said kind="success">Capability set saved.</Said>
					<div className="actions" data-fill>
						<Button size="large" variant="quiet">Stay</Button>
						<Button size="large">Join room</Button>
					</div>
				</div>
			</Sample>
			<Sample
				label="A second step"
				note="What will be lost, in the reader's words, then the way out and the commitment. The rule at the left is the commitment's tone."
			>
				<div className="kitchen-stack">
					<Confirm
						label="Leave the room"
						say="Leave #design? You can come back by its name."
						keep="Stay"
						commit="Leave"
						onKeep={() => undefined}
						onCommit={() => undefined}
					/>
					<Confirm
						label="Continue locally"
						tone="primary"
						say="This browser detaches and keeps working from a local copy. Later changes will not sync."
						keep="Stay attached"
						commit="Continue locally"
						onKeep={() => undefined}
						onCommit={() => undefined}
					/>
				</div>
			</Sample>
			<Sample
				label="Entries"
				note="One thing the surface knows about per row: the name, a short fact, the acts at the line's end, and the longer facts under it."
			>
				<div className="kitchen-stack">
					<ul className="entries">
						<li className="entry">
							<div className="entry-head">
								<span className="entry-name">keyed-relay</span>
								<span className="tag">this page</span>
								<div className="actions">
									<Button variant="quiet">Revoke…</Button>
								</div>
							</div>
							<p className="entry-meta">
								from ocapn://example
							</p>
						</li>
						<li className="entry" data-idle="true">
							<div className="entry-head">
								<span className="entry-name">onion</span>
								<span className="entry-meta">unavailable</span>
							</div>
							<p className="hint">This server was started without a running Tor.</p>
						</li>
					</ul>
					<p className="empty">Nothing here yet.</p>
				</div>
			</Sample>
			<Sample
				label="Chips"
				note="A short fact beside a name. Teal is the default. A list whose chips are a scale rather than a set of equals ranks them with a tone."
			>
				<Row>
					<span className="tag">this page</span>
					<span className="tag" data-tone="quiet">Read only</span>
					<span className="tag">Can interact</span>
					<span className="tag" data-tone="warn">Can administer</span>
				</Row>
			</Sample>
			<Sample label="A door" note="A mark, a name and one sentence, and the act that goes through it.">
				<div className="kitchen-stack">
					<div className="launch">
						<span className="launch-mark" aria-hidden="true">
							<Icon name="session" size={18} />
						</span>
						<div className="launch-copy">
							<p className="launch-title">
								<span>Local session</span>
								<span className="tag">This browser</span>
							</p>
							<p className="hint">This browser owns this session.</p>
						</div>
						<Button variant="quiet">Manage local data…</Button>
					</div>
				</div>
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
			<Sample
				label="Segmented"
				note="A closed set of answers, any number of which can be in force. Finished and ready to use, though nothing in the page draws one yet. It is as wide as its answers and never wider, it stays on one line, every boundary in it is a single line that lights from whichever side of it was chosen, and the squeezed example is as narrow as the rail so its answers cut rather than break. Each cell is a button that answers Tab and Space. Arrow walking belongs to the tab bar next door, where the answers take turns."
			>
				<div className="kitchen-stack">
					<p className="group-label" id="kitchenSegmentedAccess">Who can get in</p>
					<Segmented
						aria-labelledby="kitchenSegmentedAccess"
						choices={[{ value: "public", label: "Public" }, { value: "private", label: "Private" }]}
						chosen={inView}
						onToggle={include}
					/>
					<p className="group-label" id="kitchenSegmentedWhere">
						Squeezed to the rail's width, with names long enough to cut
					</p>
					<div className="kitchen-narrow">
						<Segmented
							id="kitchenSegmentedWrap"
							aria-labelledby="kitchenSegmentedWhere"
							choices={[
								{ value: "here", label: "this directory" },
								{ value: "unread", label: "127.0.0.1:6000" },
								{ value: "quiet", label: "ocapn://a-very-long-address" },
								{ value: "away", label: "somewhere else" },
							]}
							chosen={inView}
							onToggle={include}
						/>
					</div>
					{
						/* The control has no idea an icon is an icon. A cell draws
						   whatever it is handed, and this page's icons are drawn
						   aria-hidden, so a cell built this way still announces as
						   its words. */
					}
					<p className="group-label" id="kitchenSegmentedMarked">With an icon in each answer</p>
					<Segmented
						aria-labelledby="kitchenSegmentedMarked"
						choices={[
							{
								value: "public",
								label: (
									<>
										<Icon name="group" size={11} />
										Public
									</>
								),
							},
							{
								value: "private",
								label: (
									<>
										<Icon name="lock" size={11} />
										Private
									</>
								),
							},
						]}
						chosen={inView}
						onToggle={include}
					/>
					<p className="group-label" id="kitchenSegmentedOff">With nothing on offer</p>
					<Segmented
						aria-labelledby="kitchenSegmentedOff"
						choices={[{ value: "public", label: "Public" }, { value: "private", label: "Private" }]}
						chosen={inView}
						onToggle={include}
						disabled
					/>
				</div>
			</Sample>
			<Sample label="Copy">
				<Row>
					<CopyButton text="ocapn://example" label="Copy the sample locator" />
				</Row>
				<CopyField id="kitchenLocator" text="ocapn://example" label="Copy the sample locator" />
				<CopyField
					text="ocapn://127.0.0.1%3A9765.tcp/s/cGFuY2FrZS1kZXNpZ24tc3lzdGVtLWNvbXBhY3QtY29weQ"
					label="Copy the sample locator, compactly"
				/>
				<CopyField
					compact={false}
					text="ocapn://127.0.0.1%3A9765.tcp/s/cGFuY2FrZS1kZXNpZ24tc3lzdGVtLWNvbXBhY3QtZXhwYW5kZWQtY29weQ"
					label="Copy the expanded sample locator"
				/>
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
						<JoinPrefix className="join-prefix-dir" label="Choose one of your directories">
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
				label="A room's directory"
				note="The caption every row carries: which directory the room is on, and how that directory is doing when it is not simply connected. It stays until that directory says otherwise, and pressing it opens what is known about that directory."
			>
				<div className="kitchen-stage">
					<Button variant="caption" className="rwhere">
						<Icon name="directory" size={12} />
						<span className="rwhere-said">in this directory</span>
					</Button>
					<Button variant="caption" className="rwhere">
						<Icon name="directory" size={12} />
						<span className="rwhere-said">in 127.0.0.1:6000</span>
						<span className="rwhere-how">{PHASE_SAID.reconnecting}</span>
					</Button>
					<Button variant="caption" className="rwhere">
						<Icon name="directory" size={12} />
						<span className="rwhere-how">{PHASE_SAID.disconnected}</span>
					</Button>
				</div>
			</Sample>
			<KitchenAnswers />
		</div>
	);
}
