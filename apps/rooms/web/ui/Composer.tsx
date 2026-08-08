// The band at the foot of the message column: what other members are typing,
// the formatting hint, the emoji tray, and the field itself.
//
// The draft lives in the store rather than in this component, which is the same
// rule the rest of the page follows and it pays for itself here: the @ button on
// a message and the emoji tray both put text into the draft, and neither of them
// is inside this component. With one owner they are ordinary writes. With the
// draft held locally they would each need a handle reaching in.

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useCoarsePointer, useDismissOnClickOutside } from "./hooks.ts";
import { usePeer } from "./peer.ts";
import type { Conv } from "./types.ts";
import { PICKER } from "./text.ts";
import { TYPING_IDLE_MS } from "../../lib/limits.ts";
import { Icon } from "./icons.tsx";

/** Tell the room we are typing while the draft holds text, and stop when we
 * send, go idle, blur, or leave.
 *
 * The flag is level, not edge: `true` goes once and a final `false` always goes,
 * so a stuck indicator cannot linger on the other members' screens. Leaving the
 * conversation runs this effect's cleanup, which is what sends that last
 * `false` — there is no separate "stop typing on switch" call to forget.
 *
 * `draft` is a dependency even though nothing here reads it, and that is the
 * whole of the idle timer working: `typing` stays true across a whole burst of
 * keystrokes, so depending on it alone the effect runs once, the timer fires at
 * four seconds, and nothing ever re-arms it. Typing longer than that would stop
 * telling the room. Depending on the draft re-arms the timer per keystroke,
 * which is what "idle" has to mean. */
function useTypingSignal(typing: boolean, draft: string, setTyping: (on: boolean) => void) {
	const on = useRef(false);
	useEffect(() => {
		if (!typing) {
			if (on.current) {
				on.current = false;
				setTyping(false);
			}
			return;
		}
		if (!on.current) {
			on.current = true;
			setTyping(true);
		}
		const idle = setTimeout(() => {
			on.current = false;
			setTyping(false);
		}, TYPING_IDLE_MS);
		return () => clearTimeout(idle);
	}, [typing, draft, setTyping]);
	// Leaving the page entirely still owes the room a final `false`.
	useEffect(() => () => {
		if (on.current) {
			on.current = false;
			setTyping(false);
		}
	}, [setTyping]);
}

// Long enough for a phone's keyboard to finish sliding in, so the second pass
// measures the layout it leaves behind rather than the one mid-animation.
const KEYBOARD_SETTLE_MS = 300;

function typingText(names: string[]): string {
	if (names.length === 0) return "";
	if (names.length === 1) return `${names[0]} is typing…`;
	if (names.length === 2) return `${names[0]} and ${names[1]} are typing…`;
	return `${names[0]}, ${names[1]}, and ${names.length - 2} more are typing…`;
}

