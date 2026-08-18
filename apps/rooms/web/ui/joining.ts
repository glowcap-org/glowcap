// What the join card asks, and where each of its answers comes from.
//
// The card is the one surface in this application with several fields and
// several ways of being reached, so it is where the act model in `intent.ts`
// earns its keep. Everything here is a pure function of an act, what the
// reader has typed under it, and what this browser remembers, which is what
// lets the whole question be answered in a test without a page.

import type { DirId } from "./types.ts";
import {
	type Act,
	type Answer,
	current,
	type Edits,
	type Given,
	keepable,
	type Remembered,
	settle,
	type Source,
} from "./intent.ts";

export const JOIN_DEFAULT_ROOM = "general";
export const JOIN_DEFAULT_NICK = "guest";
/** Shape of a locator, used when this page's own address is not known yet. */
export const JOIN_LOCATOR_SHAPE = "ocapn://designator.transport";

/** Empty and this page's own locator are one destination: the field that means
 * "here" stays empty, so a paste of the home locator does not become a second
 * way to say the same thing. */
export function thisDirectoryLocator(value: string, home: DirId | null): string {
	const typed = value.trim();
	if (typed === "") return "";
	if (home !== null && typed === (home as string)) return "";
	return value;
}

/** Every field of the card, each with the evidence behind it, and how the
 * reader got here. The source rides along because a caption is only honest
 * beside it: the same firmness means something different when the reader
 * pressed a control from when a link decided. */
export interface JoinAnswers {
	source: Source;
	room: Answer<string>;
	locator: Answer<string>;
	nick: Answer<string>;
	secret: Answer<boolean>;
}

/** What the card shows, given how the reader got in front of it.
 *
 * The order is `intent.ts`'s and is not repeated here. What this adds is which
 * tiers each field has: a room, a locator, and a name are all worth offering
 * back from a past visit, and a lock is not. A private room is minted for good
 * on submit, so a lock quietly remembered from last week would mint one nobody
 * asked for. */
export function joinAnswers(act: Act, edits: Edits, memory: Remembered, home: DirId | null): JoinAnswers {
	const mine = current(edits, act);
	return {
		source: act.source,
		room: settle(mine.room, act.room, keepable(memory.room, JOIN_DEFAULT_ROOM), ""),
		locator: locatorAnswer(mine.locator, act.locator, memory.locator, home),
		nick: settle(mine.nick, act.nick, keepable(memory.nick, JOIN_DEFAULT_NICK), ""),
		secret: settle(mine.secret, act.secret, undefined, false),
	};
}

/** The locator field, whose every tier means one extra thing: this page's own
 * directory is the empty field.
 *
 * Reading each tier through that rule before they are weighed is what makes an
 * act that implies home beat a remembered foreign address. The act implies the
 * empty field, and an empty field named by an act is an answer, where an empty
 * memory is only a habit nobody has formed. It also keeps the caption honest,
 * since a remembered locator that turns out to name this page would otherwise
 * present a blank field claiming to be what the reader used last. */
function locatorAnswer(
	edited: string | undefined,
	given: Given<string> | undefined,
	memory: string,
	home: DirId | null,
): Answer<string> {
	const here = (value: string) => thisDirectoryLocator(value, home);
	return settle(
		edited === undefined ? undefined : here(edited),
		given === undefined ? undefined : { value: here(given.value), firmness: given.firmness },
		keepable(here(memory), ""),
		"",
	);
}

/** The card, saying what it is for.
 *
 * A card reached by following an address is answering that address, and a card
 * opened from the rail is answering nothing in particular. Those are different
 * cards, and the one place a card explains itself is its opening line, so that
 * is where the difference is said — once, in a sentence, rather than as a note
 * beside every field that happens to be filled.
 *
 * Saying it per field was the first attempt and it was worse in two ways. It
 * repeated one idea three times, loudest exactly when the reader had the most
 * to read; and it left this paragraph claiming the card was for naming a room
 * in this page's directory while the fields underneath said it was for a
 * particular room somewhere else. One statement cannot contradict itself.
 *
 * `where` is the destination in the words the rest of the page uses for a
 * directory, resolved by the caller because naming one takes the directories
 * this tab holds and this module answers without them. */
export function joinLead(answers: JoinAnswers, where: string): string {
	return `No account is required. ${aimedAt(answers, where)} A room that does not exist yet opens when ` +
		`you enter it. Display names are not verified.`;
}

function aimedAt(answers: JoinAnswers, where: string): string {
	// Only an address speaks up. A press put the reader here a moment ago and
	// they can see what they pressed; what this browser merely remembers is an
	// offer, and describing an offer as though it were a destination is how the
	// card would start sounding certain about a guess.
	if (answers.source === "link") {
		if (answers.room.from === "named") return `This address is for #${answers.room.value} in ${where}.`;
		if (answers.locator.from === "named") return `This address is for ${where}. Name a room to enter there.`;
	}
	return "Name a room in this page's directory, or paste another directory's OCapN locator.";
}

/** Hint in an empty locator field: this page's address, shortened so it reads
 * as a locator rather than as a value already typed. `address` is the shared
 * route every other surface hands out (`peer.dirAddress`), so the hint and the
 * copyable address name the same thing; null when the page has no home
 * directory yet. */
export function joinLocatorPlaceholder(address: string | null): string {
	if (address == null) return JOIN_LOCATOR_SHAPE;
	const locator = address.trim();
	if (locator === "") return JOIN_LOCATOR_SHAPE;
	return shortenLocator(locator);
}

function shortenLocator(locator: string): string {
	const bare = locator.split("?")[0];
	const schemeAt = bare.indexOf("://");
	if (schemeAt < 0) return bare;
	const scheme = bare.slice(0, schemeAt + 3);
	const authority = bare.slice(schemeAt + 3).split("/")[0];
	const dot = authority.lastIndexOf(".");
	const designator = dot < 0 ? authority : authority.slice(0, dot);
	const transport = dot < 0 ? "" : authority.slice(dot);
	if (designator.length <= 12) return scheme + authority;
	return scheme + designator.slice(0, 4) + "…" + designator.slice(-6) + transport;
}
