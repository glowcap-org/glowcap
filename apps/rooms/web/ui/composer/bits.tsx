// Composer helpers: the typing signal, the file chip, and how to name who is typing.

import { useEffect, useRef } from "react";
import type { Conv } from "../types.ts";
import { commandIn } from "../commands.ts";
import type { Trigger } from "../complete.ts";
import { fileSize } from "../media.ts";
import { Icon } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { TYPING_IDLE_MS } from "../../../lib/limits.ts";

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

/** Whose names an `@` completes against, here.
 *
 * A mention reaches somebody in the conversation, so most `@`s complete against
 * the room's members (or the one person a direct line is with). But a command
 * whose target is somebody to bring in — `/invite`, `/msg` — wants the people
 * the members list leaves out, so its `@` completes against the directory's
 * reachable set instead. The command registry declares which (`targets`); the
 * one place that knows a name is not present is here, where the draft is.
 * Room-wide names are not in this list: they are mention vocabulary, and
 * completion keeps them off any command that declared `targets`. Your own
 * name is not either: a line to yourself is not a conversation. */
export function nickSource(
	trigger: Trigger | null,
	conv: Conv | null,
	draft: string,
	reachable: ReadonlySet<string>,
	you: string,
): readonly string[] {
	if (trigger?.kind !== "nick" || conv === null) return [];
	if (commandIn(draft)?.command.targets === "reachable") {
		const mine = you.toLowerCase();
		return mine === "" ? [...reachable] : [...reachable].filter((name) => name.toLowerCase() !== mine);
	}
	return conv.type === "room" ? [...conv.members.keys()] : [conv.id];
}

/** One file chip in the composer: its kind, its name and size, and the × that
 * takes it back out. One shape for both a newly-picked file and a file kept from
 * a line being refiled — they differ only in what removing means, which is the
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

export function typingText(names: Iterable<string>, except: string): string {
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
	if (count === 1) return `${first} is typing…`;
	if (count === 2) return `${first} and ${second} are typing…`;
	return `${first}, ${second}, and ${count - 2} more are typing…`;
}
