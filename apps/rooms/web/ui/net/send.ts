// Saying something, and changing it afterwards.
//
// Everything a reader can put into a conversation comes through here: a line, a
// line with files, a change to one already said, and taking one back. A room
// and a direct line differ in who holds the message afterwards — the room, or
// the person you are talking to — and that difference is the only reason this
// file ever branches on which kind of conversation it has.
//
// Our own messages are painted before the wire has agreed to them, because a
// composer that waits feels broken. That optimism is what most of the care here
// is about: a room's echo confirms the line and reconciles it in place, a
// direct line has no echo and so settles on the send itself, and every path
// that can fail puts the message back the way it was rather than leaving a
// reader looking at something that never happened.

import { TYPING } from "../../../lib/protocol.ts";
import { MAX_MESSAGE_FILES } from "../../../lib/limits.ts";
import * as store from "../store.ts";
import { type Item, type RoomConv } from "../types.ts";

import { markSend, reason, trouble } from "./common.ts";
import { convSession, type Live } from "./live.ts";
import { releaseHeldFile } from "./files.ts";
import { activeBackChannel } from "./direct.ts";
import { failRoomSend, NOT_IN_THIS_ROOM } from "./common.ts";
export { applyRefile, refileActive, resendFile, sendFiles, stopSend } from "./send_files.ts";

// ── Sending ───────────────────────────────────────────────────────────────

/** Attach picked, dropped, or pasted files to the conversation on screen.
 *
 * What fits is taken and the rest is refused here, at the gesture, rather than
 * at Send. A file the attachment contract refuses keeps its place in the
 * composer so a reader can correct it, and that only works while correcting is
 * something a person would do: dropping a folder of photos on a message that
 * carries eight is an ordinary gesture, and it used to build a row of chips the
 * reader then had to take apart one press at a time before anything could be
 * sent at all. */
export function addFiles(files: readonly File[]): void {
	if (files.length === 0) return;
	const room = MAX_MESSAGE_FILES - store.activeDraft().files.length;
	if (room <= 0) {
		store.deliverActive(
			store.sysItem(`This message already carries ${MAX_MESSAGE_FILES} files, which is as many as one can.`),
		);
		return;
	}
	store.addDraftFiles(files.slice(0, room));
	const over = files.length - room;
	if (over > 0) {
		store.deliverActive(store.sysItem(
			`A message may carry at most ${MAX_MESSAGE_FILES} files, so ${
				over === 1 ? "one file was" : over + " files were"
			} left out. ` +
				`Send this one and the rest can follow.`,
		));
	}
}

/** Put an @mention of `who` into the composer, from the toolbar on a message. */
export function mention(who: string): void {
	// The conversation on screen's own draft, which is the one the message this
	// came from is sitting in.
	const text = store.activeDraft().text;
	const gap = text && !/\s$/.test(text) ? " " : "";
	store.setDraft(text + gap + "@" + who + " ");
}

export function setDraft(text: string): void {
	store.setDraft(text);
}

/** Put this conversation's last submitted line back in the composer.
 *
 * Only while the field is empty, nothing is attached, and no line is being
 * rewritten — otherwise Up is still the caret. Commands that never appeared
 * in the log are included, because they were submitted here too. */
export function recallLastSent(): string | null {
	const conv = store.activeConv();
	const draft = store.activeDraft();
	if (
		conv === null || draft.changing !== undefined || draft.files.length > 0 ||
		draft.text.trim() !== ""
	) {
		return null;
	}
	const last = store.lastSentFor(conv.key);
	if (last === undefined) return null;
	store.setDraft(last);
	return last;
}

/**
 * Say a line into `conv`'s room. We paint our own line at once as "sending"; the room
 * echoes it back to every member, which confirms it (see `pump`). A rejected post marks
 * the line failed with a retry control instead of vanishing.
 */
export function sayLine(conv: RoomConv, text: string): void {
	const item = store.chatItem(store.dirNick(conv.dir), text, true, "sending");
	store.deliver(conv.key, item);
	convSession(conv.key)?.echoes.push({ key: conv.key, id: item.id, attachmentIds: [], text });
	postRoomLine(conv.key, item.id, text);
}

