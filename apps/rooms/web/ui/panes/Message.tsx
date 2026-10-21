import { messageEditing, messageWithdrawing } from "../../../lib/text/controls.ts";
import { PRESENTATION, useProgress } from "../presentation.ts";
// One stack of messages from one speaker, and the small toolbar that hangs off
// it. Consecutive lines from the same person inside a few minutes share a row:
// one avatar, one name, one timestamp, and a bubble each.
//
// The row is memoised on the group it was given, so a message arriving in a busy
// room repaints the newest row and leaves the rest of the log alone.

import { memo, useMemo, useState } from "react";
import { messageRetry } from "../../../lib/text/controls.ts";
import {
	messageCopyText,
	messageEdited,
	messageMention,
	messageMore,
	messageMoreFrom,
	messageNotConfirmed,
	messageNotSent,
	messageSending,
	messageSendingLong,
	messageWithdrawn,
} from "../../../lib/text/conversation.ts";
import { type BridgeFacts, canRetry, type ChatItem, isUnsent, type SendControlPolicy } from "../types.ts";
import type { Group } from "../log_blocks.ts";
import { Avatar } from "../Avatar.tsx";
import { foreignName } from "../member_identity.ts";
import { fmtTime } from "../text.ts";
import { readRichText, richTextMentions } from "../markdown.ts";

import { RichText } from "./RichText.tsx";
import { MessageLinkPreviews } from "./LinkPreviews.tsx";

import { IconButton } from "../IconButton.tsx";
import { useCopy } from "../Copy.tsx";
import { MenuLayer, MenuList, MenuRow, useMenu } from "../Menu.tsx";
import { Attached, mediaLayouts } from "../message/attach.tsx";
/** Everything else one message can be asked to do.
 *
 * A menu rather than a row of marks, because the list holds two kinds
 * of thing: copying is about the words and belongs on anybody's line, while
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
	const { open, setOpen, holder, trigger, layer } = useMenu();
	const { copy } = useCopy(item.pendingEdit?.text ?? item.text);
	// Copying is about the words; there are none on a line that was taken back.
	const words = !item.withdrawn && item.withdrawal == null && item.text !== "";
	// Changing and taking back are the reference this tab holds, not authorship.
	const held = item.held === true && !item.withdrawn && item.withdrawal == null && item.pendingEdit == null;

	if (!words && !held && item.mine) return null;
	// The exact minute this line landed rides the same reveal as the mark: the
	// group's stamp under the stack says when the last of them arrived, and a
	// reader who wants one line's own time points at that line. Decorative for
	// a screen reader, which already has the group's stamp and the log's order.
	const at = new Date(item.at);
	return (
		<div className={open ? "line-acts open" : "line-acts"} ref={holder}>
			<time className="line-at" dateTime={at.toISOString()} aria-hidden="true">{fmtTime(at)}</time>
			<IconButton
				ref={trigger}
				icon="more"
				label={item.mine ? messageMore : messageMoreFrom(item.from)}
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
				<MenuLayer holder={holder} layer={layer} className={item.mine ? undefined : "from-them"}>
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
								{messageCopyText}
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
								{messageMention(item.from)}
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
								{
									/* What it does, which is not deleting. The line keeps its
								    place and says what became of it, the comment on that
								    place says why, so a control promising removal promised
								    something the room does not do, and the reader met the
								    other word a moment later in "Message withdrawn". */
								}
								Withdraw
							</MenuRow>
						)}
					</MenuList>
				</MenuLayer>
			)}
		</div>
	);
}

/** How much room a menu needs under the mark that opens it before it would
 * rather open upward. Three rows and their padding, rounded up. */
