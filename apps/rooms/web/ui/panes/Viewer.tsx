// A posted file at full size, over the whole interface.
//
// It sits beside Settings rather than inside a message, for the same reason
// Settings does: an overlay that covers the page is not part of the thing that
// opened it. Both use the native-dialog lifecycle in `modal.ts`.
// The store names the line being viewed rather than copying the file out of
// it, so bytes arriving while the viewer is open reach it.
//
// There is no card here. Settings is a panel because it is a form with fields
// and a title; a picture is the content, and a frame around it would only take
// space from it. What the viewer adds is a bar with the file's name and the
// two things there are to do — save it, or leave — over a legibility gradient
// rather than a surface, because the media behind it can be any colour. A
// picture has two sizes, fitted and actual, and the stage scrolls the second
// natively; `ViewerImage` says why there is no third.

import { type CSSProperties, memo, useRef, useState } from "react";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { IconButton } from "../IconButton.tsx";
import { useRoomsState } from "../hooks.ts";
import { viewedAttachment } from "../store.ts";
import { kindOf } from "../media.ts";
import { saveAs } from "../download.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { ViewerImage } from "./ViewerImage.tsx";
import { fileDownload, viewerActualSize, viewerFit, viewerTryAgain } from "../../../lib/text/page.ts";
import { modalClose, viewerLoading } from "../../../lib/text/controls.ts";

export const Viewer = memo(function Viewer() {
	const viewing = useRoomsState((state) => state.viewing);
	const file = useRoomsState((state) => viewedAttachment(state));
	const open = viewing !== null && file !== null;
	const convKey = viewing?.key ?? "";
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const dialog = useRef<HTMLDialogElement>(null);
	const closeButton = useRef<HTMLButtonElement>(null);
	const last = useRef(file);
	if (file != null) last.current = file;
	const shown = last.current;
	const kind = shown != null ? kindOf(shown.mime) : "file";
	const { held, onExited } = useHeldModal(open);
	useModalDialog(dialog, () => browser.closeViewer(), closeButton, open, onExited);
	// Fitted or actual size, and whether actual size would show anything more.
	// Held here rather than in the stage because the bar's zoom button is the
	// same state with a different handle.
	const [actual, setActual] = useState(false);
	const [oversized, setOversized] = useState(false);
	// What the stage's own scrollbar takes out of the window's width, so the
	// bar can stop short of it. See `.viewer-bar` for why it cannot simply
	// stop taking the pointer there.
	const [gutter, setGutter] = useState(0);
	const [shownId, setShownId] = useState(shown?.id);
	// Reset before rendering the new stage. A passive effect can overwrite
	// the new image's load/layout measurement after it has already arrived.
	if (shownId !== shown?.id) {
		setShownId(shown?.id);
		setActual(false);
		setOversized(false);
		setGutter(0);
	}
	if (!held || shown == null) return null;

	return (
		<dialog
			ref={dialog}
			className="viewer"
			style={{ "--viewer-gutter": `${gutter}px` } as CSSProperties}
			aria-label={shown.name}
			aria-keyshortcuts={kind === "image" ? "ArrowLeft ArrowRight" : undefined}
			onKeyDown={(event) => {
				if (
					kind !== "image" || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey ||
					(event.key !== "ArrowLeft" && event.key !== "ArrowRight")
				) return;
				event.preventDefault();
				session.stepViewer(event.key === "ArrowLeft" ? "previous" : "next");
			}}
		>
			<div className="viewer-bar">
				<span className="name" title={shown.name}>{shown.name}</span>
				{shown.url !== undefined && kind === "image" && (
					<IconButton
						id="viewerZoom"
						icon={actual ? "collapse" : "expand"}
						label={actual ? viewerFit(shown.name) : viewerActualSize(shown.name)}
						variant="ghost"
						tone="inverse"
						aria-pressed={actual}
						disabled={!oversized && !actual}
						onClick={() => setActual(!actual)}
					/>
				)}
				{shown.url !== undefined && (
					<IconButton
						icon="download"
						label={fileDownload(shown.name)}
						variant="ghost"
						tone="inverse"
						onClick={() => saveAs(shown.url!, shown.name)}
					/>
				)}
				<IconButton
					ref={closeButton}
					icon="close"
					label={modalClose}
					variant="ghost"
					tone="inverse"
					onClick={() => browser.closeViewer()}
				/>
			</div>
			{shown.url !== undefined && kind === "image"
				? (
					<ViewerImage
						src={shown.url}
						alt={shown.name}
						actual={actual}
						oversized={oversized}
						onMeasure={setOversized}
						onGutter={setGutter}
						onToggle={() => setActual(!actual)}
						onBackdrop={() => browser.closeViewer()}
					/>
				)
				: (
					<div
						className="viewer-stage"
						onClick={(e) => {
							if (e.target === e.currentTarget) browser.closeViewer();
						}}
					>
						{shown.url === undefined
							? shown.error === undefined
								? <span className="viewer-wait" aria-label={viewerLoading} />
								: (
									<span className="viewer-failure" role="alert">
										{shown.error}
										{shown.lost !== true && (
											<IconButton
												icon="retry"
												label={viewerTryAgain(shown.name)}
												variant="ghost"
												tone="inverse"
												onClick={() => session.openFile(convKey, shown.id)}
											/>
										)}
									</span>
								)
							: <video src={shown.url} controls autoPlay playsInline />}
					</div>
				)}
		</dialog>
	);
});
