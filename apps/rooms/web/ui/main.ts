// The rooms browser client's entry module. Authored in TypeScript against the DOM
// libs (see the ui/deno.json lib setting) and bundled to /page.js by serve.ts at
// startup, so there is no committed build artifact. It runs standalone in the page,
// with no framework: the app is split across small ES modules, and main.ts is the
// entry that wires them together and drives the first render on load.

import {
	app,
	backBtn,
	browseRoomsBtn,
	composerBar,
	content,
	emojiBtn,
	isMobile,
	joinBtn,
	joinForm,
	jumpBtn,
	leaveBtn,
	lineInput,
	log,
	membersToggle,
	mobileMQ,
	newDm,
	newDmBtn,
	newDmInput,
	newRoom,
	newRoomBtn,
	newRoomInput,
	nickInput,
	provenanceLock,
	railToggle,
	roomInput,
	sheetScrim,
	themeToggle,
} from "./dom.ts";
import { activeConv, LS, state } from "./state.ts";
import {
	clearUnreadDivider,
	nearBottom,
	renderDms,
	renderPresence,
	renderRooms,
	setBanner,
	setComposerEnabled,
	syncRailToggles,
	toBottom,
	updateTitle,
} from "./render.ts";
import { renderNotifyBtn } from "./notify.ts";
import { setIcon } from "./icons.ts";
import { closeDm, connect, join, leaveRoom, pickRoom, startDm } from "./net.ts";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";

// ── Light / "syrup" dark theme, remembered across visits ──────────────────
function applyTheme(t: string) {
	document.documentElement.dataset.theme = t;
	setIcon(themeToggle, t === "dark" ? "sun" : "moon");
	themeToggle.title = t === "dark" ? "Switch to light" : "Switch to syrup (dark)";
}
// The icons the markup used to carry inline. `icons.ts` owns every path now:
// duplicating six of them in page.html meant editing the module left the copies
// stale, and two of the six were overwritten on load anyway. The theme and
// notify buttons are painted by applyTheme and renderNotifyBtn below.
setIcon(emojiBtn, "smile");
setIcon(leaveBtn.querySelector(".leave-x")!, "close", 14);
setIcon(membersToggle.querySelector(".count-mark")!, "group");
setIcon(jumpBtn, "arrowDown", 15);
setIcon(provenanceLock, "lock", 12);

