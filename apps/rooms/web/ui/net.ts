// The rooms page's data layer, as a real OCapN peer in the browser. The page
// instantiates the pancake runtime over `@pancake/web` (the wasm Host, no dlopen),
// dials the room server through serve.ts's `/relay` byte pipe, and drives the
// directory and room as capabilities — the same `lib/room_client.ts` the
// terminal clients use. No JSON bridge: the browser holds the room capability
// itself.
//
// Direct messages work by introduction. The browser asks the directory to
// introduce it to a member, redeems the handoff-give by dialing that member
// through the relay's `?locator=` iroh path, and messages them straight over
// that direct line, with the room never on the message path — the same
// three-party handoff `demo-rooms-dm-iroh` proves, driven from a browser tab.
// The relay dials any iroh node but pins TCP to the room server, so a member
// reachable only over TCP surfaces an honest "couldn't reach directly" rather
// than a fake send. The other direction — a member dialing a browser first —
// still waits on browser reachability, so a browser opens the line by sending.
//
// Nothing here draws anything. It reads and writes the store, and the interface
// is a function of the store; this file imports no component and touches no
// element. That is also why the peer survives anything React does: the session
// is owned here, at module scope, so a remount, a StrictMode double-pass, or an
// error boundary catching a render never disturbs a live conversation.

import { lineCost, MAX_LINE } from "../../lib/limits.ts";
import { typedRoomLink } from "./joining.ts";
import { type DirId, liveRoomCounts, type RoomDestination } from "./types.ts";
import type { Reach } from "./intent.ts";
import * as store from "./store.ts";
import { directoryName, lineRoom, roomCalled, tooLong } from "./text.ts";
import { type CommandPowers } from "./commands.ts";
import { prepareComposerSend } from "./composer/send.ts";
import { reason } from "./net/common.ts";
import { dmSay, openDm, startDm } from "./net/direct.ts";
import { convSession, dirAddress, dirSession, isConnected } from "./net/live.ts";
import { prepareDirectArchiveFacet } from "./net/archive_target.ts";

// The page reaches this layer through one namespace, so what moved into a
// module of its own is named here as well. The split is where the code lives,
// not a change to what the interface may ask for.
export { openAttachment, stepViewer } from "./net/files.ts";
export { startDm } from "./net/direct.ts";
export { retrySend, selfLocator } from "./net/reachable.ts";
export { connect, leaveDirectory } from "./net/connection.ts";
export { releaseDirectoryNick } from "./net/directory_identity.ts";
export { openDirectory } from "./net/connection.ts";
export { bootRuntime } from "./net/runtime_boot.ts";
export { readOpsBundle, refreshOpsCap, replaceOpsBundle } from "./net/ops.ts";
export { joinIrcBridge, partIrcBridge } from "./net/irc.ts";
export { connectIrcIdentity, disconnectIrcIdentity } from "./net/irc_identity.ts";
export { requestListenerDown, requestListenerUp } from "./net/listeners.ts";
export {
	loadMoreOperator,
	refreshOperator,
	requestNickRevoke,
	requestOperatorReferenceRelease,
	requestOperatorReset,
	requestOperatorRoomRemove,
	requestOperatorTroubleClear,
	requestRoomLinkRevoke,
	requestSessionDisconnect,
	requestStewardGive,
	requestStewardRevoke,
	retireMatchingOperator,
} from "./net/operator.ts";
export { restoreArchivePeer, retryArchivePeer, takeArchivePeer, useDeviceArchive } from "./net/archive_target.ts";
export { dropArchiveShare, readArchiveShare } from "./net/archive_shares.ts";
export { publishPeeredRoom, revokePeeredPublication } from "./net/peering.ts";
export { askMemberOut, askMemberOutSettled, steward, takeStewardship } from "./net/stewardship.ts";
import { leaveDirectory, openDirectory } from "./net/connection.ts";
export { setDirStanding, setRoomStanding, setStanding } from "./net/standing.ts";
export { directoryId, directoryLocator, directoryReady } from "./net/bootstrap.ts";
export { FIRST_BACKOFF_MS } from "./net/bootstrap.ts";
export { reserveSelectionForAddress } from "./net/bootstrap.ts";
export { dirAddress } from "./net/live.ts";
export { acceptInvite, declineInvite } from "./net/invites.ts";
export { closeDm, endConversation, leaveRoom, openPrivateRoom, pickRoom, showRoom } from "./net/rooms.ts";
export { createRoomLink } from "./net/room_links.ts";
import { takeRoomLink } from "./net/invites.ts";
import { mintRoomLink } from "./net/room_links.ts";
import { abandonJoin, endConversation, enterRoom, openPrivateRoom, pickRoom, stageJoin } from "./net/rooms.ts";
import { actLocator, directoryId, FIRST_BACKOFF_MS, notALocator, requestedLocator } from "./net/bootstrap.ts";
import { setDirStanding, setRoomStanding, setStanding } from "./net/standing.ts";
export { addFiles, mention, recallLastSent, setDraft, setTyping, stopSend, withdraw } from "./net/send.ts";
import { editLine, lastLineOfOurs, refileActive, sayLine, sendFiles, withdraw } from "./net/send.ts";
import { askMemberOut, steward } from "./net/stewardship.ts";

