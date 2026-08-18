// Text the interface derives from a name or a message, with no DOM in sight.
// The data layer reads `mentionsYou` from here, which is why the pieces that
// build elements live next door in `RichText.tsx` instead.

import type { DirId, SessionPhase } from "./types.ts";
import { lineCost, MAX_LINE, MAX_NICK, ROOM_MENTIONS } from "../../lib/limits.ts";

/** How a directory's connection reads in words. The dot beside it carries the
 * same fact in shape and colour; this is what a reader who has neither gets. */
export const PHASE_SAID: Record<SessionPhase, string> = {
	connected: "Connected",
	connecting: "Connecting…",
	reconnecting: "Reconnecting…",
	disconnected: "Not connected",
};

/** The rail foot's state row, said under the reader's own name.
 *
 * One producer for the one line, by one priority rule. The connection's story
 * wins while there is one, as the plain phase word: this line is under the
 * reader's own name, so it says how they stand rather than narrating what a
 * connection is doing. The net layer's own sentences — reaching this
 * locator, entering that room — are about a directory, and the card
 * describing that directory is where they are read; a forty-character
 * locator in the reader's standing line says nothing about the reader and
 * crowds out the one thing this line is for. A settled connection lets that
 * word through: their standing when they set one, worn in the roster's away
 * tint, and otherwise a quiet "here" once a directory has granted a name, or
 * the plain connected word before one has. */
export interface FootState {
	said: string;
	/** Whether the row is the reader's standing, which is the one arm the foot
	 * tints the way the roster tints a member's away reason. */
	away: boolean;
}

export function footState(
	session: SessionPhase,
	standing: string,
	named: boolean,
): FootState {
	if (session !== "connected") return { said: PHASE_SAID[session].toLowerCase(), away: false };
	if (standing !== "") return { said: standing, away: true };
	return { said: named ? "here" : PHASE_SAID.connected.toLowerCase(), away: false };
}

// A stable per-name avatar tint, so every speaker keeps one colour. The ten values
// live in the rooms stylesheets as `--avatar-1` … `--avatar-10`, beside the rest of the rooms
// palette, because a colour written here cannot be themed and cannot be checked
// against the chip's white initials. This picks the slot; the stylesheet owns the
// colour.
const AVATAR_SLOTS = 10;

/** A locator is escaped for a wire, and what comes back out of one is not a name:
 * a port reads as `127.0.0.1%3A6000` until the escaping is undone. Undone only
 * for the name — the locator itself is copied and dialled exactly as it arrived,
 * from `DirId`, never from this. A malformed escape is left as it is rather than
 * throwing, because a directory that named itself badly still has to appear. */
function readable(text: string): string {
	try {
		return decodeURIComponent(text);
	} catch {
		return text;
	}
}

/** What to call a directory in the interface.
 *
 * A locator is an address, not a name. Forty characters of designator cannot be
 * read aloud and two of them cannot be told apart at a glance, so a directory
 * is named by whatever part of it a person could actually say, and the exact
 * locator stays one copy away in Settings.
 *
 * The directory this page came with is `this directory`, because it is the one a
 * reader never chose: showing them its address answers a question they did not
 * ask, and the address bar already says where the page came from. */
export function directoryName(id: DirId, home: DirId | null): string {
	if (home !== null && id === home) return "this directory";
	const locator = id as string;
	if (locator === "") return "this directory";
	if (!locator.includes("://")) return readable(locator);
	const authority = readable(locator.slice(locator.indexOf("://") + 3).split("/")[0]);
	const dot = authority.lastIndexOf(".");
	const designator = dot < 0 ? authority : authority.slice(0, dot);
	const transport = dot < 0 ? "" : authority.slice(dot + 1);
	if (designator.length <= 24) return designator;
	return (transport || "peer") + " " + designator.slice(0, 4);
}

/** How a room is named in speech and in the tab title. A public room is its
 * hash-name; a private one is only its label, because that label is not a name
 * anybody can enter. The lock that stands in for the hash is drawn, not spelled. */
export function roomCalled(id: string, held: boolean): string {
	return held ? id : "#" + id;
}

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
	// By code point, not code unit: the nick rule admits letters of every
	// script, and `parts[0][0]` on an astral-plane letter is half a surrogate
	// pair, which draws as replacement-character garbage in the chip.
	const first = [...parts[0]][0];
	const second = parts[1] ? [...parts[1]][0] : "";
	return (first + second).toUpperCase();
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

