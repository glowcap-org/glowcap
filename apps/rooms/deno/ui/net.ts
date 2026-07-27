// The rooms page's data layer, as a real OCapN peer in the browser. The page
// instantiates the pancake stack over `@pancake/web` (the wasm Host, no dlopen),
// dials the room server through web.ts's `/relay` byte pipe, and drives the
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

import { init, type RendezvousHandle, serveRendezvous } from "@pancake/web";
import {
	currentSession,
	formatPeerUri,
	Host,
	Ref,
	type Session,
	TRANSPORT_KEYED_RELAY,
} from "@pancake/stack";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";
import { DirectMessage, Directory, Room } from "../../lib/room_client.ts";
import { DM } from "../../lib/protocol.ts";
import { enterOrOpen } from "../lib/enter_room.ts";
import { dial } from "../lib/locator.ts";
import { NICK_TAKEN, PEER_OFFLINE } from "../../lib/errors.ts";
import { roomErrorOf } from "../lib/errors.ts";
import type { ChatItem, DmConv } from "./types.ts";
import { app, composer, joinBtn, membersToggle, newDmBtn, nickInput, roomInput } from "./dom.ts";
import {
	activeConv,
	chatItem,
	convKey,
	convs,
	dmablePeers,
	ensureDm,
	ensureRoom,
	liveRooms,
	LS,
	state,
	sysItem,
} from "./state.ts";
import {
	applyPresence,
	deliver,
	refreshSendState,
	renderDms,
	renderDmStatus,
	renderPresence,
	renderRooms,
	renderTyping,
	setBanner,
	setComposerEnabled,
	setJoinError,
	setStatus,
	showJoinScreen,
	switchTo,
	toActive,
} from "./render.ts";
import { maybeNotify } from "./notify.ts";
import { mentionsYou } from "./richtext.ts";

let userPickedRoom = false; // set when the user taps a room, so entering switches to it
let stackReady: Promise<unknown> | null = null;
let dir: Directory | null = null;
let currentRoom: Room | null = null;
let pumpToken = 0; // bumped on each room switch so a stale pump stops delivering
let backoff = 500;
// A session must survive this long before its handshake counts as a stable
// connection worth resetting the backoff to 500. Below it, a server that accepts
// then drops keeps the exponential backoff climbing instead of storming.
const BACKOFF_STABLE_MS = 10_000;
let stableTimer: ReturnType<typeof setTimeout> | null = null;
let everConnected = false;
// Open direct lines, keyed by lowercased peer nick. One introduction per peer:
// the first send opens it (redeeming the handoff by dialing the member), later
// sends reuse it. A failed open is dropped so the next send retries.
const dmLines = new Map<string, Promise<DirectMessage>>();

// ── Cold-dial rendezvous: being reachable as a browser (ADR-0088) ──────────
// The one inbox host per page. It dials the directory AND accepts cold-dials,
// so the gift the room deposits over our directory session and the withdraw a
// cold-dial carries land in one shared gift registry. It publishes a giftable
// `dm` (answering every accepted cold-dial on whichever connection carries it)
// and registers our key designator at the relay's rendezvous, so a peer that
// redeems an introduction to us is bridged onto our held socket. Kept across
// reconnects: a cold-dial line is browser-to-browser through the relay,
// independent of the room server, so a room respawn must not tear it down.
let inboxHost: Host | null = null;
let rendezvous: RendezvousHandle | null = null;
// The nick our current directory session advertised a keyed-relay locator for,
// so we register once per (nick, session) rather than on every room switch.
let advertisedNick: string | null = null;
// Reply back-channels a peer handed us with an incoming DM: the connection the
// message arrived on plus the reply capability it carried, keyed by the
// sender's lowercased nick. Our own reply rides this arriving connection
// (`currentSession`, ADR-0088) — the only way to answer a peer that opened no
// listener — rather than cold-dialing them back.
const dmBackChannels = new Map<string, { session: Session; reply: Ref }>();

