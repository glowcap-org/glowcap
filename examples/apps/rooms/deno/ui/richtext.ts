import { state } from "./state.ts";

// A stable per-name avatar tint, drawn from pancake's warm palette so every
// speaker keeps one colour.
const AVATAR = [
	"#c76f18",
	"#257f88",
	"#a4560c",
	"#1b5f66",
	"#b5862f",
	"#5e8c61",
	"#9c4a2f",
	"#3a7d8c",
	"#7a5c34",
	"#2f6f78",
];
export function hueOf(name: string): string {
	let h = 0;
	for (let i = 0; i < name.length; i++) {
		h = (h * 31 + name.charCodeAt(i)) >>> 0;
	}
	return AVATAR[h % AVATAR.length];
}
export function initials(name: string): string {
	const parts = name.replace(/[^\p{L}\p{N} _-]/gu, "").split(/[ _-]+/).filter(
		Boolean,
	);
	if (parts.length === 0) return "?";
	return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
}
export function fmtTime(d: Date): string {
	let h = d.getHours();
	const ampm = h >= 12 ? "PM" : "AM";
	h = h % 12 || 12;
	return h + ":" + String(d.getMinutes()).padStart(2, "0") + " " + ampm;
}

// ── Rich text: :shortcode: emoji, minimal markdown, links, @mentions ───────
export const EMOJI: Record<string, string> = {
	":smile:": "😄",
	":laughing:": "😆",
	":grin:": "😁",
	":joy:": "😂",
	":wink:": "😉",
	":heart:": "❤️",
	":+1:": "👍",
	":-1:": "👎",
	":fire:": "🔥",
	":tada:": "🎉",
	":eyes:": "👀",
	":rocket:": "🚀",
	":wave:": "👋",
	":pancakes:": "🥞",
	":coffee:": "☕",
	":thinking:": "🤔",
	":sob:": "😭",
	":clap:": "👏",
	":100:": "💯",
	":ok_hand:": "👌",
	":star:": "⭐",
	":check:": "✅",
};
export const PICKER = [
	"😀",
	"😄",
	"😂",
	"😉",
	"😍",
	"🤔",
	"😎",
	"😭",
	"👍",
	"👎",
	"👏",
	"🙏",
	"🔥",
	"🎉",
	"❤️",
	"💯",
	"👀",
	"🚀",
	"🥞",
	"☕",
	"✨",
	"✅",
	"❌",
	"⭐",
];

export function substituteEmoji(text: string): string {
	return text.replace(/:[a-z0-9_+\-]+:/g, (m) => EMOJI[m] || m);
}
export function mentionsYou(text: string): boolean {
	if (!state.nick) return false;
	const re = /@([\w][\w-]*)/g;
	let m: RegExpExecArray | null;
	while ((m = re.exec(text)) !== null) {
		if (m[1].toLowerCase() === state.nick.toLowerCase()) return true;
	}
	return false;
}
// Build a safe DOM fragment. Every literal goes in via textContent / .href, so
// message text can never inject markup.
export function renderRich(text: string): DocumentFragment {
	const frag = document.createDocumentFragment();
	const s = substituteEmoji(text);
	const re =
		/(\x60[^\x60]+\x60)|(\*\*[^*]+\*\*)|(~~[^~]+~~)|(\*[^*]+\*)|(_[^_]+_)|(https?:\/\/[^\s]+)|(@[\w][\w-]*)/g;
	let i = 0;
	let m: RegExpExecArray | null;
	while ((m = re.exec(s)) !== null) {
		if (m.index > i) {
			frag.appendChild(document.createTextNode(s.slice(i, m.index)));
		}
		let node: HTMLElement;
		if (m[1]) {
			node = document.createElement("code");
			node.textContent = m[1].slice(1, -1);
		} else if (m[2]) {
			node = document.createElement("strong");
			node.textContent = m[2].slice(2, -2);
		} else if (m[3]) {
			node = document.createElement("s");
			node.textContent = m[3].slice(2, -2);
		} else if (m[4]) {
			node = document.createElement("em");
			node.textContent = m[4].slice(1, -1);
		} else if (m[5]) {
			node = document.createElement("em");
			node.textContent = m[5].slice(1, -1);
		} else if (m[6]) {
			let url = m[6], trail = "";
			const tm = url.match(/[)\].,!?:;]+$/);
			if (tm) {
				trail = tm[0];
				url = url.slice(0, -trail.length);
			}
			const a = document.createElement("a");
			a.href = url;
			a.target = "_blank";
			a.rel = "noopener noreferrer";
			a.textContent = url;
			frag.appendChild(a);
			if (trail) frag.appendChild(document.createTextNode(trail));
			i = m.index + m[0].length;
			continue;
		} else {
			node = document.createElement("span");
			node.className = "mention" +
				(state.nick && m[7].slice(1).toLowerCase() === state.nick.toLowerCase()
					? " you"
					: "");
			node.textContent = m[7];
		}
		frag.appendChild(node);
		i = m.index + m[0].length;
	}
	if (i < s.length) frag.appendChild(document.createTextNode(s.slice(i)));
	return frag;
}
export function makeBubble(text: string, highlight: boolean): HTMLElement {
	const b = document.createElement("div");
	b.className = "bubble" + (highlight ? " hl" : "");
	b.appendChild(renderRich(text));
	return b;
}
