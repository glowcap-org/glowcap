// Files on a message: a picture, a sound, or a named row, each with its own
// transfer. The bubble asks this how to draw them.

import { useEffect, useState } from "react";
import { type AttachmentView } from "../types.ts";
import { AUTO_IMAGE_BYTES } from "../../../lib/limits.ts";
import { fileSize, kindOf } from "../media.ts";
import { saveAs } from "../download.ts";
import { useRoomsSession } from "../controller/session.ts";
import { Icon } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { Said } from "../Said.tsx";
/** The shape a picture or a video will take, from what its sender measured.
 * Reserving it before the bytes arrive is what keeps a log of media from
 * shoving every line below it down the page as each one loads; without a
 * declared shape the box falls back to one landscape block, which costs one
 * reflow rather than one per file. */
type MediaLayout = "natural" | "tile-full" | "tile-half" | "tile-third";

function tileClass(layout: MediaLayout): string {
	if (layout === "natural") return "";
	return ` image-tile image-${layout}`;
}

function shapeOf(file: AttachmentView, layout: MediaLayout): { aspectRatio: string } {
	if (layout === "tile-third") return { aspectRatio: "1 / 1" };
	if (layout === "tile-half") return { aspectRatio: "3 / 2" };
	if (layout === "tile-full") return { aspectRatio: "3 / 1" };
	return { aspectRatio: file.width && file.height ? `${file.width} / ${file.height}` : "4 / 3" };
}

/** Lay image runs into complete gallery rows without changing attachment order.
 * Each run is balanced across rows of at most three images; the six-column
 * grid divides evenly into thirds, halves, or one full-width tile. A non-image
 * attachment ends the run because pairing images across it would make the
 * visual order lie. */
export function mediaLayouts(files: readonly AttachmentView[]): readonly MediaLayout[] | undefined {
	let imageCount = 0;
	for (const file of files) {
		if (kindOf(file.mime) === "image" && ++imageCount === 2) break;
	}
	if (imageCount < 2) return undefined;

	const layouts: MediaLayout[] = files.map(() => "natural");
	for (let start = 0; start < files.length;) {
		if (kindOf(files[start].mime) !== "image") {
			start++;
			continue;
		}
		let end = start + 1;
		while (end < files.length && kindOf(files[end].mime) === "image") end++;

		const imageRun = end - start;
		const rowCount = Math.ceil(imageRun / 3);
		const smallerRow = Math.floor(imageRun / rowCount);
		const largerRows = imageRun % rowCount;
		let at = start;
		for (let row = 0; row < rowCount; row++) {
			const rowSize = smallerRow + (row < largerRows ? 1 : 0);
			const layout: MediaLayout = rowSize === 3 ? "tile-third" : rowSize === 2 ? "tile-half" : "tile-full";
			for (let cell = 0; cell < rowSize; cell++) layouts[at++] = layout;
		}
		start = end;
	}
	return layouts;
}

/** One accessible transfer state for compact audio/file rows. Progress is a
 * named progressbar, failure announces once as it arrives, and resting metadata
 * is ordinary text rather than a live region that speaks every chunk. */
function TransferStatus(
	{ file, mine, idle }: { file: AttachmentView; mine: boolean; idle: string },
) {
	if (file.error !== undefined) return <Said as="span" className="sub" kind="failure">{file.error}</Said>;
	if (file.got !== undefined) {
		const pct = file.size > 0 ? Math.round((file.got / file.size) * 100) : 0;
		return (
			<span
				className="sub"
				role="progressbar"
				aria-label={`${mine ? "Uploading" : "Downloading"} ${file.name}`}
				aria-valuenow={pct}
				aria-valuemin={0}
				aria-valuemax={100}
			>
				{pct}% of {fileSize(file.size)}
			</span>
		);
	}
	return <span className="sub">{idle}</span>;
}