/** Hand the selected archive's read-only account of one direct conversation
 * to its other member. The narrowed occurrence is retained only for the ask;
 * the receiver owns the projected occurrence it accepts. */
export async function shareArchiveHistory(key: string): Promise<string> {
	const conv = store.getConv(key);
	const home = convSession(key);
	if (conv?.type !== "dm" || home === null) return "This direct conversation is not connected right now.";
	let facet: Awaited<ReturnType<typeof prepareDirectArchiveFacet>> | null = null;
	try {
		facet = await prepareDirectArchiveFacet(home, conv.persistId);
		const dm = await openDm(conv);
		await dm.handArchive(home.id, conv.persistId, facet.ref);
		store.deliver(
			key,
			store.sysItem(`You shared a read-only archive account of this conversation with ${conv.id}.`),
		);
		return "";
	} catch (error) {
		const why = reason(error);
		store.deliver(key, store.sysItem(`Could not share this conversation's archive history: ${why}`));
		return why;
	} finally {
		facet?.release();
	}
}

/** What a slash command may reach.
 *
 * One table, named a verb at a time, rather than handing commands this module.
 * A command that wants something not here is a decision somebody makes on
 * purpose — which is the same argument this app makes about authority
 * everywhere else, turned on its own vocabulary. */
const NO_GRANTS: ReadonlySet<string> = new Set();

