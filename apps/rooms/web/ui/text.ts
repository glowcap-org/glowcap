// Text the interface derives from a name or a message, with no DOM in sight.
// The data layer reads `mentionsYou` from here, which is why the pieces that
// build elements live next door in `RichText.tsx` instead.

// A stable per-name avatar tint, so every speaker keeps one colour. The ten values
// live in page.css as `--avatar-1` … `--avatar-10`, beside the rest of the rooms
// palette, because a colour written here cannot be themed and cannot be checked
// against the chip's white initials. This picks the slot; the stylesheet owns the
// colour.
const AVATAR_SLOTS = 10;
export function hueOf(name: string): string {
	let h = 0;
	for (let i = 0; i < name.length; i++) {
		h = (h * 31 + name.charCodeAt(i)) >>> 0;
	}
	return `var(--avatar-${(h % AVATAR_SLOTS) + 1})`;
}

export function initials(name: string): string {
	const parts = name.replace(/[^\p{L}\p{N} _-]/gu, "").split(/[ _-]+/).filter(Boolean);
	if (parts.length === 0) return "?";
	return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
}

export function fmtTime(d: Date): string {
	let h = d.getHours();
	const ampm = h >= 12 ? "PM" : "AM";
	h = h % 12 || 12;
	return h + ":" + String(d.getMinutes()).padStart(2, "0") + " " + ampm;
}

/** Which day an instant falls on, as a value two instants can be compared by.
 * The log groups by it and labels by it, so there is one of these. */
export function dayKey(at: number): string {
	const d = new Date(at);
	return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
}

/** The heading the log puts above the first message of a day. */
export function dayLabel(at: number): string {
	const today = Date.now();
	const yesterday = new Date();
	yesterday.setDate(yesterday.getDate() - 1);
	if (dayKey(at) === dayKey(today)) return "Today";
	if (dayKey(at) === dayKey(yesterday.getTime())) return "Yesterday";
	return new Date(at).toLocaleDateString(undefined, {
		weekday: "long",
		month: "long",
		day: "numeric",
	});
}

/** How this page tells someone what they typed will not fit.
 *
 * One phrasing, because it is one thing to say: a room name in the rail, a name
 * on the join card, and a message in the composer were each wording it
 * separately, which is three places for one decision about how the page speaks. */
export function tooLong(noun: string, max: number): string {
	return `${noun} too long (max ${max} characters)`;
}

/** Whether two lines belong in one stack: same author, close enough in time. */
export const GROUP_WINDOW_MS = 5 * 60 * 1000;

// ── Rich text: :shortcode: emoji, minimal markdown, links, @mentions ───────
const EMOJI: Record<string, string> = {
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

export function mentionsYou(text: string, nick: string): boolean {
	if (!nick) return false;
	const re = /@([\w][\w-]*)/g;
	let m: RegExpExecArray | null;
	while ((m = re.exec(text)) !== null) {
		if (m[1].toLowerCase() === nick.toLowerCase()) return true;
	}
	return false;
}
