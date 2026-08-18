// The message column.
//
// Layout is a pure pass in `log_blocks.ts`. This file draws what that pass
// named: the intro, the banners, and the grouped rows. Nothing about who can
// see a banner is decided here.

import { memo, type ReactNode, type Ref, useMemo } from "react";
import type { ChatItem, Conv, Unread } from "./types.ts";
import { MessageGroup } from "./Message.tsx";
import { usePeer } from "./peer.ts";
import { type Block, blocksOf } from "./log_blocks.ts";
import { Avatar } from "./Avatar.tsx";
import { Icon } from "./icons.tsx";

/** The line the "New messages" rule hangs above, or null when there is none. */
function rulePlace(unread: Unread): number | null {
	return unread.kind === "caught-up" ? null : unread.from;
}

// The panel at the top of a conversation. A log that starts mid-air reads as if
// something failed to load, and the top of the log is the one place with room to
// say what this room actually is. Each kind says the true thing about itself: a
// public room is open to anyone holding its name, a private one to nobody who
// was not handed it, and a direct message is the part worth understanding: a
// line the room introduced and then stepped out of.
//
// A direct line's panel describes a moment that passes while the reader is
// looking at it, so it is derived from the conversation's current state and
// rewrites itself when the introduction lands.
function introBody(conv: Conv): string {
	if (conv.type === "room") {
		// The two rooms say opposite things about who can walk in, and the panel
		// is where a reader finds out which kind they are in. Saying the open
		// sentence over a private room would be the worst wrong answer here.
		if (conv.held) {
			return "This is the beginning of the room, and it is private. It is in no list and " +
				"nobody can enter it by name. Everybody here was handed it by somebody who " +
				"was already in. Hand it on with /invite, and whoever holds it can do the same.";
		}
		return "This is the beginning of the room. Anyone who knows its name can join, " +
			"and nobody had to make an account: the name you picked is a display name, " +
			"not an identity anyone checked.";
	}
	if (conv.line === "closed") {
		return "This conversation is closed. " + conv.id +
			" left the room, which takes their name back and may grant it to " +
			"someone else, so there is no way from here to tell a later " +
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
	changing: number | undefined,
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
					{block.who !== undefined && <span className="who">{block.who}</span>}
					<span className="sys-line">{block.text}</span>
				</div>
			);
		case "span":
			return block.who !== undefined
				? (
					<div
						key={block.key}
						className="sys here"
						role="group"
						aria-label={block.who}
					>
						<div className="sys-aside">
							<span className="aside-mark" aria-hidden="true">{block.who}</span>
							<div className="sys-run">
								{block.lines.map((line) => <span key={line.key} className="sys-line">{line.text}
								</span>)}
							</div>
						</div>
					</div>
				)
				: (
					<div key={block.key} className={block.className}>
						<div className="sys-run">
							{block.lines.map((line) => <span key={line.key} className="sys-line">{line.text}</span>)}
						</div>
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
					changing={changing}
				/>
			);
	}
}

function LogPane(
	{ conv, nick, hidden, ignored, changing, ref }: {
		conv: Conv | null;
		nick: string;
		hidden: boolean;
		/** The line this window is part way through rewriting, so the log can say
		 * which one it is. Passed rather than read here for the same reason the
		 * ignored set is: the log stays a function of its props. */
		changing: number | undefined;
		/** Names this window is not showing. Passed rather than read here so the
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
		() => (item: ChatItem) =>
			item.attachments !== undefined && item.attachments.length > 0
				? peer.changeFiles(item.id, item.text, item.attachments)
				: peer.changeLine(item.id, item.text),
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
						{
							/* The same mark the title and the rail wear: a public room
							   is its hash-name, a private one a lock, a person their
							   chip. */
						}
						<h2>
							{conv.type === "room" && (
								<span
									className={conv.held ? "hash held-lock" : "hash"}
									aria-hidden="true"
									title={conv.held
										? "A private room: it is not listed, and only people it was handed to are here"
										: undefined}
								>
									{conv.held ? <Icon name="lock" size={15} /> : "#"}
								</span>
							)}
							{conv.type === "dm" && <Avatar name={conv.id} />}
							{conv.id}
						</h2>
						<p>{introBody(conv)}</p>
					</div>
					{blocks.map((block) =>
						drawBlock(block, nick, conv.key, retry, stop, edit, withdraw, peer.mention, changing)
					)}
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