const POWERS: CommandPowers = {
	say(text) {
		store.deliverActive(store.sysItem(text));
	},
	joinRoom(name) {
		const conv = store.activeConv();
		const dir = conv?.dir ?? store.actingDir()?.id ?? null;
		if (dir === null) {
			store.deliverActive(store.sysItem("There is no directory to enter a room on yet."));
			return;
		}
		pickRoom(dir, name);
	},
	leaveHere() {
		endConversation();
	},
	directMessage(who) {
		startDm(who);
	},
	you() {
		const conv = store.activeConv();
		const dir = conv?.dir ?? store.actingDir()?.id ?? null;
		return dir === null ? "" : store.dirNick(dir);
	},
	setTheme(theme) {
		store.setTheme(theme);
	},
	showRoster(shown) {
		store.showRoster(shown);
	},
	clearHere() {
		const key = store.get().activeKey;
		if (key !== null) store.clearHistory(key);
	},
	ignore(name) {
		store.ignore(name);
	},
	unignore(name) {
		return store.unignore(name);
	},
	ignored() {
		return [...store.get().ignored].sort();
	},
	editLast(text) {
		const key = store.get().activeKey;
		const last = key === null ? null : lastLineOfOurs(key);
		if (key === null || last === null) return false;
		editLine(key, last.id, text);
		return true;
	},
	withdrawLast() {
		const key = store.get().activeKey;
		const last = key === null ? null : lastLineOfOurs(key);
		if (key === null || last === null) return false;
		withdraw(key, last.id);
		return true;
	},
	setTopic(text) {
		const conv = store.activeConv();
		const room = conv === null ? undefined : convSession(conv.key)?.rooms.get(conv.key);
		if (conv?.type !== "room" || room === undefined || !room.canSetTopic) return false;
		// The room answers everybody with the change, this tab included, so there
		// is nothing to apply here: what is on screen comes back off the wire.
		room.setTopic(text).catch((error) => {
			store.deliverActive(store.sysItem(`Could not set the topic: ${reason(error)}`));
		});
		return true;
	},
	kick(who) {
		const conv = store.activeConv();
		return conv?.type === "room" ? askMemberOut(conv.key, who) : false;
	},
	steward(link) {
		const conv = store.activeConv();
		return conv?.type === "room" ? steward(conv.key, link) : false;
	},
	setAway(why) {
		const conv = store.activeConv();
		if (conv?.type !== "room") return false;
		// Written where this reader's standing already comes from, rather than
		// always at one level. Nobody who has never touched the other two is given
		// a room-shaped answer to a question they asked in words that mean
		// everywhere, and nobody who *has* set a room or a directory apart finds
		// `/away` quietly overruling it from outside.
		if (conv.standing !== null) setRoomStanding(conv.key, why);
		else if (store.get().dirs.get(conv.dir)?.standing != null) setDirStanding(conv.dir, why);
		else setStanding(why);
		return true;
	},
	joinLink(link, label) {
		// No directory is named here, and that is the point: a link carries its
		// own, so taking one up does not depend on where the reader happens to be
		// standing. What this side supplies is the name they would like to be
		// called, from the directory they are reading if it has granted them one.
		const dir = store.activeConv()?.dir ?? store.actingDir()?.id ?? null;
		const nick = (dir === null ? "" : store.dirNick(dir)) || store.reachingNick();
		void takeRoomLink(link, label, nick).then((why) => {
			if (why !== "") store.deliverActive(store.sysItem(`That link did not open a room: ${why}`));
		}, (error) => {
			store.deliverActive(store.sysItem(`That link did not open a room: ${reason(error)}`));
		});
	},
	invite(nick) {
		const conv = store.activeConv();
		const session = conv === null ? null : convSession(conv.key);
		const room = conv === null ? undefined : session?.rooms.get(conv.key);
		if (conv?.type !== "room" || session === null || room === undefined) return false;
		if (store.isSelf(session.id, nick)) return false;
		// The room itself, handed over the direct line to them: the reference is
		// the invitation, carried across as a handoff, with nothing asked of the
		// room or the directory about who may be offered it and nothing durable
		// minted anywhere — which a link is not free of. They may take it up,
		// ignore it, or pass it on.
		// Offering a room means opening a line to carry it, which puts a direct
		// conversation on screen. Say why it appeared, in the line itself — a
		// bare DM opening beside the room with no reason reads as the app doing
		// something unbidden. Only on a line that did not already exist: a
		// standing conversation should not gain a system line every invite.
		const label = conv.id;
		const registration = store.peerRegistration(session.id, nick);
		if (registration == null) return false;
		const existed = store.liveDmWith(session.id, registration.name, registration.registrationId) != null;
		const line = store.ensureDm(session.id, registration.name, registration.registrationId);
		if (line === null) return false;
		const conversation = store.getConv(line.key);
		if (conversation?.type !== "dm") return false;
		if (!existed) {
			store.deliver(
				line.key,
				store.sysItem(
					`This opened so you could offer ${nick} ${label ? roomCalled(label, conv.held) : "a room"}. ` +
						`It is now a direct line to them like any other.`,
				),
			);
		}
		void openDm(conversation)
			.then((dm) => dm.handRoom(label, room.reference))
			.then(() => store.deliver(conv.key, store.sysItem(`${nick} has been offered this room.`)))
			.catch((error) =>
				store.deliver(
					conv.key,
					store.sysItem(
						`Could not offer this room to ${nick}: ${reason(error)}. ` +
							`/link makes an offer that travels as text instead`,
					),
				)
			);
		return true;
	},
	roomLink(name) {
		const asked = name?.trim().replace(/^#/, "") ?? "";
		if (asked !== "") {
			const conv = store.activeConv();
			const dir = conv?.dir ?? store.actingDir()?.id ?? null;
			const session = dir === null ? null : dirSession(dir);
			if (session === null) return false;
			void session.dir.link(asked)
				.then((link) => {
					const target = store.joinedRooms(session.id).find((row) =>
						!row.held && row.id.toLowerCase() === asked.toLowerCase()
					);
					if (target !== undefined) store.noteRoomLink(target.key, link);
					store.deliverActive(
						store.sysItem(
							`Anybody who holds this link can be in ${roomCalled(asked, false)}:\n  ${link}`,
						),
					);
				})
				.catch((error) =>
					store.deliverActive(
						store.sysItem(`Could not link ${roomCalled(asked, false)}: ${reason(error)}`),
					)
				);
			return true;
		}
		const conv = store.activeConv();
		const session = conv === null ? null : convSession(conv.key);
		if (conv?.type !== "room" || session === null) return false;
		void mintRoomLink(session, conv.key)
			.then((link) =>
				store.deliver(
					conv.key,
					store.sysItem(
						`Anybody who holds this link can be in ${roomCalled(conv.id, conv.held)}:\n  ${link}`,
					),
				)
			)
			.catch((error) => store.deliver(conv.key, store.sysItem(`Could not link this room: ${reason(error)}`)));
		return true;
	},
	standingHere() {
		const conv = store.activeConv();
		return conv?.type === "room" ? store.standingFor(conv.key) : "";
	},
	granted() {
		const conv = store.activeConv();
		return conv?.type === "room" ? conv.grants : NO_GRANTS;
	},
	liveRooms() {
		return liveRoomCounts(store.actingDir()?.liveRooms ?? new Map());
	},
	roster() {
		const conv = store.activeConv();
		if (conv?.type !== "room") return [];
		const reachable = store.actingDir()?.dmablePeers ?? new Set<string>();
		return [...conv.members].map(([name, standing]) => ({
			name,
			online: standing.online,
			away: standing.away,
			reachable: reachable.has(name.toLowerCase()),
		}));
	},
	directories() {
		const state = store.get();
		const rooms = (dir: DirId) =>
			[...state.convs.values()].flatMap((conv) =>
				conv.type === "room" && conv.dir === dir ? [roomCalled(conv.id, conv.held)] : []
			);
		return [...state.dirs.values()].map((dir) => ({
			// The route, not the authority the map is keyed by: routing hints are
			// part of what makes an address dialable, and an address a reader
			// cannot dial is not the answer they asked for.
			locator: dirAddress(dir.id),
			name: directoryName(dir.id, state.homeDir),
			nick: dir.nick,
			standing: store.standingOn(dir.id, state),
			rooms: liveRoomCounts(dir.liveRooms),
			joined: rooms(dir.id),
			connected: dir.session === "connected",
		}));
	},
	quitDirectory() {
		const dir = store.activeConv()?.dir ?? store.actingDir()?.id ?? null;
		if (dir === null) {
			store.deliverActive(store.sysItem("There is no directory to give back."));
			return;
		}
		leaveDirectory(dir);
	},
	aboutConversation() {
		store.showAboutConv();
	},
};

/** Send whatever is in the composer to whatever is on screen. */
export function send(): void {
	const draft = store.activeDraft();
	const text = draft.text;
	const files = [...draft.files];
	const conv = store.activeConv();
	// An empty composer sends nothing — unless it is changing a file line, where
	// empty is a real instruction: every file removed and no caption left takes
	// the line down. `keeping` is what tells the two apart.
	if ((text.trim() === "" && files.length === 0 && draft.keeping === undefined) || !conv) return;
	if (!isConnected()) {
		store.deliverActive(store.sysItem("Not connected, your message was not sent"));
		return;
	}
	// Measured against what this room will carry, which may be less than this app
	// allows — a bridged room has to fit its lines into somebody else's protocol.
	// In bytes, because that is what the limit on the other side counts.
	const cap = lineRoom(conv, MAX_LINE);
	if (lineCost(text) > cap) {
		store.deliverActive(store.sysItem(tooLong("Message", cap)));
		return;
	}
	// Changing a line the reader pressed the pencil on. Taken before the command
	// reading below, because these words are the message being rewritten rather
	// than an instruction: somebody fixing a line that began with a slash is
	// still fixing a line.
	if (draft.changing !== undefined) {
		// Changing a file line's files rather than a plain line's words: the same
		// pencil, one level up. The refile paints its new set and clears the
		// composer at once, the way an ordinary send does; its own failures speak
		// on the file rows and put the line back.
		if (draft.keeping !== undefined && (conv.type === "room" || conv.type === "dm")) {
			void refileActive(conv, draft.changing, text, draft.keeping, files);
			store.rememberLastSent(conv.key, text);
			store.cancelChange();
			return;
		}
		// Emptied only once the change is on its way. A refusal here keeps the
		// reader's words and the line they belong to, so the composer is still
		// where they left it rather than blank with an explanation above it.
		if (editLine(conv.key, draft.changing, text)) {
			store.rememberLastSent(conv.key, text);
			store.cancelChange();
		}
		return;
	}
	const prepared = prepareComposerSend(conv, draft, POWERS);
	if (prepared.kind === "nothing") return;
	if (prepared.kind === "refused") {
		store.deliverActive(store.sysItem(prepared.why));
		return;
	}
	if (prepared.kind === "handled") {
		store.rememberLastSent(conv.key, prepared.original);
		store.setDraft("");
		store.clearDraftFiles();
		return;
	}
	// A room echoes every post back to every member, which is what confirms our
	// own line. A direct message has no echo, so it is confirmed by the send
	// settling instead.
	if (prepared.files.length > 0) {
		sendFiles(conv, [...prepared.files], prepared.text);
	} else if (conv.type === "room") sayLine(conv, prepared.text);
	else dmSay(conv, prepared.text);
	store.rememberLastSent(conv.key, prepared.original);
	store.setDraft("");
	store.clearDraftFiles();
}

/** Put the join card up as the answer to one act.
 *
 * The reader is asking to reach somewhere this tab is not, and the card is the
 * question that gets them there. What it offers comes from the act and nothing
 * else, so the same card is a gate on a link, a blank form from the rail's
 * "elsewhere", or a directory already in hand with only its room left to name,
 * without any of those three having to know what the others left behind.
 *
 * Nothing is left and nothing is closed: the card is the conversation column
 * standing empty, and every room and direct line is still there behind it. That
 * is what makes this the step up from the rail's own field rather than a way
 * out of where you are. */
export function reachFor(act: Reach): void {
	// The card is all that opens. On a phone a press steps back from the list
	// screen to the conversation column the card fills; on a wide layout the
	// rail is a column beside it and closing it would take the rooms away at the
	// moment the reader most wants to see which ones they have.
	store.showJoinFor({ ...act, locator: act.locator && actLocator(act.locator) });
}

/** Say what is known about one directory.
 *
 * Every directory this tab holds opens the same card: locator, connection, the
 * name it granted, and Leave. Settings is about this page — its locators, its
 * appearance, inspect — and a button there opens that card for the directory
 * that served the page, rather than answering the same three questions twice.
 *
 * Null closes the card. */
export function aboutDirectory(dir: DirId | null): void {
	store.showAboutDir(dir);
}

/** Turn desktop notifications on or off, asking the browser the first time.
 * Returns a reason the reader should see when it cannot turn on, or null. */
export async function toggleNotify(): Promise<string | null> {
	const { notifyOn } = store.get();
	if (notifyOn) {
		store.setNotify(false);
		return null;
	}
	if (!("Notification" in globalThis)) {
		return "This browser can't show desktop notifications";
	}
	let permitted = Notification.permission;
	if (permitted === "default") permitted = await Notification.requestPermission();
	if (permitted !== "granted") {
		return "Notifications are blocked in your browser settings";
	}
	store.setNotify(true);
	return null;
}

export function joinRoom(
	destination: RoomDestination,
	nick: string,
	signal?: AbortSignal,
): Promise<string> {
	if (signal?.aborted) {
		abandonJoin();
		return Promise.resolve("");
	}
	// A directory this join opened, so stopping it can drop the row rather than
	// leave a connecting server the reader never seated. Captured here because
	// the × has to unstick the card without waiting for the dial, and the dial
	// still has to see the same stop so it does not commit afterwards.
	let fresh: DirId | null = null;
	const work = (async (): Promise<string> => {
		try {
			const room = destination.room;
			// A `/link` sturdyref is not a directory address: `parsePeer` rejects
			// the swissnum path, and entering by name would not find a private
			// room. Redeem it as the room link it is, from either join field.
			const linked = typedRoomLink(destination.locator, room);
			if (linked !== null) {
				if (signal?.aborted) return "";
				store.setStatus("taking up the room link…");
				return await takeRoomLink(linked.link, linked.label, nick);
			}
			let locator: string;
			try {
				locator = await requestedLocator(destination.locator);
			} catch (err) {
				return reason(err);
			}
			if (signal?.aborted) return "";
			// Changing directories is changing peers, not changing a field on the live
			// room capability. Stage the intent, close the old directory session, and let
			// the ordinary reconnect spine establish the selected peer before it replays
			// the join. This path is only exposed on the join card, after leaving a room,
			// so no live membership is sacrificed to probe an address.
			// A room somewhere else is a directory this tab does not hold a live
			// session on yet, so open it beside the ones it does. A store row is not
			// that: stopping a join forgets the row while the outstanding dial is
			// still finishing, and treating the row as "already opened" made the next
			// Join skip the dial and fail at once. Opening takes nothing away. The
			// rooms already entered keep delivering while this one is being reached,
			// and an address that turns out to be wrong costs a failed dial rather
			// than a membership.
			const wanted = directoryId(locator);
			if (wanted === null) return notALocator(locator);
			if (locator !== "" && dirSession(wanted) === null) {
				fresh = wanted;
				// Said by the name the rail would give it, never the raw locator:
				// forty characters of designator are an address, not a sentence.
				store.setStatus("reaching " + directoryName(wanted, store.get().homeDir) + "…");
				// Stop owns only a directory this Join introduced. Existing room intent
				// still needs its directory reconstructed after this form is canceled.
				const openingSignal = store.joinedRooms(wanted).length === 0 ? signal : undefined;
				const opened = await openDirectory(locator, FIRST_BACKOFF_MS, openingSignal);
				if (signal?.aborted) return "";
				if (opened !== "") return opened;
			}
			if (!isConnected()) {
				// One join is staged at a time, so anything still waiting is superseded by
				// this one and is let go rather than left pending on a card that has moved
				// on.
				store.setStatus("reaching the room directory…");
				return stageJoin(room, nick, destination.hidden === true, signal);
			}
			const entering = directoryId(locator);
			if (entering === null) return notALocator(locator);
			if (signal?.aborted) return "";
			store.setDirStatus(entering, "entering #" + room + "…");
			if (destination.hidden === true) return openPrivateRoom(entering, room, nick, signal);
			return enterRoom(entering, room, nick, { requested: nick, select: true, signal });
		} catch (err) {
			if (signal?.aborted) return "";
			return reason(err);
		}
	})();
	if (signal == null) return work;
	const stopped = new Promise<string>((resolve) => {
		const stop = () => {
			abandonJoin();
			if (fresh !== null && store.joinedRooms(fresh).length === 0) {
				leaveDirectory(fresh);
			}
			resolve("");
		};
		if (signal.aborted) stop();
		else signal.addEventListener("abort", stop, { once: true });
	});
	return Promise.race([work, stopped]);
}
