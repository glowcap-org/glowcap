import {
	app,
	backBtn,
	banner,
	composer,
	content,
	dmListEl,
	dot,
	emojiBtn,
	emojiPop,
	isMobile,
	joinScreen,
	jumpBtn,
	lineInput,
	log,
	membersEl,
	membersToggle,
	nickError,
	nickInput,
	notifyToggle,
	presenceSummary,
	provenance,
	provenanceText,
	roomListEl,
	roomMeta,
	roomName,
	roomSigil,
	sendBtn,
	statusEl,
	typingEl,
} from "./dom.ts";
import type { ActionItem, ChatItem, Conv, DmConv, Item, RoomConv, SysItem } from "./types.ts";
import type { Presence } from "../../lib/limits.ts";
import { activeConv, convKey, convs, dmablePeers, liveRooms, state } from "./state.ts";
import { fmtTime, hueOf, initials, makeBubble, mentionsYou } from "./richtext.ts";
import { autoGrow, insertMention, stopTyping } from "./composer.ts";
import { pickRoom, retrySend, startDm } from "./net.ts";
import { renderNotifyBtn } from "./notify.ts";

// Grouping and divider state for the conversation currently painted in the log.
let lastGroup: { from: string | null; at: number } = { from: null, at: 0 };
let lastDayKey = "";
let unreadDivider: HTMLElement | null = null;

// The bubble painted for each of our own optimistic sends, so net.ts can reconcile a
// line in place — clearing its "sending" tint when the wire confirms it, or tinting it
// "failed" and making it tap-to-retry when the send rejects — without repainting the
// whole log. The map is weak, so an item that scrolls out of a switched-away
// conversation is collected with its history.
const sendBubbles = new WeakMap<ChatItem, HTMLElement>();
// Reflect an item's current send state onto its bubble: a "sending" line dims, a
// "failed" line tints and becomes a button that re-sends on click or Enter/Space, and a
// confirmed line (state cleared) returns to a plain bubble.
function applySendState(item: ChatItem, bubble: HTMLElement) {
	bubble.classList.toggle("sending", item.state === "sending");
	bubble.classList.toggle("failed", item.state === "failed");
	if (item.state === "failed") {
		bubble.title = "Not sent — tap to retry";
		bubble.setAttribute("role", "button");
		bubble.setAttribute("tabindex", "0");
		bubble.setAttribute("aria-label", "Message not sent, tap to retry");
		bubble.onclick = () => retrySend(item);
		bubble.onkeydown = (e) => {
			if (e.key === "Enter" || e.key === " ") {
				e.preventDefault();
				retrySend(item);
			}
		};
	} else {
		if (item.state === "sending") bubble.title = "Sending…";
		else bubble.removeAttribute("title");
		bubble.removeAttribute("role");
		bubble.removeAttribute("tabindex");
		bubble.removeAttribute("aria-label");
		bubble.onclick = null;
		bubble.onkeydown = null;
	}
}
// Called by net.ts after it mutates an item's send state, to repaint just that bubble.
export function refreshSendState(item: ChatItem) {
	const bubble = sendBubbles.get(item);
	if (bubble) applySendState(item, bubble);
}

// A small hover toolbar per message: copy the text, or drop an @mention of the
// author into the composer.
export function makeActs(from: string): HTMLElement {
	const acts = document.createElement("div");
	acts.className = "acts";
	const copy = document.createElement("button");
	copy.type = "button";
	copy.title = "Copy message";
	copy.textContent = "Copy";
	copy.onclick = () => {
		const row = copy.closest(".row");
		if (!row) return;
		const txt = [...row.querySelectorAll(".bubble")].map((b) => b.textContent).join("\n");
		if (navigator.clipboard) {
			navigator.clipboard.writeText(txt).catch(() => {});
		}
	};
	const reply = document.createElement("button");
	reply.type = "button";
	reply.title = "Mention " + from;
	reply.textContent = "@";
	reply.onclick = () => insertMention(from);
	acts.append(copy, reply);
	return acts;
}

