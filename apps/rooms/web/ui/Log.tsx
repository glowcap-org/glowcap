// The message column.
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

import { memo, type ReactNode, type Ref, useMemo } from "react";
import type { ChatItem, Conv, Item, Unread } from "./types.ts";
import { dayKey, dayLabel, GROUP_WINDOW_MS } from "./text.ts";
import { actionIn, noticeIn } from "./commands.ts";
import { type Group, MessageGroup } from "./Message.tsx";
import { usePeer } from "./peer.ts";

/** The line the "New messages" rule hangs above, or null when there is none. */
function rulePlace(unread: Unread): number | null {
	return unread.kind === "caught-up" ? null : unread.from;
}

type Block =
	| { kind: "day"; key: string; label: string }
	| { kind: "unread"; key: string }
	| { kind: "banner"; key: string; className: string; text: string }
	| { kind: "group"; key: string; group: Group };

/** Everything the log draws for one conversation, in order.
 *
 * A day heading, a banner, or the unread rule ends whatever row was open, which
 * is what keeps a stack of bubbles from spanning a divider. */
function blocksOf(history: readonly Item[], rule: number | null, ignored: ReadonlySet<string>): Block[] {
	const blocks: Block[] = [];
	let day = "";
	let open: Group | null = null;
	let openAt = 0;

	const breakRow = () => {
		open = null;
		openAt = 0;
	};

	for (const item of history) {
		// Somebody this window is not drawing. Skipped here rather than filtered
		// out of the history, because the history is what the room said and this is
		// a decision about what to look at — the lines are still there, and
		// unignoring shows them without asking the room for anything.
		if (item.kind !== "sys" && ignored.has(item.from.toLowerCase())) continue;
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
			blocks.push({ kind: "banner", key: "b-" + item.id, className: "sys", text: item.text });
			breakRow();
			continue;
		}
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

// The panel at the top of a conversation. A log that starts mid-air reads as if
// something failed to load, and the top of the log is the one place with room to
// say what this room actually is. Each kind says the true thing about itself: a
// room is open to anyone holding its name, while a direct message is the part
// worth understanding, a line the room introduced and then stepped out of.
//
// A direct line's panel describes a moment that passes while the reader is
// looking at it, so it is derived from the conversation's current state and
// rewrites itself when the introduction lands.
function introBody(conv: Conv): string {
	if (conv.type === "room") {
		return "This is the beginning of the room. Anyone who knows its name can join, " +
			"and nobody had to make an account: the name you picked is a display name, " +
			"not an identity anyone checked.";
	}
	if (conv.line === "closed") {
		return "This conversation is closed. " + conv.id +
			" left the room, which takes their name back and may grant it to " +
			"someone else — so there is no way from here to tell a later " +
			conv.id + " from the one you were talking to. The messages above are " +
			"yours to keep; starting a new conversation with that name reaches " +
			"whoever holds it now.";
	}
	return conv.line === "live"
		? "This line is direct. The room introduced the two of you and then stepped " +
			"out of the path, so these messages travel peer to peer and the room never " +
			"sees them."
		: "This line is not open yet. Sending the first message opens it: the room " +
			"introduces the two of you, the introduction is redeemed, and the room then " +
			"drops out of the path so what you say travels peer to peer.";
}

function drawBlock(
	block: Block,
	nick: string,
	convKey: string,
	onRetry: (id: number) => void,
	onStop: (id: number) => void,
	onEdit: (item: ChatItem) => void,
	onWithdraw: (id: number) => void,
	onMention: (who: string) => void,
): ReactNode {
	switch (block.kind) {
		case "day":
			return (
				<div key={block.key} className="divider day">
					<span>{block.label}</span>
				</div>
			);
		case "unread":
			return (
				<div key={block.key} className="divider unread">
					<span>New messages</span>
				</div>
			);
		case "banner":
			return (
				<div key={block.key} className={block.className}>
					<span>{block.text}</span>
				</div>
			);
		case "group":
			return (
				<MessageGroup
					key={block.key}
					group={block.group}
					nick={nick}
					convKey={convKey}
					onRetry={onRetry}
					onStop={onStop}
					onEdit={onEdit}
					onWithdraw={onWithdraw}
					onMention={onMention}
				/>
			);
	}
}

function LogPane(
	{ conv, nick, hidden, ignored, ref }: {
		conv: Conv | null;
		nick: string;
		hidden: boolean;
		/** Names this window is not drawing. Passed rather than read here so the
		 * log keeps being a function of its props, and so unignoring somebody
		 * repaints for the same reason an arriving line does. */
		ignored: ReadonlySet<string>;
		ref: Ref<HTMLElement>;
	},
) {
	// The history array is replaced only when a line arrives or changes, so this
	// pass runs then and not on every unrelated repaint (a typing flag, a member
	// coming online). The rows below memoise on their own group, so an arriving
	// line repaints the newest row alone.
	const blocks = useMemo(
		() => (conv ? blocksOf(conv.history, rulePlace(conv.unread), ignored) : []),
		[conv?.history, conv?.unread, ignored],
	);
	// Bound once per conversation, so the rows below keep comparing equal while
	// you type. The verb table never changes, so this only moves when the
	// conversation does.
	const peer = usePeer();
	const retry = useMemo(
		() => (id: number) => conv && peer.retry(conv.key, id),
		[conv?.key, peer],
	);
	// Memoised like the retry beside it, and for the same reason: the message
	// group is memoised on these being the same function between renders.
	const stop = useMemo(
		() => (id: number) => conv && peer.stopSend(conv.key, id),
		[conv?.key, peer],
	);
	// Changing a line puts its words back in the composer, which is where text
	// is written, and names the line they came from. The name is the part that
	// matters: `/edit` changes the most recent line, and a pencil pressed on an
	// older one has to change that one.
	const edit = useMemo(
		() => (item: ChatItem) => peer.changeLine(item.id, item.text),
		[peer],
	);
	const withdraw = useMemo(
		() => (id: number) => conv && peer.withdraw(conv.key, id),
		[conv?.key, peer],
	);
	return (
		<section id="log" ref={ref} aria-live="polite" aria-label="Messages" hidden={hidden}>
			{conv && (
				<>
					<div className="conv-intro">
						<h2>{conv.type === "room" ? "#" + conv.id : conv.id}</h2>
						<p>{introBody(conv)}</p>
					</div>
					{blocks.map((block) => drawBlock(block, nick, conv.key, retry, stop, edit, withdraw, peer.mention))}
				</>
			)}
		</section>
	);
}

// Memoised for the same reason the panes in App are: the draft is a store field,
// so a keystroke replaces the state object, and none of the props above change
// with it. Without this the log re-renders per character and React re-runs the
// row comparator once for every message in the conversation.
export const Log = memo(LogPane);
