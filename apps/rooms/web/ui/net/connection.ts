// Holding a directory: opening one, losing one, and coming back.
//
// A directory session is the one thing here that is expected to die. The room
// server restarts, a laptop sleeps, a relay drops the socket — so every path
// below is written for a session that ends without warning, and the question it
// keeps asking is what belongs to the connection and what belongs to the page.
// Conversations, history, and this tab's own reachability are the page's and
// stay; the rooms entered on a session, the lines redeemed over it, and the
// references governing what was said there go with it.
//
// Coming back is per directory rather than per tab, because one server being
// down says nothing about another: each backs off on its own schedule while the
// rest carry on.

import * as store from "../store.ts";
import { iceServers } from "./ice.ts";
import { Directory } from "../../../lib/room/client.ts";
import { dialDirectory } from "../../../lib/locator.ts";
import { directoryLivePhase, type DirId, dirId } from "../types.ts";
import { markSend, reason, trouble } from "./common.ts";
import { isCurrent, type Live } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";
import {
	announceDirectoryReady,
	BACKOFF_CEILING_MS,
	BACKOFF_STABLE_MS,
	directoryId,
	FIRST_BACKOFF_MS,
	heldHomeLocator,
	homeLocator,
	notALocator,
	noteHomeDirectoryLocator,
} from "./bootstrap.ts";
import { bootRuntime } from "./runtime_boot.ts";
import { dropInspect, takeDiagnosticCap } from "./diagnostics.ts";
import { dropListeners, takeListenersCap } from "./listeners.ts";
import { dropOperatorHold, takeOperatorCap } from "./operator.ts";
import { dropPeering, takePeeringCap } from "./peering.ts";
import { forgetOpsSwiss, rememberedOpsSwiss } from "./ops_memory.ts";
import { commitAttachmentUpdates, releaseFiles, releaseLines } from "./files.ts";
import { dropDirectRoute, releaseBackChannel } from "./direct.ts";
import { releaseHandedRoomsForDirectory } from "./direct_offers.ts";
import { ADVERTISE_RETRY_LIMIT, ensureInbox, ensureOfferer, forgetOfferer, offerInboxFor } from "./reachable.ts";
import { closeDm, enterRoom, leaveRoom, openManagedRoom, settleStaged, takeStaged } from "./rooms.ts";
import { dropIrcHold, takeIrcGatewayCap } from "./irc.ts";
import { dropArchiveLineCoordinates, releaseArchivedFiles } from "./history.ts";
import { tabArchiveRef } from "../archive.ts";
import { releaseArchiveSharesForDirectory } from "./archive_shares.ts";
import { reenterRooms, roomReconnectLocator } from "./room_reentry.ts";
import { type DirectoryConnectionAttempt } from "./directory_connection_lifecycle.ts";

// ── Connection ────────────────────────────────────────────────────────────
/** What a reader is told when an attempt to reach the room directory did not get
 * there. Two surfaces say it — the join card, which was waiting on a join, and
 * the status line, which is waiting on nothing — and they say the same thing
 * because it is one fact. */
const UNREACHABLE = "could not reach the room directory. Retrying…";

/** Open the directory this page came from. The one directory a tab starts with;
 * every other one is added deliberately. */
export function connect(page: RoomsPageContext): void {
	const projection = page.projection;
	// Lines leave this tab three ways: the log passing its far end, a reader
	// emptying a conversation, and a conversation being forgotten. What they
	// were holding is held here: a picture's object URL, the capability its
	// bytes come from, and the reference that governed one of our own. The
	// store knows when a line stops being drawn and nothing about what it
	// carried; this side knows the opposite, so all three arrive here.
	projection.onLinesDropped((key, gone) => {
		dropArchiveLineCoordinates(page, key, gone);
		// Unconditionally: what the archive holds for these lines is on this
		// device, so a conversation with no session to speak of still has rows to
		// hand back, and holding them on is what keeps a swapped-out archive
		// target from retiring.
		releaseArchivedFiles(
			page,
			key,
			gone.flatMap((item) => item.kind === "chat" ? (item.attachments ?? []).map((file) => file.id) : []),
		);
		const session = page.live.convSession(key);
		if (session !== null) releaseLines(session, key, gone);
	});
	void openDirectory(page, null, FIRST_BACKOFF_MS);
}

