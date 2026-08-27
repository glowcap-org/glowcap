// The page's settings dialog: this window's locators, its appearance, whether
// it asks the browser to notify, how it advertises itself for direct messages,
// and one saved operations-capability bundle. The bundle has one switch per
// capability and one text projection; saving reconciles both possession and
// durable custody. While any capability is held, an Operations control in the
// head stands the reader on the /ops page with the held panes.

import { useEffect, useRef, useState } from "react";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { current, type DmMode } from "./prefs.ts";
import { Button } from "./Button.tsx";
import { CopyField } from "./Copy.tsx";
import { SettingsHead } from "./SettingsHead.tsx";
import { openModalFrom, useHeldModal, useModalDialog } from "./modal.ts";
import { type TabFace, Tabs } from "./Tabs.tsx";
import { anyOpsHeld, type DirView, type OpsHeld, type SettingsTab } from "./types.ts";
import type { ArchiveTargetView } from "./archive_model.ts";
import { CapabilitySetForm } from "./settings/CapabilitySet.tsx";
import { useCapabilitySetModel } from "./settings/CapabilitySetModel.tsx";
import { Confirm } from "./Confirm.tsx";
import { SessionSettings } from "./settings/Session.tsx";
import { Said } from "./Said.tsx";
import type { RoomsSessionFacet } from "../../lib/rooms_session.ts";
import { effectiveRoomsSessionAccess } from "./controller/access.ts";

interface SettingsProps {
	open: boolean;
	theme: "light" | "dark";
	notifyOn: boolean;
	/** The directory this page came from, while this tab still holds it. Null
	 * before it has answered and after it has been given back, when Settings
	 * still knows the locator and has no session to open a card about. */
	dir: DirView | null;
	/** Which operations capabilities this tab holds, which draws the Operations control in the head. */
	opsHeld: OpsHeld;
	/** Whether the selected archive keeps message history; the Capabilities switch
	 * draws it and `session.setKeepHistory` flips it. */
	keepHistory: boolean;
	/** Where member-owned history is currently written. */
	archiveTarget: ArchiveTargetView;
	/** Null for a local controller; otherwise the authority carried by this attached facet. */
	sessionAccess: RoomsSessionFacet | null;
	/** Which panel to show when this dialog mounts. Returning from a take
	 * lands on Capabilities rather than resetting to Locators. */
	tab: SettingsTab;
	/** Keep the tree while another native dialog has the top layer. */
	retain?: boolean;
}

export function Settings(
	{ open, retain = false, theme, notifyOn, dir, opsHeld, keepHistory, archiveTarget, sessionAccess, tab }:
		SettingsProps,
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
			keepHistory={keepHistory}
			archiveTarget={archiveTarget}
			sessionAccess={sessionAccess}
			tab={tab}
		/>
	);
}

