// The shared title row of Settings and Help: appearance, notifications, and
// the glossary. Help is an icon here rather than a tab, so it can sit pressed
// the same way the Settings control sits pressed while its layer is up.

import { type MouseEvent, type ReactNode, type Ref, useState } from "react";
import { modalClose, themeToggle } from "../../../lib/text/controls.ts";
import { IconButton } from "../IconButton.tsx";
import { ModalHead } from "../ModalHead.tsx";
import { useOpenModal } from "../modal.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { loadOpsPage, prefetch } from "../chunks.ts";
import { Said } from "../Said.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { helpTitle } from "../../../lib/text/help.ts";
import {
	notifyBlocked,
	notifyChanging,
	notifyOnMention,
	notifyToggle,
	operationsTitle,
	themeToDark,
	themeToLight,
} from "../../../lib/text/settings.ts";

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
		closeLabel = modalClose,
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
	const openModalFrom = useOpenModal();
	const browser = useRoomsBrowser();
	const [notifyErr, setNotifyErr] = useState<string | null>(null);
	const [notifyBusy, setNotifyBusy] = useState(false);
	const id = (value: string) => named ? value : undefined;
	return (
		<div className="settings-head">
			<ModalHead
				titleId={id(titleId)}
				title={title}
				closeId={closeId}
				closeLabel={closeLabel}
				closeRef={closeRef}
				onClose={onClose}
			/>
			<div className="settings-toggles">
				{ops !== undefined && (
					<IconButton
						id={id("opsBtn")}
						className="ops-lead"
						icon="wrench"
						label={operationsTitle}
						title={operationsTitle}
						aria-pressed={ops.open}
						onPointerEnter={() => prefetch(loadOpsPage)}
						onFocus={() => prefetch(loadOpsPage)}
						onClick={ops.onOpen}
					/>
				)}
				<IconButton
					id={id("themeToggle")}
					icon={theme === "dark" ? "sun" : "moon"}
					label={themeToggle}
					title={theme === "dark" ? themeToLight : themeToDark}
					onClick={() => browser.setTheme(theme === "dark" ? "light" : "dark")}
				/>
				<IconButton
					id={id("notifyToggle")}
					icon={notifyOn ? "bell" : "bellOff"}
					label={notifyBusy ? notifyChanging : notifyToggle}
					title={notifyBusy ? notifyChanging : notifyOnMention}
					aria-pressed={notifyOn}
					aria-describedby={named && notifyErr ? "notifyHint" : undefined}
					busy={notifyBusy}
					onClick={() => {
						setNotifyErr(null);
						setNotifyBusy(true);
						void browser.toggleNotify()
							.then(setNotifyErr, (error) => {
								setNotifyErr(refusalText(error));
							})
							.finally(() => setNotifyBusy(false));
					}}
				/>
				<IconButton
					id={id("helpBtn")}
					icon="help"
					label={helpTitle}
					aria-pressed={helpOpen}
					onClick={(event) =>
						helpOpen ? browser.closeHelp() : openModalFrom(event.currentTarget, () => browser.openHelp())}
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
				? <Said id={id("notifyHint")} kind="warning">{notifyBlocked}</Said>
				: null}
			{children}
		</div>
	);
}
