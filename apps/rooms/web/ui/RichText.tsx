// A message line, with fenced and inline code, emphasis, links, and @mentions.
//
// Nothing here can inject markup, and that is now a property of the shape rather
// than a rule to remember: every piece of the message becomes a JSX child, and
// React writes children as text. The old version built the same tree by hand and
// had to route every literal through `textContent` to get the same guarantee.

import { Fragment, type ReactNode, useState } from "react";
import { hasIrcFormatting, type IrcRun, ircRuns, mentionsYou, ROOM_MENTIONS, substituteEmoji } from "./text.ts";

// One pattern, one alternative per kind of span, in the order they win.
const SPAN =
	/(\x60[^\x60]+\x60)|(\|\|[^|]+\|\|)|(\*\*[^*]+\*\*)|(~~[^~]+~~)|(\*[^*]+\*)|(_[^_]+_)|(https?:\/\/[^\s]+)|(@[\w][\w-]*)/g;
const FENCE = /```([a-zA-Z0-9_+-]*)[^\S\r\n]*(?:\r?\n)([\s\S]*?)(?:\r?\n)?```/g;

function span(m: RegExpExecArray, key: number, nick: string): ReactNode {
	if (m[1]) return <code key={key}>{m[1].slice(1, -1)}</code>;
	// Covered until it is asked for. A button rather than a span that reveals on
	// hover, because a pointer passing over a spoiler should not spend it — and
	// because a reader without a pointer needs a way to ask at all.
	if (m[2]) return <Spoiler key={key} text={m[2].slice(2, -2)} />;
	if (m[3]) return <strong key={key}>{m[3].slice(2, -2)}</strong>;
	if (m[4]) return <s key={key}>{m[4].slice(2, -2)}</s>;
	if (m[5]) return <em key={key}>{m[5].slice(1, -1)}</em>;
	if (m[6]) return <em key={key}>{m[6].slice(1, -1)}</em>;
	if (m[7]) {
		// Punctuation that closes the sentence rather than the link: keep it as
		// text, so a URL at the end of a line does not swallow the full stop.
		const trail = m[7].match(/[)\].,!?:;]+$/)?.[0] ?? "";
		const url = trail ? m[7].slice(0, -trail.length) : m[7];
		return (
			<Fragment key={key}>
				<a href={url} target="_blank" rel="noopener noreferrer">{url}</a>
				{trail}
			</Fragment>
		);
	}
	// Three readings, not two. A name that is not yours is a mention; your own
	// name is one addressed to you; and a room-wide call is addressed to you as
	// one of everybody, which is a different thing again and is drawn as its own
	// rather than borrowed from either.
	const wide = ROOM_MENTIONS.includes(m[8].slice(1).toLowerCase());
	const you = mentionsYou(m[8], nick);
	const how = wide ? "mention room" : you ? "mention you" : "mention";
	return <span key={key} className={how}>{m[8]}</span>;
}

/** Text nobody reads until they ask.
 *
 * A real control rather than a hover reveal: a pointer crossing a line should
 * not spend its surprise, a phone has no hover to reveal with, and a reader on
 * a keyboard needs a way to ask at all. Once asked it stays open — a spoiler
 * that re-covers itself is a thing you have to keep asking. */
function Spoiler({ text }: { text: string }) {
	const [shown, setShown] = useState(false);
	return shown ? <span className="spoiler shown">{text}</span> : (
		<button
			type="button"
			className="spoiler"
			aria-label="Show hidden text"
			onClick={() => setShown(true)}
		>
			{text}
		</button>
	);
}

/** One IRC-formatted stretch, wrapped in what was in force across it.
 *
 * The emphasis is drawn with the same elements the app's own marks produce, so
 * a bold word is bold however it was written. Colour is a class per number
 * rather than a style, because mIRC's palette is sixteen names and what those
 * look like is the stylesheet's to say — the same rule every other colour here
 * follows. */
function IrcSpan({ run, children }: { run: IrcRun; children: ReactNode }) {
	let out = children;
	if (run.mono) out = <code>{out}</code>;
	if (run.strike) out = <s>{out}</s>;
	if (run.italic) out = <em>{out}</em>;
	if (run.bold) out = <strong>{out}</strong>;
	if (run.underline) out = <u>{out}</u>;
	if (run.fg === undefined && run.bg === undefined) return <>{out}</>;
	const paint = [run.fg === undefined ? "" : `irc-fg-${run.fg}`, run.bg === undefined ? "" : `irc-bg-${run.bg}`]
		.filter(Boolean)
		.join(" ");
	return <span className={paint}>{out}</span>;
}

function inline(text: string, nick: string, keyAt: number): ReactNode[] {
	// A line relayed from IRC carries its emphasis as control characters. Split
	// on those first, then read each stretch the ordinary way, so a bridged
	// message keeps both its own formatting and everything this app understands.
	// Lines this app writes carry none of them and take the path below unchanged.
	if (hasIrcFormatting(text)) {
		return ircRuns(text).map((run, at) => (
			<IrcSpan key={`irc${keyAt}-${at}`} run={run}>{inline(run.text, nick, keyAt + at)}</IrcSpan>
		));
	}
	const s = substituteEmoji(text);
	const out: ReactNode[] = [];
	let at = 0;
	let m: RegExpExecArray | null;
	SPAN.lastIndex = 0;
	while ((m = SPAN.exec(s)) !== null) {
		if (m.index > at) out.push(s.slice(at, m.index));
		out.push(span(m, keyAt + m.index, nick));
		at = m.index + m[0].length;
	}
	if (at < s.length) out.push(s.slice(at));
	return out;
}

/** Everything between the fences: quoted runs, and ordinary lines.
 *
 * A quote is the one thing here that is a *block* rather than a span, so it is
 * read a line at a time out here rather than by the inline pattern, which knows
 * nothing about where a line begins. Consecutive quoted lines join into one
 * quote, the way anybody who has pasted three lines of somebody else expects. */
function prose(text: string, nick: string, keyAt: number): ReactNode[] {
	const out: ReactNode[] = [];
	const lines = text.split("\n");
	let quoted: string[] = [];
	let plain: string[] = [];
	const flushQuote = (at: number) => {
		if (quoted.length === 0) return;
		out.push(
			<blockquote key={`q${keyAt}-${at}`}>{inline(quoted.join("\n"), nick, keyAt + at)}</blockquote>,
		);
		quoted = [];
	};
	const flushPlain = (at: number) => {
		if (plain.length === 0) return;
		out.push(...inline(plain.join("\n"), nick, keyAt + at));
		plain = [];
	};
	lines.forEach((line, at) => {
		const quote = line.match(/^\s*>\s?(.*)$/);
		if (quote !== null) {
			flushPlain(at);
			quoted.push(quote[1]);
		} else {
			flushQuote(at);
			plain.push(line);
		}
	});
	flushQuote(lines.length);
	flushPlain(lines.length);
	return out;
}

export function RichText({ text, nick }: { text: string; nick: string }) {
	const out: ReactNode[] = [];
	let at = 0;
	let fence: RegExpExecArray | null;
	FENCE.lastIndex = 0;
	while ((fence = FENCE.exec(text)) !== null) {
		if (fence.index > at) out.push(...prose(text.slice(at, fence.index), nick, at));
		out.push(
			<pre key={fence.index} className="code-block" data-language={fence[1] || undefined}>
				<code>{fence[2]}</code>
			</pre>,
		);
		at = fence.index + fence[0].length;
	}
	if (at < text.length) out.push(...prose(text.slice(at), nick, at));
	return <>{out}</>;
}