// The host-wide inbox a member's direct message arrives on. A giftable answers
// calls on every session of the inbox host, so it fields a cold-dial redeem the
// same way whichever connection carried it. Paint the incoming line in that
// peer's DM thread, and remember the reply capability the sender hosts on this
// arriving connection so our own reply can ride back over it.
function inboxDm(verb: string, args: unknown[]): null {
	if (verb !== DM) throw new Error(`dm inbox has no method ${verb}`);
	const from = typeof args[0] === "string" && args[0].length > 0 ? args[0] : "?";
	const text = typeof args[1] === "string" ? args[1] : "";
	const reply = args[2];
	// Capture the arriving connection synchronously inside the turn: it is null
	// once the turn returns, so a later reply must read it now and send on a
	// later turn.
	//
	// `from` is a display label the caller supplies, not authority. No
	// *capability* is misdirected by a spoofed one, because a reply travels to
	// the `reply` capability rather than to the name — but the message content
	// is another matter, and this route is what later messages to that nick are
	// sent over. An unsolicited caller claiming a nick we are already talking to
	// would take the route and receive everything we typed for the real peer.
	//
	// So a live route is not displaced. A caller who is first, or who arrives
	// after the previous connection died, still takes it: that is the same trust
	// as any unauthenticated nick in this room, and the roster says as much. What
	// this refuses is the interesting case, where a route we are actively using
	// is taken out from under us.
	const session = currentSession();
	if (session !== null && reply instanceof Ref) {
		const key = from.toLowerCase();
		const held = dmBackChannels.get(key);
		if (held === undefined || !held.session.sessionOpen) {
			dmBackChannels.set(key, { session, reply });
		}
	}
	receiveDmReply(from, from, text);
	return null;
}

// Create the inbox host once and start serving cold-dials against it. Idempotent
// across reconnects so our identity, held registrations, and open cold-dial
// lines survive a room-server respawn.
function ensureInbox(): Host {
	if (inboxHost) return inboxHost;
	const host = new Host();
	host.publishGiftable(DM, inboxDm);
	inboxHost = host;
	rendezvous = serveRendezvous(host, relayRegisterUrl, {
		onError: (err) => console.error("rooms: rendezvous registration error:", reason(err)),
	});
	return host;
}

// Advertise our inbox host's keyed-relay locator to the directory so we appear
// in the DM-able roster and a peer can introduce+redeem us. Registered once per
// nick on the current directory session; a reconnect re-advertises because the
// new directory has no memory of the old introduction.
function advertisePresence(): void {
	if (!dir || !inboxHost || !state.nick) return;
	if (advertisedNick === state.nick) return;
	advertisedNick = state.nick;
	const locator = formatPeerUri(TRANSPORT_KEYED_RELAY, inboxHost.designator());
	dir.register(state.nick, locator).catch(() => {
		// Let a later join retry the introduction if this registration was lost.
		if (advertisedNick === state.nick) advertisedNick = null;
	});
}

