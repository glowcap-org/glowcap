// The page's settings dialog: this window's locators, its appearance, whether
// it asks the browser to notify, how it advertises itself for direct messages,
// and one toggle per operations
// capability. A toggle that is on means this tab holds that capability:
// flipping it on opens the take modal — paste the swiss number, fetch it —
// and only a successful take lands it on. Flipping it off lets the
// capability go. While any is held, an Operations control in the head opens
// the modal with the held panes.

import { useEffect, useRef, useState } from "react";
import { usePeer } from "./peer.ts";
import { current, type DmMode } from "./prefs.ts";
import { Button } from "./Button.tsx";
import { Switch } from "./Switch.tsx";
import { CopyField } from "./Copy.tsx";
import { SettingsHead } from "./SettingsHead.tsx";
import { openModalFrom, useHeldModal, useModalDialog } from "./modal.ts";
import { type TabFace, Tabs } from "./Tabs.tsx";
import { anyOpsHeld, type DirView, OPS_CAPS, type OpsCap, type OpsHeld, type SettingsTab } from "./types.ts";
import { OPS_CATALOG } from "./ops/catalog.ts";

interface SettingsProps {
	open: boolean;
	theme: "light" | "dark";
	notifyOn: boolean;
	/** The directory this page came from, while this tab still holds it. Null
	 * before it has answered and after it has been given back, when Settings
	 * still knows the locator and has no session to open a card about. */
	dir: DirView | null;
	/** Which operations capabilities this tab holds, which is what the toggles
	 * say and what draws the Operations control in the head. */
	opsHeld: OpsHeld;
	/** Whether the Operations modal is the top layer, so its control can sit
	 * pressed while this dialog is retained beneath it. */
	opsOpen: boolean;
	/** Which panel to show when this dialog mounts. Returning from Operations
	 * lands on Advanced rather than resetting to Locators. */
	tab: SettingsTab;
	/** Keep the tree while another native dialog has the top layer. */
	retain?: boolean;
}

export function Settings(
	{ open, retain = false, theme, notifyOn, dir, opsHeld, opsOpen, tab }: SettingsProps,
) {
	const { held, onExited } = useHeldModal(open, retain);
	if (!held) return null;
	return (
		<SettingsDialog
			open={open}
			retain={retain}
			onExited={onExited}
			theme={theme}
			notifyOn={notifyOn}
			dir={dir}
			opsHeld={opsHeld}
			opsOpen={opsOpen}
			tab={tab}
		/>
	);
}

function SettingsDialog(
	{ open, retain, onExited, theme, notifyOn, dir, opsHeld, opsOpen, tab }: Omit<SettingsProps, "retain"> & {
		retain?: boolean;
		onExited: () => void;
	},
) {
	const peer = usePeer();
	const titleId = "settingsTitle";
	const dialog = useRef<HTMLDialogElement>(null);
	// The chosen tab, which is what the dialog opens focus onto.
	const chosenTab = useRef<HTMLButtonElement>(null);
	const [live] = useState(current);
	const [pane, setPane] = useState<SettingsTab>(tab);
	const [dm, setDm] = useState<DmMode>(live.dm);
	const [roomLoc, setRoomLoc] = useState<string | null>(null);
	const [selfLoc, setSelfLoc] = useState<string | null>(null);
	const tabs: readonly TabFace<SettingsTab>[] = [
		{ id: "overview", domId: "overviewTab", label: "Locators", panelId: "overviewPanel" },
		{ id: "settings", domId: "settingsTab", label: "Advanced", panelId: "settingsPanel" },
	];
	useModalDialog(
		dialog,
		() => peer.closeSettings(),
		chosenTab,
		open,
		onExited,
		retain,
	);

	useEffect(() => {
		let cancelled = false;
		const showSelf = () => {
			if (!cancelled) setSelfLoc(peer.selfLocator());
		};
		showSelf();
		void peer.directoryReady.then(showSelf);
		setRoomLoc(peer.directoryLocator());
		return () => {
			cancelled = true;
		};
	}, [peer]);

	const dirty = dm !== live.dm;
	const selectPane = (next: SettingsTab) => {
		setPane(next);
		peer.setSettingsTab(next);
	};
	const save = () => {
		if (!dirty) {
			peer.closeSettings();
			return;
		}
		peer.applySettings({ dm });
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
		>
			<form
				className="modal-card"
				data-dir="home"
				onSubmit={(e) => {
					e.preventDefault();
					save();
				}}
			>
				<SettingsHead
					titleId={titleId}
					title="Settings"
					theme={theme}
					notifyOn={notifyOn}
					helpOpen={false}
					named={open}
					ops={anyOpsHeld(opsHeld)
						? {
							open: opsOpen,
							onOpen: (event) => openModalFrom(event.currentTarget, () => peer.openOperations()),
						}
						: undefined}
					closeId={open ? "settingsClose" : undefined}
					closeLabel={dirty ? "Discard changes and close" : "Close"}
					onClose={() => peer.closeSettings()}
				>
					<Tabs
						tabs={tabs}
						selected={pane}
						labelledBy={titleId}
						chosenRef={chosenTab}
						onSelect={selectPane}
					/>
				</SettingsHead>
				{pane === "overview" && (
					<div
						id="overviewPanel"
						role="tabpanel"
						aria-labelledby="overviewTab"
					>
						{
							/* This page's directory, as an address. What it granted you and
						    Leave live on its card — the same card a room's caption opens —
						    so this panel does not answer those twice. */
						}
						<div className="group well">
							<p className="uri-label">This directory</p>
							<CopyField
								id="directoryLocator"
								text={roomLoc}
								label="Copy the locator for this directory"
							/>
							<p className="hint">This is the address of the room directory the page is showing.</p>
							{dir !== null && (
								<Button
									id="settingsAboutDir"
									type="button"
									variant="quiet"
									onClick={(event) =>
										openModalFrom(event.currentTarget, () => peer.aboutDirectory(dir.id))}
								>
									About this directory
								</Button>
							)}
						</div>
						<div className="group well">
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
						<div className="group well" role="group" aria-labelledby="dmLegend">
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
									A peer that is not a browser can write first. Noise encrypts the direct connection
									end to end; the relay carries only ciphertext.
								</span>
							</label>
						</div>
						{
							/* One toggle per operations capability, and the toggle is the
						    capability: on means this tab holds it. Flipping one on opens
						    the take modal, and only a successful take lands it on;
						    flipping it off lets the capability go, pane and swiss with
						    it. The Operations control in the head appears while any is
						    held. */
						}
						<div className="group well" role="group" aria-labelledby="opsLegend">
							<p className="group-label" id="opsLegend">Operations</p>
							{OPS_CAPS.map((cap: OpsCap) => (
								<div className="switch-row" key={cap}>
									<p className="group-label" id={`ops-${cap}-legend`}>{OPS_CATALOG[cap].label}</p>
									<Switch
										id={OPS_CATALOG[cap].toggleId}
										checked={opsHeld[cap]}
										label={OPS_CATALOG[cap].label}
										aria-labelledby={`ops-${cap}-legend`}
										onClick={(event) => {
											if (opsHeld[cap]) {
												peer.dropOpsCap(cap);
											} else openModalFrom(event.currentTarget, () => peer.openOpsTake(cap));
										}}
									/>
								</div>
							))}
						</div>
						<Button type="submit" disabled={!dirty}>Save and reload</Button>
					</div>
				)}
			</form>
		</dialog>
	);
}
