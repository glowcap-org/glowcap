// Composer helpers: the typing signal, the file chip, and how to name who is typing.

import { useEffect, useRef } from "react";
import { useRoomsState } from "../hooks.ts";
import { NO_TYPERS } from "../store/core.ts";
import { fileSize } from "../media.ts";
import { Icon } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { TYPING_IDLE_MS } from "../limits.ts";
import { typingMore, typingOne, typingTwo } from "../../../lib/text/page.ts";

/** Tell the room we are typing while the draft holds text, and stop when we
 * send, go idle, blur, or leave.
 *
 * The flag is level, not edge: `true` goes once and a final `false` always goes,
 * so a stuck indicator cannot linger on the other members' screens. Leaving the
 * conversation runs this effect's cleanup and sends that last `false`. There is
 * no separate "stop typing on switch" call to forget.
 *
 * `draft` is a dependency even though nothing here reads it, and that is the
 * whole of the idle timer working: `typing` stays true across a whole burst of
 * keystrokes, so depending on it alone the effect runs once, the timer fires at
 * four seconds, and nothing ever re-arms it. Typing longer than that would stop
 * telling the room. Depending on the draft re-arms the timer per keystroke, so
 * "idle" means no keystroke arrived during the whole interval. */
export function useTypingSignal(typing: boolean, draft: string, setTyping: (on: boolean) => void) {
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
export const KEYBOARD_SETTLE_MS = 300;

/** One file chip in the composer: its kind, its name and size, and the × that
 * takes it back out. One shape for both a newly-picked file and a file kept from
 * a line being refiled. They differ only in what removing means, which is the
 * caller's `onRemove`. */
export function FileChip(
	{ image, name, size, onRemove }: { image: boolean; name: string; size: number; onRemove: () => void },
) {
	return (
		<div className="composer-file">
			<span className="composer-file-kind">
				<Icon name={image ? "image" : "file"} size={18} />
			</span>
			<span className="composer-file-copy">
				<span className="composer-file-name" title={name}>{name}</span>
				<span className="composer-file-size">{fileSize(size)}</span>
			</span>
			<IconButton
				className="composer-file-remove"
				icon="close"
				label={`Remove ${name}`}
				size="small"
				variant="ghost"
				tone="danger"
				onClick={onRemove}
			/>
		</div>
	);
}

/** Who is composing in this conversation. Subscribes here, not at the page
 * root, so a peer's keystroke does not rebuild the shell. */
function useConversationTypers(key: string | null): ReadonlySet<string> {
	return useRoomsState((state) => key == null ? NO_TYPERS : state.typers.get(key) ?? NO_TYPERS);
}

export function useTypingSaid(key: string | null, except: string): string {
	return typingText(useConversationTypers(key), except);
}

function typingText(names: Iterable<string>, except: string): string {
	let first = "";
	let second = "";
	let count = 0;
	for (const name of names) {
		if (name === except) continue;
		if (count === 0) first = name;
		else if (count === 1) second = name;
		count++;
	}
	if (count === 0) return "";
	if (count === 1) return typingOne(first);
	if (count === 2) return typingTwo(first, second);
	return typingMore(first, second, count - 2);
}