// Same-origin ws(s) URL for a relay endpoint, matching the page's scheme: an
// https page (a forwarded or deployed origin) must use `wss://`, or the browser
// blocks the insecure socket as mixed content. Every dial the wasm peer makes
// rides one of these to the page's own server, which relays the opaque bytes.
function pageSocketUrl(path: string, param: string, value: string): string {
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${location.host}${path}?${param}=${encodeURIComponent(value)}`;
}

// A dial rides `/relay?target=<locator>`: the room dial names a `host:port`
// (TCP), a member dial names an `ocapn://…iroh` URI, and web.ts dials whichever.
// A cold-dial to a registered peer is a bridge, not a dial, so it has its own
// endpoint — `/relay?rendezvous=<id>` (the redeem side, wired into the adapter as
// `rendezvousUrl`) bridges onto the inbound socket we *hold* by registering at
// `/register?id=<id>` (wired into `serveRendezvous`).
const relayLocatorUrl = (locator: string) => pageSocketUrl("/relay", "target", locator);
// A `host:port` is just a tcp dial target: reuse the one endpoint spelling so a
// later rename touches one line, not two.
const relayWsUrl = (host: string, port: number) => relayLocatorUrl(`${host}:${port}`);
const relayRendezvousUrl = (id: string) => pageSocketUrl("/relay", "rendezvous", id);
const relayRegisterUrl = (id: string) => pageSocketUrl("/register", "id", id);

export function isConnected(): boolean {
	return dir !== null;
}

// Our own room lines painted optimistically and awaiting the room's echo. The room
// echoes every post back to every member, so we paint ours at once as "sending" and
// reconcile it to confirmed when its echo arrives, rather than waiting on a round trip
// or eating a dropped send silently. Matched FIFO by text.
const pendingRoomSends: ChatItem[] = [];
// The closure that re-sends a failed line, keyed by the bubble's history item, so a tap
// on a failed bubble resends that exact line. Weak, so it dies with the item's history.
const retryOf = new WeakMap<ChatItem, () => void>();

/** Re-send a line whose bubble is marked failed (a tap on it, or Enter/Space). */
export function retrySend(item: ChatItem): void {
	retryOf.get(item)?.();
}

/**
 * Say a line into the joined room. We paint our own line at once as "sending"; the room
 * echoes it back to every member, which confirms it (see `pump`). A rejected post marks
 * the line failed and tap-to-retry instead of vanishing.
 */
export function sayLine(text: string): void {
	if (!state.joinedRoom) return;
	const conv = ensureRoom(state.joinedRoom);
	const item = chatItem(state.nick, text, true, "sending");
	retryOf.set(item, () => resendRoomLine(item, text));
	deliver(conv, item);
	pendingRoomSends.push(item);
	postRoomLine(item, text);
}

// Re-arm a failed line as "sending" and post it again. The bubble is already in history,
// so this repaints it in place rather than delivering a fresh one.
function resendRoomLine(item: ChatItem, text: string): void {
	item.state = "sending";
	refreshSendState(item);
	pendingRoomSends.push(item);
	postRoomLine(item, text);
}

// Post a line to the joined room, marking it failed if there is no room or the post
// rejects. Success is silent: the room's echo confirms the line through `confirmRoomEcho`.
function postRoomLine(item: ChatItem, text: string): void {
	const room = currentRoom;
	if (!room) {
		failRoomSend(item);
		return;
	}
	room.say(text).catch(() => failRoomSend(item));
}

// A room line that cannot be confirmed: drop it from the echo queue and tint it failed.
function failRoomSend(item: ChatItem): void {
	const i = pendingRoomSends.indexOf(item);
	// Already off the queue means the room echoed this line back and
	// `confirmRoomEcho` cleared it. A `say` that rejects afterwards is reporting
	// on a line the room demonstrably received, so tinting it failed here would
	// contradict the echo the user can see.
	if (i < 0) return;
	pendingRoomSends.splice(i, 1);
	item.state = "failed";
	refreshSendState(item);
}

// The room echoed a line back to us. If it matches an optimistic send still in flight,
// confirm that line in place (clear its "sending" tint) and report that it is handled,
// so `pump` does not paint a second copy.
function confirmRoomEcho(text: string): boolean {
	const i = pendingRoomSends.findIndex((it) => it.state === "sending" && it.text === text);
	if (i < 0) return false;
	const [item] = pendingRoomSends.splice(i, 1);
	item.state = undefined;
	retryOf.delete(item);
	refreshSendState(item);
	return true;
}

/** Set our typing flag in the joined room (room-only; a DM has no typing channel). */
export function setTyping(on: boolean): void {
	currentRoom?.setTyping(on).catch(() => {});
}

// ── Rooms: picking, creating, joining ─────────────────────────────────────
export function pickRoom(name: string): void {
	if (state.joinedRoom && state.nick && dir) {
		const key = convKey("room", name);
		if (key === state.activeKey) {
			app.classList.remove("show-list");
			return;
		}
		if (convs.has(key) && name.toLowerCase() === state.joinedRoom.toLowerCase()) {
			switchTo(key);
		} else switchRoom(name);
	} else {
		roomInput.value = name;
		setJoinError("");
		app.classList.remove("show-list");
		nickInput.focus();
	}
}

export function switchRoom(name: string): void {
	userPickedRoom = true;
	setStatus("connecting", "entering #" + name + "…");
	void enterRoom(name, state.nick);
}

/// A join the user asked for before the peer session was open. The session is
/// fetched, instantiated, and handshaked after the page loads, and a returning
/// visitor's name is prefilled with the Join button focused — so pressing Enter
/// inside that window is the *common* first interaction, not an unusual one.
/// It used to be dropped silently, leaving a disabled "Joining…" button with no
/// way back but a reload.
let pendingJoin: { room: string; nick: string } | null = null;

export function join(): void {
	state.nick = (nickInput.value || "guest").trim();
	const room = (roomInput.value || "general").trim();
	if (!state.nick || !room) return;
	if (state.nick.length > MAX_NICK) {
		setJoinError(`name too long (max ${MAX_NICK} characters)`);
		return;
	}
	if (room.length > MAX_ROOM) {
		setJoinError(`room name too long (max ${MAX_ROOM} characters)`);
		return;
	}
	joinBtn.disabled = true;
	joinBtn.textContent = "Joining…";
	setJoinError("");
	if (!isConnected()) {
		// Held, not dropped. The button already reads "Joining…", which is true:
		// the session is still opening, and `openSession` replays this the
		// moment it can.
		pendingJoin = { room, nick: state.nick };
		setStatus("connecting", "reaching the room server…");
		return;
	}
	setStatus("connecting", "entering #" + room + "…");
	void enterRoom(room, state.nick);
}

function rejectJoin(text: string): void {
	userPickedRoom = false;
	composer.hidden = true;
	membersToggle.hidden = true;
	showJoinScreen(true);
	resetJoinButton();
	setJoinError(text);
	setStatus("disconnected", "pick another name");
}

function resetJoinButton(): void {
	joinBtn.disabled = false;
	joinBtn.textContent = "Join room";
}

// Enter `name` as `nick`: subscribe to the room (a capability), then leave the
// current one, so a rejected claim leaves the current room intact — the same
// order the room_client client uses.
async function enterRoom(name: string, nick: string, attempt = 0): Promise<void> {
	if (!dir) {
		// Never silently: a caller that reaches here with no session has a live
		// "Joining…" button waiting on an answer that will not come.
		resetJoinButton();
		setJoinError("not connected to the room server yet");
		return;
	}
	try {
		const ref = await enterOrOpen(dir, name);
		const next = await Room.subscribe(
			dir.session,
			ref,
			nick,
			(from, on) => setRoomTyping(from, on),
		);
		const prev = currentRoom;
		currentRoom = next;
		if (prev) await prev.leave().catch(() => {});
		// Commit the nick we actually claimed. Two tabs of one browser share the
		// persisted nick, so a collision may have suffixed it below; reflect the
		// real name in the UI so a member never sees a stale one.
		if (state.nick !== nick) {
			state.nick = nick;
			nickInput.value = nick;
		}
		// Now that we hold a nick in a room, advertise our keyed-relay locator so
		// others can introduce+redeem us for direct messages (ADR-0088 cold-dial).
		advertisePresence();
		enteredRoom(name);
		void pump(next);
	} catch (err) {
		const re = roomErrorOf(err);
		if (re?.code === NICK_TAKEN && attempt < 20) {
			// A second tab of the same browser prefills the first tab's persisted
			// nick, so it dead-ends on the room's duplicate-name guard. Claim a free
			// variant instead — `alice` → `alice-2` → `alice-3` — so "open a tab,
			// click Join" just works, which is the whole point of two-tab DMs.
			const base = nick.replace(/-\d+$/, "");
			const candidate = `${base}-${attempt + 2}`.slice(0, MAX_NICK);
			return enterRoom(name, candidate, attempt + 1);
		}
		if (re?.code === NICK_TAKEN) rejectJoin(re.detail);
		else if (!state.joinedRoom) {
			resetJoinButton();
			setJoinError(reason(err));
			setStatus("disconnected", "could not join");
		} else {
			const conv = activeConv();
			if (conv) toActive(sysItem(reason(err)));
			else setBanner(reason(err));
		}
	}
}

// The room confirmed us. Show it, creating its conversation on first entry.
function enteredRoom(name: string): void {
	state.joinedRoom = name;
	const conv = ensureRoom(name);
	conv.members.clear();
	LS.set("rooms.nick", state.nick);
	LS.set("rooms.room", name);
	setStatus("connected", "connected as " + state.nick);
	newDmBtn.hidden = false;
	app.classList.add("joined");
	const cur = activeConv();
	if (userPickedRoom || !cur || cur.type === "room") switchTo(conv.key);
	else {
		setComposerEnabled(true);
		renderRooms();
		renderDms();
	}
	userPickedRoom = false;
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
async function pump(room: Room): Promise<void> {
	const token = ++pumpToken;
	const reader = room.messages.getReader();
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) return;
			if (token !== pumpToken) {
				// A newer pump owns the view. Drop this stream rather than leave it
				// locked and half-read; `for await` used to do this on return.
				await reader.cancel().catch(() => {});
				return;
			}
			const { from, text, system, presence } = value;
			const roomConv = state.joinedRoom ? ensureRoom(state.joinedRoom) : null;
			if (!roomConv) continue;
			if (presence) applyPresence(roomConv, presence);
			if (system) deliver(roomConv, sysItem(text));
			else {
				const mine = from === state.nick;
				// Our own line was painted optimistically; its echo confirms it in
				// place rather than painting a duplicate.
				if (mine && confirmRoomEcho(text)) continue;
				deliver(roomConv, chatItem(from, text, mine));
				if (!mine && mentionsYou(text)) {
					maybeNotify("#" + state.joinedRoom + " · " + from, text);
				}
			}
		}
	} catch (err) {
		// Leaving a room ends the stream cleanly, which arrives as `done` above,
		// not here. Reaching this means something actually broke, and silence is
		// what made the missing-iterator failure take so long to find: the room
		// simply never spoke. Say so where the reader is looking.
		if (token === pumpToken) {
			toActive(sysItem("This room stopped delivering messages: " + reason(err)));
		}
	} finally {
		try {
			reader.releaseLock();
		} catch { /* already released by cancel above */ }
	}
}

