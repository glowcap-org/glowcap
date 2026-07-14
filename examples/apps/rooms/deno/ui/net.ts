import { MAX_NICK, MAX_ROOM } from "../lib/wire.ts";
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
	dmablePeers,
	ensureDm,
	ensureRoom,
	liveRooms,
	LS,
	noteItem,
	state,
	sysItem,
} from "./state.ts";
import {
	applyPresence,
	deliver,
	renderDms,
	renderDmStatus,
	renderPresence,
	renderRooms,
	renderTyping,
	setBanner,
	setComposerEnabled,
	setJoinError,
	setStatus,
	switchTo,
	toActive,
	transportLabel,
} from "./render.ts";
import { maybeNotify } from "./notify.ts";
import { mentionsYou } from "./richtext.ts";
import { type Inbound, Outbound } from "../lib/wire.ts";

let userPickedRoom = false; // set when the user taps a room, so entering switches to it even from a DM
export let ws: WebSocket | null = null;
let backoff = 500;
let everConnected = false;

export function send(msg: Inbound) {
	if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

// ── Rooms: picking, creating, joining ─────────────────────────────────────
export function pickRoom(name: string) {
	if (state.joinedRoom && state.nick && ws && ws.readyState === WebSocket.OPEN) {
		const key = convKey("room", name);
		// Tapping the room you are already in: nothing to switch, but on mobile the
		// list is covering it, so close the list to reveal the conversation.
		if (key === state.activeKey) {
			app.classList.remove("show-list");
			return;
		}
		// If we already hold this room, just show it; otherwise ask to enter it.
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
export function switchRoom(name: string) {
	userPickedRoom = true; // explicit navigation: entering the room should switch to it
	setStatus("connecting", "entering #" + name + "…");
	send({ join: { room: name, nick: state.nick } });
}
export function join() {
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
	send({ join: { room, nick: state.nick } });
}
export function rejectJoin(text: string) {
	userPickedRoom = false;
	composer.hidden = true;
	membersToggle.hidden = true;
	joinScreen.style.display = "";
	resetJoinButton();
	setJoinError(text);
	setStatus("disconnected", "pick another name");
}

/** Put the join form back in a usable state after a refused enter/open. */
function resetJoinButton() {
	joinBtn.disabled = false;
	joinBtn.textContent = "Join room";
}
// The server confirmed us in a room. Show it, creating its conversation
// on first entry.
export function enteredRoom(name: string) {
	state.joinedRoom = name;
	const conv = ensureRoom(name);
	conv.members.clear();
	LS.set("rooms.nick", state.nick);
	LS.set("rooms.room", name);
	setStatus("connected", "connected as " + state.nick);
	newDmBtn.hidden = false;
	// Once joined there is a list to go back to, so reveal the mobile back button.
	app.classList.add("joined");
	// Switch to the room when the user picked it (even from a DM) or when nothing
	// else is on screen. A reconnect that replays the join while you are reading a
	// direct message keeps you in that DM rather than yanking you to the room; the
	// disconnect disabled the composer, so re-enable it and refresh the sidebar
	// without switching.
	const cur = activeConv();
	if (userPickedRoom || !cur || cur.type === "room") switchTo(conv.key);
	else {
		setComposerEnabled(true);
		renderRooms();
		renderDms();
	}
	userPickedRoom = false;
}

// ── Direct messages: starting and receiving ───────────────────────────────
// Ask the bridge to introduce us to a peer, and open the thread right away with
// a pending note. The confirmation (or a failure) replaces the pending state.
export function startDm(peer: string) {
	if (!peer) return;
	if (state.nick && peer.toLowerCase() === state.nick.toLowerCase()) {
		toActive(sysItem("You can't start a direct message with yourself."));
		return;
	}
	const conv = ensureDm(peer);
	if (!conv.noted) {
		conv.noted = true;
		conv.history.push(noteItem(
			"Direct message with " + peer,
			"Introducing you to " + peer +
				" through the room… once redeemed, messages go straight to them.",
		));
	}
	send({ dmOpen: { to: peer } });
	switchTo(conv.key);
}
export function dmReady(peer: string) {
	const conv = ensureDm(peer);
	const wasReady = conv.ready;
	conv.ready = true;
	if (!conv.noted) {
		conv.noted = true;
		deliver(
			conv,
			noteItem(
				"Direct message with " + peer,
				"You were introduced by the room. Messages now travel over " +
					transportLabel() +
					" straight to " + peer +
					". The room server is no longer on the path.",
			),
		);
	} else if (!wasReady) {
		deliver(
			conv,
			sysItem(
				"Introduction redeemed — you are now talking directly, over " +
					transportLabel() +
					".",
			),
		);
	}
	renderDmStatus(conv);
	renderDms();
}
export function dmFrom(peer: string, text: string) {
	const isNew = !convs.has(convKey("dm", peer));
	const conv = ensureDm(peer);
	if (isNew && !conv.noted) {
		conv.noted = true;
		conv.ready = true;
		conv.history.push(noteItem(
			"Direct message with " + peer,
			peer + " was introduced to you and reached you directly over " +
				transportLabel() +
				". This conversation does not pass through the room server.",
		));
	}
	conv.ready = true;
	deliver(conv, chatItem(peer, text, false));
	if (conv.key !== state.activeKey || document.hidden) {
		maybeNotify("Direct message · " + peer, text);
	}
	renderDms();
}
export function dmFailed(peer: string, offline: boolean, text?: string) {
	const conv = ensureDm(peer);
	conv.ready = false;
	// The bridge already told us whether the peer is simply offline (a typed flag on
	// the wire, not a scraped message); everything else is a transient we describe in
	// plain English without leaking internals.
	const why = offline
		? peer + " is offline right now, so your message wasn't delivered."
		: text
		? "Couldn't deliver your message to " + peer + " right now."
		: "Couldn't reach " + peer + " right now.";
	deliver(conv, sysItem(why));
	renderDms();
}
// The directory's set of DM-able members changed. Give each direct line the same
// presence treatment a room gives its roster: announce the peer coming and going
// in that conversation, the way a room announces a join or a leave. A peer that
// re-registers returns at a new endpoint, so the old direct line is void on any
// transition; clear the ready flag so the next message re-introduces rather than
// sending into a dead endpoint. The offline/online state also drives the sidebar
// pip and the header, both refreshed once at the end.
export function updateDmable(list: string[]) {
	const next = new Set<string>();
	for (const name of list) next.add(String(name).toLowerCase());
	for (const conv of convs.values()) {
		if (conv.type !== "dm") continue;
		const key = conv.id.toLowerCase();
		const was = dmablePeers.has(key), now = next.has(key);
		if (was === now) continue;
		conv.ready = false;
		deliver(
			conv,
			sysItem(
				now
					? conv.id +
						" is back online — your next message opens a fresh direct line."
					: conv.id +
						" went offline — messages resume when they return.",
			),
		);
	}
	dmablePeers.clear();
	for (const key of next) dmablePeers.add(key);
	renderDms();
	const conv = activeConv();
	if (conv && conv.type === "room") renderPresence(conv);
	else if (conv) renderDmStatus(conv);
}

// Another member's typing flag in the joined room. Track it per-room with an
// auto-clear timer, so a dropped "off" — a member who vanished mid-keystroke —
// still lets the indicator fade instead of sticking. Our own flag never arrives
// (the room excludes the typer), but guard against it anyway.
function setRoomTyping(from: string, on: boolean) {
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
	} else {
		conv.typers.delete(from);
	}
	renderTyping(conv);
}

// ── Connection ────────────────────────────────────────────────────────────
export function connect() {
	setStatus("connecting", everConnected ? "reconnecting…" : "connecting…");
	if (everConnected && state.joinedRoom) setBanner("Reconnecting…");
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	ws = new WebSocket(proto + location.host + "/ws");

	ws.onopen = () => {
		backoff = 500;
		setBanner("");
		if (everConnected && state.joinedRoom) toActive(sysItem("Reconnected"));
		everConnected = true;
		// If we were in a room, replay the join to be put back and re-registered for
		// DMs; otherwise wait for the user to pick one.
		if (state.joinedRoom && state.nick) {
			setStatus("connecting", "rejoining #" + state.joinedRoom + "…");
			send({ join: { room: state.joinedRoom, nick: state.nick } });
		} else setStatus("connecting", "pick a room");
	};
	ws.onmessage = (event) => {
		let raw: unknown;
		try {
			raw = JSON.parse(event.data);
		} catch {
			return; // ignore malformed frames
		}
		// Validate against the wire schema; drop anything that is not a known message.
		// Past this point the fields are the declared types, so no coercion is needed.
		const parsed = Outbound.safeParse(raw);
		if (!parsed.success) return;
		const m = parsed.data;
		if ("rooms" in m) {
			liveRooms.clear();
			for (const [name, count] of m.rooms) liveRooms.set(name, count);
			renderRooms();
			return;
		}
		if ("dmable" in m) {
			updateDmable(m.dmable);
			return;
		}
		if ("dmSelf" in m) {
			state.transport = m.dmSelf.transport;
			return;
		}
		if ("nameTaken" in m) {
			rejectJoin(m.nameTaken);
			return;
		}
		if ("joined" in m) {
			enteredRoom(m.joined);
			return;
		}
		if ("dmReady" in m) {
			dmReady(m.dmReady.peer);
			return;
		}
		if ("dmFrom" in m) {
			dmFrom(m.dmFrom.peer, m.dmFrom.text);
			return;
		}
		if ("dmFailed" in m) {
			dmFailed(m.dmFailed.peer, m.dmFailed.offline, m.dmFailed.text);
			return;
		}
		if ("typing" in m) {
			setRoomTyping(m.typing.from, m.typing.on);
			return;
		}
		if ("notice" in m) {
			// A join/enter refusal arrives as a notice. Before we have a room,
			// there is no active conversation to paint into — surface it on the
			// join form and unlock the button so the attempt is not stranded.
			if (!state.joinedRoom) {
				resetJoinButton();
				setJoinError(m.notice);
				setStatus("disconnected", "could not join");
				return;
			}
			const conv = activeConv();
			if (conv) toActive(sysItem(m.notice));
			else setBanner(m.notice);
			return;
		}
		// A room line: route it to the joined room's conversation.
		const roomConv = state.joinedRoom ? ensureRoom(state.joinedRoom) : null;
		if (!roomConv) return;
		if (m.presence) applyPresence(roomConv, m.presence);
		if (m.from === "room") deliver(roomConv, sysItem(m.text));
		else {
			const mine = m.from === state.nick;
			deliver(roomConv, chatItem(m.from, m.text, mine));
			if (!mine && mentionsYou(m.text)) {
				maybeNotify("#" + state.joinedRoom + " · " + m.from, m.text);
			}
		}
	};
	ws.onclose = () => {
		setStatus("reconnecting", "reconnecting…");
		if (state.joinedRoom) setBanner("Reconnecting…");
		setComposerEnabled(false);
		// A fresh bridge means fresh direct-message capabilities; drop the "live"
		// marker so the next message re-introduces, but keep the visible history.
		for (const c of convs.values()) if (c.type === "dm") c.ready = false;
		renderDms();
		setTimeout(connect, backoff);
		backoff = Math.min(backoff * 2, 5000);
	};
	ws.onerror = () => {
		try {
			ws?.close();
		} catch { /* already closing */ }
	};
}

// Prove this tab is alive to the bridge on a steady beat. A tab that vanishes —
// a crash, a killed process, a dropped network — never sends a WebSocket close,
// so the bridge cannot tell it apart from an idle one by the socket alone. These
// pings are that signal: when they stop, the bridge drops our room membership
// instead of leaving a ghost member shown online to everyone. Harmless while
// disconnected — `send` is a no-op unless the socket is open.
setInterval(() => send({ ping: true }), 15000);
