// Inline completion for the composer: what the caret is in the middle of
// typing, and what could finish it. Pure functions of text and lists, with no
// DOM in sight, so the rules live under test rather than inside a component.
//
// Four sigils, one grammar. `@` completes a member, `#` a room, `:` an emoji,
// and `/` a composer command. A sigil only triggers at the start of the token
// under the caret, so `mail@host` and `10:30` stay plain text. `:` waits for one
// valid shortcode character, so a clause-ending colon or `:)` stays quiet.
// `/link` and `/join` also complete a listed room name as their argument,
// without needing `#`.

import { type CommandHere, commandIn, held } from "./commands.ts";
import { ROOM_MENTIONS_OFFERED } from "./text.ts";
import { EMOJI_TABLE } from "./emoji.ts";

export type TriggerKind = "nick" | "room" | "emoji" | "command";

/** The completable token under the caret: which sigil, where it starts, and
 * the query typed so far (without the sigil). */
export interface Trigger {
	kind: TriggerKind;
	/** Index of the sigil in the text; replacement spans [start, caret). */
	start: number;
	query: string;
	/** A room name after `/link` or `/join`, written without `#`. */
	bare?: true;
}

const NAME_QUERY = /^[\w-]*$/;
const EMOJI_QUERY = /^[a-z0-9_+-]+$/;

export function triggerAt(text: string, caret: number): Trigger | null {
	let start = caret;
	while (start > 0 && !/\s/.test(text[start - 1])) start--;
	if (start >= caret) return null;
	const sigil = text[start];
	const query = text.slice(start + 1, caret);
	if (sigil === "@" && NAME_QUERY.test(query)) return { kind: "nick", start, query };
	if (sigil === "#" && NAME_QUERY.test(query)) return { kind: "room", start, query };
	if (sigil === "/" && NAME_QUERY.test(query)) return { kind: "command", start, query };
	if (sigil === ":" && query.length >= 1 && EMOJI_QUERY.test(query)) {
		return { kind: "emoji", start, query };
	}
	return null;
}

/** A listed room name as the argument of `/link` or `/join`.
 *
 * `#lobby` still works; so does `lobby` without the hash. `/link` with nothing
 * after it is this room, so the list stays down until a name is started —
 * taking Enter for a row would steal the send that mints this room's link.
 * `/join` needs a destination, so an empty argument offers the listed rooms. */
export function commandArgTrigger(text: string, caret: number): Trigger | null {
	const named = commandIn(text);
	if (named?.command.argument !== "room") return null;
	const head = text.match(/^\/[\w-]+\s+/);
	if (head === null) return null;
	const start = head[0].length;
	if (caret < start) return null;
	const token = text.slice(start, caret);
	if (token.includes(" ") || token.includes("/") || token.includes(":")) return null;
	if (token.startsWith("#")) {
		const query = token.slice(1);
		if (!NAME_QUERY.test(query)) return null;
		return { kind: "room", start, query };
	}
	if (!NAME_QUERY.test(token)) return null;
	if (token === "" && named.command.needsArgument !== true) return null;
	return { kind: "room", start, query: token, bare: true };
}

/** One row the list offers: what accepting it puts in the draft in place of
 * the trigger, and what the row shows. */
export interface Candidate {
	kind: TriggerKind;
	/** Replaces [trigger.start, caret). Names carry their sigil and a trailing
	 * space so typing flows on; an emoji is just its glyph. */
	insert: string;
	/** The row's own name: the command, the person, the room, the shortcode. What
	 * a reader is picking, and the half that never gives up room. */
	label: string;
	/** What that name is, said after it and quieter. A command's summary, or what
	 * a room-wide mention reaches. It gives up room first, because the beginning
	 * of a summary is the part that answers "which one is this". */
	hint?: string;
	/** The glyph an emoji row leads with. */
	glyph?: string;
	/** Whether Enter still belongs to the list rather than to sending.
	 *
	 * True for every row that has something left to offer: more of a name than
	 * is typed, or a command's argument. It goes false only for a whole command
	 * that needs nothing after it, where the row is showing the reader what they
	 * have already written and taking their Enter for it would be a surprise.
	 * Tab accepts a row either way. */
	keepsEnter: boolean;
}

/** Lower is better; `Infinity` filters the row out. A prefix match beats a
 * substring match, and for emoji the code beats its keywords, so `:fir`
 * offers `fire` before anything that merely mentions it. */
/** Where `query` sits in `hay`, as a rank: at the front, somewhere inside, or
 * nowhere. Lower sorts first, and `Infinity` means it does not match at all.
 *
 * Shared with the rail's own fields, so a name offered there is ordered the way
 * the composer would order it and a reader learns one behaviour. */
export function rank(hay: string, query: string): number {
	if (query === "") return 0;
	const at = hay.toLowerCase().indexOf(query);
	if (at < 0) return Infinity;
	return at === 0 ? 0 : 1;
}

