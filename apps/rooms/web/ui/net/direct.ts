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
import { type Attachment, type AttachmentSource, readRefileChange } from "../../../lib/attachment.ts";
import { trouble } from "./common.ts";
import { DirectMessage, PostedLine } from "../../../lib/room_client.ts";
import { EDIT, REFILE, WITHDRAW } from "../../../lib/protocol.ts";
import { PEER_OFFLINE, roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import { type DirId, type DmConv, type Item, silencedFrom } from "../types.ts";
import { lineNotShowable } from "../text.ts";
import { maybeNotify } from "../notify.ts";
import { fetchesOnArrival } from "../media.ts";
import { markSend, reason } from "./common.ts";
import { actingDir, convSession, dirSession, type Live } from "./live.ts";
import { FILE_GONE_WITH_ITS_CONNECTION, holdDirectFile, openAttachment, releaseHeldFile } from "./files.ts";
import { hydrateDm } from "./history.ts";
import { applyTyping } from "./typing.ts";
import { receiveArchiveShare } from "./archive_shares.ts";
import { releaseIncomingArguments, releaseIncomingAttachments, releaseIncomingRef } from "./direct_custody.ts";
import { handedRoom, offeredRoom } from "./direct_offers.ts";
import { MAX_DM_INBOXES } from "../../../lib/limits.ts";

/** Reply routes a peer handed us with an incoming message, by conversation.
 *
 * Homed here rather than on a directory session for the reason the inbox host
 * is: this route arrived over a connection the *peer* opened to that host, so a
 * room server respawning has nothing to do with it. `DirectMessage.adopt` owns
 * the imported occurrence without claiming ownership of that shared CapTP
 * session. */
const backChannels = new Map<string, DirectMessage>();

/** The live reply route for one conversation. A stale row is retired through
 * the same close owner as every explicit release rather than handed to a
 * caller that can no longer use it. */
export function activeBackChannel(key: string): DirectMessage | null {
	const held = backChannels.get(key);
	if (held === undefined) return null;
	if (held.live) return held;
	releaseBackChannel(key);
	return null;
}

/** Adopt a reply route only when no working route already owns the
 * conversation. The caller retains ownership of `reply` when this returns
 * false and must release that occurrence. */
function adoptBackChannel(
	key: string,
	peer: string,
	peerRegistrationId: string,
	session: Session,
	reply: Ref,
): boolean {
	if (activeBackChannel(key) !== null) return false;
	backChannels.set(key, DirectMessage.adopt(session, reply, peer, peerRegistrationId));
	return true;
}

/** Adopt or return one incoming reply occurrence. The conversation becomes
 * live from route authority itself; no placeholder message is needed. */
export function takeBackChannel(
	key: string,
	peer: string,
	peerRegistrationId: string,
	session: Session,
	reply: Ref,
): void {
	if (!adoptBackChannel(key, peer, peerRegistrationId, session, reply)) {
		releaseIncomingRef(session, reply, "unused direct reply route");
		return;
	}
	const owner = convSession(key);
	if (owner != null) dropDirectRoute(owner, peerRegistrationId);
	store.setDmLine(key, "live");
}

/** Answer a directory introduction request by opening the compatible carrier
 * in the reciprocal direction and handing over our reply route. */
export function establishRequestedDirect(dir: DirId, peer: string, peerRegistrationId: string): void {
	const session = dirSession(dir);
	if (session == null || store.isSelf(dir, peer)) return;
	void openDirectRoute(session, peer, peerRegistrationId).then(async (line) => {
		await line.establishReplyRoute();
	}).catch((error) => trouble(`could not establish the reciprocal direct route to ${peer}`, error));
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
	const registration = store.peerRegistration(here, peer);
	if (registration == null) {
		store.deliverActive(store.sysItem(`${peer} is not registered for direct messages here.`));
		return;
	}
	const conv = store.ensureDm(here, registration.name, registration.registrationId);
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
	if (session == null) throw new Error("not connected");
	const back = activeBackChannel(key);
	try {
		if (back) {
			return sources.length > 0 ? await back.sendFiles(sources, text) : await back.say(text);
		}
		const line = await openDm(conv);
		return sources.length > 0 ? await line.sendFiles(sources, text) : await line.say(text);
	} catch (err) {
		// Let the dead line go so the next send retries: a stale back-channel
		// falls back to a fresh introduction, a stale introduction re-redeems.
		if (back) releaseBackChannel(key);
		else dropDirectRoute(session, conv.peerRegistrationId);
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
export function directReceiverFor(dir: DirId, peer: string, peerRegistrationId: string, acceptReplyRoute: boolean) {
	return {
		message: (text: string, attachments: Attachment[], via: Session, reply: Ref | null) => {
			const conv = store.ensureDm(dir, peer, peerRegistrationId);
			if (conv == null) {
				if (reply != null) releaseIncomingRef(via, reply, "unused direct reply route");
				releaseIncomingAttachments(via, attachments, "unused direct message file");
				return null;
			}
			hydrateDm(conv);
			if (reply != null) {
				if (acceptReplyRoute) takeBackChannel(conv.key, peer, peerRegistrationId, via, reply);
				else releaseIncomingRef(via, reply, "redundant direct reply route");
			}
			return receiveDm(conv.key, peer, text, attachments, via);
		},
		ready: (via: Session, reply: Ref) => {
			const conv = store.liveDmWith(dir, peer, peerRegistrationId);
			if (conv == null || !acceptReplyRoute) {
				releaseIncomingRef(via, reply, "unused direct reply route");
				return;
			}
			takeBackChannel(conv.key, peer, peerRegistrationId, via, reply);
		},
		typing: (on: boolean) => {
			const conv = store.liveDmWith(dir, peer, peerRegistrationId);
			if (conv != null) applyTyping(conv.key, peer, on);
		},
		handArchive: (directory: string, conversation: string, archive: Ref, owner: Session) => {
			const home = dirSession(dir);
			if (home == null) {
				releaseIncomingRef(owner, archive, "refused archive share");
				throw new Error("they are between connections. Ask again in a moment");
			}
			receiveArchiveShare(home, owner, directory, conversation, archive, peer, peerRegistrationId);
		},
		handRoom: (label: string, room: Ref, owner: Session) => {
			const home = dirSession(dir);
			if (home == null) {
				releaseIncomingRef(owner, room, "refused room offer");
				throw new Error("they are between connections. Ask again in a moment");
			}
			if (!handedRoom(home, owner, label, room, peer)) {
				throw new Error("their offers list is full. Ask again once they have answered some");
			}
		},
		offerRoom: (label: string, link: string) => {
			const home = dirSession(dir);
			if (home == null) throw new Error("they are between connections. Ask again in a moment");
			if (!offeredRoom(home, label, link, peer)) {
				throw new Error("their offers list is full. Ask again once they have answered some");
			}
		},
	};
}

function openDirectRoute(session: Live, peer: string, peerRegistrationId: string): Promise<DirectMessage> {
	const key = peerRegistrationId;
	const existing = session.directRoutes.get(key);
	if (existing) {
		// Same staleness as the back-channel above, one step softer: `say` is
		// async, so a dead line surfaces as a rejection and repairs itself after
		// one visibly failed message. Checking here spends no message at all.
		const reopen = () => {
			// Only if it is still the entry we looked at; a concurrent send may
			// already have replaced it. Handed back rather than forgotten, for the
			// same reason the failed send above hands its line back.
			if (session.directRoutes.get(key) === existing) dropDirectRoute(session, peerRegistrationId);
			return openDirectRoute(session, peer, peerRegistrationId);
		};
		return existing.then((line) => (line.live ? line : reopen()), reopen);
	}
	if (session.directRoutes.size >= MAX_DM_INBOXES) {
		return Promise.reject(new Error(`this browser holds at most ${MAX_DM_INBOXES} direct routes per directory`));
	}
	const line = DirectMessage.open(
		session.dir,
		peer,
		directReceiverFor(session.id, peer, peerRegistrationId, false),
		peerRegistrationId,
	);
	session.directRoutes.set(key, line);
	return line;
}

export function openDm(conv: DmConv): Promise<DirectMessage> {
	const session = dirSession(conv.dir);
	if (session == null) return Promise.reject(new Error("not connected"));
	if (store.isSelf(conv.dir, conv.id)) {
		return Promise.reject(new Error("You can't start a direct message with yourself."));
	}
	if (conv.line === "closed") {
		return Promise.reject(new Error(`${conv.id} left, so this conversation is closed`));
	}
	return openDirectRoute(session, conv.id, conv.peerRegistrationId);
}

/** Let one conversation's arriving back-channel go: drop the row and release
 * the imported reply route.
 *
 * One authority, because four sites let a back-channel go. The adopted line
 * releases exactly its imported route; the peer that opened the shared CapTP
 * session remains its lifecycle owner. */
export function releaseBackChannel(key: string): void {
	const back = backChannels.get(key);
	backChannels.delete(key);
	if (back === undefined) return;
	void back.close().catch((err) => trouble("an arriving direct route would not release", err));
}

export function dropDirectRoute(session: Live, peerRegistrationId: string): void {
	const key = peerRegistrationId;
	const line = session.directRoutes.get(key);
	if (line === undefined) return;
	session.directRoutes.delete(key);
	void line.then(
		(l) => l.close().catch((err) => trouble("a direct line would not close, so its connection stays up", err)),
		// The caller that created this promise owns its open failure. Retirement
		// owns only the live route that an opening successfully produced.
		() => undefined,
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
		if (via != null) releaseIncomingAttachments(via, attachments, "refused direct message file");
		else if (attachments.length > 0) throw new Error("direct message files arrived without their owning session");
		return null;
	}
	if (via == null && attachments.length > 0) {
		throw new Error("direct message files arrived without their owning session");
	}
	const owner = convSession(key);
	const filesAvailable = via != null && owner != null;
	const views = attachments.map((attachment) =>
		store.attachmentView({
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
			...(filesAvailable ? {} : { lost: true, error: FILE_GONE_WITH_ITS_CONNECTION }),
		})
	);
	const item = store.chatItem(peer, text, false, undefined, views.length > 0 ? views : undefined);
	// A direct file is pulled from the sender's own host, so fetching one on its
	// own from somebody the reader has silenced would be this window reaching out
	// to exactly the person they asked it to stop hearing from. The reference is
	// kept either way, so unignoring and pressing the file still works.
	const silenced = silencedFrom(peer, false, store.get().ignored);
	if (via != null && owner != null) {
		for (const [index, attachment] of attachments.entries()) {
			const view = views[index];
			owner.files.set(view.id, holdDirectFile(via, attachment));
		}
	} else if (via != null) {
		releaseIncomingAttachments(via, attachments, "orphaned direct message file");
	}
	store.deliver(key, item);
	if (via != null && owner != null) {
		for (const [index, attachment] of attachments.entries()) {
			if (fetchesOnArrival(attachment, silenced)) openAttachment(key, views[index].id);
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
		if (args.length !== 1 || typeof args[0] !== "string") {
			releaseIncomingArguments(session, args, "refused direct line edit argument");
			throw new Error("edit needs exactly one text argument");
		}
		const item = dmHandledItem(key, itemId);
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
		if (args.length !== 0) {
			releaseIncomingArguments(session, args, "refused direct line withdrawal argument");
			throw new Error("withdraw takes no arguments");
		}
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
		try {
			applyDmRefile(key, peer, itemId, session, args);
		} catch (error) {
			releaseIncomingArguments(session, args, "refused direct line refile argument");
			throw error;
		}
		return null;
	}
	releaseIncomingArguments(session, args, "unsupported direct line argument");
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
	records.forEach((record, index) => owner.files.set(newViews[index].id, holdDirectFile(session, record)));
	store.updateItem(key, item.id, { text: caption, attachments: nextViews.length > 0 ? nextViews : undefined });
	// The same rule the first delivery follows: nothing is pulled from a peer the
	// reader has silenced, and a direct file comes from that peer's own host.
	const silenced = silencedFrom(peer, false, store.get().ignored);
	records.forEach((record, index) => {
		const view = newViews[index];
		if (fetchesOnArrival(record, silenced)) openAttachment(key, view.id);
	});
}
