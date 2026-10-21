// The page's settings dialog: session custody, capability holdings, and
// reachability. Holdings separates live session possession
// from explicitly saved bearer authority. While any operations capability is
// live, the head also offers the Operations page that can use it.

import { memo, useEffect, useRef, useState } from "react";
import {
	dmConnectionTitle,
	reachAboutDirectory,
	reachBrowserTitle,
	reachDirectoryTitle,
	settingsConnectionRefused,
	settingsConnectionSaving,
	settingsCopyBrowser,
	settingsCopyDirectory,
	settingsDmDirectLabel,
	settingsDmDirectSaid,
	settingsDmRelayLabel,
	settingsDmRelaySaid,
	settingsDmReload,
	settingsShareBrowser,
	settingsShareDirectory,
} from "../../../lib/text/settings.ts";
import { saveAndReload } from "../../../lib/text/controls.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { current, type DmMode } from "../prefs.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { Button } from "../Button.tsx";
import { CopyField } from "../Copy.tsx";
import { SettingsHead } from "./SettingsHead.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { type TabFace, Tabs } from "../Tabs.tsx";
import { anyOpsHeld, type DirView, type OpsHeld, type SettingsTab } from "../types.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { SessionSettings } from "./Session.tsx";
import { Holdings } from "./Holdings.tsx";
import { Said } from "../Said.tsx";
import { useSessionPermission } from "../hooks.ts";
import { useChangeGroup, useCommitments } from "../commitment.tsx";
import { settingsTitle } from "../../../lib/text/settings.ts";
import { settingsHoldingsTab, settingsReachabilityTab, settingsSessionTab } from "../../../lib/text/settings.ts";

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
	/** Whether the selected archive keeps message history. The Capabilities switch
	 * draws it and `session.setKeepHistory` flips it. */
	keepHistory: boolean;
	/** Where member-owned history is written. */
	archiveTarget: ArchiveTargetView;
	/** Which panel to show when this dialog mounts. */
	tab: SettingsTab;
	/** Keep the tree while another native dialog has the top layer. */
	retain?: boolean;
}

export const Settings = memo(function Settings(
	{ open, retain = false, theme, notifyOn, dir, opsHeld, keepHistory, archiveTarget, tab }: SettingsProps,
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
			tab={tab}
		/>
	);
});

