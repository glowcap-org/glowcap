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

import { useEffect, useRef, useState } from "react";
import type { AttachmentView } from "./types.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { IconButton } from "./IconButton.tsx";
import { kindOf } from "./media.ts";
import { saveAs } from "./download.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { ViewerImage } from "./ViewerImage.tsx";

export function Viewer(
	{ open, file, convKey }: { open: boolean; file: AttachmentView | null; convKey: string },
) {
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
	const shownId = shown?.id;
	useEffect(() => {
		setActual(false);
		setOversized(false);
	}, [shownId]);
	if (!held || shown == null) return null;

	return (
		<dialog
			ref={dialog}
			className="viewer"
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
						label={actual ? `Fit ${shown.name} to the window` : `Show ${shown.name} at actual size`}
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
						label={`Download ${shown.name}`}
						variant="ghost"
						tone="inverse"
						onClick={() => saveAs(shown.url!, shown.name)}
					/>
				)}
				<IconButton
					ref={closeButton}
					icon="close"
					label="Close"
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
								? <span className="viewer-wait" aria-label="Loading" />
								: (
									<span className="viewer-failure" role="alert">
										{shown.error}
										{shown.lost !== true && (
											<IconButton
												icon="retry"
												label={`Try ${shown.name} again`}
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
}