/* How many answers a list offers.
 *
 * A command list offers all of them. There are a couple of dozen, the set is
 * this client's own and does not grow with use, and `/` on its own is how a
 * reader finds out what they can do here: cutting that to the first handful
 * answered the question with a third of the answer and gave no sign the rest
 * existed. What a conversation cannot run is already off the list, so the
 * length is the honest one.
 *
 * The other lists are drawn from corpora nobody here bounds. There are a few
 * hundred emoji, and a room's roster is the room's to size, so those keep a
 * handful: a name or a glyph is something a reader is part-way through typing,
 * and ranking has the narrowing well in hand. */
const LIMITS: Readonly<Record<TriggerKind, number>> = {
	command: Number.MAX_SAFE_INTEGER,
	nick: 8,
	room: 8,
	emoji: 8,
};

const EMPTY_GRANTS: ReadonlySet<string> = new Set();

export function completeCandidates(
	trigger: Trigger,
	sources: {
		nicks: readonly string[];
		rooms: readonly string[];
		grants?: ReadonlySet<string>;
		here: CommandHere;
		/** What an `@` after the command in the draft completes against. Absent
		 * is a mention: somebody in this conversation, and in a room the room
		 * itself. `"reachable"` is a person to bring in, which is not a mention,
		 * so the room-wide names stay off that list. */
		targets?: "reachable";
	},
	limit: number = LIMITS[trigger.kind],
): Candidate[] {
	const query = trigger.query.toLowerCase();
	const scored: { score: number; candidate: Candidate }[] = [];
	const here = sources.here;
	if (trigger.kind === "command") {
		// What this conversation can actually run. The runner still knows every
		// name so a typed refusal stays precise; the list does not advertise one.
		for (const command of held(sources.grants ?? EMPTY_GRANTS, here)) {
			const score = rank(command.name, query);
			if (score === Infinity) continue;
			scored.push({
				score,
				candidate: {
					kind: "command",
					insert: `/${command.name} `,
					label: `/${command.name}`,
					hint: command.summary,
					// Written in full and needing nothing more, this row has nothing to
					// add, so Enter goes back to sending. Half typed it still completes
					// the name, and a command that takes an argument still leaves the
					// reader at it.
					keepsEnter: command.needsArgument === true || query !== command.name.toLowerCase(),
				},
			});
		}
	} else if (trigger.kind === "emoji") {
		for (const entry of EMOJI_TABLE) {
			let score = rank(entry.code, query);
			for (const word of entry.keywords) {
				score = Math.min(score, rank(word, query) + 2);
			}
			if (score === Infinity) continue;
			scored.push({
				score,
				candidate: {
					kind: "emoji",
					insert: entry.glyph,
					label: `:${entry.code}:`,
					glyph: entry.glyph,
					keepsEnter: true,
				},
			});
		}
	} else {
		const sigil = trigger.kind === "nick" ? "@" : trigger.bare === true ? "" : "#";
		// The room's own names sit among the members, because that is where a
		// reader reaches for them. Labelled apart, though: calling everyone is not
		// the same act as calling one person, and the list should say so before the
		// message does.
		const named = trigger.kind === "nick"
			? [
				...sources.nicks.map((name) => ({ name, says: name, hint: undefined, after: false })),
				// Room-wide names are mention vocabulary: they address everyone here,
				// they are not people. A command that declares `targets` is naming a
				// person to act on — `/invite`, `/msg` — so they stay off that list.
				...(here === "room" && sources.targets == null
					? ROOM_MENTIONS_OFFERED.map((name) => ({
						name,
						says: name,
						hint: "everyone in this room",
						// Ranked behind the people. With nothing typed, `@` is nearly always
						// reaching for somebody, and a handful of room-wide names at the top
						// would push the members out of a list this short. Typing toward one
						// still brings it straight up, because then nobody else matches.
						after: true,
					}))
					: []),
			]
			: sources.rooms.map((name) => ({ name, says: name, hint: undefined, after: false }));
		for (const { name, says, hint, after } of named) {
			const score = rank(name, query);
			if (score === Infinity) continue;
			scored.push({
				score: score + (after ? 1 : 0),
				// A name is a word inside a sentence rather than an instruction, so
				// its row keeps Enter even when the name is written out: what follows
				// it is the rest of what the reader was saying.
				candidate: { kind: trigger.kind, insert: `${sigil}${name} `, label: says, hint, keepsEnter: true },
			});
		}
	}
	scored.sort((a, b) => a.score - b.score || a.candidate.label.localeCompare(b.candidate.label));
	return scored.slice(0, limit).map((s) => s.candidate);
}

/** The draft after accepting `candidate`, and where the caret lands in it. */
export function acceptCompletion(
	text: string,
	trigger: Trigger,
	caret: number,
	candidate: Candidate,
): { text: string; caret: number } {
	// A name's trailing space is there so typing flows on; when the draft
	// already continues with one, adding another would double it.
	const insert = candidate.insert.endsWith(" ") && text[caret] === " "
		? candidate.insert.slice(0, -1)
		: candidate.insert;
	const next = text.slice(0, trigger.start) + insert + text.slice(caret);
	return { text: next, caret: trigger.start + insert.length };
}