// ── Direct messages by introduction ───────────────────────────────────────
// Open a DM conversation with `peer` and show it. The direct line itself opens
// lazily on the first send, so opening the thread asks the directory for nothing.
export function startDm(peer: string): void {
	if (!peer) return;
	if (state.nick && peer.toLowerCase() === state.nick.toLowerCase()) {
		toActive(sysItem("You can't start a direct message with yourself."));
		return;
	}
	const conv = ensureDm(peer);
	switchTo(conv.key);
}

// Send a direct message to `peer`, opening the introduced line on first use. A
// DM has no echo, so paint our own line at once; a dial that can't land (a member
// reachable only over TCP, or one who has left) says so in the thread.
export function dmSay(peer: string, text: string): void {
	const conv = ensureDm(peer);
	const item = chatItem(state.nick, text, true, "sending");
	retryOf.set(item, () => sendDm(conv, item, peer, text));
	deliver(conv, item);
	sendDm(conv, item, peer, text);
}

// Open the introduced line (lazily on first use) and deliver one line to `peer`, tracking
// the bubble's send state honestly. On success the bubble clears to confirmed; on failure
// it tints failed and tap-to-retry, and a friendly note names why. A retry runs this again
// with the same bubble.
function sendDm(conv: DmConv, item: ChatItem, peer: string, text: string): void {
	item.state = "sending";
	refreshSendState(item);
	const key = peer.toLowerCase();
	// A peer who direct-messaged us first handed us a reply capability on the
	// connection their message arrived on. Answer over that same connection
	// (ADR-0088 receiver primitive), the only path that reaches a peer that
	// opened no listener; otherwise open (or reuse) an introduced line to them.
	//
	// The capability is only good while that connection is. A peer who went
	// offline and came back is a *new* connection, and nothing else drops the
	// entry: the `unregistered` arm below clears their introduced line, and the
	// clear at disconnect is about our own session ending, not theirs.
	let cached = dmBackChannels.get(key);
	if (cached && !cached.session.sessionOpen) {
		dmBackChannels.delete(key);
		cached = undefined;
	}
	const back = cached;
	// Started inside a promise on purpose. Anything this expression raises
	// synchronously would escape the `.catch` below, and that catch is what
	// drops the dead route. Skipping it once turned one lost message into every
	// message: the entry stayed, so the next send failed in the same place.
	// `Session.send` itself now reports a closed session as a rejected handle
	// rather than a throw, but this is the wrapper for everything else.
	const delivered = back
		? (async () => await back.session.send(back.reply, DM, [state.nick, text]))()
		: openDm(peer).then((line) => line.say(state.nick, text));
	delivered
		.then(() => {
			item.state = undefined;
			retryOf.delete(item);
			refreshSendState(item);
			if (!conv.ready) {
				conv.ready = true;
				renderDmStatus(conv);
				renderDms();
			}
		})
		.catch((err) => {
			// Drop the dead line so the next send retries: a stale back-channel
			// falls back to a fresh introduction, a stale introduction re-redeems.
			if (back) dmBackChannels.delete(key);
			else dmLines.delete(key);
			item.state = "failed";
			refreshSendState(item);
			deliver(conv, sysItem(dmFailureText(peer, err)));
		});
}

