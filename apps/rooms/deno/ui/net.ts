// The rooms page's data layer, as a real OCapN peer in the browser. The page
// instantiates the pancake stack
// over `@pancake/web` (the wasm Host, no dlopen), dials the room server
// through web.ts's `/relay` byte pipe, and drives the directory and room as
// capabilities — the same `lib/room_client.ts` the terminal clients use. No
// JSON bridge: the browser holds the room capability itself.
//
// Public chat is a browser peer here. Direct messages stay a later milestone:
// a browser has no locator another peer can dial, and the relay only reaches
// the room server, so a DM in either direction needs relay-by-member routing
// and a browser-to-browser path. The DM surface below explains that rather
// than pretending.

import { init } from "@pancake/web";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";
import { Directory, Room } from "../../lib/room_client.ts";
import { enterOrOpen } from "../lib/enter_room.ts";
import { NICK_TAKEN } from "../../lib/errors.ts";
import { roomErrorOf } from "../lib/errors.ts";
import {
	app,
	composer,
	joinBtn,
	joinScreen,
	membersToggle,
	newDmBtn,
	nickInput,
	roomInput,
} from "./dom.ts";
import {
	activeConv,
	chatItem,
	convKey,
	convs,
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
	renderDms,
	renderRooms,
	renderTyping,
	setBanner,
	setComposerEnabled,
	setJoinError,
	setStatus,
	switchTo,
	toActive,
} from "./render.ts";
import { maybeNotify } from "./notify.ts";
import { mentionsYou } from "./richtext.ts";

/** The one message the page sends its data layer, replacing the old JSON
 * `Inbound`: a room line, a typing flag, or a direct-message attempt. */
type Outgoing =
	| { say: string }
	| { typing: boolean }
	| { dmSay: { to: string; text: string } };

let userPickedRoom = false; // set when the user taps a room, so entering switches to it
let stackReady: Promise<unknown> | null = null;
let dir: Directory | null = null;
let currentRoom: Room | null = null;
let pumpToken = 0; // bumped on each room switch so a stale pump stops delivering
let backoff = 500;
let everConnected = false;

// The wasm peer maps every dial's host:port to web.ts's relay on this origin,
// so the keyed OCapN session rides a WebSocket to the page's own server. Match
// the page's scheme: an HTTPS page (a forwarded or deployed origin) must use
// `wss://`, or the browser blocks the insecure socket as mixed content.
function relayWsUrl(host: string, port: number): string {
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${location.host}/relay?to=${host}:${port}`;
}

// A native-only locator (an iroh room server) rides the same relay by URI:
// web.ts dials it with `dialLocatorForRelay` and pipes the bytes.
function relayLocatorUrl(locator: string): string {
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${location.host}/relay?locator=${encodeURIComponent(locator)}`;
}

export function isConnected(): boolean {
	return dir !== null;
}

export function send(msg: Outgoing): void {
	if ("say" in msg) {
		currentRoom?.say(msg.say).catch(() => {});
	} else if ("typing" in msg) {
		currentRoom?.setTyping(msg.typing).catch(() => {});
	} else if ("dmSay" in msg) {
		dmUnavailable(msg.dmSay.to);
	}
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
	setStatus("connecting", "entering #" + room + "…");
	void enterRoom(room, state.nick);
}

function rejectJoin(text: string): void {
	userPickedRoom = false;
	composer.hidden = true;
	membersToggle.hidden = true;
	joinScreen.style.display = "";
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
async function enterRoom(name: string, nick: string): Promise<void> {
	if (!dir) return;
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
		enteredRoom(name);
		void pump(next);
	} catch (err) {
		const re = roomErrorOf(err);
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
async function pump(room: Room): Promise<void> {
	const token = ++pumpToken;
	try {
		for await (const { from, text, system, presence } of room.messages) {
			if (token !== pumpToken) return;
			const roomConv = state.joinedRoom ? ensureRoom(state.joinedRoom) : null;
			if (!roomConv) continue;
			if (presence) applyPresence(roomConv, presence);
			if (system) deliver(roomConv, sysItem(text));
			else {
				const mine = from === state.nick;
				deliver(roomConv, chatItem(from, text, mine));
				if (!mine && mentionsYou(text)) {
					maybeNotify("#" + state.joinedRoom + " · " + from, text);
				}
			}
		}
	} catch { /* the stream ended under us */ }
}

// ── Direct messages: a later milestone in the browser ─────────────────────
// A browser has no locator another peer can dial, and the relay only reaches
// the room server, so neither direction of a DM works yet. Explain it in the
// thread instead of failing silently or pretending it went through.
const DM_PENDING = "Direct messages from the browser are coming in a later milestone: a browser " +
	"peer has no address another member can dial, and the byte relay reaches only " +
	"the room server for now. Public rooms already run as a real peer.";

export function startDm(peer: string): void {
	if (!peer) return;
	if (state.nick && peer.toLowerCase() === state.nick.toLowerCase()) {
		toActive(sysItem("You can't start a direct message with yourself."));
		return;
	}
	const conv = ensureDm(peer);
	if (!conv.noted) {
		conv.noted = true;
		conv.history.push(sysItem(DM_PENDING));
	}
	switchTo(conv.key);
}

function dmUnavailable(peer: string): void {
	const conv = ensureDm(peer);
	deliver(conv, sysItem(DM_PENDING));
	renderDms();
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
		// `connect` (which `Directory.connect` rides) dial over the relay.
		stackReady ??= init({
			wasm: fetch("/pancake_driver.wasm"),
			wsUrl: relayWsUrl,
			relayUrl: relayLocatorUrl,
		});
		await stackReady;
		const locator = (await (await fetch("/locator")).text()).trim();
		const next = await Directory.connect(locator);
		dir = next;

		const seen = await next.watch((event) => {
			switch (event.kind) {
				case "closed":
					liveRooms.delete(event.name);
					renderRooms();
					break;
				case "registered":
				case "unregistered":
					break; // DM membership is a later milestone
				default:
					liveRooms.set(event.name, event.count);
					renderRooms();
					break;
			}
		});
		liveRooms.clear();
		for (const room of seen) liveRooms.set(room.name, room.count);
		renderRooms();

		backoff = 500;
		setBanner("");
		if (everConnected && state.joinedRoom) toActive(sysItem("Reconnected"));
		everConnected = true;

		// A dropped directory session (the server respawning) reconnects the page.
		next.session.serve().finally(() => onDisconnected(next)).catch(() => {});

		// If we were in a room, re-enter it; otherwise wait for the user to pick.
		if (state.joinedRoom && state.nick) {
			setStatus("connecting", "rejoining #" + state.joinedRoom + "…");
			void enterRoom(state.joinedRoom, state.nick);
		} else setStatus("connecting", "pick a room");
	} catch (err) {
		// Surface the real cause for the devtools console; the user sees a plain
		// retry line, but a blocked ws (an http page over https, say) or a wasm
		// load failure is otherwise invisible.
		console.error("rooms: could not open the peer session:", err);
		if (!state.joinedRoom) {
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
	setStatus("reconnecting", "reconnecting…");
	if (state.joinedRoom) setBanner("Reconnecting…");
	setComposerEnabled(false);
	scheduleReconnect();
}

function scheduleReconnect(): void {
	setTimeout(connect, backoff);
	backoff = Math.min(backoff * 2, 5000);
}
