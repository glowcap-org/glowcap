// Composer helpers: the typing signal, the file chip, and how to name who is typing.

import { useCallback, useEffect, useMemo, useRef } from "react";
import { useRoomsState } from "../hooks.ts";
import { NO_TYPERS } from "../store/projection.ts";
import { fileSize } from "../media.ts";
import { Icon } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { ComposerTyping } from "../typing.ts";
import { typingMore, typingOne, typingTwo } from "../../../lib/text/page.ts";

/** Tell a conversation we are typing while the member edits its draft, and
 * stop when we send, go idle, blur, or leave. `ComposerTyping` owns the level
 * and its timers.
 *
 * `edit` is how the composer changes the draft at the member's hand, and
 * `typed` marks a change it makes another way as theirs. The effect that
 * follows the changed draft reads either as a keystroke, so a draft that
 * changes with neither says nothing. */
export function useTypingSignal(
	conversation: string | null,
	typing: boolean,
	draft: string,
	setTyping: (conversation: string, on: boolean) => void,
	setDraft: (text: string) => void,
): { edit: (text: string) => void; typed: () => void } {
	const composer = useMemo(() => new ComposerTyping(setTyping), [setTyping]);
	const edited = useRef(false);
	useEffect(() => () => composer.close(), [composer]);
	useEffect(() => {
		composer.note(conversation, typing, edited.current);
		edited.current = false;
	}, [composer, conversation, typing, draft]);
	const typed = useCallback(() => {
		edited.current = true;
	}, []);
	return {
		typed,
		edit: (text) => {
			if (text !== draft) typed();
			setDraft(text);
		},
	};
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