// A friendly reason a direct message could not land, from the typed taxonomy rather than
// the raw wire reason: a member the directory has no registration for is offline, and any
// other failure is reported generically instead of leaking a wire code.
function dmFailureText(peer: string, err: unknown): string {
	const re = roomErrorOf(err);
	if (re?.code === PEER_OFFLINE) return `${peer} is offline.`;
	return `Couldn't reach ${peer}.`;
}

// The introduced direct line to `peer`, opened once and reused. `DirectMessage.open`
// asks the directory to introduce us and wraps the handoff-give; the redeem dial
// opens the direct connection, riding the relay's iroh path to the member. The
// line hosts a reply inbox on that connection, so a member's reply lands here and
// paints in the peer's DM thread — the member never dials us.
function openDm(peer: string): Promise<DirectMessage> {
	const key = peer.toLowerCase();
	const existing = dmLines.get(key);
	if (existing) {
		// Same staleness as the back-channel above, one step softer: `say` is
		// async, so a dead line surfaces as a rejection and repairs itself after
		// one visibly failed message. Checking here spends no message at all.
		const reopen = () => {
			// Only if it is still the entry we looked at; a concurrent send may
			// already have replaced it.
			if (dmLines.get(key) === existing) dmLines.delete(key);
			return openDm(peer);
		};
		return existing.then((line) => (line.live ? line : reopen()), reopen);
	}
	if (!dir) return Promise.reject(new Error("not connected"));
	const line = DirectMessage.open(dir, peer, (from, text) => receiveDmReply(peer, from, text));
	dmLines.set(key, line);
	return line;
}