/** The box a picture or a video occupies before its bytes are here.
 *
 * It shimmers while they are on the way, because a rectangle that is going to
 * become a picture should say so with the space it is already holding. When
 * the bytes are waiting to be asked for, the same box carries the ask, with
 * the size on it: that is the fact the reader is deciding about. */
function MediaPlaceholder(
	{ file, id, convKey, layout }: {
		file: AttachmentView;
		id: number;
		convKey: string;
		layout: MediaLayout;
	},
) {
	const session = useRoomsSession();
	const kind = kindOf(file.mime);
	const loading = file.got !== undefined;
	const pct = loading && file.size > 0 ? Math.round((file.got! / file.size) * 100) : 0;
	const coming = loading ||
		(kind === "image" && file.size <= AUTO_IMAGE_BYTES && file.error === undefined);
	const failed = file.error !== undefined;
	const verb = failed ? "Retry" : kind === "video" ? "Play" : "Show";
	return (
		<div
			// Light travels across a tile whose bytes are on the way. One that
			// failed is not waiting on anything, and a tile that goes on shimmering
			// says the opposite of what its words say.
			className={`attach attach-media pending${coming ? " shimmer" : ""}${tileClass(layout)}`}
			style={shapeOf(file, layout)}
		>
			{coming
				? (
					<span
						className="pct"
						role="progressbar"
						aria-label={`Loading ${file.name}`}
						aria-valuenow={pct}
						aria-valuemin={0}
						aria-valuemax={100}
					>
						{loading ? `${pct}%` : ""}
					</span>
				)
				: file.lost === true
				// Nothing is coming, so the tile keeps the reason and drops the ask.
				? <Said as="span" className="why" kind="failure">{file.error}</Said>
				: (
					<>
						<button
							type="button"
							className="act"
							title={`${verb} ${file.name}`}
							aria-label={`${verb} ${file.name}, ${fileSize(file.size)}`}
							onClick={() => session.openFile(convKey, id)}
						>
							<Icon name={failed ? "retry" : kind === "video" ? "play" : "image"} />
							<span>{failed ? "Retry" : fileSize(file.size)}</span>
						</button>
						{failed && file.error !== undefined && (
							<Said as="span" className="why" kind="failure">{file.error}</Said>
						)}
					</>
				)}
		</div>
	);
}

/** A picture or a video on a line.
 *
 * Both open full-screen, because that is what a reader taps one for. The
 * difference is what the row itself shows: a picture is its own preview, while
 * a video gets a player, so a short clip can be watched where it was posted
 * without leaving the conversation. */
function AttachedMedia(
	{ file, id, convKey, sending, layout }: {
		file: AttachmentView;
		id: number;
		convKey: string;
		sending: boolean;
		layout: MediaLayout;
	},
) {
	const session = useRoomsSession();
	const loading = file.got !== undefined;
	const pct = loading && file.size > 0 ? Math.round((file.got! / file.size) * 100) : 0;

	if (file.url === undefined) {
		return <MediaPlaceholder file={file} id={id} convKey={convKey} layout={layout} />;
	}
	if (kindOf(file.mime) === "video") {
		return (
			<div className="attach attach-media" style={shapeOf(file, "natural")}>
				<video src={file.url} controls playsInline preload="metadata" />
				<IconButton
					className="expand"
					icon="expand"
					label={`View ${file.name}`}
					size="small"
					variant="solid"
					tone="inverse"
					onClick={() => session.openViewer(convKey, id)}
				/>
			</div>
		);
	}
	return (
		<button
			type="button"
			className={`attach attach-media attach-image${tileClass(layout)}`}
			style={shapeOf(file, layout)}
			title={file.name}
			aria-label={`View ${file.name}`}
			onClick={() => session.openViewer(convKey, id)}
		>
			<img src={file.url} alt={file.name} />
			{sending && loading && (
				<span
					className="upload"
					role="progressbar"
					aria-label={`Uploading ${file.name}`}
					aria-valuenow={pct}
					aria-valuemin={0}
					aria-valuemax={100}
				>
					<span className="bar" style={{ width: `${pct}%` }} />
				</span>
			)}
		</button>
	);
}