/** Hold one directory: open a session to `locator`, register there, and keep it
 * beside every other directory this tab holds.
 *
 * Opening takes nothing away. A directory already held is answered without
 * dialling a second time, so asking for one twice is not a way to lose the
 * rooms on it.
 *
 * `locator` of null means the directory that served this page. One open runs at
 * a time per directory. A later request waits for the earlier one to settle,
 * but a Leave in between invalidates both rather than seating a directory the
 * reader already gave back. */
export async function openDirectory(
	page: RoomsPageContext,
	locator: string | null,
	backoff: number,
	signal?: AbortSignal,
): Promise<string> {
	if (signal?.aborted) return "";
	const target = locator ?? await homeLocator(page);
	const id = directoryId(target);
	if (id == null) return notALocator(target);
	if (page.live.dirs.has(id)) return "";
	return await page.connections.open(
		id,
		page.live.dirs.size,
		signal,
		() => page.live.dirs.has(id),
		(attempt) => openDirectoryAttempt(page, locator, backoff, attempt, signal),
	);
}

async function openDirectoryAttempt(
	page: RoomsPageContext,
	locator: string | null,
	backoff: number,
	attempt: DirectoryConnectionAttempt,
	signal?: AbortSignal,
	retainedId?: DirId,
): Promise<string> {
	const projection = page.projection;
	if (attempt.stale()) return "";
	try {
		// Instantiate the wasm peer once; its adapter injection lets the runtime's
		// `connect` (which `Directory.connect` rides) dial over the relay. Cache
		// only a *resolved* init: `/glowcap_host.wasm` answers 503 until the
		// module is built, so a first attempt can lose that race — a rejected
		// promise left cached would make every reconnect re-await the same failure
		// forever instead of retrying once the asset is live.
		const runtime = await bootRuntime(page);
		// The inbox host both dials the directory and accepts cold-dials, so start
		// it before the dial: the directory session must be present in the same
		// host's live-session directory when a later cold-dial withdraws from that
		// session's gift table.
		ensureInbox(page, runtime, iceServers);
		const target = locator ?? await homeLocator(page);
		if (attempt.stale()) return "";
		const addressed = directoryId(target);
		if (addressed === null) return notALocator(target);
		// A durable room link may give a reconnect a stronger, multi-location
		// route than the concrete address that first opened this directory. The
		// page's directory identity stays where its conversations are filed; the
		// link is authority for changing only the route used to reach it.
		const id = retainedId ?? addressed;
		const stale = attempt.stale;
		const held = page.live.dirs.get(id);
		if (held !== undefined) return "";
		if (stale()) return "";
		page.live.directoryLocators.set(id, target);
		// The one open with no locator of its own is the page's own server, and it
		// is the only one that can say so. Written once: leaving this directory
		// gives the session back, not the knowledge of which server served the page.
		if (locator === null) store.setHomeDir(projection, id);
		if (stale()) return "";
		const wasReconnect = store.dirReached(projection, id);
		store.openDir(projection, id, target);
		store.patchDir(projection, id, directoryLivePhase(wasReconnect, false, undefined));
		if (stale()) {
			dropAbortedDirectory(page, id, locator, undefined, attempt.left());
			return "";
		}
		// Dial transport-neutrally, the same as every terminal client: the rooms
		// Physical addresses dial directly; an identity route fetches the named
		// directory through the Host's Node-owned route scheduler. The injected
		// browser adapter realizes each concrete transport over the relay. The
		// runtime's default `connect` would reject both a bare designator and `id`.
		const next = await Directory.connect(target, (address) => dialDirectory(address, runtime));
		if (stale()) {
			dropAbortedDirectory(page, id, locator, next, attempt.left());
			return "";
		}
		// Everything this session will hold, minted with it. Nothing below adds a
		// field to module scope, so nothing below can outlive the session by
		// being forgotten at the other end.
		const session: Live = {
			page,
			id,
			dir: next,
			archive: tabArchiveRef(page, next.session),
			home: projection.get().homeDir === id,
			locator: target,
			// The attempt's own backoff, so the stability window below has its
			// documented job: seeded with the constant instead, a server that
			// accepted and then dropped was redialled at the floor forever, and
			// the window reset a value that never climbed.
			backoff,
			rooms: new Map(),
			stewardshipPending: new Map(),
			standingTold: new Map(),
			posted: new Map(),
			echoes: [],
			refiling: new Map(),
			directRoutes: new Map(),
			advertised: null,
			advertiseRetries: ADVERTISE_RETRY_LIMIT,
			registered: false,
			deferredOffers: new Map(),
			stable: null,
			signaling: null,
			files: new Map(),
			objectUrls: new Map(),
			progress: { pending: new Map(), frame: null },
			outgoing: new Map(),
		};
		page.live.dirs.set(id, session);
		const seen = await next.watch((event) => {
			if (!isCurrent(session)) return;
			switch (event.kind) {
				case "truncated":
					store.noteTrouble(
						projection,
						`directory ${id}`,
						`${event.count} additional live rooms are outside this directory snapshot.`,
					);
					break;
				case "closed":
					store.dropLiveRoom(projection, id, event.entry);
					break;
				case "registered":
					if (!store.setDmable(projection, id, event.name, event.registrationId, true)) {
						store.noteTrouble(
							projection,
							`directory ${id}`,
							"Additional direct-message registrations are outside this directory view.",
						);
						break;
					}
					// Offer a member who arrives after us an inbox straight away, so their
					// first message costs no extra round trip. One already on the roster
					// before we had a name is covered by the directory asking on demand.
					offerInboxFor(session, event.name, event.registrationId);
					break;
				case "unregistered":
					store.setDmable(projection, id, event.name, event.registrationId, false);
					// The member left, so the room has their name back and may grant
					// it to someone else. Close what we have with them and hand the
					// lines back; a later introduction under the same name opens a
					// new conversation, because it may well be a new person.
					// Their reply route goes with them: it reached that connection,
					// and the next holder of the name is not on it.
					for (const key of store.closeDmsWith(projection, id, event.name, event.registrationId)) {
						dropDirectRoute(session, event.registrationId);
						releaseBackChannel(page, key);
					}
					// The next holder of this name is a different person and gets an
					// inbox of their own. An offer still queued for them is dropped
					// rather than spending a permanent name on someone who has left.
					session.deferredOffers.delete(event.registrationId);
					ensureOfferer(page, session.id).forget(event.registrationId);
					break;
				default:
					store.setLiveRoom(projection, id, event.entry);
					break;
			}
		});
		if (stale()) {
			dropAbortedDirectory(page, id, locator, next, attempt.left());
			return "";
		}
		store.resetLiveRooms(projection, id, seen);
		announceDirectoryReady(page);
		store.markDirReached(projection, id);
		store.setDirSession(projection, id, "connected");
		// A remembered operations swiss auto-redeems on the home session coming
		// up, so a refresh does not demand re-entry; possession stays derived
		// from the same take path a paste uses. A failed redeem erases the
		// memory — a dead secret must not linger or retry forever.
		if (id === projection.get().homeDir) void redeemRememberedOps(page, id);

		// Whether this directory has answered before is a durable fact the store
		// already owns; a copy on the session was constant-false (its constructor
		// runs only when no prior session exists), so this line was unreachable
		// and no reader was ever told the room came back.
		if (wasReconnect && store.joinedRooms(projection, id).length > 0) {
			store.deliverActive(projection, store.sysItem(projection, "Reconnected"));
		}

		// A dropped directory session (the server respawning) reconnects the page.
		next.session.serve()
			.catch((err) => trouble(projection, "the directory session ended", err))
			.finally(() => endSession(session));
		// Reset the backoff only once this session has *survived* a stability
		// window, not the instant the handshake reached `watch`. A server that
		// accepts, answers `watch`, then drops immediately (a post-accept crash
		// loop) would otherwise re-earn the reset every cycle and reconnect every
		// 500 ms — a storm, not a backoff. Cleared in `releaseSession` if the
		// session dies before the window elapses, because the timer belongs to it.
		session.stable = setTimeout(() => {
			session.backoff = FIRST_BACKOFF_MS;
			session.stable = null;
		}, BACKOFF_STABLE_MS);

		// Re-enter every room we were in before honoring a staged first join. The
		// re-entry owner distinguishes listed names, durable links, and handed
		// references that died with the old session.
		const reentering = reenterRooms(page, id);
		if (!reentering && stale()) {
			dropAbortedDirectory(page, id, locator, next, attempt.left());
			return "";
		} else if (!reentering) {
			const wanted = takeStaged(page);
			if (wanted !== null) {
				store.setDirStatus(projection, id, "entering #" + wanted.room + "…");
				settleStaged(
					page,
					wanted.policy.visibility === "secret" || wanted.policy.speaking === "moderated"
						? await openManagedRoom(page, id, wanted.room, wanted.policy, wanted.nick, signal)
						: await enterRoom(page, id, wanted.room, wanted.nick, {
							requested: wanted.nick,
							select: true,
							signal,
						}),
				);
			} else store.setDirStatus(projection, id, "");
		}
		return "";
	} catch (err) {
		// The cause rides the retry line the reader sees: a blocked ws (an http
		// page over https, say) or a wasm load failure is otherwise invisible,
		// and "retrying" alone gives them nothing to correct. The console keeps
		// the full object for whoever is debugging with a stack in hand.
		trouble(projection, "could not open the peer session", err);
		const unreachable = `${UNREACHABLE} (${reason(err)})`;
		if (signal?.aborted) {
			if (locator !== null) {
				const id = retainedId ?? directoryId(locator);
				if (id !== null) dropAbortedDirectory(page, id, locator, undefined, attempt.left());
			}
			return "";
		}
		const failedLocator = locator ?? heldHomeLocator(page) ?? "";
		const failed = retainedId ??
			(failedLocator === "" ? dirId("") : directoryId(failedLocator) ?? dirId(""));
		if (attempt.left()) {
			dropAbortedDirectory(page, failed, locator, undefined, true);
			return "";
		}
		// A staged join is not lost on a failed attempt: the retry below opens
		// another session, which replays it. The card is told so it can offer the
		// button back, in case the reader would rather change their mind.
		settleStaged(page, unreachable);
		// The attempt is over and it failed. Left on connecting or reconnecting,
		// the foot would go on claiming an attempt that is no longer running, and
		// the opening screen would go on waiting for an answer that has already
		// come back. The next open derives the same four words the rest of the
		// page uses.
		//
		// Open the row before reporting on it. Everything above this line can
		// throw before the server was ever recorded — the wasm module answers 503
		// until it is built, and a page loaded offline never learns its own
		// locator — and a report about a server the store has never heard of is
		// dropped on the floor. That silence is the whole failure: the opening
		// screen waits for *some* server to have answered either way, so a first
		// attempt that failed this early left the page on "Opening a peer in your
		// browser…" for good, retrying behind a screen that never lifted.
		// An unparseable locator has no identity to file the failure under, so it
		// stands in as the empty one: the report still reaches the status line and
		// the join card, and no row is opened for an address that cannot exist.
		// The server this page came from is retried for as long as this tab
		// still holds it: there is no address to correct, so giving up while
		// holding it would leave a reader with a dead page and nothing to do
		// about it. Leaving it is how they give up; a retry after that would
		// seat a directory they already gave back.
		const home = retainedId !== undefined
			? retainedId === projection.get().homeDir
			: locator === null || failedLocator === (heldHomeLocator(page) ?? "");
		// A server somebody typed and that has never once answered is most likely a
		// typo, and retrying a typo forever is how one mistyped locator became a
		// permanent row dialling every few seconds for the life of the tab with no
		// way to remove it. Let it go instead; the address is still in the card's
		// field, so correcting it is an edit rather than a retype.
		if (!home && !store.dirReached(projection, failed)) {
			store.forgetDir(projection, failed);
			page.live.directoryLocators.delete(failed);
			page.connections.forget(failed);
			// The line that announced this attempt has to stop announcing it. It was
			// written before the dial and belongs to whichever server the reader is
			// on, so leaving it saying "reaching …" reports an attempt that ended,
			// on a server that was never even involved.
			store.setStatus(projection, "");
			return unreachable;
		}
		store.openDir(projection, failed, failedLocator);
		store.setDirSession(projection, failed, "disconnected");
		store.setDirStatus(projection, failed, unreachable);
		if (home) noteHomeDirectoryLocator(page, null);
		const retryBackoff = Math.min(backoff * 2, BACKOFF_CEILING_MS);
		page.connections.schedule(failed, retryBackoff, () => {
			void reopenDirectory(page, home ? null : failedLocator, retryBackoff, failed);
		});
		return unreachable;
	}
}