// ── Painting one item into the log (pure DOM append) ──────────────────────
function dayKey(d: Date): string {
	return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
}
function dayLabel(d: Date): string {
	const today = new Date(), yest = new Date();
	yest.setDate(today.getDate() - 1);
	if (dayKey(d) === dayKey(today)) return "Today";
	if (dayKey(d) === dayKey(yest)) return "Yesterday";
	return d.toLocaleDateString(undefined, {
		weekday: "long",
		month: "long",
		day: "numeric",
	});
}
function maybeDayDivider(at: number) {
	const d = new Date(at), k = dayKey(d);
	if (k === lastDayKey) return;
	lastDayKey = k;
	const div = document.createElement("div");
	div.className = "divider day";
	const span = document.createElement("span");
	span.textContent = dayLabel(d);
	div.append(span);
	log.append(div);
}
export function ensureUnreadDivider() {
	if (unreadDivider) return;
	unreadDivider = document.createElement("div");
	unreadDivider.className = "divider unread";
	const span = document.createElement("span");
	span.textContent = "New messages";
	unreadDivider.append(span);
	log.append(unreadDivider);
}
export function clearUnreadDivider() {
	if (unreadDivider) {
		unreadDivider.remove();
		unreadDivider = null;
	}
}

function paintChat(item: ChatItem) {
	const from = item.from, text = item.text, mine = item.mine, now = item.at;
	if (text.slice(0, 4) === "/me ") {
		paintAction({ kind: "action", from, text: text.slice(4), at: now });
		return;
	}
	maybeDayDivider(now);
	const mentioned = !mine && mentionsYou(text);
	const last = log.lastElementChild as HTMLElement | null;
	const grouped = lastGroup.from === from &&
		(now - lastGroup.at) < 5 * 60 * 1000 &&
		!!last && last.classList.contains("row") && last.dataset.from === from;
	if (grouped) {
		const stack = last!.querySelector(".stack")!;
		const time = stack.querySelector(".time")!;
		const bubble = makeBubble(text, mentioned);
		stack.insertBefore(bubble, time);
		sendBubbles.set(item, bubble);
		applySendState(item, bubble);
		time.textContent = fmtTime(new Date(now));
	} else {
		const row = document.createElement("div");
		row.className = "row " + (mine ? "mine" : "them");
		row.dataset.from = from;
		const stack = document.createElement("div");
		stack.className = "stack";
		if (!mine) {
			const who = document.createElement("div");
			who.className = "who";
			who.textContent = from;
			stack.append(who);
		}
		const time = document.createElement("div");
		time.className = "time";
		// The bubble already carries its author and the sidebar its arrival, so the
		// per-line timestamp is decorative for a screen reader; hide it from the tree.
		time.setAttribute("aria-hidden", "true");
		time.textContent = fmtTime(new Date(now));
		const bubble = makeBubble(text, mentioned);
		stack.append(bubble, time);
		sendBubbles.set(item, bubble);
		applySendState(item, bubble);
		if (mine) {
			row.append(stack);
		} else {
			const av = document.createElement("div");
			av.className = "avatar";
			// Purely a coloured initial; the author is already spoken in the `who` line.
			av.setAttribute("aria-hidden", "true");
			av.style.background = hueOf(from);
			av.textContent = initials(from);
			row.append(av, stack);
		}
		row.append(makeActs(from));
		log.append(row);
	}
	lastGroup = { from, at: now };
}
// A single-line banner in the log (a system notice or a `/me` action): one
// `<div class=cls><span>text</span>`, breaking any active message grouping.
function paintBanner(cls: string, text: string, at: number) {
	maybeDayDivider(at);
	const box = document.createElement("div");
	box.className = cls;
	const span = document.createElement("span");
	span.textContent = text;
	box.append(span);
	log.append(box);
	lastGroup = { from: null, at: 0 };
}
function paintAction(item: ActionItem) {
	paintBanner("sys action", "✻ " + item.from + " " + item.text, item.at);
}
function paintSys(item: SysItem) {
	paintBanner("sys", item.text, item.at);
}
function paint(item: Item) {
	if (item.kind === "chat") paintChat(item);
	else if (item.kind === "action") paintAction(item);
	else paintSys(item);
}

// ── Autoscroll ────────────────────────────────────────────────────────────
// The scroll region differs by device: on desktop the message log is its own
// overflow area; on mobile the whole document scrolls, like a native chat. Route
// every scroll read/write through these so both share one path and desktop is
// unchanged (scroller() is the log there).
export function scroller(): Element {
	return isMobile() ? (document.scrollingElement || document.documentElement) : log;
}
export function nearBottom(): boolean {
	const e = scroller();
	return e.scrollHeight - e.scrollTop - e.clientHeight < 80;
}
export function toBottom(): void {
	const e = scroller();
	e.scrollTop = e.scrollHeight;
}
function afterAppend(pinned: boolean) {
	if (pinned) {
		toBottom();
		jumpBtn.classList.remove("show");
	} else jumpBtn.classList.add("show");
}