/** Why a line from somebody else cannot be shown, or null when it can.
 *
 * A room holds its members to its cap, and a room is not the only source: a
 * direct line has no room in its path at all, and a room is whatever answered
 * the address a reader typed. What arrives is drawn into the log and walked by
 * the rich-text pass, so an unbounded line is an unbounded amount of both, and
 * an author nobody can name is a line this app cannot attribute honestly.
 *
 * Refused rather than cut. A sentence cut in half can say the opposite of what
 * it said, and this app would be the one saying it. */
export function lineNotShowable(from: string, text: string): string | null {
	if (from.length > MAX_NICK) {
		return "A line arrived under a name longer than any this app grants, so it is not here.";
	}
	if (lineCost(text) > MAX_LINE) {
		return `${from} sent a line longer than this app will show, so it is not here.`;
	}
	return null;
}

/** Whether two lines belong in one stack: same author, close enough in time. */
export const GROUP_WINDOW_MS = 5 * 60 * 1000;

// ── Rich text: :shortcode: emoji, minimal markdown, links, @mentions ───────
// The emoji themselves live in `emoji.ts`, the one table the tray, the
// substitution below, and completion all read.
import { EMOJI_BY_CODE } from "./emoji.ts";

// The tray's page of favourites, an ordering over the shared table. A code
// listed here but absent from the table is a broken derivation, so the lookup
// throws rather than skipping quietly.
const PICKER_CODES = [
	"grinning",
	"smile",
	"joy",
	"wink",
	"heart_eyes",
	"thinking",
	"sunglasses",
	"sob",
	"+1",
	"-1",
	"clap",
	"pray",
	"fire",
	"tada",
	"heart",
	"100",
	"eyes",
	"rocket",
	"pancakes",
	"coffee",
	"sparkles",
	"check",
	"x",
	"star",
] as const;
export const PICKER: readonly string[] = PICKER_CODES.map((code) => {
	const glyph = EMOJI_BY_CODE.get(`:${code}:`);
	if (glyph === undefined) throw new Error(`picker names an emoji the table lacks: ${code}`);
	return glyph;
});

export function substituteEmoji(text: string): string {
	return text.replace(/:[a-z0-9_+\-]+:/g, (m) => EMOJI_BY_CODE.get(m) ?? m);
}

/** What may appear in a name, written once for everything that reads one.
 *
 * Wider than this app's own names on purpose. A room bridged to IRC carries
 * members whose nicks were legal there, and IRC has allowed `[ ] \ ` _ ^ { | }`
 * since before this app existed — so `@some[nick]` has to highlight, notify and
 * complete like any other. Reading a name is a question about syntax rather
 * than about authority, which is why it is settled here rather than by a mode
 * somebody turns on: there is no version of this page where that name should be
 * met as ordinary text.
 *
 * A trailing hyphen or dot is left out of a match so a name at the end of a
 * sentence does not swallow the punctuation, the same rule links follow. */
const NAME_CHARS = String.raw`\w\[\]\\\`^{|}-`;
const MENTION = new RegExp(String.raw`@([${NAME_CHARS}]*[\w\[\]\\\`^{|}])`, "g");

/** The names that reach a whole room rather than one person.
 *
 * IRC never had these — it had operators and a channel notice — but every chat
 * since has converged on the same handful of words, and a reader's fingers know
 * them. All three are kept rather than one blessed spelling, because a person
 * arriving from another client should be understood rather than corrected.
 *
 * They mean "everyone here" and are answered as a mention of you, because you
 * are one of everyone. What separates them from a name is that nobody can be
 * called one: the directory refuses to grant any of them (`nickRefusal`), so
 * the words stay vocabulary. The list itself lives beside that reservation in
 * `lib/limits.ts`, one authority for both readings. */
export { ROOM_MENTIONS } from "../../lib/limits.ts";

/** The two the composer offers.
 *
 * Every spelling above is understood, because a person arriving from another
 * client should be read rather than corrected. Only these two are suggested,
 * because a list is a recommendation and five ways to say one thing is not a
 * recommendation — it is five ways to wonder which is right. Liberal in what it
 * accepts, brief in what it proposes. */
export const ROOM_MENTIONS_OFFERED: readonly string[] = ["here", "room"];

/** Whether a line reaches this reader: by their name, or by naming the room.
 *
 * The one answer both the highlight in the log and the desktop notification
 * read, so a line cannot light up without notifying or the other way round. */
/** The longest line this conversation will carry, in bytes.
 *
 * The tighter of what this app allows and what the room says of itself, so a
 * room with nothing to say about it is capped exactly as before. One answer,
 * read both by the counter that warns and by the send that refuses — two
 * numbers here would eventually disagree, and the disagreement would be a
 * message a reader was told they could send and then could not. */