function SettingsDialog(
	{ open, retain, onExited, theme, notifyOn, dir, opsHeld, keepHistory, archiveTarget, tab }:
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
	const commitments = useCommitments();
	const session = useRoomsSession();
	const canInteract = useSessionPermission("interactWorkspace");
	const canAdminister = useSessionPermission("manageCustody");
	const titleId = "settingsTitle";
	const dialog = useRef<HTMLDialogElement>(null);
	// The chosen tab receives focus when the dialog opens.
	const chosenTab = useRef<HTMLButtonElement>(null);
	const managed = useManagedSession();
	const [live] = useState(() => current(managed.current?.intent));
	const tabs: readonly TabFace<SettingsTab>[] = [
		{ id: "session", domId: "sessionTab", label: settingsSessionTab, panelId: "sessionPanel" },
		...(canAdminister
			? [
				{ id: "holdings", domId: "holdingsTab", label: settingsHoldingsTab, panelId: "holdingsPanel" },
			] as const
			: []),
		{
			id: "reachability",
			domId: "reachabilityTab",
			label: settingsReachabilityTab,
			panelId: "reachabilityPanel",
		},
	];
	const [pane, setPane] = useState<SettingsTab>(
		tabs.some((candidate) => candidate.id === tab) ? tab : "session",
	);
	const [dm, setDm] = useState<DmMode>(live.dm);
	const [dmError, setDmError] = useState("");
	const [roomLoc, setRoomLoc] = useState<string | null>(null);
	const [selfLoc, setSelfLoc] = useState<string | null>(null);
	const [dmBusy, setDmBusy] = useState(false);
	const dmSaving = useRef(false);
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

	const dirty = dm !== live.dm;
	useChangeGroup("settings-direct-message", {
		dirty,
		discard: () => {
			if (dmSaving.current) throw new Error(settingsConnectionSaving);
			setDm(live.dm);
			setDmError("");
		},
	});
	const selectPane = (next: SettingsTab) => {
		setPane(next);
		browser.setSettingsTab(next);
	};
	const requestCloseRef = useRef(() => {});
	const requestClose = () => {
		commitments.request(() => browser.closeSettings());
	};
	requestCloseRef.current = requestClose;
	const save = async () => {
		if (dmSaving.current) return;
		if (!dirty) {
			browser.closeSettings();
			return;
		}
		dmSaving.current = true;
		setDmBusy(true);
		setDmError("");
		try {
			if (!await session.applySettings({ dm })) {
				setDmError(settingsConnectionRefused);
			}
		} catch (error) {
			setDmError(refusalText(error));
		} finally {
			dmSaving.current = false;
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
				<div className="modal-body">
					<SettingsHead
						titleId={titleId}
						title={settingsTitle}
						theme={theme}
						notifyOn={notifyOn}
						helpOpen={false}
						named={open}
						ops={anyOpsHeld(opsHeld)
							? {
								// Operations is its own page, so the control
								// navigates rather than layering: never pressed.
								open: false,
								onOpen: () => commitments.request(() => browser.openOperations()),
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
					{pane === "session" && (
						<div
							id="sessionPanel"
							role="tabpanel"
							aria-labelledby="sessionTab"
						>
							<SessionSettings keepHistory={keepHistory} archiveTarget={archiveTarget} />
						</div>
					)}
					{pane === "holdings" && canAdminister && (
						<div
							id="holdingsPanel"
							role="tabpanel"
							aria-labelledby="holdingsTab"
						>
							<Holdings archiveTarget={archiveTarget} />
						</div>
					)}
					{pane === "reachability" && (
						<div
							id="reachabilityPanel"
							role="tabpanel"
							aria-labelledby="reachabilityTab"
						>
							<h3 className="well-title overline" id="directoryLegend">{reachDirectoryTitle}</h3>
							<div className="group well" role="group" aria-labelledby="directoryLegend">
								<CopyField
									id="directoryLocator"
									text={roomLoc}
									label={settingsCopyDirectory}
								/>
								{
									/* Its sibling below says what its locator is for, and this one
											    said nothing. A room is a name on a directory, so this
											    address is what a room here is reached through. */
								}
								<p className="hint">{settingsShareDirectory}</p>
								{dir !== null && (
									<div className="actions">
										<Button
											id="settingsAboutDir"
											variant="quiet"
											onClick={() => browser.showDirectory(dir.id)}
										>
											{reachAboutDirectory}
										</Button>
									</div>
								)}
							</div>
							<h3 className="well-title overline" id="browserLegend">{reachBrowserTitle}</h3>
							<div className="group well" role="group" aria-labelledby="browserLegend">
								<CopyField id="selfLocator" text={selfLoc} label={settingsCopyBrowser} />
								<p className="hint">{settingsShareBrowser}</p>
							</div>
							{canInteract && (
								<>
									<h3 className="well-title overline" id="dmLegend">{dmConnectionTitle}</h3>
									<form
										id="dmSettingsForm"
										className="group well"
										role="group"
										aria-labelledby="dmLegend"
										onSubmit={(event) => {
											event.preventDefault();
											commitments.request(save, { except: ["settings-direct-message"] });
										}}
									>
										<div className="choices" role="radiogroup" aria-labelledby="dmLegend">
											<label className="choice">
												<input
													type="radio"
													name="dm"
													value="webrtc"
													checked={dm === "webrtc"}
													onChange={() => setDm("webrtc")}
												/>
												<span>
													<strong>{settingsDmDirectLabel}</strong>
													{settingsDmDirectSaid}
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
													<strong>{settingsDmRelayLabel}</strong>
													{settingsDmRelaySaid}
												</span>
											</label>
										</div>
										<p className="hint" id="dmReloadHint">{settingsDmReload}</p>
										{dmError !== "" && <Said kind="failure">{dmError}</Said>}
										<div className="actions">
											<Button id="dmSave" type="submit" busy={dmBusy} disabled={!dirty}>
												{saveAndReload}
											</Button>
										</div>
									</form>
								</>
							)}
						</div>
					)}
				</div>
			</div>
		</dialog>
	);
}