// Re-arm a failed line as "sending" and post it again. The line is already in the
// conversation, so this changes it in place rather than adding a fresh one.
export function resendRoomLine(key: string, id: number, text: string): void {
	markSend(key, id, "sending");
	convSession(key)?.echoes.push({ key, id, attachmentIds: [], text });
	postRoomLine(key, id, text);
}

// Post a line to one room, marking it failed if we are not in that room or the post
// rejects. Success is silent: the room's echo confirms the line through `confirmRoomEcho`.
/** Said wherever this tab holds a room's conversation but no membership on the
 * live session behind it. Both ways back are named because which one applies
 * turns on something the reader cannot see: a connection part way back re-enters
 * every room it holds a moment later, while a re-entry that was refused waits for
 * them to ask for it. Without this the send looks like a broken control. */
function postRoomLine(key: string, id: number, text: string): void {
	const room = convSession(key)?.rooms.get(key);
	if (!room) {
		failRoomSend(key, id);
		store.deliver(key, store.sysItem(NOT_IN_THIS_ROOM));
		return;
	}
	room.say(text)
		.then((line) => {
			// A room that answers with a reference is one whose lines can be
			// changed; an older one answers with nothing and the line is simply
			// said. Either way the post succeeded, so the absence is remembered as
			// an absence rather than treated as a failure.
			if (line === null) return;
			convSession(key)?.posted.set(id, line);
			// Holding the reference is what the pencil and the close act on, so the
			// bubble is told: they are drawn from this rather than from authorship.
			store.holdLine(key, id);
		})
		.catch((error) => {
			// The bubble tints "Not sent" either way; without the reason beside it
			// a reader pressed retry into the same refusal for as long as they
			// were willing to believe it might work. The direct-message path has
			// said why since it shipped — this one never got the same sentence.
			trouble("the room did not take a line", error);
			store.deliver(key, store.sysItem(`The room did not take that line: ${reason(error)}`));
			failRoomSend(key, id);
		});
}

/** Withdraw a line already posted, by the reference the room answered with. */
export function withdraw(key: string, id: number): void {
	const line = convSession(key)?.posted.get(id);
	if (line === undefined) {
		// No reference means no authority, and the two reasons a reader can be in
		// that position are worth telling apart: a line somebody else posted was
		// never theirs to take back, and a line from before this connection was
		// lost with the session that carried it.
		store.deliverActive(store.sysItem("That line cannot be taken back from here."));
		return;
	}
	line.withdraw()
		.then(() => {
			// A room broadcasts the withdrawal back and the echo marks our own copy;
			// a direct line has no echo, so the sender marks its copy once the
			// withdrawal has actually landed — by item id, since a direct line has no
			// wire line id. Waiting for it to land, rather than painting it at once,
			// keeps a failed withdrawal from showing the line gone while the reason
			// below says it is not. The files the line carried let go with it, since
			// a withdrawn bubble draws nothing that could ask for them.
			const conv = store.getConv(key);
			if (conv?.type !== "dm") return;
			const owner = convSession(key);
			const item = conv.history.find((row) => row.id === id);
			if (owner !== null && item?.kind === "chat") {
				for (const view of item.attachments ?? []) releaseHeldFile(owner, view.id);
			}
			store.updateItem(key, id, { withdrawn: true } as Partial<Item>);
		})
		.catch((error) => {
			store.deliverActive(store.sysItem(`Could not take that line back: ${reason(error)}`));
		});
}

