// The message column.
//
// Layout is a pure pass in `log_blocks.ts`. This file draws what that pass
// named: the intro, the banners, and the grouped rows. Nothing about who can
// see a banner is decided here.

import { memo, type ReactNode, type Ref, useMemo } from "react";
import type { BridgeFacts, ChatItem, Conv, Item, SendControlPolicy, Unread } from "../types.ts";
import { MessageGroup } from "./Message.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { type Block, blocksOf } from "../log_blocks.ts";
import { Avatar } from "../Avatar.tsx";
import { Icon } from "../icons.tsx";
import { roomMarkGlyph, roomMarkTitle } from "../room_mark.tsx";
import { roomPreset } from "../room_policy.ts";
import { directoryName } from "../text.ts";
import { useRoomsState } from "../hooks.ts";
import {
	conversationBeginning,
	conversationClosedDirect,
	conversationDirectory,
	conversationLiveDirect,
	conversationLoadingEarlier,
	conversationPendingDirect,
	conversationPrivateRoom,
	conversationPublicRoom,
	type EarlierHistory,
	logNewMessages,
} from "../../../lib/text/conversation.ts";
import { messagesLabel } from "../../../lib/text/controls.ts";

/** The line the "New messages" rule hangs above, or null when there is none. */
function rulePlace(unread: Unread): number | null {
	return unread.kind === "caught-up" ? null : unread.from;
}

// The panel at the top of a conversation, assembled from the conversation's
// current state so a direct line rewrites itself when its introduction lands.
// A log that starts mid-air reads as though something failed to load, which is
// why every kind opens by saying how far back the messages go. The sentences
// are `lib/text/conversation.ts`.
function introBody(conv: Conv): string {
	if (conv.type === "directory") return conversationDirectory;
	if (conv.type === "room") {
		const beginning = conversationBeginning((conv.earlierHistory ?? "none") as EarlierHistory);
		return beginning + (conv.held ? conversationPrivateRoom : conversationPublicRoom);
	}
	if (conv.line === "closed") return conversationClosedDirect(conv.id);
	return conv.line === "live" ? conversationLiveDirect : conversationPendingDirect;
}

function drawBlock(
	block: Block,
	nick: string,
	convKey: string,
	onRetry: (id: number) => void,
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
					<span>{logNewMessages}</span>
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
	//
	// The key is taken out of the conversation before the verbs close over it,
	// because the key is the whole of what they use. `conv` itself is a fresh
	// object on every arriving line, so a verb that captured it would either
	// rebind on every line — redrawing the rows these are memoised for — or
	// hold a stale object and depend on a comment to say why that is harmless.
	// Closing over the string is the same behavior with none of that to argue.
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const homeDir = useRoomsState((state) => state.homeDir);
	const convKey = conv?.key;
	const retry = useMemo(
		() => (id: number) => convKey != null && session.retry(convKey, id),
		[convKey, session],
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
		() => (id: number) => convKey != null && session.withdraw(convKey, id),
		[convKey, session],
	);
	return (
		<section id="log" ref={ref} aria-live="polite" aria-label={messagesLabel} hidden={hidden}>
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
						<div className="history-loading" role="status" aria-label={conversationLoadingEarlier}>
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
