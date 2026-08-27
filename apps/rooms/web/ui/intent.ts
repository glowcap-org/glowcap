// What the reader meant, and how firmly they meant it.
//
// A form field is not state. It is an answer, and an answer only makes sense
// beside the question that was asked. The join card asks "which room, on which
// directory, under what name", and the honest answer depends entirely on how
// the reader got in front of it: following a link to a room is a different
// question from pressing "add a room" in the rail, and both are different from
// opening the page cold.
//
// Kept as four remembered fields the whole application wrote into, the card
// could not tell those apart, so it answered all three the same way and got two
// of them wrong. A link to a room in this page's directory would arrive with
// the locator of some other directory sitting in the field, because that was
// the last one anybody had typed. The gate on a link named one place and
// offered another.
//
// So an act is recorded rather than its consequences. Each act says where it
// came from and what it names, presentation resolves the fields from it, and
// the reader's own typing is one more act over the top. Values flow one way:
//
//     act ─┐
//   edits ─┼─► settle ─► what the card shows
//  memory ─┤
// default ─┘
//
// Nothing writes a field directly, so no surface can leave a value behind for
// the next one to find.

/** Where an act came from.
 *
 * Only these three exist because only these three are a reader doing
 * something. A presentation the application caused by itself — bounced back to
 * the card by a directory going away, or landing there after leaving the last
 * room — files no act at all, which is the whole of what "no user intent"
 * means here. Filing one would be the application putting words in the
 * reader's mouth; filing none leaves the last real answer standing, and
 * leaves anything the reader had typed exactly where they left it. */
export type Source =
	/** A control on this page was operated. */
	| "press"
	/** An address: typed, pasted, followed from elsewhere, or walked to with
	 * the browser's own back and forward. */
	| "link"
	/** This browser reopening what it had, with nobody naming anything. */
	| "restore";

/** How firmly one value is meant, strongest first.
 *
 * This is the whole precedence rule, and it is an ordering of evidence rather
 * than of importance: the reader's own typing is the most direct evidence
 * there is, and the application's default is the admission that there is
 * none. */
export type Firmness =
	/** The reader typed it here, under this act. */
	| "edited"
	/** The act said it outright. A link to `/room/general` names that room. */
	| "named"
	/** The act did not say it, but standing where it stood only has one
	 * reading. A link to a room in this page's own directory implies this
	 * directory, whether or not anybody wrote it down. */
	| "implied"
	/** Not in this act at all: what this browser did last. */
	| "recent"
	/** Nobody has an answer, so the application offers its own. */
	| "default";

/** A value an act carries, with how firmly it carries it. */
export interface Given<T> {
	readonly value: T;
	readonly firmness: "named" | "implied";
}

/** The act said this outright. */
export function named<T>(value: T): Given<T> {
	return { value, firmness: "named" };
}

/** The act stood somewhere that leaves only one reading of this. */
export function implied<T>(value: T): Given<T> {
	return { value, firmness: "implied" };
}

/** One act of reaching for a room.
 *
 * A field left out is a field this act says nothing about, which is different
 * from one it names as empty: a link to a room in this page's directory
 * implies an empty locator, and that empty is an answer that outranks whatever
 * was typed last week. So every reader tests for absence rather than for
 * emptiness. */
export interface Act {
	readonly source: Source;
	/** Which act this is. Rises with every act filed, so a later one supersedes
	 * an earlier one without anybody having to reset what the earlier one left
	 * behind. */
	readonly seq: number;
	readonly room?: Given<string>;
	/** The directory, as a locator somebody could dial. Empty means the
	 * directory serving this page, which is the one way the card says "here". */
	readonly locator?: Given<string>;
	readonly nick?: Given<string>;
	readonly secret?: Given<boolean>;
}

/** An act with its place in the order left to the store to assign. */
export type Reach = Omit<Act, "seq">;

/** What the reader changed by hand, and which act they were answering when
 * they changed it.
 *
 * The act is what makes an override stop applying. Typing a locator sticks for
 * as long as the reader is answering the question that asked for it, and going
 * somewhere else asks a new question, so the override falls away with the act
 * it belonged to. Nothing has to remember to clear it. */
export interface Edits {
	readonly seq: number;
	readonly room?: string;
	readonly locator?: string;
	readonly nick?: string;
	readonly secret?: boolean;
}

/** What this browser did last, offered when no act has anything to say.
 *
 * Written when a join succeeds, never while one is being typed. A locator
 * half-entered and abandoned is not something the reader did, and remembering
 * it would offer it back as though it were. */
export interface Remembered {
	readonly room: string;
	readonly locator: string;
	readonly nick: string;
}

/** A value to show, and where it came from. */
export interface Answer<T> {
	readonly value: T;
	readonly from: Firmness;
}

/** One field, resolved from the strongest evidence available.
 *
 * This is the only place the precedence lives. Every field of every surface
 * that answers to an act goes through here, so "which wins" is one rule with
 * one reading rather than a habit each form picks up separately.
 *
 * `remembered` is left out by a caller for a field this browser does not keep,
 * and `undefined` at any tier means that tier has nothing to say, which is why
 * an act naming the empty string still wins over a remembered value. */
export function settle<T>(
	edited: T | undefined,
	given: Given<T> | undefined,
	remembered: T | undefined,
	fallback: T,
): Answer<T> {
	if (edited !== undefined) return { value: edited, from: "edited" };
	if (given !== undefined) return { value: given.value, from: given.firmness };
	if (remembered !== undefined) return { value: remembered, from: "recent" };
	return { value: fallback, from: "default" };
}

/** The edits that still apply, which are the ones made under the act on the
 * table. An older act's overrides are not cleared when a new act arrives; they
 * simply stop being read, so nothing has to run at the moment of the change. */
export function current(edits: Edits, act: Act): Edits {
	return edits.seq === act.seq ? edits : { seq: act.seq };
}

/** Whether a remembered value is worth offering back.
 *
 * The application's own defaults are not preferences: a reader who never named
 * a room is not asking for `general` next time, they are being shown the same
 * blank the application would have shown anyway. Offering it back as "recent"
 * would say the reader chose it. */
export function keepable(value: string, fallback: string): string | undefined {
	return value === "" || value === fallback ? undefined : value;
}