function SettingsDialog(
	{ open, retain, onExited, theme, notifyOn, dir, opsHeld, keepHistory, archiveTarget, sessionAccess, tab }:
		& Omit<
			SettingsProps,
			"retain"
		>
		& {
			retain?: boolean;
			onExited: () => void;
		},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const capabilitySet = useCapabilitySetModel();
	const controller = browser.roomsController();
	const access = effectiveRoomsSessionAccess(controller, sessionAccess);
	const canInteract = access != null && access !== "observe";
	const canAdminister = access === "admin";
	const titleId = "settingsTitle";
	const dialog = useRef<HTMLDialogElement>(null);
	// The chosen tab, which is what the dialog opens focus onto.
	const chosenTab = useRef<HTMLButtonElement>(null);
	const [live] = useState(current);
	const tabs: readonly TabFace<SettingsTab>[] = [
		{ id: "overview", domId: "overviewTab", label: "Locators", panelId: "overviewPanel" },
		{ id: "session", domId: "sessionTab", label: "Data", panelId: "sessionPanel" },
		...(canInteract
			? [
				{ id: "settings", domId: "settingsTab", label: "Advanced", panelId: "settingsPanel" },
			] as const
			: []),
	];
	// The operations capability set lives under Advanced now; a remembered
	// "capabilities" tab still lands there.
	const asked: SettingsTab = tab === "capabilities" ? "settings" : tab;
	const [pane, setPane] = useState<SettingsTab>(
		tabs.some((candidate) => candidate.id === asked) ? asked : "overview",
	);
	const [dm, setDm] = useState<DmMode>(live.dm);
	const [dmError, setDmError] = useState("");
	const [roomLoc, setRoomLoc] = useState<string | null>(null);
	const [selfLoc, setSelfLoc] = useState<string | null>(null);
	const [dmBusy, setDmBusy] = useState(false);
	const [guarding, setGuarding] = useState(false);
	useModalDialog(
		dialog,
		() => requestCloseRef.current(),
		chosenTab,
		open,
		onExited,
		retain,
	);

	useEffect(() => {
		let cancelled = false;
		const showSelf = () => {
			if (!cancelled) setSelfLoc(session.selfLocator());
		};
		showSelf();
		void session.directoryReady.then(showSelf);
		setRoomLoc(session.directoryLocator());
		return () => {
			cancelled = true;
		};
	}, [session]);

	// What closing this window would throw away, named in the reader's words.
	// Both live under Advanced, so the question is asked there, above the form
	// that holds the changes, rather than as a bare "are you sure" on top of a
	// panel the reader cannot see from.
	const unsaved = [
		dm !== live.dm ? "the direct message connection" : "",
		capabilitySet.dirty ? "the capability set" : "",
	].filter((subject) => subject !== "");
	const dirty = dm !== live.dm;
	const selectPane = (next: SettingsTab) => {
		setPane(next);
		setGuarding(false);
		browser.setSettingsTab(next);
	};
	const requestCloseRef = useRef(() => {});
	const requestClose = () => {
		if (unsaved.length === 0) {
			browser.closeSettings();
			return;
		}
		setPane("settings");
		setGuarding(true);
	};
	requestCloseRef.current = requestClose;
	const save = async () => {
		if (!dirty) {
			browser.closeSettings();
			return;
		}
		setDmBusy(true);
		setDmError("");
		try {
			if (!await session.applySettings({ dm })) {
				setDmError("This browser refused to save the connection choice.");
			}
		} finally {
			setDmBusy(false);
		}
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
			<div
				className="modal-card card-plane"
				data-dir="home"
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
							// Operations is its own page now, so the control
							// navigates rather than layering: never pressed.
							open: false,
							onOpen: () => browser.openOperations(),
						}
						: undefined}
					closeId={open ? "settingsClose" : undefined}
					onClose={requestClose}
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
						<h3 className="well-title overline" id="directoryLegend">This directory</h3>
						<div className="group well" role="group" aria-labelledby="directoryLegend">
							<CopyField
								id="directoryLocator"
								text={roomLoc}
								label="Copy the locator for this directory"
							/>
							<p className="hint">This is the address of the room directory the page is showing.</p>
							{dir !== null && (
								<div className="actions">
									<Button
										id="settingsAboutDir"
										type="button"
										variant="quiet"
										onClick={(event) =>
											openModalFrom(event.currentTarget, () => browser.aboutDirectory(dir.id))}
									>
										About this directory
									</Button>
								</div>
							)}
						</div>
						<h3 className="well-title overline" id="browserLegend">This browser</h3>
						<div className="group well" role="group" aria-labelledby="browserLegend">
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
				{pane === "session" && (
					<div
						id="sessionPanel"
						role="tabpanel"
						aria-labelledby="sessionTab"
					>
						<SessionSettings keepHistory={keepHistory} archiveTarget={archiveTarget} />
					</div>
				)}
				{pane === "settings" && (
					<div
						id="settingsPanel"
						role="tabpanel"
						aria-labelledby="settingsTab"
					>
						{guarding && (
							<Confirm
								id="settingsUnsaved"
								label="Unsaved changes"
								say={`Closing now throws away your changes to ${
									unsaved.length === 2 ? unsaved.join(" and ") : unsaved[0]
								}.`}
								keep="Keep editing"
								commit="Discard and close"
								keepId="settingsUnsavedKeep"
								commitId="settingsUnsavedDiscard"
								onKeep={() => setGuarding(false)}
								onCommit={() => browser.closeSettings()}
							/>
						)}
						<h3 className="well-title overline" id="dmLegend">Direct message connection</h3>
						<form
							id="dmSettingsForm"
							className="group well"
							role="group"
							aria-labelledby="dmLegend"
							onSubmit={(event) => {
								event.preventDefault();
								void save();
							}}
						>
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
									end to end. The relay carries only ciphertext.
								</span>
							</label>
							<p className="hint" id="dmReloadHint">Saving reloads this window.</p>
							{dmError !== "" && <Said kind="failure">{dmError}</Said>}
							<div className="actions">
								<Button id="dmSave" type="submit" busy={dmBusy} disabled={!dirty}>
									Save and reload
								</Button>
							</div>
						</form>

						{
							/* Which operator capabilities this tab holds, for an
						    administering capability only: the rarest setting, under
						    the connection choice anyone with interact access sees. */
						}
						{canAdminister && (
							<>
								<h3 className="well-title overline" id="opsLegend">Operations</h3>
								<div className="group well" role="group" aria-labelledby="opsLegend">
									<CapabilitySetForm />
								</div>
							</>
						)}
					</div>
				)}
			</div>
		</dialog>
	);
}
