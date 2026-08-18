// The log's layout pass: history in, the list of things to draw out.
//
// The log used to be painted by appending: each arriving line decided for itself
// whether it needed a day heading above it, whether it could join the row before
// it, and where the unread rule had got to, by reading the element it had just
// appended. Three pieces of module state carried that reasoning between calls,
// and switching conversation reset all three and repainted from scratch.
//
// Here the same reasoning is one pass over the history, and it is a pure
// function: `blocksOf` turns a list of lines into the list of things to draw.
// Nothing carries between renders, so nothing can be left over from the
// conversation before.

import { type ChatItem, type Item, silencedByIgnore } from "./types.ts";
import { dayKey, dayLabel, GROUP_WINDOW_MS } from "./text.ts";
import { actionIn, noticeIn } from "./commands.ts";

/** A run of lines from one speaker, as the log groups them. */
export interface Group {
	from: string;
	mine: boolean;
	items: ChatItem[];
}

export type SysLine = { key: string; text: string };

export type Block =
	| { kind: "day"; key: string; label: string }
	| { kind: "unread"; key: string }
	| { kind: "banner"; key: string; className: string; text: string; who?: string }
	/** Consecutive system lines of one kind, drawn as one run. Local lines share
	 * a single "Only you"; shared announcements share one centred stretch. */
	| { kind: "span"; key: string; className: string; who?: string; lines: SysLine[] }
	| { kind: "group"; key: string; group: Group };

/** The short mark on a line that never left this tab. Shared banners carry
 * none: they already sit in the room's centre, which is the default. One mark
 * names a whole run, so a packed stretch of local answers is still one aside. */
export const ONLY_YOU = "Only you";

type Span = Extract<Block, { kind: "span" }>;

/** Everything the log draws for one conversation, in order.
 *
 * A day heading, a banner, or the unread rule ends whatever row was open, which
 * is what keeps a stack of bubbles from spanning a divider. Consecutive system
 * lines of the same kind join the open run instead of starting a new one. */
export function blocksOf(history: readonly Item[], rule: number | null, ignored: ReadonlySet<string>): Block[] {
	const blocks: Block[] = [];
	let day = "";
	let open: Group | null = null;
	let openAt = 0;
	let span: Span | null = null;

	const breakRow = () => {
		open = null;
		openAt = 0;
		span = null;
	};

	const intoSpan = (className: string, who: string | undefined, item: Item & { text: string }) => {
		const line: SysLine = { key: "b-" + item.id, text: item.text };
		if (span !== null && span.className === className) {
			span.lines.push(line);
			return;
		}
		breakRow();
		span = { kind: "span", key: "s-" + item.id, className, who, lines: [line] };
		blocks.push(span);
	};

	for (const item of history) {
		// Somebody this window is not showing. Skipped here rather than filtered
		// out of the history, because the history is what the room said and this is
		// a decision about what to look at — the lines are still there, and
		// unignoring shows them without asking the room for anything.
		if (silencedByIgnore(item, ignored)) continue;
		if (item.id === rule) {
			blocks.push({ kind: "unread", key: "unread" });
			breakRow();
		}
		const itemDay = dayKey(item.at);
		if (itemDay !== day) {
			day = itemDay;
			blocks.push({ kind: "day", key: "day-" + item.id, label: dayLabel(item.at) });
			breakRow();
		}
		if (item.kind === "sys") {
			if (item.audience === "here") intoSpan("sys here", ONLY_YOU, item);
			else intoSpan("sys", undefined, item);
			continue;
		}
		span = null;
		const action = (text: string) => {
			blocks.push({
				kind: "banner",
				key: "b-" + item.id,
				className: "sys action",
				text: "✻ " + item.from + " " + text,
			});
			breakRow();
		};
		if (item.kind === "action") {
			action(item.text);
			continue;
		}
		// The command rides as text, so any client can send it without the room
		// knowing. Parsing is shared with the composer rather than reimplemented.
		const carried = actionIn(item.text);
		if (carried !== null) {
			action(carried);
			continue;
		}
		// A notice keeps its author, because it is somebody speaking rather than
		// something happening. It is drawn the way every IRC client has drawn one
		// since before this app existed, which is also what tells a reader why it
		// arrived without lighting anything up.
		const quiet = noticeIn(item.text);
		if (quiet !== null) {
			blocks.push({
				kind: "banner",
				key: "n-" + item.id,
				className: "sys notice",
				text: "-" + item.from + "- " + quiet,
			});
			breakRow();
			continue;
		}
		if (open && open.from === item.from && item.at - openAt < GROUP_WINDOW_MS) {
			open.items.push(item);
		} else {
			open = { from: item.from, mine: item.mine, items: [item] };
			blocks.push({ kind: "group", key: "g-" + item.id, group: open });
		}
		openAt = item.at;
	}
	return blocks;
}
