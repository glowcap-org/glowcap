// Entering a room: subscribe, keep the membership, and pump what it says.
//
// Reached by name or by a held reference; everything after that meeting is the
// same subscribe. Callers still go through `rooms.ts`.

import { Ref } from "@pancake/runtime";
import { Room } from "../../../lib/room_client.ts";
import { enterOrOpen } from "../../../lib/enter_room.ts";
import { MAX_NICK, mayPresentNameVoucher } from "../../../lib/limits.ts";
import { NICK_TAKEN, roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import { type DirId, silencedFrom } from "../types.ts";
import { lineNotShowable, roomCalled } from "../text.ts";
import { notifiesYou } from "../commands.ts";
import { maybeNotify } from "../notify.ts";
import { fetchesOnArrival } from "../media.ts";
import { reason } from "./common.ts";
import { dirAddress, dirSession, isCurrent } from "./live.ts";
import { tellStanding } from "./standing.ts";
import { setRoomTyping } from "./typing.ts";
import { holdRoomFile, openAttachment, releaseHeldFile } from "./files.ts";

import { advertisePresence } from "./reachable.ts";
import { applyRefile, confirmRoomEcho } from "./send.ts";
import { takePickedRoom } from "./bootstrap.ts";

// Enter `name` as `nick`: subscribe to the room, which is a capability, and keep
// it beside every other room this session holds. Resolves with "" once we are
// in, or with the reason a reader needs to act on.
//
// Entering takes nothing away. A room already held is re-subscribed rather than
// duplicated, which the room reads as the same connection re-claiming its place
// and answers without telling the other members anything happened.
export async function enterRoom(
	dir: DirId,
	name: string,
	nick: string,
	attempt = 0,
	held?: { key: string; room: Ref },
	voucher?: Uint8Array,
	// What the reader actually asked to be called, carried through the retries
	// that suffix `nick`, because "the grant differs from the request" is the
	// one honest test for a rename: comparing against the previously committed
	// name misfires the moment somebody renames on purpose.
	requested = nick,
	// Whether the room this subscribes to was reached by an identity-checked
	// path. A room entered by name comes from the directory's own reference; a
	// link is redeemed through `enliven`, which refuses a peer-identity
	// mismatch. Both are the real directory. A handed reference is not checked —
	// its host is whoever handed it — so it is not trusted with the one thing
	// that would be dangerous to give a stranger: a name voucher.
	trusted = true,
	signal?: AbortSignal,
): Promise<string> {
	if (signal?.aborted) return "";
	const session = dirSession(dir);
	if (session === null) {
		// Never silently: a caller that reaches here with no session has a live
		// "Joining…" button waiting on an answer that will not come.
		return "not connected to the room directory yet";
	}
	// A room reached by name is found by that name; one this tab holds a
	// reference to was handed over and has no name to look up. Everything after
	// this line is the same for both, which is why they meet here rather than in
	// two copies of the subscribe, the nick retry, and the bookkeeping.
	const key = held?.key ?? store.roomKey(dir, name);
	try {
		const ref = held?.room ?? await enterOrOpen(session.dir, name);
		if (signal?.aborted) return "";
		const next = await Room.subscribe(
			session.dir.session,
			ref,
			nick,
			(from, on) => setRoomTyping(key, from, on),
			voucher,
		);
		if (!isCurrent(session) || signal?.aborted) {
			// The session was replaced while we were subscribing, so this room is
			// already unreachable. Drop it rather than filing it under a table the
			// reconnect has moved on from.
			void next.leave().catch(() => {});
			return "";
		}
		const prev = session.rooms.get(key);
		session.rooms.set(key, next);
		// A membership held on this same session has just been replaced by the
		// subscribe above, which the room treats as this connection re-claiming its
		// place. Only the old stream is ours to end: telling the room we are
		// leaving would take back the place we just re-took, because a departure is
		// keyed by connection and there is only one of those here.
		try {
			prev?.replaced();
		} catch (error) {
			// The new membership is already committed. Cleanup of the replaced
			// wrapper is therefore diagnostic, never grounds to report that joining
			// failed or to remove the new room.
			console.error("rooms: replaced membership cleanup failed:", reason(error));
		}
		// Commit the nick we actually claimed. Two tabs of one browser share the
		// persisted nick, so a collision may have suffixed it below; reflect the
		// real name in the store so a member never sees a stale one.
		store.setDirNick(dir, nick);
		// And say so where the reader types. Their own bubbles carry no name, so
		// the only other trace of a rename was the rail foot — far away, absent
		// on a phone — while everyone else saw the new name, and mentions of the
		// asked-for one no longer reached them.
		if (requested.toLowerCase() !== nick.toLowerCase()) {
			store.deliver(
				key,
				store.sysItem(
					`You are "${nick}" here. "${requested}" is taken. Mentions of ${requested} will not reach you.`,
				),
			);
		}
		// Now that we hold a nick in a room, advertise our direct-message locator
		// (`webrtc` by default, the relay rendezvous from Settings / `?dm=relay`) so others
		// can introduce+redeem us for direct messages.
		advertisePresence(session);
		if (signal?.aborted) {
			void next.leave().catch(() => {});
			session.rooms.delete(key);
			return "";
		}
		enteredRoom(dir, name, requested, held?.key);
		// What this membership was handed. Recorded after the conversation exists
		// and from the membership that answered, so a reader's command list is the
		// room's answer rather than this file's opinion of what rooms offer.
		store.setGrants(key, next.canSetTopic ? new Set(["topic"]) : new Set());
		// A membership is a connection's, and this reader's own standing is not.
		// Said again to the room just entered, so a reconnect does not quietly walk
		// them back in. This membership has heard nothing, whatever the one it
		// replaced was told, so the record is dropped before asking.
		session.standingTold.delete(key);
		tellStanding(key);
		// The one failure here that used to be perfectly silent: the reader's own
		// granted name sitting on their own ignore list — put there against a
		// previous holder of the name, or by a slip — hid every line from that
		// name. Their own lines are exempt now, so what remains hidden is other
		// people using it, and that is still worth a sentence where they will
		// type: nothing else on the screen says why those lines never arrive.
		if (store.get().ignored.has(nick.toLowerCase())) {
			store.deliver(
				key,
				store.sysItem(
					`Your name "${nick}" is on your ignore list, so lines from anybody else using it ` +
						`stay hidden. Your own messages are shown. /unignore ${nick} lifts it.`,
				),
			);
		}
		void pump(dir, key, name, next);
		return "";
	} catch (err) {
		if (signal?.aborted) return "";
		const re = roomErrorOf(err);
		// The name may be this reader's own, held by this directory for another of
		// their connections — the shape a room reached by a handed reference or a
		// redeemed link creates. Before conceding the name and suffixing, present
		// the proof: a voucher minted by the name capability `register` answered
		// with. Once, because a voucher that did not satisfy the room will not
		// satisfy it twice, and an older directory mints none.
		// The voucher is a single-use bearer proof that this reader holds their
		// registered name on this directory, and the subscribe carries it to
		// whatever hosts the room. Present it only inside the directory's own
		// trust domain: a room reached by name or link is provably the
		// directory's, while a handed reference is hosted by whoever handed it
		// over, and a voucher is worth exactly the name it proves, so it goes
		// only to a host that already holds the names. A handed room that
		// genuinely needed one (the same reader on a second connection the server
		// cannot recognise as theirs) falls to the suffix instead — the safe
		// degradation, and the reason withholding costs so little.
		// This provenance rule is the whole defense, not a stopgap: the server
		// only ever redeems a voucher that reached one of its own rooms, so
		// binding a voucher to a room server-side would add nothing — every
		// genuine room already sits inside the trust domain that holds all the
		// names. The one decision with any security in it is made here, on the
		// side that chooses whom to hand the bytes to.
		if (
			mayPresentNameVoucher({
				trusted,
				nickTaken: re?.code === NICK_TAKEN,
				attempt,
				presented: voucher !== undefined,
				ownName: nick === store.dirNick(dir),
			})
		) {
			const minted = await session.dir.nameVoucher().catch(() => null);
			if (minted !== null && isCurrent(session)) {
				return await enterRoom(dir, name, nick, attempt, held, minted, requested, trusted, signal);
			}
		}
		if (re?.code === NICK_TAKEN && attempt < 20) {
			// A second tab of the same browser prefills the first tab's persisted
			// nick, so it dead-ends on the room's duplicate-name guard. Claim a free
			// variant instead — `alice` → `alice-2` → `alice-3` — so "open a tab,
			// click Join" just works, which is the whole point of two-tab DMs.
			//
			// The retry carries the reference it was given. Without it the attempt
			// falls back to entering by name, which for a room reached by a link is
			// a different room that happens to share a label — and for a private
			// one, a public room of that name, entered while the reader believes
			// they took up the one they were handed.
			// Trim the base to leave room for the suffix rather than truncating the
			// whole thing: a name already at MAX_NICK would otherwise slice its
			// suffix back off, producing the same refused name twenty times over.
			const suffix = `-${attempt + 2}`;
			const base = nick.replace(/-\d+$/, "").slice(0, MAX_NICK - suffix.length);
			const candidate = base + suffix;
			return await enterRoom(dir, name, candidate, attempt + 1, held, undefined, requested, trusted, signal);
		}
		if (re?.code === NICK_TAKEN) {
			store.showJoinCard();
			store.setStatus("pick another name");
			return re.detail;
		}
		if (store.joinedRooms().length === 0) {
			store.setStatus("could not join");
			return reason(err);
		}
		// Whoever asked for this set the foot to "entering #x…" or "rejoining N
		// rooms…". It speaks for the whole tab, nothing else refreshes it when an
		// attempt ends this way, and a run where every room refused left it
		// announcing an attempt that was over for the life of the session.
		store.setDirStatus(dir, "");
		// A room already on screen is one this is about, so it is where this goes,
		// named. A reconnect re-enters every room at once and a reader is reading
		// one of them: a bare reason in whichever conversation happened to be open
		// says nothing about which room stopped working, and the failed one goes on
		// sitting in the rail looking healthy.
		//
		// With no conversation for it yet, the reader is somewhere else with one in
		// front of them, so it goes there rather than sending them back to the card
		// and taking away the rooms that are working.
		if (store.getConv(key) !== null) {
			store.deliver(key, store.sysItem(`Could not re-enter #${name}: ${reason(err)}`));
		} else if (store.activeConv()) store.deliverActive(store.sysItem(reason(err)));
		else store.toast("failure", reason(err));
		return "";
	}
}

// The room confirmed us. Make its conversation if this is the first entry, and
// show it only if the reader asked for it or has nothing else in front of them.
//
// Entering a room no longer replaces one, so it no longer takes the screen by
// default: a reconnect re-entering three rooms must not drag a reader through
// all three, and a room entered from the rail while reading another should not
// interrupt the one being read unless that is what the tap meant.
function enteredRoom(dir: DirId, name: string, asked: string, held?: string): void {
	// The one moment a join is known to have worked, so it is the one place this
	// browser writes down what to offer next time: the room, the directory it
	// was on, and the name that was asked for. A room reached by name is worth
	// offering back; a private one is not reachable by what it is called, so
	// remembering its label would offer a way in that does not exist.
	//
	// What was asked for rather than what was granted, because this is a
	// preference and not an identity. A directory that had an `alice` already
	// grants `alice-2`, which is true there and nowhere else; remembering it
	// would offer that suffix back on every future visit, including to
	// directories where the plain name is free. What each directory actually
	// granted is `setDirNick`, one answer per directory.
	if (held === undefined) {
		store.remember({
			room: name,
			locator: dir === store.get().homeDir ? "" : dirAddress(dir),
			nick: asked,
		});
	}
	const conv = store.ensureRoom(dir, name, held);
	store.clearMembers(conv.key);
	// The entering is over, so the "entering #x…" the foot was narrating is too.
	//
	// Cleared against the directory the room is on, not against whichever one is
	// acting. Those are the same directory until the room being entered is on a
	// different one from the room being read — and then the clear lands on the
	// directory being left and is read from the directory being entered, which
	// still holds whatever it last said. Entering the first room on a directory
	// reached from the join card left the foot announcing that entry for good.
	store.setDirStatus(dir, "");
	if (takePickedRoom() || store.activeConv() === null) store.switchTo(conv.key);
}

// Deliver a room's lines to its conversation until we switch away (a newer pump
// token) or the stream ends.
//
// Read through an explicit reader rather than `for await (… of room.messages)`.
// Iterating a ReadableStream needs `Symbol.asyncIterator` on its prototype, and
// WebKit did not have it until December 2025: the request was filed in February
// 2019 as WebKit bug 194379 and landed in 303970@main on 2025-12-05, so every
// Safari built before that lacks it, iOS 26 included. Where it is missing the
// loop throws before the first read, and the room then looks entirely healthy —
// it joins, it sends, presence and the typing indicator both arrive, because
// `room_client` routes those around the stream as callbacks — while not one
// line is ever delivered. `getReader` works wherever ReadableStream does, and
// is already how `bindings/ts/web` reads its socket. The date is written down
// because it is checkable against the bug, and the answer is not guessable.
async function pump(dir: DirId, key: string, name: string, room: Room): Promise<void> {
	const reader = room.messages.getReader();
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) return;
			if (dirSession(dir)?.rooms.get(key) !== room) {
				// This membership has been replaced or left, so a newer pump owns the
				// conversation. Drop this stream rather than leave it locked and
				// half-read; `for await` used to do this on return.
				//
				// The test is this room's own identity rather than a global "newest
				// pump" counter: rooms run side by side now, so entering a second one
				// must not silence the first.
				await reader.cancel().catch(() => {});
				return;
			}
			const { from, text, system, presence, facts, attachments, lineId, change } = value;
			// By the key this pump belongs to, never by the room's name: a private
			// room's name is a label two rooms may share, and deriving a key from
			// it here minted a second conversation and delivered the room's lines
			// into it.
			const conv = store.ensureRoom(dir, name, key);
			if (presence) store.applyPresence(conv.key, presence);
			// Presence first, because it is the room's own word about who is here and
			// carries no text of its own. Then the same bound the room holds its
			// members to, held again here: this room is whatever answered the
			// address, and an edit past the cap arrives on this path too.
			const unshowable = lineNotShowable(from, text);
			if (unshowable !== null) {
				store.deliver(conv.key, store.sysItem(unshowable));
				continue;
			}
			// A line the room says something *about* rather than a line being said.
			// Applied before anything else and then done with: an edit is not a new
			// message, so it must not be delivered, counted unread, or notified —
			// somebody fixing a typo should not light the tab up again.
			if (change === "edited" && lineId !== undefined) {
				store.applyLineChange(conv.key, lineId, { text, edited: true });
				continue;
			}
			if (change === "withdrawn" && lineId !== undefined) {
				// The room freed the line's files with it, so the blobs this window
				// held for them can only refuse now. Handed back here rather than at
				// conversation teardown: a withdrawn bubble draws nothing, so nothing
				// is left that could ask for the bytes.
				const owner = dirSession(dir);
				const gone = conv.history.find((row) => row.kind === "chat" && row.lineId === lineId);
				if (owner !== null && gone?.kind === "chat") {
					for (const view of gone.attachments ?? []) releaseHeldFile(owner, view.id);
				}
				store.applyLineChange(conv.key, lineId, { withdrawn: true });
				continue;
			}
			// A line whose file set changed. Like an edit, it is applied and then
			// done with: it is not a new message, so it lights no tab and counts as
			// nothing unread. The records carry the complete new set.
			if (change === "refiled" && lineId !== undefined) {
				applyRefile(dir, room, conv.key, lineId, text, attachments);
				continue;
			}
			// What the room says about itself, which arrives the same way a
			// membership change does and is applied before the line is drawn: a
			// welcome that carries a topic should have set it by the time anything
			// under it is read.
			if (facts?.topic !== undefined) store.setTopic(conv.key, facts.topic);
			if (facts?.lineBytes !== undefined) store.setLineBytes(conv.key, facts.lineBytes);
			if (system) store.deliver(conv.key, store.sysItem(text, "shared"));
			else {
				const nick = store.dirNick(dir);
				const mine = from === nick;
				// Our own line was painted optimistically; its echo confirms it in
				// place rather than painting a duplicate. A file we posted keeps the
				// local URL it is already showing, so its echo costs no download.
				const echoed = mine ? confirmRoomEcho(conv.key, text) : null;
				if (echoed !== null) {
					// The line was painted before the room had named it. Learning the
					// name here is what lets a later edit find it.
					if (lineId !== undefined) store.nameLine(conv.key, echoed.id, lineId);
					for (const [index, attachment] of attachments.entries()) {
						const id = echoed.attachmentIds[index];
						if (id !== undefined) dirSession(dir)?.files.set(id, holdRoomFile(room, attachment));
					}
				}
				if (echoed === null) {
					const views = attachments.map((attachment) =>
						store.attachmentView({
							name: attachment.name,
							mime: attachment.mime,
							size: attachment.size,
							width: attachment.width,
							height: attachment.height,
						})
					);
					const item = store.chatItem(from, text, mine, undefined, views.length > 0 ? views : undefined);
					store.deliver(conv.key, lineId === undefined ? item : { ...item, lineId });
					// The same silence the log draws with, one step earlier: a line the
					// reader will not see must not fetch anything about itself either.
					const silenced = silencedFrom(from, mine, store.get().ignored);
					for (const [index, attachment] of attachments.entries()) {
						const view = views[index];
						dirSession(dir)?.files.set(view.id, holdRoomFile(room, attachment));
						// A picture appears rather than waiting behind a button, the way
						// it does in every chat client; anything larger is asked for.
						// Nothing is pulled on its own for a member the reader has
						// silenced — the reference is kept, so unignoring and pressing
						// the file still works, but silence is not a thing this window
						// says while it downloads.
						if (fetchesOnArrival(attachment, silenced)) openAttachment(conv.key, view.id);
					}
				}
				// The same silence the log draws with, from the same authority: a
				// line the reader will not see must not ring a bell about itself.
				if (!mine && !silencedFrom(from, mine, store.get().ignored) && notifiesYou(text, nick)) {
					maybeNotify(roomCalled(name, conv.held) + " · " + from, text);
				}
			}
		}
	} catch (err) {
		// Leaving a room ends the stream cleanly, which arrives as `done` above,
		// not here. Reaching this means something actually broke, and silence is
		// what made the missing-iterator failure take so long to find: the room
		// simply never spoke. Say so in the room it happened to, which is not
		// necessarily the one being read.
		if (dirSession(dir)?.rooms.get(key) === room) {
			// With the way back in the same breath. The connection is still up and
			// the room takes a re-claim on it, keeping this member's place and the
			// references to what they have already said, so there is something to
			// do here rather than a dead conversation and a reason for it.
			store.deliver(
				key,
				store.sysItem(
					`This room stopped delivering messages: ${reason(err)}. Type /join ${name} to re-enter it.`,
				),
			);
		}
	} finally {
		try {
			reader.releaseLock();
		} catch { /* already released by cancel above */ }
	}
}