/** Sound on a line. There is nothing to open full-screen — a player is the
 * whole of what a listener wants — so this fetches on the press that starts
 * it and then plays in place. */
function AttachedAudio(
	{ file, id, convKey, mine }: { file: AttachmentView; id: number; convKey: string; mine: boolean },
) {
	const session = useRoomsSession();
	const loading = file.got !== undefined;
	if (file.url !== undefined) {
		return (
			<div className="attach attach-audio">
				<audio src={file.url} controls preload="metadata" />
				<span className="sub">{file.name}</span>
			</div>
		);
	}
	return (
		<div className="attach attach-audio pending">
			{file.lost !== true && (
				<IconButton
					icon={file.error !== undefined ? "retry" : "play"}
					label={file.error !== undefined ? `Retry ${file.name}` : `Play ${file.name}`}
					disabled={loading}
					onClick={() => session.openFile(convKey, id)}
				/>
			)}
			<TransferStatus file={file} mine={mine} idle={`${file.name} · ${fileSize(file.size)}`} />
		</div>
	);
}

/** Everything else: a row naming the file, and one control.
 *
 * That control is Download, and it does the whole job in one press — fetch the
 * bytes from the room, then hand them to the browser to save. Two presses, one
 * to fetch and one to save, is a seam from the implementation showing through:
 * the reader asked for the file, not for its transfer. */
function AttachedFile(
	{ file, id, convKey, mine }: { file: AttachmentView; id: number; convKey: string; mine: boolean },
) {
	const session = useRoomsSession();
	const [wanted, setWanted] = useState(false);
	const loading = file.got !== undefined;

	// The press that asked for it is what saves it, once the bytes land. This
	// effect is the seam between an answer that arrives later and a control
	// pressed earlier; it fires once, because it clears the flag it waits on.
	useEffect(() => {
		if (!wanted || file.url === undefined) return;
		setWanted(false);
		saveAs(file.url, file.name);
	}, [wanted, file.url, file.name]);

	return (
		<div className="attach attach-file">
			<span className="glyph" aria-hidden="true">
				<Icon name="file" />
			</span>
			<span className="meta">
				<span className="name" title={file.name}>{file.name}</span>
				<TransferStatus file={file} mine={mine} idle={fileSize(file.size)} />
			</span>
			{file.lost !== true && (
				<IconButton
					icon={file.error !== undefined ? "retry" : "download"}
					label={file.error !== undefined ? `Retry ${file.name}` : `Download ${file.name}`}
					variant="outline"
					tone={mine ? "on-accent" : "neutral"}
					disabled={loading}
					onClick={() => {
						// Already here: save it. Not here yet: ask for it, and let
						// the effect above save it when it lands. Doing both would
						// save a file that was already fetched twice.
						if (file.url !== undefined) {
							saveAs(file.url, file.name);
							return;
						}
						setWanted(true);
						session.openFile(convKey, id);
					}}
				/>
			)}
		</div>
	);
}

/** One file in a message, drawn the way its kind is meant to be met. Its own id
 * keeps fetch progress and controls independent from every sibling in the same
 * bubble. */
export function Attached(
	{ file, convKey, mine, sending, layout }: {
		file: AttachmentView;
		convKey: string;
		mine: boolean;
		sending: boolean;
		layout: MediaLayout;
	},
) {
	switch (kindOf(file.mime)) {
		case "image":
		case "video":
			return (
				<AttachedMedia
					file={file}
					id={file.id}
					convKey={convKey}
					sending={sending}
					layout={layout}
				/>
			);
		case "audio":
			return <AttachedAudio file={file} id={file.id} convKey={convKey} mine={mine} />;
		default:
			return <AttachedFile file={file} id={file.id} convKey={convKey} mine={mine} />;
	}
}