export function Composer(
	{ conv, nick, draft, mobile, enabled, keepLatestInView }: {
		conv: Conv | null;
		nick: string;
		draft: string;
		mobile: boolean;
		enabled: boolean;
		/** Keep the newest message in view. `force` scrolls even when the reader
		 * had scrolled up, which is what focusing the field on a phone wants. */
		keepLatestInView: (force?: boolean) => void;
	},
) {
	const peer = usePeer();
	const bar = useRef<HTMLDivElement>(null);
	const field = useRef<HTMLTextAreaElement>(null);
	// Two pieces of state nothing outside this band ever reads, so they stay here:
	// whether the tray is open, and whether the field holds the caret.
	const [emojiOpen, setEmojiOpen] = useState(false);
	const closeEmoji = useCallback(() => setEmojiOpen(false), []);
	const [focused, setFocused] = useState(false);
	// Enter sends on a physical keyboard (Shift+Enter is the newline). On a touch
	// device there is no Shift, so Return inserts a newline and sending is the
	// button's job.
	const coarse = useCoarsePointer();

	// Only a room has a typing channel; a direct message is peer to peer with none.
	// Every way of stopping — sending, going idle, blurring, switching away,
	// closing the tab — is this one condition going false.
	useTypingSignal(
		enabled && focused && conv !== null && draft.trim() !== "",
		draft,
		peer.setTyping,
	);

	// Never carry a stray tray across a conversation switch. Arriving at a
	// conversation on a wide screen also takes the caret, so you can type at once;
	// on a phone it must not, because forcing the keyboard up would cover the
	// messages you just opened.
	useEffect(() => {
		setEmojiOpen(false);
		if (!mobile && enabled) field.current?.focus();
	}, [conv?.key, mobile, enabled]);

	// Fit the box to its content. The cap is the stylesheet's `max-height`, read
	// rather than repeated: two copies of one number drift the moment either moves.
	// It is read once and remembered, because asking for it is a style
	// recalculation and asking on every character is one per keystroke; the band's
	// own observer below re-reads it when anything could have changed it.
	const cap = useRef(Infinity);
	const fit = useCallback(() => {
		const box = field.current;
		if (!box) return;
		box.style.height = "auto";
		box.style.height = Math.min(box.scrollHeight, cap.current) + "px";
	}, []);
	useLayoutEffect(() => {
		const box = field.current;
		if (box) cap.current = parseFloat(getComputedStyle(box).maxHeight) || Infinity;
		fit();
	}, [draft, enabled, fit]);

	// The composer floats over the bottom of the message column, so the log has to
	// leave that much of itself clear and the jump-to-latest button has to sit above
	// it. Both read one number. The band holds one height at rest by design — every
	// row in it reserves its space — but a long draft grows the field and the window
	// can be resized under it, so the number is measured rather than guessed.
	useLayoutEffect(() => {
		const band = bar.current;
		if (!band) return;
		const observer = new ResizeObserver(() => {
			document.documentElement.style.setProperty(
				"--composer-h",
				`${Math.round(band.getBoundingClientRect().height)}px`,
			);
			keepLatestInView();
		});
		observer.observe(band);
		return () => observer.disconnect();
	}, [keepLatestInView]);

	useDismissOnClickOutside(emojiOpen, ".emoji-pop, .emoji-btn", closeEmoji);

	const insertAtCursor = (s: string) => {
		const box = field.current;
		if (!box) return;
		const start = box.selectionStart ?? draft.length;
		const end = box.selectionEnd ?? draft.length;
		peer.setDraft(draft.slice(0, start) + s + draft.slice(end));
		queueMicrotask(() => {
			box.selectionStart = box.selectionEnd = start + s.length;
			box.focus();
		});
	};

	const typers = conv ? [...conv.typers].filter((who) => who !== nick) : [];
	const said = typingText(typers);
	const placeholder = conv
		? (conv.type === "dm" ? "Message " + conv.id + " directly" : "Message #" + conv.id)
		: "Message";

	return (
		<div className="composer" ref={bar}>
			<div
				id="emojiPop"
				className={emojiOpen ? "emoji-pop show" : "emoji-pop"}
				role="group"
				aria-label="Emoji"
			>
				{PICKER.map((glyph) => (
					<button
						key={glyph}
						type="button"
						// Keep the field focused: a mousedown here would otherwise
						// collapse the caret and land the emoji at the end.
						onMouseDown={(e) => e.preventDefault()}
						onClick={() => {
							insertAtCursor(glyph);
							setEmojiOpen(false);
						}}
					>
						{glyph}
					</button>
				))}
			</div>
			<div className="composer-status">
				<div id="typing" className={said ? "typing show" : "typing"} aria-hidden="true">
					{said}
				</div>
				<div id="hint" className="hint">
					<b>Enter</b> to send · <b>Shift+Enter</b> for a new line · <b>**bold**</b> ·
					{" "}
					<b>*italic*</b> · <b>`code`</b> · <b>@name</b> · <b>:smile:</b> · <b>/me</b>
				</div>
			</div>
			<form
				id="composer"
				hidden={conv === null}
				onSubmit={(e) => {
					e.preventDefault();
					peer.send();
				}}
			>
				<textarea
					id="line"
					ref={field}
					rows={1}
					value={draft}
					placeholder={placeholder}
					autoComplete="off"
					aria-label="Message"
					disabled={!enabled}
					onChange={(e) => peer.setDraft(e.target.value)}
					onBlur={() => setFocused(false)}
					onFocus={() => {
						setFocused(true);
						// The keyboard slides in on a phone; once it has settled, bring
						// the newest messages into view so you see what you are replying
						// to. Two passes ride out the animation without a magic delay.
						if (!mobile) return;
						keepLatestInView(true);
						setTimeout(() => keepLatestInView(true), KEYBOARD_SETTLE_MS);
					}}
					onKeyDown={(e) => {
						if (e.key === "Escape" && emojiOpen) {
							setEmojiOpen(false);
							return;
						}
						// isComposing guards against sending mid-IME-composition.
						if (
							e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing &&
							!coarse
						) {
							e.preventDefault();
							peer.send();
						}
					}}
				/>
				<button
					type="button"
					id="emojiBtn"
					className="emoji-btn"
					title="Emoji"
					aria-label="Insert emoji"
					disabled={!enabled}
					onMouseDown={(e) => e.preventDefault()}
					onClick={() => setEmojiOpen(!emojiOpen)}
				>
					<Icon name="smile" />
				</button>
				<button id="sendBtn" type="submit" disabled={!enabled}>Send</button>
			</form>
		</div>
	);
}
