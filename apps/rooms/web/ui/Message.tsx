// One stack of messages from one speaker, and the small toolbar that hangs off
// it. Consecutive lines from the same person inside a few minutes share a row:
// one avatar, one name, one timestamp, and a bubble each.
//
// The row is memoised on the group it was given, so a message arriving in a busy
// room repaints the newest row and leaves the rest of the log alone.

import { memo, useEffect, useState } from "react";
import { type AttachmentView, canRetry, type ChatItem, isUnsent } from "./types.ts";
import { fmtTime, hueOf, initials, mentionsYou } from "./text.ts";
import { AUTO_IMAGE_BYTES } from "../../lib/limits.ts";
import { fileSize, kindOf } from "./media.ts";
import { saveAs } from "./download.ts";
import { RichText } from "./RichText.tsx";
import { usePeer } from "./peer.ts";
import { Icon } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import { CopyButton } from "./Copy.tsx";

/** A run of lines from one speaker, as the log groups them. */
export interface Group {
	from: string;
	mine: boolean;
	items: ChatItem[];
}

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
function mediaLayouts(files: readonly AttachmentView[]): readonly MediaLayout[] | undefined {
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
	if (file.error !== undefined) return <span className="sub" role="alert">{file.error}</span>;
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
	const peer = usePeer();
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
				? <span className="why" role="alert">{file.error}</span>
				: (
					<>
						<button
							type="button"
							className="act"
							title={`${verb} ${file.name}`}
							aria-label={`${verb} ${file.name}, ${fileSize(file.size)}`}
							onClick={() => peer.openFile(convKey, id)}
						>
							<Icon name={failed ? "retry" : kind === "video" ? "play" : "image"} />
							<span>{failed ? "Retry" : fileSize(file.size)}</span>
						</button>
						{failed && <span className="why" role="alert">{file.error}</span>}
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
	const peer = usePeer();
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
					onClick={() => peer.openViewer(convKey, id)}
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
			onClick={() => peer.openViewer(convKey, id)}
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
	const peer = usePeer();
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
					onClick={() => peer.openFile(convKey, id)}
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
	const peer = usePeer();
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
						peer.openFile(convKey, id);
					}}
				/>
			)}
		</div>
	);
}

/** One file in a message, drawn the way its kind is meant to be met. Its own id
 * keeps fetch progress and controls independent from every sibling in the same
 * bubble. */
