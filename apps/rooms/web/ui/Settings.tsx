// The page's settings dialog: this window's locators, its appearance, whether
// it asks the browser to notify, how it advertises itself for direct messages,
// and where it publishes a protocol trace. Appearance and notifications apply
// at once. Saving the rest reloads, because those knobs are decided when the
// peer opens.

import { useEffect, useRef, useState } from "react";
import { usePeer } from "./peer.ts";
import { advertisedViz, current, type DmMode } from "./prefs.ts";
import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
import { CopyField } from "./Copy.tsx";
import { DirectoryFacts, GrantedNameNote } from "./DirectoryFacts.tsx";
import { useModalDialog } from "./modal.ts";
import type { DirView } from "./types.ts";

type Pane = "overview" | "settings";

interface SettingsProps {
	open: boolean;
	theme: "light" | "dark";
	notifyOn: boolean;
	/** The directory this page is on, which is the one Settings describes. Null
	 * before any directory has been opened, when there is nothing yet to say about
	 * it beyond the locator the page came with. */
	dir: DirView | null;
	/** How many rooms are held on that directory. */
	rooms: number;
}

export function Settings({ open, theme, notifyOn, dir, rooms }: SettingsProps) {
	return open ? <SettingsDialog theme={theme} notifyOn={notifyOn} dir={dir} rooms={rooms} /> : null;
}

