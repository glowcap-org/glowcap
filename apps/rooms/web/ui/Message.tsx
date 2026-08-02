// One stack of messages from one speaker, and the small toolbar that hangs off
// it. Consecutive lines from the same person inside a few minutes share a row:
// one avatar, one name, one timestamp, and a bubble each.
//
// The row is memoised on the group it was given, so a message arriving in a busy
// room repaints the newest row and leaves the rest of the log alone.

import { memo } from "react";
import type { ChatItem } from "./types.ts";
import { fmtTime, hueOf, initials, mentionsYou } from "./text.ts";
import { RichText } from "./RichText.tsx";
import { usePeer } from "./peer.ts";

/** A run of lines from one speaker, as the log groups them. */
export interface Group {
	from: string;
	mine: boolean;
	items: ChatItem[];
}

function Bubble(
	{ item, nick, onRetry }: { item: ChatItem; nick: string; onRetry: (id: number) => void },
) {
	const highlight = !item.mine && mentionsYou(item.text, nick);
	const body = <RichText text={item.text} nick={nick} />;
	const className = "bubble" + (highlight ? " hl" : "") +
		(item.state ? " " + item.state : "");
	// A line the wire refused is the one bubble that is also a control: tapping it
	// sends it again. Everything else is text, and says nothing to a screen reader
	// beyond what it reads.
	if (item.state === "failed") {
		return (
			<div
				className={className}
				title="Not sent — tap to retry"
				role="button"
				tabIndex={0}
				aria-label="Message not sent, tap to retry"
				onClick={() => onRetry(item.id)}
				onKeyDown={(e) => {
					if (e.key !== "Enter" && e.key !== " ") return;
					e.preventDefault();
					onRetry(item.id);
				}}
			>
				{body}
			</div>
		);
	}
	return (
		<div className={className} title={item.state === "sending" ? "Sending…" : undefined}>
			{body}
		</div>
	);
}

// Copy the message, or drop an @mention of the author into the composer.
function Acts({ group, onMention }: { group: Group; onMention: (who: string) => void }) {
	const peer = usePeer();
	return (
		<div className="acts">
			<button
				type="button"
				title="Copy message"
				onClick={() => {
					const text = group.items.map((item) => item.text).join("\n");
					// A reader pressed this and expects something to have happened.
					// Clipboard access can be refused outright, and saying nothing
					// leaves them to discover it by pasting.
					navigator.clipboard?.writeText(text).catch(() =>
						peer.banner("Your browser would not let the page copy that.")
					);
				}}
			>
				Copy
			</button>
			<button
				type="button"
				title={"Mention " + group.from}
				onClick={() => onMention(group.from)}
			>
				@
			</button>
		</div>
	);
}

// A group is rebuilt on every pass over the history, so identity says nothing.
// What matters is whether it holds the same lines, and a line is only replaced
// when it actually changes — so comparing the members element by element lets an
// arriving message repaint one row instead of the whole log.
function sameGroup(a: Group, b: Group): boolean {
	// `blocksOf` is memoised, so when the history has not changed these are the
	// same object and the walk below is skipped entirely.
	if (a === b) return true;
	if (a.from !== b.from || a.mine !== b.mine || a.items.length !== b.items.length) return false;
	return a.items.every((item, at) => item === b.items[at]);
}

export const MessageGroup = memo(function MessageGroup(
	{ group, nick, onRetry, onMention }: {
		group: Group;
		nick: string;
		onRetry: (id: number) => void;
		onMention: (who: string) => void;
	},
) {
	const last = group.items[group.items.length - 1];
	// The bubble already carries its author and the sidebar its arrival, so the
	// per-line timestamp is decorative for a screen reader; it is hidden from the
	// tree rather than read out with every line.
	const stack = (
		<div className="stack">
			{!group.mine && <div className="who">{group.from}</div>}
			{group.items.map((item) => (
				<Bubble key={item.id} item={item} nick={nick} onRetry={onRetry} />
			))}
			<div className="time" aria-hidden="true">{fmtTime(new Date(last.at))}</div>
		</div>
	);
	return (
		<div className={"row " + (group.mine ? "mine" : "them")} data-from={group.from}>
			{!group.mine && (
				// Purely a coloured initial; the author is already spoken in the `who` line.
				<div
					className="avatar"
					aria-hidden="true"
					style={{ background: hueOf(group.from) }}
				>
					{initials(group.from)}
				</div>
			)}
			{stack}
			<Acts group={group} onMention={onMention} />
		</div>
	);
}, (prev, next) =>
	prev.nick === next.nick &&
	prev.onRetry === next.onRetry &&
	prev.onMention === next.onMention &&
	sameGroup(prev.group, next.group));