function Attached(
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

function Bubble(
	{ item, nick, convKey, onRetry, onStop, onEdit, onWithdraw }: {
		item: ChatItem;
		nick: string;
		convKey: string;
		onRetry: (id: number) => void;
		onStop: (id: number) => void;
		onEdit: (item: ChatItem) => void;
		onWithdraw: (id: number) => void;
	},
) {
	const highlight = !item.mine && mentionsYou(item.text, nick);
	const layouts = item.attachments === undefined ? undefined : mediaLayouts(item.attachments);
	// A withdrawn line shows nothing of what it said. Keeping the text and
	// striking it through would be a worse lie than deleting it: it would leave
	// the words readable while claiming they had been taken back.
	const body = item.withdrawn ? null : (
		<>
			<RichText text={item.text} nick={nick} />
			{item.attachments !== undefined && (
				<div className={`attachment-set${layouts === undefined ? "" : " image-grid"}`}>
					{item.attachments.map((file, at) => (
						<Attached
							key={file.id}
							file={file}
							convKey={convKey}
							mine={item.mine}
							sending={item.state === "sending"}
							layout={layouts?.[at] ?? "natural"}
						/>
					))}
				</div>
			)}
		</>
	);
	const className = "bubble" + (highlight ? " hl" : "") +
		(item.state ? " " + item.state : "") + (item.withdrawn ? " withdrawn" : "");
	return (
		<div className={className} title={item.state === "sending" ? "Sending…" : undefined}>
			{
				/* On your own lines, and on the line rather than on the group: a group
			    is however many things you said close together, and changing one of
			    them is about that one. The bar the group carries acts on all of
			    them, which is right for copying and wrong for this. */
			}
			{
				/* Taken back, and still here. A line that vanished would leave every
			    reply to it reading as a non-sequitur, and would quietly rewrite what
			    a conversation looked like to somebody scrolling it later. So the
			    place stays and says what happened to it. */
			}
			{item.withdrawn && <span className="withdrawn-said">Message withdrawn</span>}
			{
				/* Changed since it was said. Small and after the words, because it
			    qualifies them rather than being one of them — and worth saying at
			    all because a reader who answered what this used to say should be
			    able to see that it moved under them. */
			}
			{item.edited && !item.withdrawn && <span className="edited-said">edited</span>}
			{item.held === true && !item.withdrawn && (
				<div className="line-acts">
					<IconButton
						icon="pencil"
						label="Change this message"
						size="small"
						variant="ghost"
						onClick={() => onEdit(item)}
					/>
					<IconButton
						icon="close"
						label="Withdraw this message"
						size="small"
						variant="ghost"
						tone="danger"
						onClick={() => onWithdraw(item.id)}
					/>
				</div>
			)}
			{body}
			{
				/* A send with files in it is the one a reader may need to take back:
			    the bubble is already posted and cannot be un-said, but a large file
			    is minutes of their bandwidth and picking the wrong one should not
			    commit them to it. Stopping leaves the send exactly where a failed
			    one sits, which is where the retry beside this already goes — so the
			    pair reads as one idea rather than two, and nothing new has to be
			    learned to undo the stop. Text alone is gone before it could be
			    caught, so it offers nothing. */
			}
			{item.state === "sending" && item.attachments !== undefined && (
				<div className="delivery-failure" role="status">
					<span>Sending</span>
					<IconButton
						icon="close"
						label="Stop sending these files"
						size="small"
						variant="ghost"
						tone="on-accent"
						onClick={() =>
							onStop(item.id)}
					/>
				</div>
			)}
			{
				/* Not sent, and whether that is the end of it. A line lost with a
				    session carries the way to send it again; one typed into a
				    conversation whose member has left carries none, because there is
				    nothing pressing it could reach — the room has the name back and
				    the next holder is someone else. The line in the log says that in
				    full; what this must not do is offer an action against it. */
			}
			{isUnsent(item.state) && (
				<div className="delivery-failure" role="status">
					<span>Not sent</span>
					{canRetry(item.state) && (
						<IconButton
							icon="retry"
							label="Retry failed message"
							size="small"
							variant="ghost"
							tone="on-accent"
							onClick={() => onRetry(item.id)}
						/>
					)}
				</div>
			)}
		</div>
	);
}

// Copy the message, or drop an @mention of the author into the composer.
function Acts({ group, onMention }: { group: Group; onMention: (who: string) => void }) {
	return (
		<div className="acts">
			<CopyButton
				text={group.items.map((item) => item.text).join("\n")}
				label="Copy message"
				size="small"
				variant="ghost"
			/>
			<IconButton
				icon="mention"
				label={"Mention " + group.from}
				size="small"
				variant="ghost"
				onClick={() => onMention(group.from)}
			/>
		</div>
	);
}

// A group is rebuilt on every pass over the history, so identity says nothing.
// What matters is whether it holds the same lines, and a line is only replaced
// when it actually changes — so comparing the members element by element lets an
// arriving message repaint one row instead of the whole log.
function sameGroup(a: Group, b: Group): boolean {
	// `blocksOf` is memoised, so when the history has not changed these are the
	// same object and the walk below is skipped entirely.
	if (a === b) return true;
	if (a.from !== b.from || a.mine !== b.mine || a.items.length !== b.items.length) return false;
	return a.items.every((item, at) => item === b.items[at]);
}

export const MessageGroup = memo(function MessageGroup(
	{ group, nick, convKey, onRetry, onStop, onEdit, onWithdraw, onMention }: {
		group: Group;
		nick: string;
		/** Which conversation these lines are in, so a file's fetch names the
		 * line it belongs to. */
		convKey: string;
		onRetry: (id: number) => void;
		onStop: (id: number) => void;
		onEdit: (item: ChatItem) => void;
		onWithdraw: (id: number) => void;
		onMention: (who: string) => void;
	},
) {
	const last = group.items[group.items.length - 1];
	// The bubble already carries its author and the sidebar its arrival, so the
	// per-line timestamp is decorative for a screen reader; it is hidden from the
	// tree rather than read out with every line.
	const stack = (
		<div className="stack">
			{!group.mine && <div className="who">{group.from}</div>}
			{group.items.map((item) => (
				<Bubble
					key={item.id}
					item={item}
					nick={nick}
					convKey={convKey}
					onRetry={onRetry}
					onStop={onStop}
					onEdit={onEdit}
					onWithdraw={onWithdraw}
				/>
			))}
			<div className="time" aria-hidden="true">{fmtTime(new Date(last.at))}</div>
		</div>
	);
	return (
		<div className={"row " + (group.mine ? "mine" : "them")} data-from={group.from}>
			{!group.mine && (
				// Purely a coloured initial; the author is already spoken in the `who` line.
				<div
					className="avatar"
					aria-hidden="true"
					style={{ background: hueOf(group.from) }}
				>
					{initials(group.from)}
				</div>
			)}
			{stack}
			<Acts group={group} onMention={onMention} />
		</div>
	);
}, (prev, next) =>
	prev.nick === next.nick &&
	prev.convKey === next.convKey &&
	prev.onRetry === next.onRetry &&
	prev.onStop === next.onStop &&
	prev.onEdit === next.onEdit &&
	prev.onWithdraw === next.onWithdraw &&
	prev.onMention === next.onMention &&
	sameGroup(prev.group, next.group));