// ── Delivering an item to a conversation ──────────────────────────────────
// If the conversation is the one on screen, paint it; otherwise store it and
// raise the sidebar's unread badge. Either way it is kept in history.
export function deliver(conv: Conv, item: Item) {
	conv.history.push(item);
	const onScreen = conv.key === state.activeKey && !document.hidden;
	if (conv.key === state.activeKey) {
		const pinned = nearBottom() || (item.kind === "chat" && item.mine);
		if (document.hidden) ensureUnreadDivider();
		paint(item);
		afterAppend(pinned);
	}
	// Anything not on screen right now counts toward the unread badges: the DM
	// sidebar entry (the room list shows member counts, not unread) and the tab
	// title. System lines do not.
	if (!onScreen && (item.kind === "chat" || item.kind === "action")) {
		conv.unread += 1;
		renderDms();
	}
	updateTitle();
}
// Deliver to the active conversation regardless of type (local notices).
export function toActive(item: Item) {
	const conv = activeConv();
	if (conv) deliver(conv, item);
}

// Repaint the whole log from a conversation's history (used on switch).
export function renderConv(conv: Conv) {
	// Silence the log's live region while we repaint the whole history, so a screen
	// reader announces new arrivals rather than the entire backlog every time you
	// open a conversation. It is restored on the next frame, once the repaint settles.
	log.setAttribute("aria-live", "off");
	log.innerHTML = "";
	lastGroup = { from: null, at: 0 };
	lastDayKey = "";
	unreadDivider = null;
	for (const item of conv.history) paint(item);
	// Land at the newest message on entry. The immediate call covers the common
	// case; the next-frame call covers a long conversation that has not finished
	// laying out yet (especially the mobile page-scroll), so it actually reaches
	// the bottom instead of falling a screen short.
	toBottom();
	requestAnimationFrame(() => {
		toBottom();
		log.setAttribute("aria-live", "polite");
	});
	jumpBtn.classList.remove("show");
}

