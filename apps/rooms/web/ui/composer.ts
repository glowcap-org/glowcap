import { composer, dmListEl, emojiBtn, emojiPop, lineInput, roomListEl } from "./dom.ts";
import { activeConv, sysItem } from "./state.ts";
import { PICKER } from "./richtext.ts";
import { MAX_LINE } from "../../lib/limits.ts";
import { dmSay, isConnected, sayLine, setTyping } from "./net.ts";
import { toActive } from "./render.ts";

// ── Composer ──────────────────────────────────────────────────────────────
export function autoGrow() {
	lineInput.style.height = "auto";
	// The cap is the stylesheet's `max-height`, read rather than repeated: two
	// copies of one number drift the moment either moves.
	const cap = parseFloat(getComputedStyle(lineInput).maxHeight) || Infinity;
	lineInput.style.height = Math.min(lineInput.scrollHeight, cap) + "px";
}

// ── Typing signal ───────────────────────────────────────────────────────────
// Tell the room we are typing while the composer holds text, and stop when we
// send, go idle, or blur. Room-only and ephemeral: a direct message is peer-to-
// peer with no typing channel. The flag is level, not edge — we send `true` once
// and refresh an idle timer on each keystroke, and always send a final `false` so
// a stuck indicator can never linger on the other members' screens.
let typingOn = false;
let typingIdle: ReturnType<typeof setTimeout> | undefined;
export function stopTyping() {
	clearTimeout(typingIdle);
	if (typingOn) {
		typingOn = false;
		setTyping(false);
	}
}
function noteTyping() {
	const conv = activeConv();
	if (!conv || conv.type !== "room" || !lineInput.value.trim()) {
		stopTyping();
		return;
	}
	if (!typingOn) {
		typingOn = true;
		setTyping(true);
	}
	clearTimeout(typingIdle);
	typingIdle = setTimeout(stopTyping, 4000);
}
export function sendMessage() {
	const text = lineInput.value.trim();
	if (!text) return;
	const conv = activeConv();
	if (!conv) return;
	if (!isConnected()) {
		toActive(sysItem("Not connected, your message was not sent"));
		return;
	}
	if (text.length > MAX_LINE) {
		toActive(sysItem(`Message too long (max ${MAX_LINE} characters)`));
		return;
	}
	if (conv.type === "room") {
		// net.ts paints our own line at once as "sending" and confirms it when the
		// room echoes it back to every member; a rejected send is marked failed.
		sayLine(text);
	} else {
		// A direct message has no echo; net.ts paints our own line as it sends and
		// marks it failed if the direct line cannot reach the peer.
		dmSay(conv, text);
	}
	lineInput.value = "";
	stopTyping(); // the line is gone; clear our typing flag at once
	autoGrow();
	// Keep focus after sending (both platforms) so you can fire off another line
	// without re-tapping the composer; the keyboard stays up on mobile.
	lineInput.focus();
}
export function insertMention(name: string) {
	if (lineInput.disabled) return;
	const v = lineInput.value;
	const sep = v && !/\s$/.test(v) ? " " : "";
	lineInput.value = v + sep + "@" + name + " ";
	lineInput.focus();
	autoGrow();
}
export function insertAtCursor(s: string) {
	const start = lineInput.selectionStart != null
		? lineInput.selectionStart
		: lineInput.value.length;
	const end = lineInput.selectionEnd != null ? lineInput.selectionEnd : lineInput.value.length;
	lineInput.value = lineInput.value.slice(0, start) + s +
		lineInput.value.slice(end);
	const pos = start + s.length;
	lineInput.selectionStart = lineInput.selectionEnd = pos;
	autoGrow();
}
lineInput.addEventListener("input", autoGrow);
lineInput.addEventListener("input", noteTyping);
lineInput.addEventListener("blur", stopTyping);
lineInput.addEventListener("keydown", (e) => {
	if (e.key === "Escape" && emojiPop.classList.contains("show")) {
		emojiPop.classList.remove("show");
		return;
	}
	// Enter sends on a physical keyboard (Shift+Enter is the newline). On a touch
	// device there is no Shift, so let Return insert a newline and leave sending to
	// the Send button. e.isComposing guards against sending mid-IME-composition.
	if (
		e.key === "Enter" && !e.shiftKey && !e.isComposing &&
		!matchMedia("(pointer: coarse)").matches
	) {
		e.preventDefault();
		if (composer.requestSubmit) composer.requestSubmit();
		else sendMessage();
	}
});
composer.onsubmit = (e) => {
	e.preventDefault();
	sendMessage();
};

// ── Emoji picker ──────────────────────────────────────────────────────────
for (const e of PICKER) {
	const b = document.createElement("button");
	b.type = "button";
	b.textContent = e;
	b.onclick = () => {
		insertAtCursor(e);
		emojiPop.classList.remove("show");
		lineInput.focus();
	};
	emojiPop.append(b);
}
emojiBtn.onclick = () => {
	if (!emojiBtn.disabled) emojiPop.classList.toggle("show");
};
// Keep the composer focused when using the emoji picker: a mousedown on the
// toggle or a panel emoji would otherwise steal focus and collapse the caret,
// so the emoji would land at the end instead of at the cursor.
for (const elm of [emojiBtn, emojiPop]) {
	elm.addEventListener("mousedown", (e) => e.preventDefault());
}
document.addEventListener("click", (e) => {
	const target = e.target as Node | null;
	// Containment, not identity: a click on the toggle usually lands on the
	// icon *inside* the button, so an identity test would close the popup in
	// the same click that just opened it.
	if (!emojiPop.contains(target) && !emojiBtn.contains(target)) {
		emojiPop.classList.remove("show");
	}
});

// Switching conversations from the sidebar should not blur the composer.
// Each tab picks a conversation and re-focuses the composer; if the click were
// allowed to move focus first, the focus-driven hint would collapse and slide
// back in on every switch. Suppressing the mousedown's focus shift on the two
// lists keeps the composer focused throughout, so the hint only animates on a
// genuine focus. click still fires, so picking a room or DM is unaffected.
for (const listEl of [roomListEl, dmListEl]) {
	listEl.addEventListener("mousedown", (e) => e.preventDefault());
}