export function lineRoom(conv: { type: "room"; lineBytes?: number } | { type: "dm" } | null, appMax: number): number {
	if (conv === null || conv.type !== "room" || conv.lineBytes === undefined) return appMax;
	return Math.min(appMax, conv.lineBytes);
}

// ── IRC formatting, as it arrives over a bridge ───────────────────────────
// IRC carries emphasis as control characters rather than as marks a person
// types: a byte turns bold on, the same byte turns it off again, and a reset
// clears everything. They are toggles rather than delimiters, so they nest by
// state and not by pairing, and a line may leave one on at its end.
//
// Nothing here writes them. This is the reading half, so a line relayed from an
// IRC channel arrives looking the way its author wrote it rather than carrying
// invisible characters that show as nothing and mean something.
const IRC_BOLD = "\x02";
const IRC_COLOUR = "\x03";
const IRC_MONO = "\x11";
const IRC_REVERSE = "\x16";
const IRC_RESET = "\x0F";
const IRC_ITALIC = "\x1D";
const IRC_STRIKE = "\x1E";
const IRC_UNDERLINE = "\x1F";

/** Whether a line carries any IRC formatting at all, so the ordinary path is
 * untouched for the messages this app writes itself. */
export function hasIrcFormatting(text: string): boolean {
	// deno-lint-ignore no-control-regex
	return /[\x02\x03\x0F\x11\x16\x1D\x1E\x1F]/.test(text);
}

/** One stretch of a line, with the emphasis in force across it. */
export interface IrcRun {
	text: string;
	bold: boolean;
	italic: boolean;
	underline: boolean;
	strike: boolean;
	mono: boolean;
	/** mIRC's numbered palette, as written. Kept as the number rather than a
	 * colour because what those numbers mean is a decision for the stylesheet,
	 * the same way every other colour in this interface is. */
	fg?: number;
	bg?: number;
}

/** Split a line into runs by the formatting in force across each.
 *
 * A toggle flips its own state and leaves the rest alone; a reset clears all of
 * them. Reverse swaps foreground and background, which is how IRC says
 * "highlight" — kept as the swap rather than resolved here, because the palette
 * it swaps within belongs to the stylesheet. */
export function ircRuns(text: string): IrcRun[] {
	const runs: IrcRun[] = [];
	let bold = false, italic = false, underline = false, strike = false, mono = false;
	let fg: number | undefined;
	let bg: number | undefined;
	let held = "";
	const cut = () => {
		if (held === "") return;
		runs.push({ text: held, bold, italic, underline, strike, mono, fg, bg });
		held = "";
	};
	for (let at = 0; at < text.length; at++) {
		const c = text[at];
		if (c === IRC_BOLD) {
			cut();
			bold = !bold;
			continue;
		}
		if (c === IRC_ITALIC) {
			cut();
			italic = !italic;
			continue;
		}
		if (c === IRC_UNDERLINE) {
			cut();
			underline = !underline;
			continue;
		}
		if (c === IRC_STRIKE) {
			cut();
			strike = !strike;
			continue;
		}
		if (c === IRC_MONO) {
			cut();
			mono = !mono;
			continue;
		}
		if (c === IRC_REVERSE) {
			cut();
			[fg, bg] = [bg, fg];
			continue;
		}
		if (c === IRC_RESET) {
			cut();
			bold =
				italic =
				underline =
				strike =
				mono =
					false;
			fg = bg = undefined;
			continue;
		}
		if (c === IRC_COLOUR) {
			cut();
			// `\x03` alone clears colour; otherwise up to two digits of foreground
			// and, after a comma, up to two of background.
			const rest = text.slice(at + 1);
			const named = rest.match(/^(\d{1,2})(?:,(\d{1,2}))?/);
			if (named === null) {
				fg = bg = undefined;
				continue;
			}
			fg = Number(named[1]);
			bg = named[2] === undefined ? bg : Number(named[2]);
			at += named[0].length;
			continue;
		}
		held += c;
	}
	cut();
	return runs;
}

export function mentionsYou(text: string, nick: string): boolean {
	const re = new RegExp(MENTION.source, "g");
	let m: RegExpExecArray | null;
	while ((m = re.exec(text)) !== null) {
		const named = m[1].toLowerCase();
		if (ROOM_MENTIONS.includes(named)) return true;
		if (nick && named === nick.toLowerCase()) return true;
	}
	return false;
}
