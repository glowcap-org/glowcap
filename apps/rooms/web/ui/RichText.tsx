// A message line, with its code spans, emphasis, links, and @mentions.
//
// Nothing here can inject markup, and that is now a property of the shape rather
// than a rule to remember: every piece of the message becomes a JSX child, and
// React writes children as text. The old version built the same tree by hand and
// had to route every literal through `textContent` to get the same guarantee.

import { Fragment, type ReactNode } from "react";
import { mentionsYou, substituteEmoji } from "./text.ts";

// One pattern, one alternative per kind of span, in the order they win.
const SPAN =
	/(\x60[^\x60]+\x60)|(\*\*[^*]+\*\*)|(~~[^~]+~~)|(\*[^*]+\*)|(_[^_]+_)|(https?:\/\/[^\s]+)|(@[\w][\w-]*)/g;

function span(m: RegExpExecArray, key: number, nick: string): ReactNode {
	if (m[1]) return <code key={key}>{m[1].slice(1, -1)}</code>;
	if (m[2]) return <strong key={key}>{m[2].slice(2, -2)}</strong>;
	if (m[3]) return <s key={key}>{m[3].slice(2, -2)}</s>;
	if (m[4]) return <em key={key}>{m[4].slice(1, -1)}</em>;
	if (m[5]) return <em key={key}>{m[5].slice(1, -1)}</em>;
	if (m[6]) {
		// Punctuation that closes the sentence rather than the link: keep it as
		// text, so a URL at the end of a line does not swallow the full stop.
		const trail = m[6].match(/[)\].,!?:;]+$/)?.[0] ?? "";
		const url = trail ? m[6].slice(0, -trail.length) : m[6];
		return (
			<Fragment key={key}>
				<a href={url} target="_blank" rel="noopener noreferrer">{url}</a>
				{trail}
			</Fragment>
		);
	}
	const you = mentionsYou(m[7], nick);
	return <span key={key} className={you ? "mention you" : "mention"}>{m[7]}</span>;
}

export function RichText({ text, nick }: { text: string; nick: string }) {
	const s = substituteEmoji(text);
	const out: ReactNode[] = [];
	let at = 0;
	let m: RegExpExecArray | null;
	SPAN.lastIndex = 0;
	while ((m = SPAN.exec(s)) !== null) {
		if (m.index > at) out.push(s.slice(at, m.index));
		out.push(span(m, m.index, nick));
		at = m.index + m[0].length;
	}
	if (at < s.length) out.push(s.slice(at));
	return <>{out}</>;
}