// A member replied to us over the direct connection. Paint it in the peer's DM
// thread as an incoming line, and ring the notice if the thread is not on screen.
function receiveDmReply(peer: string, from: string, text: string): void {
	const conv = ensureDm(peer);
	if (!conv.ready) {
		conv.ready = true;
		renderDmStatus(conv);
		renderDms();
	}
	deliver(conv, chatItem(from || peer, text, false));
	if (activeConv()?.key !== conv.key) maybeNotify(from || peer, text);
}

// Who is reachable for direct messages changed: repaint the DM sidebar pips and
// whichever conversation is on screen — a room's roster (its Message buttons) or
// an open DM's header status.
function refreshDmViews(): void {
	renderDms();
	const active = activeConv();
	if (active?.type === "room") renderPresence(active);
	else if (active?.type === "dm") renderDmStatus(active);
}

// Another member's typing flag in the joined room, tracked per-room with an
// auto-clear timer so a dropped "off" still fades.
function setRoomTyping(from: string, on: boolean): void {
	if (!state.joinedRoom || from === state.nick) return;
	const conv = ensureRoom(state.joinedRoom);
	const existing = conv.typers.get(from);
	if (existing) clearTimeout(existing);
	if (on) {
		conv.typers.set(
			from,
			setTimeout(() => {
				conv.typers.delete(from);
				renderTyping(conv);
			}, 6000),
		);
	} else conv.typers.delete(from);
	renderTyping(conv);
}