/** This session is over.
 *
 * Ending it is dropping the object, which is the whole point of it being one:
 * the room it had us in, the lines redeemed over it, the name it advertised, the
 * offers it had queued and the stability timer it was running all go with it,
 * and none of them is named here. What is left is only what has to be *released*
 * or *reported* — a redeemed line holds a connection and an exported inbox on
 * it, a line awaiting an echo will never get one, and the page has to be told —
 * which is a shorter list, and one that fails loudly rather than quietly when it
 * is incomplete. */
function endSession(which: Live): void {
	if (!releaseSession(which)) return;
	const page = which.page;
	store.setDirNick(page.projection, which.id, "");
	for (const room of store.joinedRooms(page.projection, which.id)) {
		store.setRoomMembership(page.projection, room.key, "joining");
	}
	// The whole of telling the reader. Every row on this directory reads its
	// phase, so writing it here says the news on the rooms it is about and says
	// it about them only. The rooms on every other directory this tab holds are
	// still live and their own rows go on saying nothing.
	store.setDirSession(page.projection, which.id, "reconnecting");
	// An empty status hands the row to the phase word. What has to go is whatever
	// act the dead session was narrating.
	store.setDirStatus(page.projection, which.id, "");
	if (which.home) noteHomeDirectoryLocator(which.page, null);
	const backoff = Math.min(which.backoff * 2, BACKOFF_CEILING_MS);
	which.page.connections.schedule(
		which.id,
		backoff,
		() => void reopenDirectory(which.page, roomReconnectLocator(which), backoff, which.id),
	);
}