function SettingsDialog({ theme, notifyOn, dir, rooms }: Omit<SettingsProps, "open">) {
	const peer = usePeer();
	const titleId = "settingsTitle";
	const dialog = useRef<HTMLDialogElement>(null);
	const overviewTab = useRef<HTMLButtonElement>(null);
	const settingsTab = useRef<HTMLButtonElement>(null);
	const [live] = useState(current);
	const [pane, setPane] = useState<Pane>("overview");
	const [dm, setDm] = useState<DmMode>(live.dm);
	const [viz, setViz] = useState(live.viz);
	const [vizHintUrl, setVizHintUrl] = useState<string | null>(null);
	const [roomLoc, setRoomLoc] = useState<string | null>(null);
	const [selfLoc, setSelfLoc] = useState<string | null>(null);
	const [notifyErr, setNotifyErr] = useState<string | null>(null);
	useModalDialog(dialog, () => peer.closeSettings(), overviewTab);

	useEffect(() => {
		let cancelled = false;
		const showSelf = () => {
			if (!cancelled) setSelfLoc(peer.selfLocator());
		};
		showSelf();
		void peer.directoryReady.then(showSelf);
		void advertisedViz().then((url) => {
			if (!cancelled) setVizHintUrl(url);
		});
		setRoomLoc(peer.directoryLocator());
		return () => {
			cancelled = true;
		};
	}, [peer]);

	const dirty = dm !== live.dm || viz.trim() !== live.viz.trim();
	const selectPane = (next: Pane) => setPane(next);
	const selectAndFocus = (next: Pane) => {
		selectPane(next);
		queueMicrotask(() => (next === "overview" ? overviewTab : settingsTab).current?.focus());
	};
	const save = () => {
		if (!dirty) {
			peer.closeSettings();
			return;
		}
		peer.applySettings({ dm, viz });
	};

	// One panel is in the document at a time, rather than two that take turns
	// being `display: none`.
	//
	// A panel laid out while it is hidden is laid out against whatever width the
	// engine has for it then, and the height that pass produces is not guaranteed
	// to be revisited when the panel is shown at the width it will actually
	// occupy. Mobile Safari kept one: the radio descriptions were measured
	// wrapping to three lines and painted wrapping to two, so the panel stood
	// forty pixels, two lines, taller than its own contents until any re-render
	// forced the measurement again. Mounted when it is selected, a panel's first
	// layout is its real one.
	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby={titleId}
			onClick={(event) => {
				if (event.target === event.currentTarget) peer.closeSettings();
			}}
		>
			<form
				className="modal-card"
				onSubmit={(e) => {
					e.preventDefault();
					save();
				}}
			>
				<div className="settings-head">
					<div className="settings-head-row">
						<h2 id={titleId}>Settings</h2>
						<div className="settings-toggles">
							<IconButton
								id="themeToggle"
								icon={theme === "dark" ? "sun" : "moon"}
								label="Toggle light or dark theme"
								title={theme === "dark" ? "Switch to light" : "Switch to syrup (dark)"}
								onClick={() => peer.setTheme(theme === "dark" ? "light" : "dark")}
							/>
							<IconButton
								id="notifyToggle"
								icon={notifyOn ? "bell" : "bellOff"}
								label="Toggle mention notifications"
								title="Notify me when I'm mentioned"
								aria-pressed={notifyOn}
								aria-describedby={notifyErr ? "notifyHint" : undefined}
								onClick={() => {
									void peer.toggleNotify().then(setNotifyErr);
								}}
							/>
						</div>
					</div>
					{notifyErr ? <p id="notifyHint" className="hint" role="alert">{notifyErr}</p> : null}
					<div
						className="settings-tabs"
						data-thumb={pane === "settings" ? "end" : "start"}
						role="tablist"
						aria-labelledby={titleId}
						onKeyDown={(e) => {
							const go = (next: Pane) => {
								e.preventDefault();
								selectAndFocus(next);
							};
							if (e.key === "ArrowRight" || e.key === "ArrowDown" || e.key === "End") {
								go("settings");
							} else if (e.key === "ArrowLeft" || e.key === "ArrowUp" || e.key === "Home") {
								go("overview");
							}
						}}
					>
						<span className="settings-tabs-thumb" aria-hidden="true" />
						<button
							ref={overviewTab}
							id="overviewTab"
							type="button"
							className="settings-tab"
							role="tab"
							aria-selected={pane === "overview"}
							aria-controls={pane === "overview" ? "overviewPanel" : undefined}
							tabIndex={pane === "overview" ? 0 : -1}
							onClick={() => selectPane("overview")}
						>
							Locators
						</button>
						<button
							ref={settingsTab}
							id="settingsTab"
							type="button"
							className="settings-tab"
							role="tab"
							aria-selected={pane === "settings"}
							aria-controls={pane === "settings" ? "settingsPanel" : undefined}
							tabIndex={pane === "settings" ? 0 : -1}
							onClick={() => selectPane("settings")}
						>
							Advanced
						</button>
					</div>
				</div>
				{pane === "overview" && (
					<div
						id="overviewPanel"
						role="tabpanel"
						aria-labelledby="overviewTab"
					>
						{
							/* This directory, said in the same three answers the card for any
						    other directory gives, so the question has one shape wherever it
						    is asked. The rail's caption under a room on this directory opens
						    exactly here. */
						}
						<div className="group">
							<p className="uri-label">This directory</p>
							<CopyField
								id="directoryLocator"
								text={roomLoc}
								label="Copy the locator for this directory"
							/>
							{dir !== null && <DirectoryFacts dir={dir} rooms={rooms} />}
							<p className="hint">This is the address of the room directory the page is showing.</p>
							<GrantedNameNote />
						</div>
						<div className="group">
							<p className="uri-label">This browser</p>
							<CopyField
								id="selfLocator"
								text={selfLoc}
								label="Copy this browser's locator"
							/>
							<p className="hint">
								Your browser's own locator lets another peer open a direct conversation with you.
							</p>
						</div>
					</div>
				)}
				{pane === "settings" && (
					<div
						id="settingsPanel"
						role="tabpanel"
						aria-labelledby="settingsTab"
					>
						<p className="lead">
							Saving reloads this window.
						</p>
						<div className="group" role="group" aria-labelledby="dmLegend">
							<p className="group-label" id="dmLegend">Direct message connection</p>
							<label className="choice">
								<input
									type="radio"
									name="dm"
									value="webrtc"
									checked={dm === "webrtc"}
									onChange={() => setDm("webrtc")}
								/>
								<span>
									<strong>Browser to browser</strong>
									Encrypted between browsers. A non-browser peer can only reply after you write first.
								</span>
							</label>
							<label className="choice">
								<input
									type="radio"
									name="dm"
									value="relay"
									checked={dm === "relay"}
									onChange={() => setDm("relay")}
								/>
								<span>
									<strong>Through the room relay</strong>
									A peer that is not a browser can write first. The relay carries those messages in
									the clear.
								</span>
							</label>
						</div>
						<div className="group" role="group" aria-labelledby="vizLegend">
							<p className="group-label" id="vizLegend">Protocol visualizer</p>
							<p id="vizLead" className="hint">
								This window publishes its own sessions, including direct messages.
							</p>
							<input
								id="vizUrl"
								name="viz"
								type="text"
								inputMode="url"
								placeholder={vizHintUrl ?? "e.g. ws://127.0.0.1:9300/"}
								value={viz}
								onChange={(e) => setViz(e.target.value)}
								autoComplete="off"
								spellCheck={false}
								aria-labelledby="vizLegend"
								aria-describedby="vizLead vizHint"
							/>
							<p id="vizHint" className="hint">
								Leave blank to use the value at <code>/viz</code> if available.
							</p>
						</div>
						<Button type="submit" disabled={!dirty}>Save and reload</Button>
					</div>
				)}
				<Button variant="quiet" onClick={() => peer.closeSettings()}>
					{dirty ? "Cancel" : "Close"}
				</Button>
			</form>
		</dialog>
	);
}