// ── Sidebar: rooms and direct messages ────────────────────────────────────
// A sidebar entry is a clickable <li>, so make it a real button for the
// keyboard too: a role, a tab stop, a label, and Enter/Space activation.
function activate(node: HTMLElement, label: string, fn: () => void) {
	node.setAttribute("role", "button");
	node.setAttribute("tabindex", "0");
	node.setAttribute("aria-label", label);
	node.onclick = fn;
	node.onkeydown = (e) => {
		if (e.key === "Enter" || e.key === " ") {
			e.preventDefault();
			fn();
		}
	};
}
// The placeholder row a sidebar or roster shows when it has nothing to list.
function appendEmpty(listEl: HTMLElement, text: string): void {
	const empty = document.createElement("li");
	empty.className = "empty";
	empty.textContent = text;
	listEl.append(empty);
}
export function renderRooms() {
	const rows = [...liveRooms.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
	roomListEl.innerHTML = "";
	if (rows.length === 0) {
		appendEmpty(roomListEl, "No rooms yet.");
		return;
	}
	for (const [name, count] of rows) {
		const li = document.createElement("li");
		const here = state.activeKey === convKey("room", name);
		if (here) li.className = "here";
		const hash = document.createElement("span");
		hash.className = "hash";
		hash.textContent = "#";
		const rname = document.createElement("span");
		rname.className = "rname";
		rname.textContent = name;
		const badge = document.createElement("span");
		badge.className = "rcount";
		badge.textContent = String(count);
		li.append(hash, rname, badge);
		activate(
			li,
			"Open room " + name + ", " + count + " here",
			() => pickRoom(name),
		);
		roomListEl.append(li);
	}
}
export function renderDms() {
	const rows = [...convs.values()].filter((c): c is DmConv => c.type === "dm")
		.sort((a, b) => a.id.localeCompare(b.id));
	dmListEl.innerHTML = "";
	if (rows.length === 0) {
		appendEmpty(
			dmListEl,
			state.joinedRoom
				? "Message a member to start one."
				: "Join a room first — then message someone from the roster.",
		);
		return;
	}
	for (const conv of rows) {
		const online = dmablePeers.has(conv.id.toLowerCase());
		const li = document.createElement("li");
		li.className = (conv.key === state.activeKey ? "here" : "") +
			(online ? "" : " off");
		const av = document.createElement("span");
		av.className = "dmavatar";
		av.setAttribute("aria-hidden", "true"); // a coloured initial beside the name, decorative
		av.style.background = hueOf(conv.id);
		av.textContent = initials(conv.id);
		const rname = document.createElement("span");
		rname.className = "rname";
		rname.textContent = conv.id;
		const pip = document.createElement("span");
		pip.className = "dmpip" + (online ? " on" : "");
		pip.title = online ? conv.id + " is online" : conv.id + " is offline";
		li.append(av, rname, pip);
		if (conv.ready) {
			const lock = document.createElement("span");
			lock.className = "lock";
			lock.textContent = "🔒";
			lock.title = "Direct, peer-to-peer";
			li.append(lock);
		}
		if (conv.unread > 0) {
			const badge = document.createElement("span");
			badge.className = "rcount";
			badge.textContent = String(conv.unread);
			li.append(badge);
		}
		activate(
			li,
			"Open direct message with " + conv.id,
			() => switchTo(conv.key),
		);
		dmListEl.append(li);
	}
}

// ── Member pane ───────────────────────────────────────────────────────────
export function applyPresence(conv: RoomConv, event: Presence | null) {
	if (!event) return;
	if (event.kind === "roster") {
		for (const name of conv.members.keys()) conv.members.set(name, false);
		for (const name of event.names) conv.members.set(name, true);
	} else {
		conv.members.set(event.name, event.kind === "join");
	}
	if (conv.key === state.activeKey) renderPresence(conv);
}
export function renderPresence(conv: RoomConv | null) {
	const members = conv ? conv.members : new Map<string, boolean>();
	const rows = [...members.entries()].sort((a, b) =>
		Number(b[1]) - Number(a[1]) || a[0].localeCompare(b[0])
	);
	const online = rows.filter(([, isOnline]) => isOnline).length;
	membersEl.innerHTML = "";
	presenceSummary.textContent = rows.length === 0
		? "Waiting for the room roster."
		: online + " online · " + rows.length + " seen";
	if (conv) roomMeta.textContent = online + " online";
	if (rows.length === 0) {
		appendEmpty(membersEl, "No members yet.");
		return;
	}
	for (const [name, isOnline] of rows) {
		const li = document.createElement("li");
		li.className = isOnline ? "online" : "offline";
		const pip = document.createElement("span");
		pip.className = "pip";
		// Presence is not carried by colour alone: the pip is a filled dot when online
		// and a hollow ring when offline, and it names the state for a screen reader.
		pip.setAttribute("role", "img");
		pip.setAttribute("aria-label", isOnline ? "online" : "offline");
		pip.title = isOnline ? "online" : "offline";
		const who = document.createElement("span");
		who.className = "name";
		who.textContent = name === state.nick ? name + " (you)" : name;
		li.append(pip, who);
		// Offer a direct line to any member the directory says is reachable, other
		// than yourself.
		if (name !== state.nick && dmablePeers.has(name.toLowerCase())) {
			const dmBtn = document.createElement("button");
			dmBtn.type = "button";
			dmBtn.className = "dm-btn";
			dmBtn.textContent = "Message";
			dmBtn.title = "Message " + name + " directly";
			dmBtn.onclick = (e) => {
				e.stopPropagation();
				startDm(name);
			};
			li.append(dmBtn);
		}
		membersEl.append(li);
	}
}

// ── Typing indicator ──────────────────────────────────────────────────────
// Show which other members of the active room are typing, in the line above the
// composer. Room-only: a direct message has no typing channel. The set is kept
// on the conversation and auto-clears (see net.ts), so this is a pure repaint —
// a no-op unless the given room is the one on screen.
function typingText(names: string[]): string {
	if (names.length === 0) return "";
	if (names.length === 1) return `${names[0]} is typing…`;
	if (names.length === 2) return `${names[0]} and ${names[1]} are typing…`;
	return `${names[0]}, ${names[1]}, and ${names.length - 2} more are typing…`;
}
export function renderTyping(conv: Conv | null) {
	const names = conv && conv.type === "room" && conv.key === state.activeKey
		? [...conv.typers.keys()].filter((n) => n !== state.nick)
		: [];
	typingEl.textContent = typingText(names);
	typingEl.classList.toggle("show", names.length > 0);
}

// ── Status, banner, join error ────────────────────────────────────────────
export function setStatus(phase: string, text: string) {
	dot.className = "dot " + phase;
	statusEl.textContent = text;
}
export function setJoinError(text: string) {
	nickError.textContent = text;
	nickInput.setAttribute("aria-invalid", text ? "true" : "false");
}
export function setBanner(text: string) {
	if (text) {
		banner.textContent = text;
		banner.classList.add("show");
	} else banner.classList.remove("show");
}

export function setComposerEnabled(on: boolean) {
	lineInput.disabled = !on;
	sendBtn.disabled = !on;
	emojiBtn.disabled = !on;
	const conv = activeConv();
	lineInput.placeholder = conv
		? (conv.type === "dm" ? "Message " + conv.id + " directly" : "Message #" + conv.id)
		: "Message";
	// Fit the box to its content as soon as it is shown, so the first render is
	// sized like every render after a keystroke, not the browser's rows=1 default.
	if (on) autoGrow();
}

export function updateTitle() {
	let badge = 0;
	for (const c of convs.values()) badge += c.unread;
	backBtn.classList.toggle("has-unread", badge > 0);
	const conv = activeConv();
	const where = conv ? (conv.type === "dm" ? "@" + conv.id : "#" + conv.id) : "";
	document.title = (badge > 0 ? "(" + badge + ") " : "") +
		(where ? where + " · " : "") +
		"pancake rooms";
}

// ── Switching the visible conversation ────────────────────────────────────
export function switchTo(key: string) {
	const conv = convs.get(key);
	if (!conv) return;
	state.activeKey = key;
	conv.unread = 0;
	// Any navigation closes the mobile list and roster overlays and shows this
	// conversation full-screen; inert on desktop where the classes are unused.
	app.classList.remove("show-list");
	app.classList.remove("members-open");
	joinScreen.style.display = "none";
	composer.hidden = false;
	setComposerEnabled(true);
	// Header, sigil, and provenance depend on the kind of conversation.
	if (conv.type === "room") {
		roomSigil.className = "hash";
		roomSigil.textContent = "#";
		roomName.textContent = conv.id;
		provenance.classList.remove("show");
		membersToggle.hidden = false;
		// Desktop honours the member-pane preference; on mobile the roster is a
		// bottom sheet, so keep the desktop column expanded (no-members off) there.
		if (isMobile()) {
			content.classList.remove("no-members");
		} else {
			content.classList.toggle("no-members", state.membersHidden);
			membersToggle.setAttribute("aria-pressed", String(!state.membersHidden));
		}
		renderPresence(conv);
	} else {
		roomSigil.className = "at";
		roomSigil.textContent = "☍"; // ☍, an introduced, direct line
		roomName.textContent = conv.id;
		renderDmStatus(conv); // online/offline in the header, in place of a roster count
		membersToggle.hidden = true;
		content.classList.add("no-members");
	}
	emojiPop.classList.remove("show"); // never carry a stray popup across a switch
	notifyToggle.hidden = false;
	renderNotifyBtn();
	stopTyping(); // leaving the old room: clear any typing flag we were sending
	renderConv(conv);
	renderTyping(conv);
	renderRooms();
	renderDms();
	updateTitle();
	setTimeout(clearUnreadDivider, 1500);
	// Focus the composer on desktop so you can type at once. On mobile, opening a
	// conversation should not force the keyboard up over the messages you just
	// opened — you tap the field to type, the way native chat apps behave.
	if (!isMobile()) lineInput.focus();
}

export function showDmProvenance(conv: DmConv) {
	const online = dmablePeers.has(conv.id.toLowerCase());
	provenance.classList.toggle("offline", !online);
	// A phone has no room for the full phrase in the header; shorten it there. A
	// browser DM is redeemed over iroh (the relay dials iroh members), so a live
	// direct line is always encrypted and peer-to-peer.
	const short = isMobile();
	provenanceText.textContent = !online
		? "Offline"
		: conv.ready
		? (short ? "Encrypted" : "Direct · encrypted, peer-to-peer")
		: "Introducing…";
	provenance.classList.toggle("show", true);
}
// Keep an open direct line's header — the roster-slot status word and the
// provenance chip — in step with the peer's reachability. A no-op unless this
// exact DM is the one on screen, so presence changes to other peers cost nothing.
export function renderDmStatus(conv: DmConv | null) {
	if (!conv || conv.key !== state.activeKey) return;
	roomMeta.textContent = dmablePeers.has(conv.id.toLowerCase()) ? "online" : "offline";
	showDmProvenance(conv);
}