/** Take again whatever the reader asked this browser to remember for `home`.
 * `remember: true` keeps the memory it just used; a refusal forgets it. */
async function redeemRememberedOps(page: RoomsPageContext, home: DirId): Promise<void> {
	const attempts = [
		["listeners", takeListenersCap],
		["diagnostics", takeDiagnosticCap],
		["peering", takePeeringCap],
		["irc", takeIrcGatewayCap],
		["operator", takeOperatorCap],
	] as const;
	await Promise.all(attempts.map(async ([capability, take]) => {
		const swiss = rememberedOpsSwiss(page, capability, home);
		if (swiss == null) return;
		if (await take(page, swiss, true) !== "") forgetOpsSwiss(page, capability, home);
	}));
}

/** Give back everything this session holds, and say whether there was anything
 * to give back.
 *
 * The half of ending a session that is the same however it ends. A session that
 * dropped is coming back, and one whose directory a reader left is not, but
 * neither may keep an object URL, an exported inbox, or a timer — so what
 * differs between them is only what happens *after* this, and that is the whole
 * reason this is not folded into its caller. */
export function releaseSession(which: Live, options?: { keepTransport?: boolean }): boolean {
	if (!isCurrent(which)) return false; // already replaced by a newer session
	if (options?.keepTransport) which.keepTransport = true;
	const page = which.page;
	which.page.live.dirs.delete(which.id);
	if (which.id === page.projection.get().homeDir) {
		dropInspect(which.page);
		dropIrcHold(which.page);
		dropListeners(which.page);
		dropOperatorHold(which.page);
		dropPeering(which.page);
	}
	if (which.stable !== null) clearTimeout(which.stable);
	// A redeemed introduction holds a connection open and an inbox exported on
	// it, so these are handed back rather than merely forgotten.
	for (const peer of [...which.directRoutes.keys()]) dropDirectRoute(which, peer);
	// A file send can still be measuring media or staging room uploads before it
	// has an echo to await. It belongs to this session all the same, and the
	// browser Files it was reading from go with it, so the bubble says unsent
	// and offers nothing, rather than a retry with nothing left to send.
	for (const [id, outgoing] of which.outgoing) {
		markSend(page.projection, outgoing.key, id, "refused");
		commitAttachmentUpdates(
			which,
			outgoing.key,
			new Map(
				outgoing.attachmentIds.map((fileId) => [fileId, {
					got: undefined,
					error: "the connection ended before these files were sent",
					lost: true,
				}]),
			),
		);
	}
	// Every picture this session showed is an object URL the browser keeps
	// until it is told otherwise, and every posted file is a capability that
	// only meant anything on this session's room.
	releaseFiles(which);
	// Our own room lines still awaiting an echo will never get one now, so mark
	// them failed with a retry action rather than leaving them dimmed forever.
	for (const row of which.echoes.splice(0)) {
		markSend(page.projection, row.key, row.id, "failed");
	}
	for (const key of which.rooms.keys()) store.retireRoomLineIds(page.projection, key);
	which.refiling.clear();
	// The references governing our own lines came over this connection and cannot
	// outlive it. What was said is still what was said; what can be done to it is
	// what changes, so the pencil and the close go rather than staying to refuse.
	//
	// All of them, including a direct line's, and that is a decision rather than
	// an oversight. A direct handle sits on whichever connection carried the
	// message: one the peer opened to us outlives this session, one we opened by
	// redeeming an introduction has just been handed back above. Keeping the
	// survivors would leave a pencil that works on some of a reader's own
	// messages and not others, with nothing on screen to say which — worse than
	// one honest rule, since the way to change a message after that is to say
	// what you meant again.
	for (const line of which.posted.values()) {
		try {
			line.release();
		} catch (error) {
			trouble(page.projection, "a line capability could not be released during session cleanup", error);
		}
	}
	which.posted.clear();
	for (const key of store.dropHeldLines(page.projection, which.id)) {
		store.deliver(
			page.projection,
			key,
			store.sysItem(
				page.projection,
				"That line can no longer be changed. Your words are still in the box, to say again if you want them said.",
			),
		);
	}
	// The next session's `watch` replays who is reachable there and re-advertises
	// us, so this directory goes back to knowing neither. Another directory's
	// peers are none of this one's business.
	store.clearDmable(page.projection, which.id);
	store.unreadyDms(page.projection);
	// Release every capability while its Host/session owner is still available,
	// then retire the shell. Starting transport retirement first races those
	// deterministic releases against the close barrier and can turn cleanup into
	// a stream of avoidable closed-handle failures. This remains idempotent when
	// the pump already completed EOF teardown.
	// Share keeps the directory session so the hosted runtime can adopt it.
	// Hosted re-register withdraws the intro this inbox is filed on, then files
	// the one Attach looks up. Closing it here, without that replace, leaves
	// the directory holding a dead inbox: Attach can offer and this tab cannot
	// answer.
	if (!options?.keepTransport) {
		void which.signaling?.close().catch((err) => trouble(page.projection, "WebRTC signaling would not stop", err));
		void which.dir.session.closeTransport().catch((err) =>
			trouble(page.projection, "could not retire the dead directory session", err)
		);
	}
	return true;
}

