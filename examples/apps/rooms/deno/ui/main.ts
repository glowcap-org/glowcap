// The rooms browser client's entry module. Authored in TypeScript against the DOM
// libs (see the ui/deno.json lib setting) and bundled to /page.js by web.ts at
// startup, so there is no committed build artifact. It runs standalone in the page,
// with no framework: the app is split across small ES modules, and main.ts is the
// entry that wires them together and drives the first render on load.

import {
	app,
	backBtn,
	content,
	isMobile,
	joinBtn,
	joinForm,
	jumpBtn,
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
	setComposerEnabled,
	toBottom,
	updateTitle,
} from "./render.ts";
import { renderNotifyBtn } from "./notify.ts";
import { connect, join, pickRoom, startDm } from "./net.ts";

// ── Light / "syrup" dark theme, remembered across visits ──────────────────
function applyTheme(t: string) {
	document.documentElement.dataset.theme = t;
	themeToggle.textContent = t === "dark" ? "☀︎" : "🌙";
	themeToggle.title = t === "dark" ? "Switch to light" : "Switch to syrup (dark)";
}
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
			closeInlinePanel(p, true);
			return;
		}
		if (e.key !== "Enter") return;
		// Cancel the default so the Enter cannot fall through to the composer we
		// are about to focus and land there as a stray newline.
		e.preventDefault();
		const name = p.input.value.trim().slice(0, 32);
		if (!name) return;
		p.input.value = "";
		closeInlinePanel(p);
		p.submit(name);
	};
}
// A click outside an open panel — and not on its own toggle — closes it.
document.addEventListener("click", (e) => {
	const target = e.target as Node | null;
	for (const p of inlinePanels) {
		if (!p.panel.contains(target) && target !== p.btn) closeInlinePanel(p);
	}
});

membersToggle.onclick = () => {
	// On mobile the roster is a bottom sheet toggled by members-open; on desktop
	// it is the collapsible right column driven by the no-members preference.
	if (isMobile()) {
		app.classList.toggle("members-open");
		return;
	}
	state.membersHidden = content.classList.toggle("no-members");
	membersToggle.setAttribute("aria-pressed", String(!state.membersHidden));
};
// Mobile navigation: the back button returns to the list; tapping the scrim
// closes the roster sheet. Both are inert on desktop (the elements are hidden).
backBtn.onclick = () => app.classList.add("show-list");
sheetScrim.onclick = () => app.classList.remove("members-open");
jumpBtn.onclick = () => {
	toBottom();
	jumpBtn.classList.remove("show");
};
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

// iOS Safari ignores user-scalable=no in the viewport meta, so disable
// pinch-zoom by preventing its proprietary gesture events. Double-tap zoom is
// dropped by touch-action: manipulation in the CSS. Scrolling the log, which is
// a single-touch pan, is unaffected. (These events never fire on desktop.)
for (const ev of ["gesturestart", "gesturechange", "gestureend"]) {
	document.addEventListener(ev, (e) => e.preventDefault(), {
		passive: false,
	});
}
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
	const conv = activeConv();
	if (conv && conv.type === "room") {
		if (isMobile()) content.classList.remove("no-members");
		else content.classList.toggle("no-members", state.membersHidden);
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
setComposerEnabled(false);
renderPresence(null);
renderRooms();
renderDms();
updateTitle();
connect();
