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

import { init } from "@pancake/web";
import * as relay from "@pancake/relay";
import * as webrtc from "@pancake/webrtc";
import { Directory } from "../../../lib/room_client.ts";
import { dial } from "../../../lib/locator.ts";
import { directorySignalingAuthority } from "../../../lib/signaling.ts";
import { CAPTP_VERSION, CODEC } from "../../../lib/protocol.ts";
import * as store from "../store.ts";
import { type DirId, dirId } from "../types.ts";
import { directoryName } from "../text.ts";
import { markSend, reason } from "./common.ts";
import { convSession, directoryLocators, dirs, isCurrent, type Live } from "./live.ts";
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
	readyRuntime,
	soleLive,
} from "./bootstrap.ts";
import { dropInspect, takeDiagnosticCap } from "./diagnostics.ts";
import { dropListeners, takeListenersCap } from "./listeners.ts";
import { forgetOpsSwiss, rememberedOpsSwiss } from "./ops_memory.ts";
import { commitAttachmentUpdates, releaseFiles, releaseLines } from "./files.ts";
import { dropLine, releaseBackChannel, releaseHandedRoomsForDirectory } from "./direct.ts";
import {
	ADVERTISE_RETRY_LIMIT,
	ensureInbox,
	ensureOfferer,
	forgetOfferer,
	offerInboxFor,
	relayLocatorUrl,
	relayWsUrl,
} from "./reachable.ts";
import { ensureVizPublisher } from "./viz.ts";
import { closeDm, enterRoom, leaveRoom, openPrivateRoom, settleStaged, takeStaged } from "./rooms.ts";

// ── Connection ────────────────────────────────────────────────────────────
/** What a reader is told when an attempt to reach the room directory did not get
 * there. Two surfaces say it — the join card, which was waiting on a join, and
 * the status line, which is waiting on nothing — and they say the same thing
 * because it is one fact. */
const UNREACHABLE = "could not reach the room directory; retrying…";

/** Open the directory this page came from. The one directory a tab starts with;
 * every other one is added deliberately. */
export function connect(): void {
	// The log lets its oldest lines go past the far end, and what they were
	// holding is held here: a picture's object URL, the capability its bytes come
	// from, and the reference that governed one of our own. The store knows when
	// a line stops being drawn and nothing about what it carried; this side knows
	// the opposite.
	store.onLinesDropped((key, gone) => {
		const session = convSession(key);
		if (session !== null) releaseLines(session, key, gone);
	});
	void openDirectory(null, FIRST_BACKOFF_MS);
}

/** Hold one directory: open a session to `locator`, register there, and keep it
 * beside every other directory this tab holds.
 *
 * Opening takes nothing away. A directory already held is answered without
 * dialling a second time, so asking for one twice is not a way to lose the
 * rooms on it.
 *
 * `locator` of null means the directory that served this page. One open runs at
 * a time per directory: stopping a join cannot withdraw the CapTP dial, and a
 * second open that joined that abandoned attempt failed at once instead of
 * waiting for it to finish and then dialling again. */
export async function openDirectory(locator: string | null, backoff: number, signal?: AbortSignal): Promise<string> {
	if (signal?.aborted) return "";
	if (locator === null) return await openDirectoryAttempt(locator, backoff, signal);
	const id = directoryId(locator);
	if (id === null) return notALocator(locator);
	const prior = opening.get(id);
	const run = (async () => {
		if (prior !== undefined) {
			await prior.catch(() => {});
			if (signal?.aborted) return "";
			if (dirs.has(id)) return "";
		}
		// A new open is the reader asking for this directory again, so a prior
		// leave no longer forbids it. Cleared here rather than at leave's
		// opposite in the store: the store forgetting a row is not the same as
		// wanting it back.
		abandoned.delete(id);
		return await openDirectoryAttempt(locator, backoff, signal);
	})();
	opening.set(id, run);
	void run.finally(() => {
		if (opening.get(id) === run) opening.delete(id);
	});
	return run;
}

/** In-flight opens, keyed by the directory they are for. The promise is the
 * attempt a later open to the same address must wait out rather than join. */
const opening = new Map<DirId, Promise<string>>();

/** Directories the reader has given back. An in-flight dial or a reconnect
 * timer must not seat one of these: leaving has to be the end of holding it,
 * including the page's own, until a later open asks again. */
const abandoned = new Set<DirId>();

/** How many times this tab has given `dir` back. An attempt captures the
 * count when it starts, and a later leave invalidates it, so a dial that was
 * already in flight cannot seat the directory behind a join that has moved on. */
