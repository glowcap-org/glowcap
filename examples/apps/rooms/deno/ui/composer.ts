import { composer, dmListEl, emojiBtn, emojiPop, lineInput, roomListEl } from "./dom.ts";
import { activeConv, chatItem, state, sysItem } from "./state.ts";
import { PICKER } from "./richtext.ts";
import { send, ws } from "./net.ts";
import { deliver, toActive } from "./render.ts";

// ── Composer ──────────────────────────────────────────────────────────────
export function autoGrow() {
	lineInput.style.height = "auto";
	lineInput.style.height = Math.min(lineInput.scrollHeight, 140) + "px";
}
export function sendMessage() {
	const text = lineInput.value.trim();
	if (!text) return;
	const conv = activeConv();
	if (!conv) return;
	if (!ws || ws.readyState !== WebSocket.OPEN) {
		toActive(sysItem("Not connected, your message was not sent"));
		return;
	}
	if (conv.type === "room") {
		// The room echoes our line back to every member, so it arrives like any
		// other; we do not paint it here.
		send({ say: text });
	} else {
		// A direct message has no echo, so show our own line right away.
		send({ dmSay: { to: conv.id, text } });
		deliver(conv, chatItem(state.nick, text, true));
	}
	lineInput.value = "";
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
	if (!emojiPop.contains(target) && target !== emojiBtn) {
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
