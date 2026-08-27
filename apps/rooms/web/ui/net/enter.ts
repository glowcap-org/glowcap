// Entering a room: subscribe, keep the membership, and pump what it says.
//
// Reached by name or by a held reference; everything after that meeting is the
// same subscribe. Callers still go through `rooms.ts`.

import { Ref } from "@pancake/runtime";
import { Room } from "../../../lib/room_client.ts";
import { enterOrOpenResult } from "../../../lib/enter_room.ts";
import { mayPresentNameVoucher, suggestedNick } from "../../../lib/limits.ts";
import { NICK_TAKEN, roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import { type DirId } from "../types.ts";
import { listedOccupancy } from "../joining.ts";
import { reason, trouble } from "./common.ts";
import { dirAddress, dirSession, isCurrent } from "./live.ts";
import { tellStanding } from "./standing.ts";
import { setRoomTyping } from "./typing.ts";
import { restoreStewardship } from "./stewardship.ts";
import { replayPeering } from "./peering.ts";
import { hydrateRoom } from "./history.ts";

import { advertisePresence } from "./reachable.ts";
import { automaticSelectionAvailable } from "./bootstrap.ts";
import { projectRoomMessage } from "./room_messages.ts";

interface EnterRoomOptions {
	attempt?: number;
	/** Automatic reconstruction may briefly meet this page's prior connection
	 * still holding the exact nickname. Retry that claim without changing it. */
	reentry?: boolean;
	claimRetries?: number;
	held?: { key: string; room: Ref };
	/** Subscribe this already-held reference.
	 *
	 * A link-join enlivens, then subscribes. Listed-ness arrives on that
	 * subscribe; the conversation is the listed room when it does, and held
	 * when it does not. Asking the room whether it is private first is not
	 * this path — an older occupancy has no such method. */
	room?: Ref;
	publicationId?: string;
	voucher?: Uint8Array;
	requested?: string;
	trusted?: boolean;
	/** Show this room after admission because the reader explicitly chose it. */
	select?: boolean;
	signal?: AbortSignal;
	/** A room link this join already holds, so the conversation can copy it
	 * without asking the room to mint another. */
	link?: string;
}

const REENTRY_CLAIM_RETRY_MS = 500;
const REENTRY_CLAIM_RETRIES = 8;

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
	options: EnterRoomOptions = {},
): Promise<string> {
	const {
		attempt = 0,
		held,
		voucher,
		requested = nick,
		trusted = true,
		select = false,
		signal,
	} = options;
	if (signal?.aborted) return "";
	store.setRequestedDirNick(dir, requested);
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
	const given = held?.room ?? options.room;
	const publicationId = options.publicationId ??
		(given === undefined && held === undefined ? store.enteredPublication(dir, name)?.id : undefined);
	const shown = name === "" ? "a room" : name;
	// A link-join does not know listed-ness until subscribe answers. Seat
	// provisionally as held; a listed arrival moves it onto the public key
	// before the conversation is committed.
	let key = held?.key ??
		(options.room !== undefined
			? store.heldRoomKey()
			: publicationId === undefined
			? store.roomKey(dir, name)
			: store.publishedRoomKey(dir, publicationId));
	let seatedHeld = held !== undefined || options.room !== undefined;
	try {
		let ref = given;
		if (ref === undefined) {
			if (publicationId === undefined) {
				const found = await enterOrOpenResult(session.dir, name);
				ref = found.ref;
				if (found.opened) session.stewardClaimable.add(key);
			} else {
				ref = await session.dir.enterPublication(publicationId);
			}
		}
		if (signal?.aborted) return "";
		const saved = store.getConv(key);
		const savedIrc = saved?.type === "room" ? saved.irc : undefined;
		const next = await Room.subscribe(
			session.dir.session,
			ref,
			nick,
			(from, on) => setRoomTyping(key, from, on),
			voucher,
		);
		if (options.room !== undefined && held === undefined && listedOccupancy(next.listed, name)) {
			key = store.roomKey(dir, name);
			seatedHeld = false;
		}
		if (!isCurrent(session) || signal?.aborted) {
			// The session was replaced while we were subscribing, so this room is
			// already unreachable. Drop it rather than filing it under a table the
			// reconnect has moved on from.
			void next.leave().catch(() => {});
			return "";
		}
		const prev = session.rooms.get(key);
		session.rooms.set(key, next);
		void replayPeering();
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
			trouble("replaced membership cleanup failed", error);
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
		enteredRoom(dir, shown, requested, {
			key: seatedHeld ? key : undefined,
			held: seatedHeld,
			publicationId,
			link: options.link,
			stewardClaimable: session.stewardClaimable.has(key),
		}, select);
		if (savedIrc === null) {
			try {
				await next.disconnectIrc();
			} catch (error) {
				store.deliver(
					key,
					store.sysItem(`Could not restore your Rooms-only IRC choice: ${reason(error)}`),
				);
			}
		} else if (savedIrc != null) {
			try {
				await next.ircIdentity(savedIrc.nick, savedIrc.account, savedIrc.password);
			} catch (error) {
				store.deliver(
					key,
					store.sysItem(`Could not restore your IRC identity: ${reason(error)}`),
				);
			}
		}
		const entered = store.getConv(key);
		if (entered?.type === "room") hydrateRoom(entered);
		// What this membership was handed. Recorded after the conversation exists
		// and from the membership that answered, so a reader's command list is the
		// room's answer rather than this file's opinion of what rooms offer.
		store.setGrants(key, next.canSetTopic ? new Set(["topic"]) : new Set());
		// A durable steward is minted only by an explicit act. Reconnecting a
		// conversation that already retained one is different: take that exact
		// bearer authority back up, and surface any failure rather than silently
		// losing moderation while leaving the interface looking privileged.
		restoreStewardship(key, next, () => isCurrent(session));
		// What the room kept of itself, stood under a log that has nothing yet.
		// The membership identity is checked again when the answer lands: a slow
		// answer from the room we replaced must not prepend itself to the new room's
		// log or settle its loading state.
		if (store.getConv(key)?.history.length === 0) {
			store.setEarlierHistory(key, "loading");
			void next.history().then((lines) => {
				if (!isCurrent(session) || session.rooms.get(key) !== next) return;
				if (lines.length === 0) {
					store.setEarlierHistory(key, "empty");
					return;
				}
				store.prependHistory(
					key,
					lines.map((line) => ({
						from: line.from,
						text: line.text,
						mine: line.from === nick,
						at: line.at,
					})),
					"Earlier messages, kept by this room",
				);
				store.setEarlierHistory(key, "shown");
			}).catch(() => {
				if (!isCurrent(session) || session.rooms.get(key) !== next) return;
				// History is an optional room verb. A refusal says that this room did
				// not provide earlier messages; it must still settle the visible wait.
				store.setEarlierHistory(key, "unavailable");
			});
		}
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
		void pump(dir, key, shown, next);
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
				return await enterRoom(dir, name, nick, { ...options, attempt, voucher: minted, requested, trusted });
			}
		}
		if (
			re?.code === NICK_TAKEN && options.reentry === true &&
			(options.claimRetries ?? 0) < REENTRY_CLAIM_RETRIES
		) {
			store.setDirStatus(dir, `waiting for the previous "${nick}" claim to close…`);
			await new Promise((resolve) => setTimeout(resolve, REENTRY_CLAIM_RETRY_MS));
			if (!isCurrent(session) || signal?.aborted) return "";
			return await enterRoom(dir, name, nick, {
				...options,
				claimRetries: (options.claimRetries ?? 0) + 1,
			});
		}
		if (re?.code === NICK_TAKEN) {
			const refusal = `${re.detail} Try "${suggestedNick(nick)}" instead.`;
			if (store.getConv(key) != null) {
				store.setRoomMembership(key, "unavailable");
				store.setDirStatus(dir, "");
				store.deliver(key, store.sysItem(`Could not re-enter #${shown}: ${refusal}`));
			} else {
				store.showJoinCard();
				store.setStatus(refusal);
			}
			return refusal;
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
			store.deliver(key, store.sysItem(`Could not re-enter #${shown}: ${reason(err)}`));
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
function enteredRoom(
	dir: DirId,
	name: string,
	asked: string,
	identity: {
		key?: string;
		held: boolean;
		publicationId?: string;
		link?: string;
		stewardClaimable: boolean;
	},
	select: boolean,
): void {
	// The one moment a join is known to have worked, so it is the one place this
	// browser writes down what to offer next time: the room, the directory it
	// was on, and the name that was asked for. A room reached by name is worth
	// offering back; a private one is not reachable by what it is called, so
	// remembering its label would offer a way in that does not exist.
	//
	// The accepted value is the value that was asked for. A collision refuses
	// without changing it and may offer a separate suggestion, so this records
	// no server-invented identity.
	if (!identity.held) {
		store.remember({
			room: name,
			locator: dir === store.get().homeDir ? "" : dirAddress(dir),
			nick: asked,
		});
	}
	const conv = store.ensureRoom(dir, name, identity);
	store.setRoomMembership(conv.key, "joined");
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
	if (select || (automaticSelectionAvailable() && store.activeConv() === null)) store.switchTo(conv.key);
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
	const seated = key;
	const reader = room.messages.getReader();
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) {
				// A stream that ends while this membership is still the current one
				// was ended by the room, not by a leave or a replacement — those
				// retire the membership row first. A dead room drawn as a healthy
				// one is the failure mode here, so the hangup says so where the
				// reader is reading, with the way back beside it.
				if (dirSession(dir)?.rooms.get(seated) === room) {
					store.deliver(
						seated,
						store.sysItem(`The room ended this conversation. Type /join ${name} to re-enter it.`),
					);
				}
				return;
			}
			if (dirSession(dir)?.rooms.get(seated) !== room) {
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
			projectRoomMessage(dir, seated, name, room, value);
		}
	} catch (err) {
		// Leaving a room ends the stream cleanly, which arrives as `done` above,
		// not here. Reaching this means something actually broke, and silence is
		// what made the missing-iterator failure take so long to find: the room
		// simply never spoke. Say so in the room it happened to, which is not
		// necessarily the one being read.
		if (dirSession(dir)?.rooms.get(seated) === room) {
			// With the way back in the same breath. The connection is still up and
			// the room takes a re-claim on it, keeping this member's place and the
			// references to what they have already said, so there is something to
			// do here rather than a dead conversation and a reason for it.
			store.deliver(
				seated,
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
