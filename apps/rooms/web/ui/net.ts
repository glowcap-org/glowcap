// The rooms page's data layer, as a real OCapN peer in the browser. The page
// instantiates the glowcap runtime over `@glowcap/web` (the wasm Host, no dlopen),
// dials the room server through serve.ts's `/relay` byte pipe, and drives the
// directory and room as capabilities — the same `lib/room/client.ts` the
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
// element. That is also why the peer survives anything React does: directory
// sessions belong to the `RoomsPage` the entry module constructed, so a
// remount, a StrictMode double-pass, or an error boundary catching a render
// never disturbs a live conversation.

import * as store from "./store.ts";
import { planJoinDestination, privateRoomNameRefusal } from "./joining.ts";
import { type DirId, isSessionConv, type MemberRef, type RoomDestination } from "./types.ts";
import type { Reach } from "./intent.ts";
import { directoryName } from "./text.ts";
import { composerLineRefusal } from "./composer/send.ts";
import { COMPOSER_NOT_CONNECTED, finishComposerSend, interpretComposerSend } from "./composer/commit.ts";
import { reason } from "./net/common.ts";
import { commandPowers } from "./net/command_powers.ts";
import { dmSay } from "./net/direct.ts";
import { dirSession, isConnected } from "./net/live.ts";
import type { RoomsPageContext } from "./page.ts";

// The page reaches this layer through one namespace, so what moved into a
// module of its own is named here as well. The split is where the code lives,
// not a change to what the interface may ask for.
export { openAttachment, stepViewer } from "./net/files.ts";
export { startDm } from "./net/direct.ts";
export { retrySend, selfLocator } from "./net/reachable.ts";
export { connect, leaveDirectory, openDirectory } from "./net/connection.ts";
export { bootRuntime } from "./net/runtime_boot.ts";
export { releaseDirectoryNick } from "./net/directory_identity.ts";
export { installOpsInvalidation, readOpsBundle, refreshOpsCap, replaceOpsBundle } from "./net/ops.ts";
export { addBridgeLease, closeBridgeConnection, openBridgeConnection, removeBridgeLease } from "./net/irc.ts";
export { askRoomBridgeForm, submitBridgeForm } from "./net/bridge_form.ts";
export { requestListenerDown, requestListenerUp } from "./net/listeners.ts";
export {
	loadMoreOperator,
	refreshOperator,
	requestNickRevoke,
	requestOperatorReferenceRelease,
	requestOperatorReset,
	requestOperatorRoomRemove,
	requestOperatorTroubleClear,
	requestRoomAuthorityRevoke,
	requestRoomLinkRevoke,
	requestRoomManager,
	requestSessionDisconnect,
	requestStewardGive,
	requestStewardRevoke,
	retireMatchingOperator,
} from "./net/operator.ts";
export { ensureVizPublisher } from "./net/viz.ts";
export { dropArchiveShare, readArchiveShare } from "./net/archive_shares.ts";
export { offerDurableArchive, shareArchiveHistory } from "./net/archive_share_send.ts";
export { publishPeeredRoom, revokePeeredPublication } from "./net/peering.ts";
export {
	askMemberOut,
	askMemberOutSettled,
	dropRoomManager,
	dropStewardship,
	recoverRoomManager,
	revokeManagedRoomAuthority,
	setManagedRoomPolicy,
	steward,
	takeRoomManager,
	takeStewardship,
	unregisterManagedRoom,
} from "./net/stewardship.ts";
import { leaveDirectory, openDirectory } from "./net/connection.ts";
export { setDirStanding, setRoomStanding, setStanding } from "./net/standing.ts";
export { directoryId, directoryLocator } from "./net/bootstrap.ts";
export { FIRST_BACKOFF_MS } from "./net/bootstrap.ts";
export { reserveSelectionForAddress } from "./net/bootstrap.ts";
export { dirAddress } from "./net/live.ts";
export { acceptInvite, declineInvite } from "./net/invites.ts";
export { closeDm, endConversation, leaveRoom, openManagedRoom, pickRoom, showRoom } from "./net/rooms.ts";
export { createRoomLink } from "./net/room_links.ts";
export { retryRoom } from "./net/room_reentry.ts";
import { takeRoomLink } from "./net/invites.ts";
import { abandonJoin, enterRoom, openManagedRoom, stageJoin } from "./net/rooms.ts";
import { actLocator, directoryId, FIRST_BACKOFF_MS, notALocator, requestedLocator } from "./net/bootstrap.ts";
import {
	addFiles,
	editLine,
	mention,
	recallLastSent,
	refileActive,
	sayLine,
	sendFiles,
	setDraft,
	setTyping,
	stopSend,
	withdraw,
} from "./net/send.ts";
export { addFiles, mention, recallLastSent, setDraft, setTyping, stopSend, withdraw };

