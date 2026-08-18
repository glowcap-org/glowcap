// The shared title row of Settings and Help: appearance, notifications, and
// the glossary. Help is an icon here rather than a tab, so it can sit pressed
// the same way the Settings control sits pressed while its layer is up.

import { type MouseEvent, type ReactNode, type Ref, useState } from "react";
import { IconButton } from "./IconButton.tsx";
import { openModalFrom } from "./modal.ts";
import { usePeer } from "./peer.ts";
import { Said } from "./Said.tsx";

export function SettingsHead(
	{
		titleId,
		title,
		theme,
		notifyOn,
		helpOpen,
		ops,
		named = true,
		closeId,
		closeLabel = "Close",
		closeRef,
		onClose,
		children,
	}: {
		titleId: string;
		title: string;
		theme: "light" | "dark";
		notifyOn: boolean;
		helpOpen: boolean;
		/** The Operations control, present while any operations pane is
		 * enabled. It leads the toggle row from the left, apart from the
		 * window toggles, because it opens a layer about the server rather
		 * than changing something about this window. */
		ops?: {
			open: boolean;
			onOpen: (event: MouseEvent<HTMLButtonElement>) => void;
		};
		/** The layer's one dismiss, an X at the row's end like the directory
		 * card's, so every modal is left the same way. A form's own Cancel
		 * beside its submit is an action and stays in the form. */
		closeId?: string;
		closeLabel?: string;
		closeRef?: Ref<HTMLButtonElement>;
		onClose?: () => void;
		/** Stable ids belong to the dialog that is actually the top layer. */
		named?: boolean;
		children?: ReactNode;
	},
) {
	const peer = usePeer();
	const [notifyErr, setNotifyErr] = useState<string | null>(null);
	const id = (value: string) => named ? value : undefined;
	return (
		<div className="settings-head">
			<div className="settings-head-row">
				<h2 id={id(titleId)}>{title}</h2>
				{onClose !== undefined && (
					<IconButton
						id={closeId}
						ref={closeRef}
						icon="close"
						label={closeLabel}
						title={closeLabel}
						size="small"
						variant="ghost"
						onClick={onClose}
					/>
				)}
			</div>
			<div className="settings-toggles">
				{ops !== undefined && (
					<IconButton
						id={id("opsBtn")}
						className="ops-lead"
						icon="wrench"
						label="Operations"
						title="Operations"
						aria-pressed={ops.open}
						onClick={ops.onOpen}
					/>
				)}
				<IconButton
					id={id("themeToggle")}
					icon={theme === "dark" ? "sun" : "moon"}
					label="Toggle light or dark theme"
					title={theme === "dark" ? "Switch to light" : "Switch to syrup (dark)"}
					onClick={() => peer.setTheme(theme === "dark" ? "light" : "dark")}
				/>
				<IconButton
					id={id("notifyToggle")}
					icon={notifyOn ? "bell" : "bellOff"}
					label="Toggle mention notifications"
					title="Notify me when I'm mentioned"
					aria-pressed={notifyOn}
					aria-describedby={named && notifyErr ? "notifyHint" : undefined}
					onClick={() => {
						void peer.toggleNotify().then(setNotifyErr);
					}}
				/>
				<IconButton
					id={id("helpBtn")}
					icon="help"
					label="Help"
					aria-pressed={helpOpen}
					onClick={(event) =>
						helpOpen ? peer.closeHelp() : openModalFrom(event.currentTarget, () => peer.openHelp())}
				/>
			</div>
			{
				/* Asked on open as well as on press: the pressed-on bell persists
			    across visits while the browser's permission does not, and a bell
			    drawn on over a permission revoked weeks ago notified nobody and
			    said nothing. */
			}
			{notifyErr
				? <Said id={id("notifyHint")} kind="warning">{notifyErr}</Said>
				: notifyOn && typeof Notification !== "undefined" && Notification.permission !== "granted"
				? (
					<Said id={id("notifyHint")} kind="warning">
						Notifications are on here, but this browser is blocking them. Allow notifications for this site
						in the browser's settings.
					</Said>
				)
				: null}
			{children}
		</div>
	);
}
