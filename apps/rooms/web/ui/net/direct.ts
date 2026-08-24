// Direct messages: opening one, carrying it, and what a peer may do to a
// message after it has arrived.
//
// A direct line never touches the room. The room introduces two members and
// steps out; from then on the conversation runs peer to peer, so everything
// here is about a connection this tab either dialed by redeeming an
// introduction or had opened to it by the other side. Which of those it is
// decides almost every question below, because only one of them can be
// re-opened from this side.
//
// The line's handle is the one piece worth reading twice. A message answers
// with a capability the *receiver* mints, so the sender can change or take back
// what the receiver is looking at — the direct sibling of the reference a room
// answers a post with, except that here the durable owner is the person you are
// talking to rather than a server. Every argument that arrives on one is
// therefore the peer's, and is bounded here rather than trusted.

import { Ref, type Session } from "@pancake/runtime";
import type { Argument } from "@pancake/runtime";
import {
	type Attachment,
	type AttachmentSource,
	readRefileChange,
	sendWithAttachments,
} from "../../../lib/attachment.ts";
import { DirectMessage, PostedLine } from "../../../lib/room_client.ts";
import { DM, EDIT, REFILE, WITHDRAW } from "../../../lib/protocol.ts";
import { PEER_OFFLINE, roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import { type DirId, type DmConv, type Item, silencedFrom } from "../types.ts";
import { lineNotShowable } from "../text.ts";
import { maybeNotify } from "../notify.ts";
import { fetchesOnArrival } from "../media.ts";
import { MAX_PENDING_INVITES } from "../../../lib/limits.ts";
import { markSend, reason } from "./common.ts";
import { actingDir, convSession, dirSession, isCurrent, type Live } from "./live.ts";
import { holdDirectFile, openAttachment, releaseHeldFile } from "./files.ts";
import { hydrateDm } from "./history.ts";

/** Reply routes a peer handed us with an incoming message, by conversation.
 *
 * Homed here rather than on a directory session for the reason the inbox host
 * is: this connection is one the *peer* opened to that host, so a room server
 * respawning has nothing to do with it, and a tab that could still be replied
 * to should still be replyable afterwards. Parked on the session, every
 * reconnect both lost the route and leaked what it named — the peer's
 * connection stayed up with our reply inbox exported on it and nothing left on
 * this side able to reach or close either. */
interface BackChannel {
	session: Session;
	reply: Ref;
}

const backChannels = new Map<string, BackChannel>();

/** The live reply route for one conversation. A stale row is retired through
 * the same close owner as every explicit release rather than handed to a
 * caller that can no longer use it. */
export function activeBackChannel(key: string): BackChannel | null {
	const held = backChannels.get(key);
	if (held === undefined) return null;
	if (held.session.sessionOpen) return held;
	releaseBackChannel(key);
	return null;
}

/** Adopt a reply route only when no working route already owns the
 * conversation. The caller retains ownership of `reply` when this returns
 * false and must release that occurrence. */
export function adoptBackChannel(key: string, session: Session, reply: Ref): boolean {
	if (activeBackChannel(key) !== null) return false;
	backChannels.set(key, { session, reply });
	return true;
}

// ── Direct messages by introduction ───────────────────────────────────────
// Open a DM conversation with `peer` and show it. The direct line itself opens
// lazily on the first send, so opening the thread asks the directory for nothing.
export function startDm(peer: string): void {
	if (!peer) return;
	const here = actingDir();
	if (store.isSelf(here, peer)) {
		store.deliverActive(store.sysItem("You can't start a direct message with yourself."));
		return;
	}
	const conv = store.ensureDm(here, peer);
	if (conv === null) return;
	hydrateDm(conv);
	noteIgnoredDm(conv.key, peer);
	store.switchTo(conv.key);
}

/** Say, once per conversation, that its peer is on the reader's ignore list.
 *
 * A direct line with an ignored peer draws nothing they say — correctly — and
 * without this it looked simply dead: a rail row, an intro panel, and silence.
 * The room path earned its note when the ignored name is the reader's own;
 * this is the direct-line sibling. Once, keyed on the conversation, because
 * the reminder is about the conversation existing, not about each line. */
const saidIgnoredDm = new Set<string>();
export function noteIgnoredDm(key: string, peer: string): void {
	if (!silencedFrom(peer, false, store.get().ignored)) return;
	if (saidIgnoredDm.has(key)) return;
	saidIgnoredDm.add(key);
	store.deliver(
		key,
		store.sysItem(`You are ignoring ${peer}, so their messages here stay hidden. /unignore ${peer} lifts it.`),
	);
}

/** Hold the handle a direct line answered with, so this line's own pencil and
 * delete act on it — the same `posted` map and `held` flag a room line uses.
 * A direct line has no echo, so the sender applies its own edits locally (see
 * `editLine`, `withdraw`, `refileActive`); this is only what makes the controls
 * appear. */
export function holdDmLine(key: string, id: number, line: PostedLine): void {
	const owner = convSession(key);
	if (owner === null) {
		line.release();
		return;
	}
	owner.posted.set(id, line);
	store.holdLine(key, id);
}

// Send a direct message to `peer`, opening the introduced line on first use. A
// DM has no echo, so paint our own line at once; a dial that can't land (a member
// reachable only over TCP, or one who has left) says so in the thread.
export function dmSay(conv: DmConv, text: string): void {
	// The conversation, not the name. Resolving by name here would find whichever
	// conversation currently answers to it — which after the member left is a
	// different one, so a message typed into the thread on screen would land in
	// another, or open a line to whoever holds the name now.
	const item = store.chatItem(store.dirNick(conv.dir), text, true, "sending");
	store.deliver(conv.key, item);
	sendDm(conv.key, item.id, text);
}

// Open the introduced line (lazily on first use) and deliver one line to the peer,
// tracking the bubble's send state honestly. On success the bubble clears to confirmed;
// on failure it tints failed and offers retry, and a friendly note names why. A retry
// runs this again with the same bubble.
export function sendDm(key: string, id: number, text: string): void {
	const conv = store.getConv(key);
	if (conv?.type !== "dm") return;
	const peer = conv.id;
	// A conversation whose member left is closed for good. The room has their
	// name back, so reaching for it now would find whoever holds it next — which
	// is the one thing this conversation must never quietly do.
	if (conv.line === "closed") {
		// Refused rather than failed: this one can never go, so it is drawn
		// without the retry that every other unsent line carries.
		markSend(key, id, "refused");
		store.deliver(
			key,
			store.sysItem(
				`${peer} left, so this conversation is closed. ` +
					`Starting a new one with that name reaches whoever holds it now, ` +
					`who may be someone else.`,
			),
		);
		return;
	}
	markSend(key, id, "sending");
	deliverDm(conv, text)
		.then((line) => {
			if (line !== null) holdDmLine(key, id, line);
			markSend(key, id, undefined);
			store.setDmLine(key, "live");
		})
		.catch((err) => {
			markSend(key, id, "failed");
			store.deliver(key, store.sysItem(dmFailureText(peer, err)));
		});
}

/** Deliver through whichever direct route this conversation owns. Text and
 * files make the same choice: an arriving reply capability first, otherwise an
 * introduced line. The attachment helper only sees the resulting Session, so
 * WebRTC, iroh, relay, and every other carrier stay below this boundary. */
export async function deliverDm(
	conv: DmConv,
	text: string,
	sources: AttachmentSource[] = [],
): Promise<PostedLine | null> {
	const key = conv.key;
	const session = dirSession(conv.dir);
	if (session === null) throw new Error("not connected");
	const back = activeBackChannel(key);
	try {
		if (back) {
			// The peer answers a handle to the line it just received, so we can
			// change or withdraw it later; a `PostedLine` on the arriving connection
			// holds it, the same as our own room lines.
			const answer = sources.length > 0
				? await sendWithAttachments(back.session, back.reply, DM, [text], sources)
				: await back.session.send(back.reply, DM, [text]);
			return answer instanceof Ref ? new PostedLine(back.session, answer) : null;
		}
		const line = await openDm(conv);
		return sources.length > 0 ? await line.sendFiles(sources, text) : await line.say(text);
	} catch (err) {
		// Let the dead line go so the next send retries: a stale back-channel
		// falls back to a fresh introduction, a stale introduction re-redeems.
		if (back) releaseBackChannel(key);
		else dropLine(session, key);
		throw err;
	}
}

// The reason a direct message could not land, said where the reader is looking.
// A direct message crosses a redeem, a dial, and a carrier of its own, and every
// one of those failures used to read as a bare "couldn't reach them" here, with
// the cause going to a console the reader does not have — which made a
// misconfigured deployment look like the feature not existing. The typed
// taxonomy still speaks first where it has a better sentence, and the failure
// that has a setting to change names it.
function dmFailureText(peer: string, err: unknown): string {
	const re = roomErrorOf(err);
	if (re?.code === PEER_OFFLINE) return `${peer} is offline.`;
	const why = re?.detail ?? reason(err);
	if (why.includes("ICE failed")) {
		return `Couldn't reach ${peer}: ${why}. ` +
			`"Through the room relay" in Settings sends direct messages without needing one.`;
	}
	return `Couldn't reach ${peer}: ${why}`;
}

// The introduced direct line to a peer, opened once and reused. `DirectMessage.open`
// asks the directory to introduce us and wraps the handoff-give; the redeem dial
// opens the direct connection over the member's advertised transport. The
// line hosts a reply inbox on that connection, so a member's reply lands here and
// paints in the peer's DM thread — the member never dials us.
export function openDm(conv: DmConv): Promise<DirectMessage> {
	const peer = conv.id;
	const key = conv.key;
	const session = dirSession(conv.dir);
	if (session === null) return Promise.reject(new Error("not connected"));
	if (store.isSelf(conv.dir, peer)) {
		return Promise.reject(new Error("You can't start a direct message with yourself."));
	}
	const existing = session.lines.get(key);
	if (existing) {
		// Same staleness as the back-channel above, one step softer: `say` is
		// async, so a dead line surfaces as a rejection and repairs itself after
		// one visibly failed message. Checking here spends no message at all.
		const reopen = () => {
			// Only if it is still the entry we looked at; a concurrent send may
			// already have replaced it. Handed back rather than forgotten, for the
			// same reason the failed send above hands its line back.
			if (session.lines.get(key) === existing) dropLine(session, key);
			return openDm(conv);
		};
		return existing.then((line) => (line.live ? line : reopen()), reopen);
	}
	// A conversation whose member has gone is never re-introduced: the name is
	// back in the room's hands and the next holder is a different person, so
	// continuing here would quietly point this thread at them.
	if (conv.line === "closed") {
		return Promise.reject(new Error(`${peer} left, so this conversation is closed`));
	}
	const line = DirectMessage.open(
		session.dir,
		peer,
		(text, attachments, via) => receiveDm(key, peer, text, attachments, via),
	);
	session.lines.set(key, line);
	return line;
}

/** Return one unadopted capability occurrence to the session that projected
 * it. Cleanup failure is observable without replacing the caller's primary
 * refusal or accepted-message outcome. */
export function releaseIncomingRef(session: Session, ref: Ref, what: string): void {
	try {
		session.release(ref);
	} catch (error) {
		// The caller's refusal or accepted message remains the primary outcome;
		// cleanup failure is retained here as process-owner diagnostics rather than
		// replacing it or disappearing.
		console.error(`rooms: ${what} could not release its capability:`, reason(error));
	}
}

/** Let one conversation's arriving back-channel go: drop the row and close the
 * connection the peer opened to us, on which our reply inbox is exported.
 *
 * One authority, because four sites let a back-channel go and they drifted: the
 * `unregistered` sweep dropped only the row, leaving the peer's connection up
 * with our export on it and nothing on this side able to reach it. Tolerant of
 * a connection already gone — a stale row's session is closed, and closing it
 * again is the same outcome. */
export function releaseBackChannel(key: string): void {
	const back = backChannels.get(key);
	backChannels.delete(key);
	if (back === undefined) return;
	try {
		void back.session.close().catch((err) =>
			console.error("rooms: an arriving direct connection would not close, so it stays up:", reason(err))
		);
	} catch (err) {
		console.error("rooms: an arriving direct connection would not close, so it stays up:", reason(err));
	}
}

export function dropLine(session: Live, key: string): void {
	const line = session.lines.get(key);
	if (line === undefined) return;
	session.lines.delete(key);
	void line.then((l) => l.close()).catch((err) =>
		console.error(
			"rooms: a direct line would not close, so its connection stays up:",
			reason(err),
		)
	);
}

/** A line arriving from `peer` in the conversation `key`. Both directions land
 * here: a reply on a line we opened, and a message from a member who reached us
 * first. Neither reads the sender off the message — a line we opened goes to the
 * member the directory introduced, and an inbox belongs to the one member the
 * directory handed it to. */
export function receiveDm(
	key: string,
	peer: string,
	text: string,
	attachments: Attachment[] = [],
	via: Session | null = null,
): Argument {
	store.setDmLine(key, "live");
	const unshowable = lineNotShowable(peer, text);
	if (unshowable !== null) {
		store.deliver(key, store.sysItem(unshowable));
		return null;
	}
	const views = attachments.map((attachment) =>
		store.attachmentView({
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
		})
	);
	const item = store.chatItem(peer, text, false, undefined, views.length > 0 ? views : undefined);
	store.deliver(key, item);
	// A direct file is pulled from the sender's own host, so fetching one on its
	// own from somebody the reader has silenced would be this window reaching out
	// to exactly the person they asked it to stop hearing from. The reference is
	// kept either way, so unignoring and pressing the file still works.
	const silenced = silencedFrom(peer, false, store.get().ignored);
	if (via) {
		for (const [index, attachment] of attachments.entries()) {
			const view = views[index];
			convSession(key)?.files.set(view.id, holdDirectFile(via, attachment));
			if (fetchesOnArrival(attachment, silenced)) openAttachment(key, view.id);
		}
	}
	if (store.get().activeKey !== key && !silencedFrom(peer, false, store.get().ignored)) {
		maybeNotify(peer, text || attachments[0]?.name || "sent a file");
	}
	// Answer the sender a handle to this very line, so they can change or take it
	// back afterwards — the direct sibling of the reference a room's `post`
	// answers, but hosted here on the receiver, which is the durable owner of a
	// direct line's display and its files. A line arriving with no connection to
	// host it on (a send-only line) simply cannot be changed.
	if (via === null) return null;
	return via.spawn((verb, args) => dmLineBehavior(key, peer, item.id, via, verb, args));
}

/** The line a DM handle names, refusing what a room's line reference refuses: a
 * line that is gone, and one already withdrawn — putting text back on a taken-
 * down line is the state neither contract allows. */
function dmHandledItem(key: string, itemId: number): Extract<Item, { kind: "chat" }> {
	const item = store.getConv(key)?.history.find((line) => line.id === itemId);
	if (item?.kind !== "chat") throw new Error("that line is gone");
	if (item.withdrawn === true) throw new Error("that line was withdrawn");
	return item;
}

/** What holding a direct line's handle lets the sender do to it. The handle runs
 * here, on the receiver, and changes this window's own copy of the line — the
 * sender has no other way to reach a display it does not own. Nothing asks who
 * is calling, the same as a room line's reference: only the peer this handle was
 * answered to could have imported it.
 *
 * Every argument is the peer's, so this side holds the same bounds the room
 * server holds on its own line verbs: an edit or caption past what this app
 * shows, and a refile past the message file cap, are refused back to the
 * caller rather than applied. Bound on receive, because there is no server in a
 * direct line to bound it for us. */
function dmLineBehavior(
	key: string,
	peer: string,
	itemId: number,
	session: Session,
	verb: string,
	args: Argument[],
): Argument {
	if (verb === EDIT) {
		const item = dmHandledItem(key, itemId);
		if (typeof args[0] !== "string") throw new Error("edit needs text");
		const text = args[0];
		// The same bound the first delivery of this line passed through: an edit
		// is a second delivery of its text, and this is its `lineNotShowable`.
		const unshowable = lineNotShowable(peer, text);
		if (unshowable !== null) throw new Error(unshowable);
		// Text only, the files left as they are — the same split a room line draws
		// between `edit` and `refile`. Keyed by the item id, not a wire line id: a
		// direct line has none, the handle itself is the correlation.
		store.updateItem(key, item.id, { text, edited: true } as Partial<Item>);
		return null;
	}
	if (verb === WITHDRAW) {
		// The line's files went back with it on the sender's side, so nothing here
		// can fetch them again. The blobs this window held for them are handed
		// back now rather than at conversation teardown: a withdrawn bubble draws
		// nothing, so nothing is left that could ask for the bytes. Saying so
		// twice is not an error, the same as a room line.
		const owner = convSession(key);
		const item = store.getConv(key)?.history.find((line) => line.id === itemId);
		if (owner !== null && item?.kind === "chat" && item.withdrawn !== true) {
			for (const view of item.attachments ?? []) releaseHeldFile(owner, view.id);
			store.updateItem(key, itemId, { withdrawn: true } as Partial<Item>);
		}
		return null;
	}
	if (verb === REFILE) {
		applyDmRefile(key, peer, itemId, session, args);
		return null;
	}
	throw new Error(`a direct line has no method ${verb}`);
}

/** Apply a direct line's refile on the receiver: keep the files this window
 * already holds whose indices the sender named, adopt the new ones riding
 * inline, and let the rest go. The kept files are never re-sent — the receiver
 * is where they live — so a refile that only drops one downloads nothing.
 * `readRefileChange` owns the shape and its bounds; a refile it refuses changes
 * nothing here and the refusal goes back to the caller. */
function applyDmRefile(key: string, peer: string, itemId: number, session: Session, args: Argument[]): void {
	const item = dmHandledItem(key, itemId);
	const old = item.attachments ?? [];
	const { caption, keep, records } = readRefileChange(args, old.length);
	const unshowable = lineNotShowable(peer, caption);
	if (unshowable !== null) throw new Error(unshowable);
	const owner = convSession(key);
	if (owner === null) throw new Error("that line's connection is gone");
	const keptViews = keep.map((at) => old[at]);
	const newViews = records.map((record) =>
		store.attachmentView({
			name: record.name,
			mime: record.mime,
			size: record.size,
			width: record.width,
			height: record.height,
		})
	);
	// Whatever this refile no longer names lets go of its bytes and its URL.
	for (const view of old) {
		if (!keptViews.some((kept) => kept.id === view.id)) releaseHeldFile(owner, view.id);
	}
	const nextViews = [...keptViews, ...newViews];
	store.updateItem(key, item.id, { text: caption, attachments: nextViews.length > 0 ? nextViews : undefined });
	// The same rule the first delivery follows: nothing is pulled from a peer the
	// reader has silenced, and a direct file comes from that peer's own host.
	const silenced = silencedFrom(peer, false, store.get().ignored);
	records.forEach((record, index) => {
		const view = newViews[index];
		owner.files.set(view.id, holdDirectFile(session, record));
		if (fetchesOnArrival(record, silenced)) openAttachment(key, view.id);
	});
}

// ── Invitations, as they arrive ────────────────────────────────────────────
//
// A room handed over reaches this tab the same way a message does: on the
// direct inbox minted for one peer. So taking one in belongs here, beside the
// inbox that hears it, while acting on it — walking into the room — belongs
// with rooms. That split is what keeps the two from importing each other.

/** This tab's own name for one invitation. Counted, because two rooms handed
 * over may be called the same thing. */
let invitationSequence = 0;

/** The live references behind handed invitations, by invitation id.
 *
 * Beside the connections rather than in the store, because a reference is not
 * data: the store draws the row, and this holds what taking it up spends.
 * A row leaves this map exactly once — moved into the room on accept, released
 * on decline — so a second press can never spend a reference twice. */
export interface PendingHandedRoom {
	room: Ref;
	/** Give this occurrence back through the Host that projected it. */
	release(what: string): void;
}

const handedRooms = new Map<string, PendingHandedRoom>();

/** Move one handed room out of pending ownership. Exactly one accept or
 * decline caller can receive the reference. */
export function takeHandedRoom(id: string): PendingHandedRoom | null {
	const room = handedRooms.get(id) ?? null;
	handedRooms.delete(id);
	return room;
}

// Said where the reader is looking as well as shown in the rail, because a row
// appearing in a column they are not reading is easy to miss entirely.
function announceOffer(from: string, label: string): void {
	store.deliverActive(store.sysItem(`${from} offered you ${label || "a room"}. It is in your rooms list.`));
}

/** Take in a room somebody handed this tab: the reference is the offer.
 *
 * An offer of a room this tab is already in is not recognisable from here — a
 * reference says nothing about what it opens — so it arrives as another offer,
 * and taking it up re-claims the membership rather than seating the reader
 * twice. */
export function handedRoom(home: Live, owner: Session, label: string, room: Ref, from: string): boolean {
	if (!isCurrent(home) || store.get().invites.length >= MAX_PENDING_INVITES) {
		// Nothing will ever draw this row — the session is gone, or the offers
		// list is at its ceiling — so the reference goes back now rather than
		// sitting unspendable until the tab closes. The full list is worth a
		// sentence on this side too, and a false answer to the caller, so the
		// sender's own screen says it did not arrive.
		if (isCurrent(home)) {
			store.deliverActive(
				store.sysItem(
					`${from} offered you ${label || "a room"}, but the offers list is full. ` +
						`Take up or decline some in the rooms list first, then ask again.`,
				),
			);
		}
		releaseIncomingRef(owner, room, "refused handed room");
		return false;
	}
	invitationSequence += 1;
	const id = "invite:" + invitationSequence;
	handedRooms.set(id, {
		room,
		release: (what) => releaseIncomingRef(owner, room, what),
	});
	store.addInvite({ id, dir: home.id, way: "handed", label, from, link: "" });
	announceOffer(from, label);
	return true;
}

/** Retire every pending offer filed under a directory the reader gave back.
 * Link offers are only data; handed offers own one capability occurrence and
 * must release it before their presentation row disappears. */
export function releaseHandedRoomsForDirectory(dir: DirId): void {
	for (const invite of store.get().invites) {
		if (invite.dir !== dir) continue;
		takeHandedRoom(invite.id)?.release("abandoned handed room");
		store.dropInvite(invite.id);
	}
}

/** Take in a room somebody offered this tab as a link.
 *
 * The link is data, so nothing about it belongs to the connection it came on:
 * it is worth keeping across a reconnect, and taking it up later redeems the
 * same string. */
export function offeredRoom(home: Live, label: string, link: string, from: string): boolean {
	if (!isCurrent(home)) return false;
	if (store.get().invites.length >= MAX_PENDING_INVITES) {
		store.deliverActive(
			store.sysItem(
				`${from} offered you ${label || "a room"}, but the offers list is full. ` +
					`Take up or decline some in the rooms list first, then ask again.`,
			),
		);
		return false;
	}
	invitationSequence += 1;
	store.addInvite({ id: "invite:" + invitationSequence, dir: home.id, way: "link", label, from, link });
	announceOffer(from, label);
	return true;
}