function reason(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

// ── Connection ────────────────────────────────────────────────────────────
export function connect(): void {
	setStatus("connecting", everConnected ? "reconnecting…" : "connecting…");
	if (everConnected && state.joinedRoom) setBanner("Reconnecting…");
	void openSession();
}

async function openSession(): Promise<void> {
	try {
		// Instantiate the wasm peer once; its adapter injection lets the stack's
		// `connect` (which `Directory.connect` rides) dial over the relay. Cache
		// only a *resolved* init: `/pancake_driver.wasm` answers 503 until the
		// module is built, so a first attempt can lose that race — a rejected
		// promise left cached would make every reconnect re-await the same failure
		// forever instead of retrying once the asset is live.
		if (stackReady === null) {
			const attempt = init({
				wasm: fetch("/pancake_driver.wasm"),
				wsUrl: relayWsUrl,
				relayUrl: relayLocatorUrl,
				rendezvousUrl: relayRendezvousUrl,
			});
			attempt.catch(() => {
				if (stackReady === attempt) stackReady = null;
			});
			stackReady = attempt;
		}
		await stackReady;
		// The inbox host both dials the directory and accepts cold-dials, so start
		// it before the dial: the directory session must ride the same host whose
		// gift registry a later cold-dial withdraws from.
		const host = ensureInbox();
		const locator = (await (await fetch("/locator")).text()).trim();
		// Dial transport-neutrally, the same as every terminal client: the rooms
		// `dial` normalises a bare `host:port` into a `tcp` locator and passes an
		// `ocapn://…iroh` URI through, both routed over the relay by the injected
		// browser adapter. The stack's default `connect` would reject the bare
		// designator `/locator` serves.
		const next = await Directory.connect(locator, (l) => dial(l, host));
		dir = next;
		// Publish `dm` on the directory session so the room's `register` can fetch
		// it to mint our introduction. The same object is the host giftable that
		// answers cold-dials; here it is the session-bootstrap name `register`
		// fetches by. A reconnect mints a fresh directory session, so re-publish.
		next.session.publish(DM, inboxDm);

		const seen = await next.watch((event) => {
			switch (event.kind) {
				case "closed":
					liveRooms.delete(event.name);
					renderRooms();
					break;
				case "registered":
					dmablePeers.add(event.name.toLowerCase());
					refreshDmViews();
					break;
				case "unregistered":
					dmablePeers.delete(event.name.toLowerCase());
					dmLines.delete(event.name.toLowerCase()); // a gone member's line is stale
					refreshDmViews();
					break;
				default:
					liveRooms.set(event.name, event.count);
					renderRooms();
					break;
			}
		});
		liveRooms.clear();
		for (const room of seen) liveRooms.set(room.name, room.count);
		renderRooms();

		setBanner("");
		if (everConnected && state.joinedRoom) toActive(sysItem("Reconnected"));
		everConnected = true;

		// A dropped directory session (the server respawning) reconnects the page.
		next.session.serve().finally(() => onDisconnected(next)).catch(() => {});
		// Reset the backoff only once this session has *survived* a stability
		// window, not the instant the handshake reached `watch`. A server that
		// accepts, answers `watch`, then drops immediately (a post-accept crash
		// loop) would otherwise re-earn the reset every cycle and reconnect every
		// 500 ms — a storm, not a backoff. Cleared in `onDisconnected` if the
		// session dies before the window elapses.
		if (stableTimer !== null) clearTimeout(stableTimer);
		stableTimer = setTimeout(() => {
			backoff = 500;
			stableTimer = null;
		}, BACKOFF_STABLE_MS);

		// If we were in a room, re-enter it. Otherwise honour a join the user
		// asked for while this session was still opening, and only then wait.
		if (state.joinedRoom && state.nick) {
			setStatus("connecting", "rejoining #" + state.joinedRoom + "…");
			void enterRoom(state.joinedRoom, state.nick);
		} else if (pendingJoin) {
			const wanted = pendingJoin;
			pendingJoin = null;
			state.nick = wanted.nick;
			setStatus("connecting", "entering #" + wanted.room + "…");
			void enterRoom(wanted.room, wanted.nick);
		} else setStatus("connecting", "pick a room");
	} catch (err) {
		// Surface the real cause for the devtools console; the user sees a plain
		// retry line, but a blocked ws (an http page over https, say) or a wasm
		// load failure is otherwise invisible.
		console.error("rooms: could not open the peer session:", err);
		if (!state.joinedRoom) {
			// A staged join is not lost on a failed attempt: the retry below
			// opens another session, which replays it. The button comes back so
			// the user can change their mind.
			resetJoinButton();
			setJoinError("could not reach the room server; retrying…");
		}
		scheduleReconnect();
	}
}

function onDisconnected(which: Directory): void {
	if (dir !== which) return; // already replaced by a newer session
	dir = null;
	currentRoom = null;
	// This session died before it proved stable, so cancel the pending
	// backoff-reset: the next reconnect keeps climbing rather than storming.
	if (stableTimer !== null) {
		clearTimeout(stableTimer);
		stableTimer = null;
	}
	// Every cached direct line was bound to this dead session (web.ts respawns the room
	// server, so a reconnect mints a fresh one). Drop them, forget who was reachable, and
	// reset each DM conversation to "not yet live" — the new session's `watch` replays the
	// `registered` events, so `dmablePeers` and the pips repopulate. Then repaint the DM
	// views so their reachability shows the truth of the moment.
	dmLines.clear();
	// Drop every reply back-channel and our advertised presence on a directory
	// reconnect. This is conservative: a cold-dial back-channel is captured on the
	// inbox host (which persists past a room-server respawn), so it is not truly
	// dead — but telling it apart from a directory-introduced one is not worth the
	// bookkeeping, and each recovers on the next send via a fresh introduction.
	// The reconnect re-advertises our presence.
	dmBackChannels.clear();
	advertisedNick = null;
	dmablePeers.clear();
	for (const conv of convs.values()) if (conv.type === "dm") conv.ready = false;
	refreshDmViews();
	// Our own room lines still awaiting an echo will never get one on this session, so mark
	// them failed and tap-to-retry rather than leaving them dimmed forever.
	for (const item of pendingRoomSends.splice(0)) {
		item.state = "failed";
		refreshSendState(item);
	}
	setStatus("reconnecting", "reconnecting…");
	if (state.joinedRoom) setBanner("Reconnecting…");
	setComposerEnabled(false);
	scheduleReconnect();
}

function scheduleReconnect(): void {
	setTimeout(connect, backoff);
	backoff = Math.min(backoff * 2, 5000);
}

// End our rendezvous registration when the tab goes away. The relay reclaims a
// dropped socket on its own (its idle ping/pong), so this is a courtesy close,
// not a correctness requirement; a browser is a rendezvous, not a mailbox.
globalThis.addEventListener("beforeunload", () => {
	rendezvous?.stop();
});