const leaveGen = new Map<DirId, number>();

/** Reconnect timers, keyed by the directory they would reopen. Leaving has to
 * cancel the one already scheduled, or a session that died just before the
 * reader left would dial itself back a second later. */
const reconnects = new Map<DirId, ReturnType<typeof setTimeout>>();

async function openDirectoryAttempt(locator: string | null, backoff: number, signal?: AbortSignal): Promise<string> {
	if (signal?.aborted) return "";
	try {
		// Install tracing before `init` creates the page's long-lived Runtime Host.
		await ensureVizPublisher();
		// Instantiate the wasm peer once; its adapter injection lets the runtime's
		// `connect` (which `Directory.connect` rides) dial over the relay. Cache
		// only a *resolved* init: `/pancake_host.wasm` answers 503 until the
		// module is built, so a first attempt can lose that race — a rejected
		// promise left cached would make every reconnect re-await the same failure
		// forever instead of retrying once the asset is live.
		const runtime = await readyRuntime(() =>
			init({
				wasm: fetch("/pancake_host.wasm"),
				wsUrl: relayWsUrl,
				relayUrl: relayLocatorUrl,
				codec: CODEC,
				captpVersion: CAPTP_VERSION,
				connectors: [
					relay.connector(),
					webrtc.connector(directorySignalingAuthority(() => soleLive()?.dir ?? null)),
				],
			})
		);
		// The inbox host both dials the directory and accepts cold-dials, so start
		// it before the dial: the directory session must be present in the same
		// host's live-session directory when a later cold-dial withdraws from that
		// session's gift table.
		ensureInbox(runtime);
		const target = locator ?? await homeLocator();
		if (signal?.aborted) return "";
		const id = directoryId(target);
		if (id === null) return notALocator(target);
		if (abandoned.has(id)) return "";
		const gen = leaveGen.get(id) ?? 0;
		const held = dirs.get(id);
		if (held !== undefined) return "";
		if (signal?.aborted) return "";
		directoryLocators.set(id, target);
		// The one open with no locator of its own is the page's own server, and it
		// is the only one that can say so. Written once: leaving this directory
		// gives the session back, not the knowledge of which server served the page.
		if (locator === null) store.setHomeDir(id);
		if (abandoned.has(id) || (leaveGen.get(id) ?? 0) !== gen) return "";
		const wasReconnect = store.dirReached(id);
		store.openDir(id);
		store.setDirSession(id, "connecting");
		if (signal?.aborted) {
			dropAbortedDirectory(id, locator);
			return "";
		}
		// Dial transport-neutrally, the same as every terminal client: the rooms
		// `dial` normalises a bare `host:port` into a `tcp` locator and passes an
		// `ocapn://…iroh` URI through, both routed over the relay by the injected
		// browser adapter. The runtime's default `connect` would reject the bare
		// designator `/locator` serves.
		const next = await Directory.connect(target, (address) => dial(address, runtime));
		if (signal?.aborted || abandoned.has(id) || (leaveGen.get(id) ?? 0) !== gen) {
			dropAbortedDirectory(id, locator, next);
			return "";
		}
		// Everything this session will hold, minted with it. Nothing below adds a
		// field to module scope, so nothing below can outlive the session by
		// being forgotten at the other end.
		const session: Live = {
			id,
			dir: next,
			home: store.get().homeDir === id,
			locator: target,
			// The attempt's own backoff, so the stability window below has its
			// documented job: seeded with the constant instead, a server that
			// accepted and then dropped was redialled at the floor forever, and
			// the window reset a value that never climbed.
			backoff,
			rooms: new Map(),
			standingTold: new Map(),
			posted: new Map(),
			echoes: [],
			refiling: new Map(),
			lines: new Map(),
			advertised: null,
			advertiseRetries: ADVERTISE_RETRY_LIMIT,
			registered: false,
			deferredOffers: new Set(),
			stable: null,
			signaling: null,
			files: new Map(),
			objectUrls: new Map(),
			progress: { pending: new Map(), frame: null },
			outgoing: new Map(),
		};
		dirs.set(id, session);
		const seen = await next.watch((event) => {
			switch (event.kind) {
				case "closed":
					store.dropLiveRoom(id, event.name);
					break;
				case "registered":
					store.setDmable(id, event.name, true);
					// Offer a member who arrives after us an inbox straight away, so their
					// first message costs no extra round trip. One already on the roster
					// before we had a name is covered by the directory asking on demand.
					offerInboxFor(session, event.name);
					break;
				case "unregistered":
					store.setDmable(id, event.name, false);
					// The member left, so the room has their name back and may grant
					// it to someone else. Close what we have with them and hand the
					// lines back; a later introduction under the same name opens a
					// new conversation, because it may well be a new person.
					// Their reply route goes with them: it reached that connection,
					// and the next holder of the name is not on it.
					for (const key of store.closeDmsWith(id, event.name)) {
						dropLine(session, key);
						releaseBackChannel(key);
					}
					// The next holder of this name is a different person and gets an
					// inbox of their own. An offer still queued for them is dropped
					// rather than spending a permanent name on someone who has left.
					for (const p of session.deferredOffers) {
						if (p.toLowerCase() === event.name.toLowerCase()) {
							session.deferredOffers.delete(p);
						}
					}
					ensureOfferer(session.id).forget(event.name);
					break;
				default:
					store.setLiveRoom(id, event.name, event.count);
					break;
			}
		});
		if (signal?.aborted || abandoned.has(id) || (leaveGen.get(id) ?? 0) !== gen) {
			dropAbortedDirectory(id, locator, next);
			return "";
		}
		store.resetLiveRooms(id, seen.map((room) => [room.name, room.count] as const));
		announceDirectoryReady();
		store.markDirReached(id);
		store.setDirSession(id, "connected");
		// A remembered operations swiss auto-redeems on the home session coming
		// up, so a refresh does not demand re-entry; possession stays derived
		// from the same take path a paste uses. A failed redeem erases the
		// memory — a dead secret must not linger or retry forever.
		if (id === store.get().homeDir) void redeemRememberedOps(id);

		store.setBanner(null);
		// Whether this directory has answered before is a durable fact the store
		// already owns; a copy on the session was constant-false (its constructor
		// runs only when no prior session exists), so this line was unreachable
		// and no reader was ever told the room came back.
		if (wasReconnect && store.joinedRooms(id).length > 0) {
			store.deliverActive(store.sysItem("Reconnected"));
		}

		// A dropped directory session (the server respawning) reconnects the page.
		next.session.serve()
			.catch((err) => console.error("rooms: the directory session ended:", reason(err)))
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

		// Re-enter every room we were in, not just one: the conversations are all
		// still on screen, and a reconnect that restored only one would leave the
		// rest looking healthy while silently delivering nothing. They go back in
		// the order they were first entered, so a partial recovery keeps the
		// oldest rooms rather than an arbitrary subset. Otherwise honour a join
		// the user asked for while this session was still opening, and only then
		// wait.
		// A room reached by name is re-entered by that name. A room this tab was
		// handed cannot be: the reference was on the connection that has just
		// gone, and there is no name to ask for it back with. Said once, in the
		// conversation itself, rather than left as a room that looks live and
		// quietly delivers nothing.
		const rejoining = store.joinedRooms(id).filter((conv) => !conv.held);
		for (const conv of store.joinedRooms(id).filter((conv) => conv.held)) {
			store.deliver(
				conv.key,
				store.sysItem(
					"This room was reached by an invitation, and that reference went with the connection. " +
						"Somebody in it can hand it over again.",
				),
			);
		}
		const nick = store.dirNick(id) || store.reachingNick();
		if (rejoining.length > 0 && nick) {
			store.setDirStatus(
				id,
				rejoining.length === 1
					? "rejoining #" + rejoining[0].id + "…"
					: "rejoining " + rejoining.length + " rooms…",
			);
			for (const conv of rejoining) void enterRoom(conv.dir, conv.id, nick);
		} else if (signal?.aborted || abandoned.has(id) || (leaveGen.get(id) ?? 0) !== gen) {
			dropAbortedDirectory(id, locator, next);
			return "";
		} else {
			const wanted = takeStaged();
			if (wanted !== null) {
				store.setDirStatus(id, "entering #" + wanted.room + "…");
				settleStaged(
					wanted.hidden ? await openPrivateRoom(id, wanted.room, wanted.nick, signal) : await enterRoom(
						id,
						wanted.room,
						wanted.nick,
						0,
						undefined,
						undefined,
						wanted.nick,
						true,
						signal,
					),
				);
			} else store.setDirStatus(id, "");
		}
		return "";
	} catch (err) {
		// Surface the real cause for the devtools console; the user sees a plain
		// retry line, but a blocked ws (an http page over https, say) or a wasm
		// load failure is otherwise invisible.
		console.error("rooms: could not open the peer session:", err);
		if (signal?.aborted) {
			if (locator !== null) {
				const id = directoryId(locator);
				if (id !== null) dropAbortedDirectory(id, locator);
			}
			return "";
		}
		// A staged join is not lost on a failed attempt: the retry below opens
		// another session, which replays it. The card is told so it can offer the
		// button back, in case the reader would rather change their mind.
		settleStaged(UNREACHABLE);
		// The attempt is over and it failed. Left on "connecting", the dot in the
		// foot of the rail would go on claiming an attempt that is no longer
		// running, and the opening screen would go on waiting for an answer that
		// has already come back. The retry sets it to "connecting" again itself,
		// so each attempt reads as the attempt it is.
		//
		// Open the row before reporting on it. Everything above this line can
		// throw before the server was ever recorded — the wasm module answers 503
		// until it is built, and a page loaded offline never learns its own
		// locator — and a report about a server the store has never heard of is
		// dropped on the floor. That silence is the whole failure: the opening
		// screen waits for *some* server to have answered either way, so a first
		// attempt that failed this early left the page on "Opening a peer in your
		// browser…" for good, retrying behind a screen that never lifted.
		const failedLocator = locator ?? heldHomeLocator() ?? "";
		// An unparseable locator has no identity to file the failure under, so it
		// stands in as the empty one: the report still reaches the status line and
		// the join card, and no row is opened for an address that cannot exist.
		const failed = failedLocator === "" ? dirId("") : directoryId(failedLocator) ?? dirId("");
		// The server this page came from is retried for as long as this tab
		// still holds it: there is no address to correct, so giving up while
		// holding it would leave a reader with a dead page and nothing to do
		// about it. Leaving it is how they give up; a retry after that would
		// seat a directory they already gave back.
		const home = locator === null || failedLocator === (heldHomeLocator() ?? "");
		// A server somebody typed and that has never once answered is most likely a
		// typo, and retrying a typo forever is how one mistyped locator became a
		// permanent row dialling every few seconds for the life of the tab with no
		// way to remove it. Let it go instead; the address is still in the card's
		// field, so correcting it is an edit rather than a retype.
		if (!home && !store.dirReached(failed)) {
			store.forgetDir(failed);
			directoryLocators.delete(failed);
			// The line that announced this attempt has to stop announcing it. It was
			// written before the dial and belongs to whichever server the reader is
			// on, so leaving it saying "reaching …" reports an attempt that ended,
			// on a server that was never even involved.
			store.setStatus("");
			return UNREACHABLE;
		}
		if (abandoned.has(failed)) {
			store.forgetDir(failed);
			store.setStatus("");
			return UNREACHABLE;
		}
		store.openDir(failed);
		store.setDirSession(failed, "disconnected");
		store.setDirStatus(failed, UNREACHABLE);
		if (home) noteHomeDirectoryLocator(null);
		scheduleReconnect(home ? null : failedLocator, Math.min(backoff * 2, BACKOFF_CEILING_MS), failed);
		return UNREACHABLE;
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
	store.setDirSession(which.id, "reconnecting");
	// An empty status hands the row to the phase word; what has to go is
	// whatever act the dead session was narrating.
	store.setDirStatus(which.id, "");
	if (store.joinedRooms(which.id).length > 0) {
		// Named while this tab holds more than one. "Reconnecting…" is the whole
		// message when there is only one thing it could be about, and a riddle the
		// moment there are two: the rooms on the other directory are still live,
		// and a reader watching one of those go quiet has no way to tell whether
		// this is about them.
		const held = store.get().dirs.size;
		const name = directoryName(which.id, store.get().homeDir);
		store.setBanner({
			kind: "working",
			text: held > 1 ? "Reconnecting to " + name + "…" : "Reconnecting…",
		});
	}
	if (which.home) noteHomeDirectoryLocator(null);
	if (abandoned.has(which.id)) return;
	scheduleReconnect(which.home ? null : which.locator, Math.min(which.backoff * 2, BACKOFF_CEILING_MS), which.id);
}

/** Give back everything this session holds, and say whether there was anything
 * to give back.
 *
 * The half of ending a session that is the same however it ends. A session that
 * dropped is coming back, and one whose directory a reader left is not, but
 * neither may keep an object URL, an exported inbox, or a timer — so what
 * differs between them is only what happens *after* this, and that is the whole
 * reason this is not folded into its caller. */
/** Take again whatever the reader asked this browser to remember for `home`.
 * `remember: true` keeps the memory it just used; a refusal forgets it. */
async function redeemRememberedOps(home: DirId): Promise<void> {
	const listeners = rememberedOpsSwiss("listeners", home);
	if (listeners !== null && (await takeListenersCap(listeners, true)) !== "") {
		forgetOpsSwiss("listeners", home);
	}
	const inspect = rememberedOpsSwiss("diagnostics", home);
	if (inspect !== null && (await takeDiagnosticCap(inspect, true)) !== "") {
		forgetOpsSwiss("diagnostics", home);
	}
}

function releaseSession(which: Live): boolean {
	if (!isCurrent(which)) return false; // already replaced by a newer session
	dirs.delete(which.id);
	if (which.id === store.get().homeDir) {
		dropInspect();
		dropListeners();
	}
	if (which.stable !== null) clearTimeout(which.stable);
	void which.signaling?.close().catch((err) => console.error("rooms: WebRTC signaling would not stop:", reason(err)));
	// A redeemed introduction holds a connection open and an inbox exported on
	// it, so these are handed back rather than merely forgotten.
	for (const key of [...which.lines.keys()]) dropLine(which, key);
	// A file send can still be measuring media or staging room uploads before it
	// has an echo to await. It belongs to this session all the same, and the
	// browser Files it was reading from go with it, so the bubble says unsent
	// and offers nothing, rather than a retry with nothing left to send.
	for (const [id, outgoing] of which.outgoing) {
		markSend(outgoing.key, id, "refused");
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
		markSend(row.key, row.id, "failed");
	}
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
			console.error("rooms: a line capability could not be released during session cleanup:", reason(error));
		}
	}
	which.posted.clear();
	for (const key of store.dropHeldLines(which.id)) {
		store.deliver(
			key,
			store.sysItem(
				"That line can no longer be changed. Your words are still in the box, to say again if you want them said.",
			),
		);
	}
	// The next session's `watch` replays who is reachable there and re-advertises
	// us, so this directory goes back to knowing neither. Another directory's
	// peers are none of this one's business.
	store.clearDmable(which.id);
	store.unreadyDms();
	// Release every capability while its Host/session owner is still available,
	// then retire the shell. Starting transport retirement first races those
	// deterministic releases against the close barrier and can turn cleanup into
	// a stream of avoidable closed-handle failures. This remains idempotent when
	// the pump already completed EOF teardown.
	void which.dir.session.closeTransport().catch((err) =>
		console.error("rooms: could not retire the dead directory session:", reason(err))
	);
	return true;
}