/** A join that was stopped before this directory seated anyone. The page's own
 * first open is not a typed address, so stopping a join does not drop it —
 * unless the reader has already given that directory back, in which case the
 * in-flight open must not seat it behind their back.
 * A session already in the table is left the same way a reader would leave it;
 * one that has only answered the dial is closed and forgotten, so it cannot
 * reconnect behind a card that has moved on. */
function dropAbortedDirectory(
	page: RoomsPageContext,
	id: DirId,
	locator: string | null,
	next?: Directory,
	left = false,
): void {
	const projection = page.projection;
	if (locator === null && !left) return;
	const live = page.live.dirs.get(id);
	if (live != null && (next == null || live.dir === next)) releaseSession(live);
	else void next?.close().catch((err) => trouble(projection, "abandoned directory would not close", err));
	store.forgetDir(projection, id);
	page.live.directoryLocators.delete(id);
	store.setStatus(projection, "");
}

/** Stop holding a directory: leave its rooms, close its direct lines, give back
 * its session, and forget it.
 *
 * The other end of `openDirectory`. Holding one is a live session, a name
 * registered on it, and everything reachable through that name, so letting it go
 * has to be all of that and not merely a row removed from a list — a directory
 * dropped from the rail while its session went on running would keep dialling,
 * keep its object URLs, and keep answering for a name nobody could see any more.
 *
 * The directory this page came from is the same. Leaving it gives the session
 * back, not the knowledge of which server served the page: an empty locator
 * still means that address, so the join card can take you back under a new
 * name without a reload. A reconnect already scheduled, or a dial still in
 * flight, has to see the leave too, or the directory would seat itself again.
 *
 * Each room is left through the room's own verb, so the wire is told and the
 * reader is moved off it exactly as if they had left it by hand. The session is
 * released *after* those, because a room can only say goodbye over the session
 * that carried it. */
