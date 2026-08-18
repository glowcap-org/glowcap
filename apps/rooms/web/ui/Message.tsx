// One stack of messages from one speaker, and the small toolbar that hangs off
// it. Consecutive lines from the same person inside a few minutes share a row:
// one avatar, one name, one timestamp, and a bubble each.
//
// The row is memoised on the group it was given, so a message arriving in a busy
// room repaints the newest row and leaves the rest of the log alone.

import { memo, useState } from "react";
import { canRetry, type ChatItem, isUnsent } from "./types.ts";
import { type Group } from "./log_blocks.ts";
import { Avatar } from "./Avatar.tsx";
import { fmtTime, mentionsYou } from "./text.ts";

import { RichText } from "./RichText.tsx";

import { IconButton } from "./IconButton.tsx";
import { useCopy } from "./Copy.tsx";
import { MenuList, MenuRow, useMenu } from "./Menu.tsx";
import { Attached, mediaLayouts } from "./message/attach.tsx";
/** Everything else one message can be asked to do.
 *
 * A menu rather than a row of marks, because the list is no longer two things
 * of one kind: copying is about the words and belongs on anybody's line, while
 * changing and taking back are about authority and belong only on a line this
 * tab still holds the reference for. Side by side as icons, those read as one
 * set of controls that happens to be shorter on somebody else's message, which
 * is the wrong story about why.
 *
 * It closes on Escape, on a press outside it, and on anything it does. Focus
 * moves into it on open and returns to the mark that opened it, because a menu
 * a keyboard cannot leave is worse than no menu at all. */
function LineMenu(
	{ item, onEdit, onWithdraw, onMention }: {
		item: ChatItem;
		onEdit: (item: ChatItem) => void;
		onWithdraw: (id: number) => void;
		onMention: (who: string) => void;
	},
) {
	const [above, setAbove] = useState(false);
	const [inward, setInward] = useState(false);
	const { open, setOpen, holder, trigger } = useMenu();
	const { copy } = useCopy(item.text);
	// Copying is about the words; there are none on a line that was taken back.
	const words = !item.withdrawn && item.text !== "";
	// Changing and taking back are the reference this tab holds, not authorship.
	const held = item.held === true && !item.withdrawn;

	if (!words && !held && item.mine) return null;
	return (
		<div className="line-acts" ref={holder}>
			<IconButton
				ref={trigger}
				icon="more"
				label={item.mine ? "More for this message" : `More for this message from ${item.from}`}
				size="small"
				variant="ghost"
				aria-haspopup="menu"
				aria-expanded={open}
				onClick={() => {
					const at = trigger.current?.getBoundingClientRect();
					if (at !== undefined) {
						const place = placeLineMenu(at, item.mine);
						setAbove(place.above);
						setInward(place.inward);
					}
					setOpen((was) => !was);
				}}
			/>
			{open && (
				<MenuList
					className={"line-menu" + (above ? " above" : "") + (inward ? " inward" : "")}
				>
					{words && (
						<MenuRow
							icon="copy"
							className="line-menu-row"
							first
							onPick={() => {
								setOpen(false);
								void copy(holder.current);
							}}
						>
							Copy text
						</MenuRow>
					)}
					{!item.mine && (
						<MenuRow
							icon="mention"
							className="line-menu-row"
							first={!words}
							onPick={() => {
								setOpen(false);
								onMention(item.from);
							}}
						>
							Mention {item.from}
						</MenuRow>
					)}
					{held && (
						<MenuRow
							icon="pencil"
							className="line-menu-row"
							onPick={() => {
								setOpen(false);
								onEdit(item);
							}}
						>
							Edit
						</MenuRow>
					)}
					{held && (
						<MenuRow
							icon="close"
							className="line-menu-row danger"
							onPick={() => {
								setOpen(false);
								onWithdraw(item.id);
							}}
						>
							Delete
						</MenuRow>
					)}
				</MenuList>
			)}
		</div>
	);
}

/** How much room a menu needs under the mark that opens it before it would
 * rather open upward. Three rows and their padding, rounded up. */
const MENU_ROOM_PX = 130;
/** How much room it needs beside the mark before it would rather open over the
 * bubble. A wide picture takes nearly the column, so the default — off the
 * bubble, away from the words — runs off the screen. */
const MENU_WIDTH_PX = 168;

function placeLineMenu(at: DOMRect, mine: boolean): { above: boolean; inward: boolean } {
	// Below the mark, unless it would open over the composer. Measured against
	// the composer's own top rather than the log's foot: the log runs underneath
	// the composer to the bottom of the window, so a menu asking the log whether
	// it had room was told yes every time and opened across the field a reader
	// types in.
	const floor = document.querySelector(".composer")?.getBoundingClientRect().top ??
		globalThis.innerHeight;
	const view = globalThis.visualViewport;
	const left = view?.offsetLeft ?? 0;
	const right = left + (view?.width ?? globalThis.innerWidth);
	const pad = 8;
	// Own lines grow left of the mark; everyone else's grow right. Flip toward
	// the bubble when that growth would leave the viewport.
	const inward = mine ? at.right - MENU_WIDTH_PX < left + pad : at.left + MENU_WIDTH_PX > right - pad;
	return { above: at.bottom + MENU_ROOM_PX > floor, inward };
}

function Bubble(
	{ item, nick, convKey, onRetry, onStop, onEdit, onWithdraw, onMention, changing }: {
		item: ChatItem;
		nick: string;
		convKey: string;
		onRetry: (id: number) => void;
		onStop: (id: number) => void;
		onEdit: (item: ChatItem) => void;
		onWithdraw: (id: number) => void;
		onMention: (who: string) => void;
		/** Whether this is the line the composer is part way through rewriting. */
		changing: boolean;
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
		(item.state ? " " + item.state : "") + (item.withdrawn ? " withdrawn" : "") +
		(changing ? " changing" : "");
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
			<LineMenu item={item} onEdit={onEdit} onWithdraw={onWithdraw} onMention={onMention} />
			{body}
			{
				/* Changed since it was said: after the words, because it qualifies
			    them rather than being one of them. Worth saying at all because a
			    reader who answered what this used to say should be able to see that
			    it moved under them — and worth saying *here* because it was being
			    drawn before the line it is about, which reads as a label on the
			    message rather than a note at the end of it. */
			}
			{item.edited && !item.withdrawn && <span className="edited-said">edited</span>}
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
	{ group, nick, convKey, onRetry, onStop, onEdit, onWithdraw, onMention, changing }: {
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
		/** The line being rewritten, so the one on screen can say it is the one. */
		changing: number | undefined;
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
					onMention={onMention}
					changing={item.id === changing}
				/>
			))}
			<div className="time" aria-hidden="true">{fmtTime(new Date(last.at))}</div>
		</div>
	);
	return (
		<div className={"row " + (group.mine ? "mine" : "them")} data-from={group.from}>
			{!group.mine && (
				// Purely a coloured initial; the author is already spoken in the `who` line.
				<Avatar name={group.from} />
			)}
			{stack}
		</div>
	);
}, (prev, next) =>
	prev.nick === next.nick &&
	prev.changing === next.changing &&
	prev.convKey === next.convKey &&
	prev.onRetry === next.onRetry &&
	prev.onStop === next.onStop &&
	prev.onEdit === next.onEdit &&
	prev.onWithdraw === next.onWithdraw &&
	prev.onMention === next.onMention &&
	sameGroup(prev.group, next.group));
