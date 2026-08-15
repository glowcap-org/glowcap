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
// rather than a surface, because the media behind it can be any colour.

import { useRef } from "react";
import type { AttachmentView } from "./types.ts";
import { usePeer } from "./peer.ts";
import { IconButton } from "./IconButton.tsx";
import { kindOf } from "./media.ts";
import { saveAs } from "./download.ts";
import { useModalDialog } from "./modal.ts";

export function Viewer({ file, convKey }: { file: AttachmentView; convKey: string }) {
	const peer = usePeer();
	const dialog = useRef<HTMLDialogElement>(null);
	const closeButton = useRef<HTMLButtonElement>(null);
	const kind = kindOf(file.mime);
	useModalDialog(dialog, () => peer.closeViewer(), closeButton);

	return (
		<dialog
			ref={dialog}
			className="viewer"
			aria-label={file.name}
			aria-keyshortcuts={kind === "image" ? "ArrowLeft ArrowRight" : undefined}
			onClick={() => peer.closeViewer()}
			onKeyDown={(event) => {
				if (
					kind !== "image" || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey ||
					(event.key !== "ArrowLeft" && event.key !== "ArrowRight")
				) return;
				event.preventDefault();
				peer.stepViewer(event.key === "ArrowLeft" ? "previous" : "next");
			}}
		>
			<div className="viewer-bar" onClick={(e) => e.stopPropagation()}>
				<span className="name" title={file.name}>{file.name}</span>
				{file.url !== undefined && (
					<IconButton
						icon="download"
						label={`Download ${file.name}`}
						variant="ghost"
						tone="inverse"
						onClick={() => saveAs(file.url!, file.name)}
					/>
				)}
				<IconButton
					ref={closeButton}
					icon="close"
					label="Close"
					variant="ghost"
					tone="inverse"
					onClick={() => peer.closeViewer()}
				/>
			</div>
			<div
				className="viewer-stage"
				onClick={(e) => e.stopPropagation()}
			>
				{file.url === undefined
					? file.error === undefined ? <span className="viewer-wait" aria-label="Loading" /> : (
						// Closing this to find the row it came from, and pressing
						// there, is a detour the reader can be spared. Only
						// where a press can work, though: a file the room cannot
						// hand over again says why and stops there.
						<span className="viewer-failure" role="alert">
							{file.error}
							{file.lost !== true && (
								<IconButton
									icon="retry"
									label={`Try ${file.name} again`}
									variant="ghost"
									tone="inverse"
									onClick={() => peer.openFile(convKey, file.id)}
								/>
							)}
						</span>
					)
					: kind === "video"
					? <video src={file.url} controls autoPlay playsInline />
					: <img src={file.url} alt={file.name} />}
			</div>
		</dialog>
	);
}
