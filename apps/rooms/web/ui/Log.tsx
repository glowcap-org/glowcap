// The message column.
//
// Layout is a pure pass in `log_blocks.ts`. This file draws what that pass
// named: the intro, the banners, and the grouped rows. Nothing about who can
// see a banner is decided here.

import { memo, type ReactNode, type Ref, useMemo } from "react";
import type { BridgeFacts, ChatItem, Conv, Item, SendControlPolicy, Unread } from "./types.ts";
import { MessageGroup } from "./Message.tsx";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { type Block, blocksOf } from "./log_blocks.ts";
import { Avatar } from "./Avatar.tsx";
import { Icon } from "./icons.tsx";
import { roomMarkGlyph, roomMarkTitle } from "./room_mark.tsx";
import { roomPreset } from "../../lib/room/policy.ts";
import { directoryName } from "./text.ts";
import { useRoomsState } from "./hooks.ts";

/** The line the "New messages" rule hangs above, or null when there is none. */
function rulePlace(unread: Unread): number | null {
	return unread.kind === "caught-up" ? null : unread.from;
}

// The panel at the top of a conversation. A log that starts mid-air reads as if
// something failed to load, and the top of the log is the one place with room to
// say what this room actually is. It opens by saying where the reader's view
// begins, because a room outlives any one arrival. When the room keeps earlier
// messages it can place them above that arrival; the state below says exactly
// which answer this membership received. Calling this the beginning of the room
// would tell somebody joining a day-old conversation that they were looking at
// all of it. Each kind then says the true thing about itself: a
// public room is open to anyone holding its name, a private one to nobody who
// was not handed it, and a direct message is the part worth understanding: a
// line the room introduced and then stepped out of.
//
// A direct line's panel describes a moment that passes while the reader is
// looking at it, so it is derived from the conversation's current state and
// rewrites itself when the introduction lands.
function introBody(conv: Conv): string {
	if (conv.type === "directory") {
		return "Rooms you join on this directory appear in the list. Commands typed here run on this directory. Their results stay in this view.";
	}
	if (conv.type === "room") {
		const beginning = conv.earlierHistory === "loading"
			? "Your live view begins with this arrival. Checking whether the room kept earlier messages. "
			: conv.earlierHistory === "shown"
			? "Earlier messages the room kept sit above where you joined. New lines arrive live. "
			: conv.earlierHistory === "empty"
			? "The room kept no earlier messages. Your live view begins with this arrival. "
			: conv.earlierHistory === "unavailable"
			? "The room did not provide earlier messages. Your live view begins with this arrival. "
			: "Your live view begins with this arrival. ";
		// The two rooms say opposite things about who can walk in, and the panel
		// is where a reader finds out which kind they are in. Saying the open
		// sentence over a private room would be the worst wrong answer here.
		if (conv.held) {
			return beginning +
				"The room is private: it is in no list, and nobody can enter it by name. " +
				"Everyone here was handed it. /invite hands it on, and whoever holds it can do the same.";
		}
		return beginning +
			"Anyone who knows the room's name can join. The name you picked is a display name, not an account.";
	}
	if (conv.line === "closed") {
		return "This conversation is closed. " + conv.id +
			" left the room. Their name may go to someone else, so there is no way from here to tell a later " +
			conv.id + " from the one you were talking to. The messages above are yours to keep. " +
			"A new conversation with that name reaches whoever holds it now.";
	}
	return conv.line === "live"
		? "This line is direct. The directory introduced the person who held this name when the conversation opened, then stepped out. " +
			"These messages travel peer to peer. The directory never sees them. A later holder of the name cannot inherit this line."
		: "This line is not open yet. The first message asks the directory to introduce the person this conversation recorded. " +
			"If the name has changed hands, it refuses. After that, messages travel peer to peer.";
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
	sendControls: SendControlPolicy,
	changing: number | undefined,
	/** What the bridge behind this room calls its own, so an author line can name
	 * a foreign member the way the roster does. Undefined in an ordinary room. */
	bridge: BridgeFacts | undefined,
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
					sendControls={sendControls}
					bridge={bridge}
					changing={changing}
				/>
			);
	}
}

function LogPane(
	{ conv, history, unread, nick, hidden, ignored, sendControls, changing, ref }: {
		conv: Conv | null;
		/** This conversation's log. Passed rather than read here so the log stays
		 * a function of its props, and so an arriving line repaints without the
		 * conversation identity changing. */
		history: readonly Item[];
		/** Where the "New messages" rule hangs, from the unread map rather than
		 * the conversation. */
		unread: Unread;
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
		sendControls: SendControlPolicy;
		ref: Ref<HTMLElement>;
	},
) {
	// The history array is replaced only when a line arrives or changes, so this
	// pass runs then and not on every unrelated repaint (a typing flag, a member
	// coming online). The rows below memoise on their own group, so an arriving
	// line repaints the newest row alone.
	const blocks = useMemo(
		() => (conv ? blocksOf(history, rulePlace(unread), ignored) : []),
		[conv, history, unread, ignored],
	);
	// Bound once per conversation, so the rows below keep comparing equal while
	// you type. The verb table never changes, so this only moves when the
	// conversation does.
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const homeDir = useRoomsState((state) => state.homeDir);
	const retry = useMemo(
		() => (id: number) => conv && session.retry(conv.key, id),
		[conv?.key, session],
	);
	// Memoised like the retry beside it, and for the same reason: the message
	// group is memoised on these being the same function between renders.
	const stop = useMemo(
		() => (id: number) => conv && session.stopSend(conv.key, id),
		[conv?.key, session],
	);
	// Changing a line puts its words back in the composer, which is where text
	// is written, and names the line they came from. The name is the part that
	// matters: `/edit` changes the most recent line, and a pencil pressed on an
	// older one has to change that one.
	const edit = useMemo(
		() => (item: ChatItem) =>
			item.attachments !== undefined && item.attachments.length > 0
				? browser.changeFiles(item.id, item.text, item.attachments)
				: browser.changeLine(item.id, item.text),
		[browser],
	);
	const withdraw = useMemo(
		() => (id: number) => conv && session.withdraw(conv.key, id),
		[conv?.key, session],
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
									title={roomMarkTitle(roomPreset(conv.policy))}
								>
									{roomMarkGlyph(roomPreset(conv.policy), 15)}
								</span>
							)}
							{conv.type === "directory" && (
								<span className="hash" aria-hidden="true">
									<Icon name="directory" size={15} />
								</span>
							)}
							{conv.type === "dm" && <Avatar name={conv.id} />}
							{conv.type === "directory" ? directoryName(conv.dir, homeDir) : conv.id}
						</h2>
						<p>{introBody(conv)}</p>
					</div>
					{conv.type === "room" && conv.earlierHistory === "loading" && (
						<div className="history-loading" role="status" aria-label="Loading earlier messages">
							<span className="history-loading-line shimmer" />
							<span className="history-loading-line short shimmer" />
						</div>
					)}
					{blocks.map((block) =>
						drawBlock(
							block,
							nick,
							conv.key,
							retry,
							stop,
							edit,
							withdraw,
							session.mention,
							sendControls,
							changing,
							conv.type === "room" ? conv.bridge : undefined,
						)
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