let theme = LS.get("rooms.theme") ||
	(matchMedia && matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
applyTheme(theme);
themeToggle.onclick = () => {
	theme = theme === "dark" ? "light" : "dark";
	applyTheme(theme);
	LS.set("rooms.theme", theme);
};

// The two inline "+" panels — create a room, start a direct message — behave as
// one group. Opening either closes the other, a click outside closes both, and
// Escape closes and hands focus back to the button that opened it, so a panel
// never lingers half-open or strands focus on a hidden field.
interface Panel {
	btn: HTMLButtonElement;
	panel: HTMLElement;
	input: HTMLInputElement;
	submit: (name: string) => void;
}
const inlinePanels: Panel[] = [
	{ btn: newRoomBtn, panel: newRoom, input: newRoomInput, submit: pickRoom },
	{ btn: newDmBtn, panel: newDm, input: newDmInput, submit: startDm },
];
function closeInlinePanel(p: Panel, refocus?: boolean) {
	if (!p.panel.classList.contains("show")) return;
	p.panel.classList.remove("show");
	p.btn.setAttribute("aria-expanded", "false");
	if (refocus) p.btn.focus();
}
function toggleInlinePanel(p: Panel) {
	const open = !p.panel.classList.contains("show");
	for (const other of inlinePanels) if (other !== p) closeInlinePanel(other);
	p.panel.classList.toggle("show", open);
	p.btn.setAttribute("aria-expanded", String(open));
	if (open) p.input.focus();
}
for (const p of inlinePanels) {
	p.btn.onclick = () => toggleInlinePanel(p);
	p.input.onkeydown = (e) => {
		if (e.key === "Escape") {
			// This panel consumed the key. Say so, or the window handler below
			// treats the same press as "close the rooms list" and the phone loses
			// the whole screen the panel was sitting on.
			e.stopPropagation();
			closeInlinePanel(p, true);
			return;
		}
		if (e.key !== "Enter") return;
		// Cancel the default so the Enter cannot fall through to the composer we
		// are about to focus and land there as a stray newline.
		e.preventDefault();
		const name = p.input.value.trim();
		if (!name) return;
		const max = p.input === newRoomInput ? MAX_ROOM : MAX_NICK;
		if (name.length > max) {
			setBanner(
				p.input === newRoomInput
					? `room name too long (max ${MAX_ROOM} characters)`
					: `name too long (max ${MAX_NICK} characters)`,
			);
			return;
		}
		p.input.value = "";
		// Refocus the toggle: closing the panel takes its input out of the tab
		// order, and without this the keyboard user is left on `<body>` with
		// nowhere to tab from.
		closeInlinePanel(p, true);
		p.submit(name);
	};
	// The field exists to be typed in, so it lives exactly as long as it holds
	// the caret. Anything that takes focus off it — a click elsewhere, a tab, the
	// window going away — puts it back. A submit has already closed it by here,
	// and the refocus that follows lands on the toggle, not the field, so this
	// cannot fight it.
	p.input.onblur = (e) => {
		// Except when the focus is going to the toggle itself, which is about to
		// decide the panel's fate and would otherwise find it already closed and
		// open it straight back.
		if ((e as FocusEvent).relatedTarget === p.btn) return;
		closeInlinePanel(p);
	};
}
// A click outside an open panel — and not on its own toggle — closes it.
document.addEventListener("click", (e) => {
	const target = e.target as Node | null;
	for (const p of inlinePanels) {
		// Containment, not identity, for the same reason as the emoji popup's
		// dismiss: the click usually lands on the icon inside the toggle.
		if (!p.panel.contains(target) && !p.btn.contains(target)) closeInlinePanel(p);
	}
});

membersToggle.onclick = () => {
	// On mobile the roster is a bottom sheet toggled by members-open; on desktop
	// it is the collapsible right column driven by the no-members preference.
	if (isMobile()) {
		// The sheet's open state is what the button reports here, not the desktop
		// column preference: a screen reader on the narrow layout was hearing the
		// desktop answer to a question about the sheet.
		const open = app.classList.toggle("members-open");
		membersToggle.setAttribute("aria-pressed", String(open));
		return;
	}
	state.membersHidden = content.classList.toggle("no-members");
	membersToggle.setAttribute("aria-pressed", String(!state.membersHidden));
};
// The rooms rail. What showing it means differs by layout — beside the
// conversation on a wide screen, a screen of its own on a phone — so the two
// homes of its toggle drive one verb and the reporting is derived, never typed
// out twice. Picking a room used to be the only way off the phone's list screen,
// so a glance at what else was live cost you the conversation you were reading.
function showRail(shown: boolean) {
	if (isMobile()) {
		app.classList.toggle("show-list", shown);
	} else {
		state.roomsHidden = !shown;
		app.classList.toggle("rooms-hidden", !shown);
	}
	syncRailToggles();
}
// The title's mark ends whatever it names: a room is left, a direct line is
// closed. One control, because from the reader's side it is one gesture.
leaveBtn.onclick = () => {
	const conv = activeConv();
	if (conv?.type === "dm") closeDm(conv);
	else leaveRoom();
};
railToggle.onclick = () => showRail(false);
backBtn.onclick = () => showRail(true);
browseRoomsBtn.onclick = () => showRail(true);
sheetScrim.onclick = () => closeRosterSheet();
function closeRosterSheet() {
	app.classList.remove("members-open");
	membersToggle.setAttribute("aria-pressed", "false");
}
// Escape dismisses whichever overlay is up, innermost first. The "+" panels
// handle their own Escape and stop it there, so this only ever sees a press that
// nothing nearer has claimed.
addEventListener("keydown", (e) => {
	if (e.key !== "Escape") return;
	if (app.classList.contains("members-open")) closeRosterSheet();
	else if (app.classList.contains("show-list")) showRail(false);
});
jumpBtn.onclick = () => {
	toBottom();
	jumpBtn.classList.remove("show");
};
// The composer floats over the bottom of the message column, so the log has to
// leave that much of itself clear and the jump-to-latest button has to sit above
// it. Both read one number. The band holds one height at rest by design — every
// row in it reserves its space — but a long draft grows the textarea and the
// window can be resized under it, so the number is measured rather than guessed.
// A conversation already pinned to the newest message stays pinned across the
// change.
new ResizeObserver(() => {
	const pinned = nearBottom();
	document.documentElement.style.setProperty(
		"--composer-h",
		`${Math.round(composerBar.getBoundingClientRect().height)}px`,
	);
	if (pinned) toBottom();
}).observe(composerBar);

const onScrollCheck = () => {
	if (nearBottom()) jumpBtn.classList.remove("show");
};
log.addEventListener("scroll", onScrollCheck);
addEventListener("scroll", onScrollCheck, { passive: true });

// When the composer is focused on mobile the keyboard slides in; once it has
// settled, bring the newest messages into view so you see what you are replying
// to. Two passes ride out the keyboard's open animation without a magic delay.
lineInput.addEventListener("focus", () => {
	if (!isMobile()) return;
	toBottom();
	setTimeout(toBottom, 300);
});

document.addEventListener("visibilitychange", () => {
	if (document.hidden) return;
	const c = activeConv();
	if (c) c.unread = 0;
	updateTitle();
	renderRooms();
	renderDms();
	setTimeout(clearUnreadDivider, 1500);
});

// Crossing the mobile/desktop breakpoint (a desktop window resize, a tablet
// rotation) swaps which layout is in force, so re-sync the parts set at switch
// time: clear the mobile-only overlays when returning to desktop, restore the
// desktop member-column preference (mobile forces the column off, using a bottom
// sheet instead), and re-pin the newest message into view for the new metrics.
mobileMQ.addEventListener("change", () => {
	if (!isMobile()) app.classList.remove("show-list", "members-open");
	// The rail's collapse preference is the wide layout's alone; the phone reads
	// its list screen, which the crossing leaves closed.
	app.classList.toggle("rooms-hidden", !isMobile() && state.roomsHidden);
	syncRailToggles();
	const conv = activeConv();
	if (conv && conv.type === "room") {
		if (isMobile()) {
			content.classList.remove("no-members");
			// The button now reports the bottom sheet, which the crossing closes.
			membersToggle.setAttribute("aria-pressed", "false");
		} else {
			content.classList.toggle("no-members", state.membersHidden);
			// And back the other way, it reports the desktop column again.
			membersToggle.setAttribute("aria-pressed", String(!state.membersHidden));
		}
	}
	requestAnimationFrame(toBottom);
});

joinForm.onsubmit = (e) => {
	e.preventDefault();
	join();
};

// Prefill the join form from the last visit, so returning is one click.
const savedNick = LS.get("rooms.nick");
if (savedNick) nickInput.value = savedNick;
const savedRoom = LS.get("rooms.room");
if (savedRoom) roomInput.value = savedRoom;
if (savedNick) joinBtn.focus();

renderNotifyBtn();
syncRailToggles();
setComposerEnabled(false);
renderPresence(null);
renderRooms();
renderDms();
updateTitle();
connect();