const MENU_ROOM_PX = 130;
/** How much room it needs beside the mark before it would rather open over the
 * bubble. A wide picture takes nearly the column, so the default (off the
 * bubble, away from the words) runs off the screen. */
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
	{ item, nick, convKey, onRetry, onEdit, onWithdraw, onMention, sendControls, changing }: {
		item: ChatItem;
		nick: string;
		convKey: string;
		onRetry: (id: number) => void;
		onEdit: (item: ChatItem) => void;
		onWithdraw: (id: number) => void;
		onMention: (who: string) => void;
		sendControls: SendControlPolicy;
		/** Whether this is the line the composer is part way through rewriting. */
		changing: boolean;
	},
) {
	const sending = useProgress(item.state === "sending", PRESENTATION.sending, item.operation ?? item.id);
	const displayed = item.pendingEdit?.text ?? item.text;
	const editing = useProgress(item.pendingEdit != null, PRESENTATION.busy, item.pendingEdit?.operation);
	const reading = useMemo(() => readRichText(displayed), [displayed]);
	const highlight = !item.mine && richTextMentions(reading, nick);
	const layouts = item.attachments === undefined ? undefined : mediaLayouts(item.attachments);
	// A withdrawn line shows nothing of what it said. Keeping the text and
	// striking it through would be a worse lie than deleting it: it would leave
	// the words readable while claiming they had been taken back.
	const body = item.withdrawn || item.withdrawal != null ? null : (
		<>
			<RichText text={displayed} nick={nick} reading={reading} />
			{item.pendingEdit == null && item.previewUrls !== undefined && (
				<MessageLinkPreviews text={item.text} urls={item.previewUrls} />
			)}
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
		(item.state && (item.state !== "sending" || sending) ? " " + item.state : "") +
		(item.withdrawn ? " withdrawn" : "") +
		(changing ? " changing" : "");
	return (
		<div className={className} title={sending ? messageSendingLong : undefined}>
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
			{editing && <span className="withdrawn-said" role="status">{messageEditing}</span>}
			{item.editFailure && <span className="delivery-failure" role="alert">{item.editFailure}</span>}
			{item.withdrawal != null && <span className="withdrawn-said" role="status">{messageWithdrawing}</span>}
			{item.withdrawalFailure && <span className="delivery-failure" role="alert">{item.withdrawalFailure}</span>}
			{item.withdrawn && <span className="withdrawn-said">{messageWithdrawn}</span>}
			<LineMenu item={item} onEdit={onEdit} onWithdraw={onWithdraw} onMention={onMention} />
			{body}
			{
				/* Changed since it was said: after the words, because it qualifies
			    them rather than being one of them. Worth saying at all because a
			    reader who answered what this used to say should be able to see that status-allow: purpose clause
			    it moved under them, and worth saying *here* because drawn before
			    the line it is about, it would read as a label on the message rather
			    than a note at the end of it. */
			}
			{item.edited && !item.withdrawn && item.withdrawal == null && (
				<span className="edited-said">{messageEdited}</span>
			)}
			{sending && (
				<div className="delivery-failure" role="status">
					<span>{messageSending}</span>
				</div>
			)}
			{
				/* Not sent, and whether that is the end of it. A line lost with a
				    session carries the way to send it again. One typed into a
				    conversation whose member has left carries none, because there is
				    nothing pressing it could reach: the room has the name back and
				    the next holder is someone else. The line in the log says that in
				    full. What this must not do is offer an action against it. */
			}
			{isUnsent(item.state) && (
				<div className="delivery-failure" role="status">
					<span>{item.state === "unconfirmed" ? messageNotConfirmed : messageNotSent}</span>
					{sendControls.retry && item.retryable !== false && canRetry(item.state) && (
						<IconButton
							icon="retry"
							label={messageRetry}
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
// when it changes. So comparing the members element by element lets an
// arriving message repaint one row instead of the whole log.
function sameGroup(a: Group, b: Group): boolean {
	// `blocksOf` is memoised, so when the history has not changed these are the
	// same object and the walk below is skipped entirely.
	if (a === b) return true;
	if (a.from !== b.from || a.mine !== b.mine || a.showTime !== b.showTime) return false;
	if (a.items.length !== b.items.length) return false;
	return a.items.every((item, at) => item === b.items[at]);
}

export const MessageGroup = memo(function MessageGroup(
	{ group, nick, convKey, onRetry, onEdit, onWithdraw, onMention, sendControls, changing, bridge }: {
		group: Group;
		nick: string;
		/** Which conversation these lines are in, so a file's fetch names the
		 * line it belongs to. */
		convKey: string;
		onRetry: (id: number) => void;
		onEdit: (item: ChatItem) => void;
		onWithdraw: (id: number) => void;
		onMention: (who: string) => void;
		sendControls: SendControlPolicy;
		/** The line being rewritten, so the one on screen can say it is the one. */
		changing: number | undefined;
		/** What the bridge behind this room calls its own, when there is one. The
		 * author line names a foreign speaker the way the roster does rather than
		 * by their row's key. */
		bridge: BridgeFacts | undefined;
	},
) {
	const last = group.items[group.items.length - 1];
	const foreign = foreignName(group.from, bridge);
	// The bubble already carries its author and the sidebar its arrival, so the
	// per-line timestamp is decorative for a screen reader; it is hidden from the
	// tree rather than read out with every line.
	const stack = (
		<div className="stack">
			{!group.mine && (
				<div className="who">
					{foreign ?? group.from}
					{foreign !== null && bridge !== undefined && <span className="bridge-chip">{bridge.badge}</span>}
				</div>
			)}
			{group.items.map((item) => (
				<Bubble
					key={item.id}
					item={item}
					nick={nick}
					convKey={convKey}
					onRetry={onRetry}
					onEdit={onEdit}
					onWithdraw={onWithdraw}
					onMention={onMention}
					sendControls={sendControls}
					changing={item.id === changing}
				/>
			))}
			{group.showTime && <div className="time" aria-hidden="true">{fmtTime(new Date(last.at))}</div>}
		</div>
	);
	return (
		<div className={"row " + (group.mine ? "mine" : "them")} data-from={group.from}>
			{!group.mine && (
				// Purely a coloured initial; the author is already spoken in the `who` line.
				<Avatar name={foreign ?? group.from} />
			)}
			{stack}
		</div>
	);
	// Prop by prop, and a prop missing from this list is a group that stops
	// repainting rather than an error anybody sees. `bridge` compares by identity
	// because `setBridgeFacts` only replaces it when a value changed.
}, (prev, next) =>
	prev.nick === next.nick &&
	prev.bridge === next.bridge &&
	prev.changing === next.changing &&
	prev.convKey === next.convKey &&
	prev.onRetry === next.onRetry &&
	prev.onEdit === next.onEdit &&
	prev.onWithdraw === next.onWithdraw &&
	prev.onMention === next.onMention &&
	prev.sendControls.retry === next.sendControls.retry &&
	sameGroup(prev.group, next.group));