/** Change a line already posted, by the reference the room answered with. */
export function editLine(key: string, id: number, text: string): boolean {
	const line = convSession(key)?.posted.get(id);
	if (line === undefined) {
		store.deliverActive(store.sysItem("That line cannot be changed from here."));
		return false;
	}
	line.edit(text)
		.then(() => {
			// A direct line has no echo, so the sender's own copy changes once the
			// edit has landed rather than on a confirming broadcast — by item id,
			// since it has no wire line id.
			if (store.getConv(key)?.type === "dm") store.updateItem(key, id, { text, edited: true } as Partial<Item>);
		})
		.catch((error) => {
			store.deliverActive(store.sysItem(`Could not change that line: ${reason(error)}`));
			// The rewrite lives nowhere else. The log still shows the words the line
			// was posted with, because a change is drawn when the room confirms it,
			// and the composer was emptied when this was dispatched — so a failure
			// here used to take the rewrite with it. Put it back where the reader left
			// it, unless they have started something else there or the line has since
			// stopped being ours to change.
			const draft = store.activeDraft();
			if (
				store.activeConv()?.key === key && draft.text === "" && draft.files.length === 0 &&
				draft.changing === undefined && convSession(key)?.posted.has(id) === true
			) {
				store.startChange(id, text);
			}
		});
	return true;
}

/** The most recent line of our own in this conversation that can still be
 * changed, which is what `/edit` and `/delete` act on when nobody names one.
 *
 * The last one is what somebody typing `/edit` means: they have just said
 * something and seen it come out wrong. Anything older is reached by pressing
 * the line itself, where there is no guessing to do. */
export function lastLineOfOurs(key: string): { id: number; text: string } | null {
	const owner = convSession(key);
	const conv = store.getConv(key);
	if (owner === null || conv === null) return null;
	for (let at = conv.history.length - 1; at >= 0; at--) {
		const item = conv.history[at];
		if (item.kind !== "chat" || !item.mine || item.withdrawn) continue;
		if (owner.posted.has(item.id)) return { id: item.id, text: item.text };
	}
	return null;
}

// A room echoed a line back to us. If it matches an optimistic send still in
// flight *in that room*, confirm that message in place (clear its "sending"
// tint) and return its attachment ids, so `pump` does not paint a second copy
// and can attach the room's blob capabilities to the bubble already on screen.
// Null means this is not our echo.
//
// The conversation is half the match, not a detail: the same text may be in
// flight in two rooms at once, and matching on text alone would confirm the
// wrong bubble and leave the right one tinted for good.
export function confirmRoomEcho(key: string, text: string): Live["echoes"][number] | null {
	const owner = convSession(key);
	if (owner === null) return null;
	const at = owner.echoes.findIndex((row) => row.key === key && row.text === text);
	if (at < 0) return null;
	const [row] = owner.echoes.splice(at, 1);
	// A room echoes a line the moment it is posted, and a file message's bytes go
	// up after that. Such a message is not delivered until they have: a reader who
	// presses it in that window waits on the room, and a session lost there leaves
	// everyone a file with nothing behind it. So whichever of the echo and the
	// last byte lands second is the one that clears the flag.
	if (!owner.outgoing.has(row.id)) markSend(row.key, row.id, undefined);
	return row;
}

/** Set our typing flag in the active conversation — the room's own
 * channel for a room, the peer's inbox for a direct line. The one
 * failure here that is genuinely nothing: a typing flag is ephemeral
 * and self-correcting, because a reader clears an unrefreshed one
 * after `TYPING_CLEAR_MS` whatever we manage to send. */
export function setTyping(on: boolean): void {
	const s = store.get();
	const conv = s.activeKey !== null ? store.getConv(s.activeKey) : undefined;
	if (conv?.type === "dm") {
		sendDmTyping(conv.key, on);
		return;
	}
	if (conv == null) return;
	convSession(conv.key)?.rooms.get(conv.key)?.setTyping(on).catch(() => {});
}

/** A typing flag rides only a route that already exists — the reply
 * capability the peer handed us, or an introduced line already open
 * (or opening). An ephemeral signal must never cause a dial. */
function sendDmTyping(key: string, on: boolean): void {
	const session = convSession(key);
	if (session === null) return;
	const back = activeBackChannel(key);
	if (back !== null) {
		back.session.tell(back.reply, TYPING, [on]).catch(() => {});
		return;
	}
	session.lines.get(key)?.then((line) => line.typing(on)).catch(() => {});
}