export function leaveDirectory(page: RoomsPageContext, dir: DirId): void {
	const projection = page.projection;
	page.connections.leave(dir);
	const live = page.live.dirs.get(dir);
	for (const conv of store.convsOn(projection, dir)) {
		if (conv.type === "directory") store.forgetConv(projection, conv.key);
		else if (conv.type === "dm") closeDm(page, conv);
		else leaveRoom(page, conv.key);
	}
	if (live !== undefined) releaseSession(live);
	// The offerer goes with the directory itself, never with one connection to
	// it. Leaving retires its aliases from the Host-scoped ledger; capabilities
	// already issued keep their old actors, so reopening cannot retarget them.
	forgetOfferer(page, dir);
	releaseHandedRoomsForDirectory(page, dir);
	releaseArchiveSharesForDirectory(page, dir);
	store.forgetDir(projection, dir);
	page.live.directoryLocators.delete(dir);
	store.showAboutDir(projection, null);
	store.setStatus(projection, "");
	if (projection.get().activeKey === null) {
		const next = store.nextStandingKey(projection.get().convs);
		if (next === undefined) store.showJoinCard(projection);
		else store.switchTo(projection, next);
	}
}

/** Reopen a known directory without deriving a new page identity from a route
 * that may now be a multi-location sturdyref locator. Reader-initiated opens
 * still use `openDirectory` and derive identity from what they typed. */
async function reopenDirectory(
	page: RoomsPageContext,
	locator: string | null,
	backoff: number,
	id: DirId,
): Promise<string> {
	return await page.connections.reopen(
		id,
		() => page.live.dirs.has(id),
		(attempt) => openDirectoryAttempt(page, locator, backoff, attempt, undefined, id),
	);
}