/** A join that was stopped before this directory seated anyone. The page's own
 * first open is not a typed address, so stopping a join does not drop it —
 * unless the reader has already given that directory back, in which case the
 * in-flight open must not seat it behind their back.
 * A session already in the table is left the same way a reader would leave it;
 * one that has only answered the dial is closed and forgotten, so it cannot
 * reconnect behind a card that has moved on. */
function dropAbortedDirectory(id: DirId, locator: string | null, next?: Directory): void {
	if (locator === null && !abandoned.has(id)) return;
	if (dirs.has(id)) {
		leaveDirectory(id);
		return;
	}
	void next?.close().catch((err) => console.error("rooms: abandoned directory would not close:", reason(err)));
	store.forgetDir(id);
	directoryLocators.delete(id);
	store.setStatus("");
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
export function leaveDirectory(dir: DirId): void {
	abandoned.add(dir);
	leaveGen.set(dir, (leaveGen.get(dir) ?? 0) + 1);
	cancelReconnect(dir);
	const live = dirs.get(dir);
	for (const conv of store.convsOn(dir)) {
		if (conv.type === "dm") closeDm(conv);
		else leaveRoom(conv.key);
	}
	if (live !== undefined) releaseSession(live);
	// The offerer goes with the directory itself, never with one connection to
	// it. The published aliases stay in the Host-scoped publisher ledger because
	// nothing withdraws a giftable; reopening starts a fresh peer mapping but
	// cannot reset or exceed the process-wide publication ceiling.
	forgetOfferer(dir);
	releaseHandedRoomsForDirectory(dir);
	store.forgetDir(dir);
	store.showAboutDir(null);
	store.setStatus("");
}

/** Try this directory again, later each time it fails. The delay belongs to the
 * directory, so a server that is down backs off on its own schedule while every
 * other directory this tab holds carries on. */
function scheduleReconnect(locator: string | null, backoff: number, id: DirId): void {
	if (abandoned.has(id)) return;
	const prior = reconnects.get(id);
	if (prior !== undefined) clearTimeout(prior);
	reconnects.set(
		id,
		setTimeout(() => {
			reconnects.delete(id);
			if (abandoned.has(id)) return;
			void openDirectory(locator, backoff);
		}, backoff),
	);
}

function cancelReconnect(id: DirId): void {
	const prior = reconnects.get(id);
	if (prior === undefined) return;
	clearTimeout(prior);
	reconnects.delete(id);
}
