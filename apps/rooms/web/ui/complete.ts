// Inline completion for the composer: what the caret is in the middle of
// typing, and what could finish it. Pure functions of text and lists, with no
// DOM in sight, so the rules live under test rather than inside a component.
//
// Four sigils, one grammar. `@` completes a member, `#` a room, `:` an emoji,
// and `/` a composer command. A sigil only triggers at the start of the token
// under the caret, so `mail@host` and `10:30` stay plain text. `:` waits for one
// valid shortcode character, so a clause-ending colon or `:)` stays quiet.

import { held, known } from "./commands.ts";
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

/** One row the list offers: what accepting it puts in the draft in place of
 * the trigger, and what the row shows. */
export interface Candidate {
	kind: TriggerKind;
	/** Replaces [trigger.start, caret). Names carry their sigil and a trailing
	 * space so typing flows on; an emoji is just its glyph. */
	insert: string;
	/** The row's text: a name, or an emoji shortcode. */
	label: string;
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
function rank(hay: string, query: string): number {
	if (query === "") return 0;
	const at = hay.toLowerCase().indexOf(query);
	if (at < 0) return Infinity;
	return at === 0 ? 0 : 1;
}

const LIMIT = 8;

const EMPTY_GRANTS: ReadonlySet<string> = new Set();

export function completeCandidates(
	trigger: Trigger,
	sources: { nicks: readonly string[]; rooms: readonly string[]; grants?: ReadonlySet<string> },
	limit: number = LIMIT,
): Candidate[] {
	const query = trigger.query.toLowerCase();
	const scored: { score: number; candidate: Candidate }[] = [];
	if (trigger.kind === "command") {
		// What this conversation has actually been handed. Everything known is
		// still offered, held or not, so a reader can discover a command and be
		// told what it waits for rather than typing into silence.
		const mine = new Set(held(sources.grants ?? EMPTY_GRANTS).map((command) => command.name));
		// The command vocabulary lives in one place and feeds both the list a
		// reader is offered and the runner that answers it, so a command cannot be
		// suggested and then not exist. Everything known is offered, including the
		// ones the room has not granted: being told what a command waits for is
		// better than typing it into silence.
		for (const command of known()) {
			const score = rank(command.name, query);
			if (score === Infinity) continue;
			scored.push({
				score,
				candidate: {
					kind: "command",
					insert: `/${command.name} `,
					// A command this conversation has not been handed says so where it
					// is offered, so a reader meets the distinction before they meet the
					// refusal. One the room did hand over is not marked: holding it is
					// ordinary, and a mark would read as a warning about a command that
					// works.
					label: `/${command.name} — ${command.summary}${
						mine.has(command.name) ? "" : " (not granted here)"
					}`,
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
		const sigil = trigger.kind === "nick" ? "@" : "#";
		// The room's own names sit among the members, because that is where a
		// reader reaches for them. Labelled apart, though: calling everyone is not
		// the same act as calling one person, and the list should say so before the
		// message does.
		const named = trigger.kind === "nick"
			? [
				...sources.nicks.map((name) => ({ name, says: name, after: false })),
				...ROOM_MENTIONS_OFFERED.map((name) => ({
					name,
					says: `${name} — everyone in this room`,
					// Ranked behind the people. With nothing typed, `@` is nearly always
					// reaching for somebody, and a handful of room-wide names at the top
					// would push the members out of a list this short. Typing toward one
					// still brings it straight up, because then nobody else matches.
					after: true,
				})),
			]
			: sources.rooms.map((name) => ({ name, says: name, after: false }));
		for (const { name, says, after } of named) {
			const score = rank(name, query);
			if (score === Infinity) continue;
			scored.push({
				score: score + (after ? 1 : 0),
				// A name is a word inside a sentence rather than an instruction, so
				// its row keeps Enter even when the name is written out: what follows
				// it is the rest of what the reader was saying.
				candidate: { kind: trigger.kind, insert: `${sigil}${name} `, label: says, keepsEnter: true },
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