/** Send whatever is in the composer for the conversation that was composed.
 * A command may already have put that conversation away; emptying the
 * composer still names it, not whoever came forward. */
export function send(page: RoomsPageContext): void {
	const projection = page.projection;
	const draft = store.activeDraft(projection);
	const text = draft.text;
	const files = [...draft.files];
	const conv = store.activeConv(projection);
	// An empty composer sends nothing — unless it is changing a file line, where
	// empty is a real instruction: every file removed and no caption left takes
	// the line down. `keeping` is what tells the two apart.
	if ((text.trim() === "" && files.length === 0 && draft.keeping == null) || conv == null) return;
	// Changing a line the reader pressed the pencil on. Taken before the command
	// reading below, because these words are the message being rewritten rather
	// than an instruction: somebody fixing a line that began with a slash is
	// still fixing a line.
	if (draft.changing != null) {
		if (!isSessionConv(conv)) return;
		if (!isConnected(page)) {
			store.deliverActive(projection, store.sysItem(projection, COMPOSER_NOT_CONNECTED));
			return;
		}
		const refusal = composerLineRefusal(conv, text);
		if (refusal != null) {
			store.deliverActive(projection, store.sysItem(projection, refusal));
			return;
		}
		// Changing a file line's files rather than a plain line's words: the same
		// pencil, one level up. The refile paints its new set and clears the
		// composer at once, the way an ordinary send does; its own failures speak
		// on the file rows and put the line back.
		if (draft.keeping != null) {
			void refileActive(page, conv, draft.changing, text, draft.keeping, files);
			store.rememberLastSent(projection, conv.key, text);
			store.cancelChange(projection);
			return;
		}
		// Emptied only once the change is on its way. A refusal here keeps the
		// reader's words and the line they belong to, so the composer is still
		// where they left it rather than blank with an explanation above it.
		if (editLine(page, conv.key, draft.changing, text)) {
			store.rememberLastSent(projection, conv.key, text);
			store.cancelChange(projection);
		}
		return;
	}
	const prepared = interpretComposerSend(projection, conv, draft, commandPowers(page));
	if (prepared == null) return;
	if (prepared.kind === "handled") {
		finishComposerSend(projection, conv.key, prepared.original);
		return;
	}
	// A directory never reaches here: `prepareComposerSend` refuses chat.
	if (!isSessionConv(conv)) return;
	// Chat still needs the wire. A tab command already ran above.
	if (!isConnected(page)) {
		store.deliverActive(projection, store.sysItem(projection, COMPOSER_NOT_CONNECTED));
		return;
	}
	// A room echoes every post back to every member, which is what confirms our
	// own line. A direct message has no echo, so it is confirmed by the send
	// settling instead.
	if (prepared.files.length > 0) {
		sendFiles(page, conv, [...prepared.files], prepared.text);
	} else if (conv.type === "room") sayLine(page, conv, prepared.text);
	else dmSay(page, conv, prepared.text);
	finishComposerSend(projection, conv.key, prepared.original);
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
export function reachFor(page: RoomsPageContext, act: Reach): void {
	// The card is all that opens. On a phone a press steps back from the list
	// screen to the conversation column the card fills; on a wide layout the
	// rail is a column beside it and closing it would take the rooms away at the
	// moment the reader most wants to see which ones they have.
	store.showJoinFor(page.projection, { ...act, locator: act.locator && actLocator(page, act.locator) });
}

/** Say what is known about one directory.
 *
 * Every directory this tab holds opens the same card: locator, connection, the
 * name it granted, and Leave. The title chip of that directory's conversation
 * is what opens it. The title's close mark opens it already asking to leave.
 * Null closes the card. */
export function aboutDirectory(page: RoomsPageContext, dir: DirId | null, askingLeave = false): void {
	store.showAboutDir(page.projection, dir, askingLeave);
}

/** Show a held directory as this tab's conversation.
 *
 * Pressing a directory on the rail, a conversation, or Settings lands here.
 * The directory card stays on the title chip, the way a room's card stays on
 * its title. A directory this tab does not hold is a no-op. */
export function showDirectory(page: RoomsPageContext, dir: DirId): void {
	const projection = page.projection;
	if (!projection.get().dirs.has(dir)) return;
	const conv = store.ensureDirectory(projection, dir);
	store.switchTo(projection, conv.key);
	store.showAboutDir(projection, null);
	store.closeAboutConv(projection);
	store.showAboutMember(projection, null);
	store.closeSettings(projection);
}

/** Say what is known about one person.
 *
 * A roster row, the reader's own seat at the foot of the rail, and a message's
 * author all name somebody, and all three open this one card rather than each
 * growing its own answer. Null closes it. */
export function aboutMember(page: RoomsPageContext, about: MemberRef | null): void {
	store.showAboutMember(page.projection, about);
}

/** Turn desktop notifications on or off, asking the browser the first time.
 * Returns a reason the reader should see when it cannot turn on, or null. */
export async function toggleNotify(page: RoomsPageContext): Promise<string | null> {
	const { notifyOn } = page.projection.get();
	if (notifyOn) {
		store.setNotify(page.projection, false);
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
	store.setNotify(page.projection, true);
	return null;
}

export function joinRoom(
	page: RoomsPageContext,
	destination: RoomDestination,
	nick: string,
	signal?: AbortSignal,
): Promise<string> {
	const projection = page.projection;
	if (signal?.aborted) {
		abandonJoin(page);
		return Promise.resolve("");
	}
	// A directory this join opened, so stopping it can drop the row rather than
	// leave a connecting server the reader never seated. Captured here because
	// the × has to unstick the card without waiting for the dial, and the dial
	// still has to see the same stop so it does not commit afterwards.
	let fresh: DirId | null = null;
	const work = (async (): Promise<string> => {
		try {
			const planned = planJoinDestination(destination);
			// A `/link` sturdyref is not a directory address: `parsePeer` rejects
			// the swissnum path, and entering by name would not find a private
			// room. Redeem it as the room link it is, from either join field.
			if (planned.kind === "room-link") {
				if (signal?.aborted) return "";
				store.setStatus(projection, "taking up the room entry link…");
				return await takeRoomLink(page, planned, nick);
			}
			const room = planned.room;
			let locator: string;
			try {
				locator = await requestedLocator(page, planned.locator);
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
			if (locator !== "" && dirSession(page, wanted) === null) {
				fresh = wanted;
				// Said by the name the rail would give it, never the raw locator:
				// forty characters of designator are an address, not a sentence.
				store.setStatus(
					projection,
					"reaching " + directoryName(wanted, projection.get().homeDir) + "…",
				);
				// Stop owns only a directory this Join introduced. Existing room intent
				// still needs its directory reconstructed after this form is canceled.
				const openingSignal = store.joinedRooms(projection, wanted).length === 0 ? signal : undefined;
				const opened = await openDirectory(page, locator, FIRST_BACKOFF_MS, openingSignal);
				if (signal?.aborted) return "";
				if (opened !== "") return opened;
			}
			if (!isConnected(page)) {
				// One join is staged at a time, so anything still waiting is superseded by
				// this one and is let go rather than left pending on a card that has moved
				// on.
				store.setStatus(projection, "reaching the room directory…");
				return stageJoin(page, room, nick, planned.policy, signal);
			}
			const entering = directoryId(locator);
			if (entering === null) return notALocator(locator);
			if (signal?.aborted) return "";
			store.setDirStatus(projection, entering, "entering #" + room + "…");
			if (planned.policy.visibility === "secret") {
				const refusal = privateRoomNameRefusal(
					room,
					[...(projection.get().dirs.get(entering)?.liveRooms.values() ?? [])].map((entry) => entry.name),
				);
				if (refusal != null) return refusal;
				return openManagedRoom(page, entering, room, planned.policy, nick, signal);
			}
			if (planned.policy.speaking === "moderated") {
				return openManagedRoom(page, entering, room, planned.policy, nick, signal);
			}
			return enterRoom(page, entering, room, nick, { requested: nick, select: true, signal });
		} catch (err) {
			if (signal?.aborted) return "";
			return reason(err);
		}
	})();
	if (signal == null) return work;
	const stopped = new Promise<string>((resolve) => {
		const stop = () => {
			abandonJoin(page);
			if (fresh !== null && store.joinedRooms(projection, fresh).length === 0) {
				leaveDirectory(page, fresh);
			}
			resolve("");
		};
		if (signal.aborted) stop();
		else signal.addEventListener("abort", stop, { once: true });
	});
	return Promise.race([work, stopped]);
}
