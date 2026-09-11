// What the join card asks, and where each of its answers comes from.
//
// The card is the one surface in this application with several fields and
// several ways of being reached, so it is where the act model in `intent.ts`
// earns its keep. Everything here is a pure function of an act, what the
// reader has typed under it, and what this browser remembers, which is what
// lets the whole question be answered in a test without a page.

import { type DirId, dirId, dirMarkIn, type DirView, type RoomDestination } from "./types.ts";
import { directoryName } from "./text.ts";
import { applicationModule, inspectCapability, inspectDirectory } from "./application.ts";
import { openRoomPolicy, privateRoomPolicy, type RoomPolicy, type RoomPreset, standingOffered } from "./room_policy.ts";
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

export interface DirectoryDestinationContext {
	readonly home: DirId | null;
	readonly defaultDirectory: { readonly id: DirId; readonly locator: string } | null;
}

export function directoryDestinationContext(
	home: DirId | null,
	defaultLocator: string | null,
	resolve: (locator: string) => DirId | null,
): DirectoryDestinationContext {
	if (defaultLocator == null) return { home, defaultDirectory: null };
	const id = resolve(defaultLocator);
	return { home, defaultDirectory: id == null ? null : { id, locator: defaultLocator } };
}

/** Whether typed text is a room link: a sturdyref, told apart by the swissnum
 * path it carries. The same tell `/join` uses, so the command and the join
 * card cannot disagree about what a paste is. */
export function looksLikeRoomLink(value: string): boolean {
	return askedJoin(value)?.kind === "link";
}

export function privateRoomNameRefusal(name: string, liveNames: Iterable<string>): string | null {
	const key = name.toLowerCase();
	for (const live of liveNames) {
		if (live.toLowerCase() === key) {
			return `#${name} is already live here. Turn off Private to open it, or choose another name for a new private room.`;
		}
	}
	return null;
}

/** The sturdyref in a `/join` argument, and any words the reader wrote after
 * it as a label. Null when the text is not a room link.
 *
 * The URI is found wherever it sits, so pasting `/link`'s whole answer — the
 * sentence and then the locator — still takes up the link rather than treating
 * "Anybody" as the first token. Words after the locator are a label; nothing
 * after it means the room should say what it is called. */
export function joinLinkIn(asked: string): { link: string; label: string } | null {
	const destination = askedJoin(asked);
	return destination?.kind === "link" ? { link: destination.link, label: destination.label } : null;
}

/** What `/join` does with its argument: take up a room link, or enter a room
 * by name. Null when the field is empty. Never "the room I am in" — a join is
 * a destination. */
export type AskedJoin =
	| { kind: "link"; link: string; label: string }
	| { kind: "name"; name: string };

export function askedJoin(asked: string): AskedJoin | null {
	const encoded = applicationModule().readRoomJoin(asked);
	return encoded == null ? null : JSON.parse(encoded) as AskedJoin;
}

/** The conversation this tab is already in that a room link names, or null.
 *
 * A locator is a destination, not the conversation it was typed in. The same
 * sturdyref this tab already holds is that destination. A listed room is also
 * that destination when this tab is in it by name, because a public link is
 * that listed room. A private room is not: two private rooms may share a
 * label, and `/join` must not guess from the conversation it was typed in. */
export function joinedForLink(
	rooms: readonly { key: string; held: boolean; id: string; link?: string }[],
	live: ReadonlySet<string>,
	link: string,
	listed: string | null,
): string | null {
	for (const conv of rooms) {
		if (conv.link === link && live.has(conv.key)) return conv.key;
	}
	if (listed !== null && listed !== "") {
		const folded = listed.toLowerCase();
		for (const conv of rooms) {
			if (!conv.held && conv.id.toLowerCase() === folded && live.has(conv.key)) return conv.key;
		}
	}
	return null;
}

/** Whether a link-join sits in the listed room.
 *
 * `listed` is what the occupancy said on arrival. Unknown — an older room —
 * is not a listed room: guessing from the name would open a public room that
 * merely shares a private occupancy's label. */
export function listedOccupancy(listed: boolean | undefined, name: string): boolean {
	return listed === true && name !== "";
}

/** A room link typed into a join, and what to call the room it opens.
 *
 * The locator field is the natural place to paste an `ocapn://` string, and a
 * `/link` sturdyref belongs there even though it is not a directory address.
 * A paste into the room field is the same link in the wrong box. Null when
 * neither field is a link, so the ordinary name-on-a-directory join applies.
 * An empty label is not "a room": the live room still has a name, and redeem
 * asks it. */
export function typedRoomLink(locator: string, room: string): { link: string; label: string } | null {
	const loc = locator.trim();
	const roomLink = room.trim();
	if (looksLikeRoomLink(loc)) return { link: loc, label: room };
	if (looksLikeRoomLink(roomLink)) return { link: roomLink, label: "" };
	return null;
}

/** One submitted join, classified before either the local or attached owner
 * performs it. A room sturdyref remains authority; it never falls through to
 * the directory-locator path merely because that owner is remote. */
export type JoinDestinationPlan =
	| { kind: "room-link"; link: string; label: string; directory: DirId; address: string }
	| { kind: "directory"; room: string; locator: string; policy: RoomPolicy };
export type RoomLinkDestination = Extract<JoinDestinationPlan, { kind: "room-link" }>;

export function planJoinDestination(destination: RoomDestination): JoinDestinationPlan {
	const linked = typedRoomLink(destination.locator, destination.room);
	if (linked === null) {
		return {
			kind: "directory",
			room: destination.room,
			locator: destination.locator,
			policy: destination.policy ?? (destination.hidden === true ? privateRoomPolicy() : openRoomPolicy()),
		};
	}
	const planned = roomLinkDestination(linked.link, linked.label);
	if (planned === null) throw new Error("that is not a room entry link");
	return planned;
}

/** Resolve the directory a room sturdyref names without consulting any page
 * state. The authority excludes route hints; the address retains them for the
 * owner that may have to dial it. */
export function roomLinkDestination(
	link: string,
	label: string,
): RoomLinkDestination | null {
	const exact = link.trim();
	const route = inspectCapability(exact);
	if (route == null) return null;
	return {
		kind: "room-link",
		link: exact,
		label,
		directory: dirId(route.authority),
		address: route.address,
	};
}

/** Empty and this page's own locator are one destination: the field that means
 * "here" stays empty, so a paste of the home locator does not become a second
 * way to say the same thing. */
export function thisDirectoryLocator(
	value: string,
	context: DirectoryDestinationContext,
	typedAs: DirId | null = null,
): string {
	const typed = value.trim();
	if (typed === "") return "";
	if (looksLikeRoomLink(typed)) return value;
	const defaultDirectory = context.defaultDirectory;
	if (
		defaultDirectory != null &&
		(typed === defaultDirectory.locator || typedAs === defaultDirectory.id)
	) return "";
	return value;
}

/** Where a locator field is aimed: the mark that destination wears, and what to
 * call it.
 *
 * One classification, read by everything that draws the answer. The card's top
 * stripe, the card's opening line, and the rail panel's line are asking the
 * same question about the same field, and asking it separately is how they came
 * to disagree in front of a reader who was typing into one of them. The answer
 * is by identity — `typedAs` is what the text resolves to — so a hinted route
 * and a bare authority are one destination.
 *
 * The field is empty or names this page's own directory, it names another this
 * tab holds, or it names something else. `hereWord` is what the first of those
 * is called in the sentence being written: the rail's line calls it what every
 * row beneath it calls a directory, while the card's line says whose page it is,
 * because the reader is looking at the field that could name another.
 *
 * `dirs` is what this tab holds, passed in because naming a directory takes
 * them and the rest of this module answers without them.
 */
export function destination(
	locator: string,
	typedAs: DirId | null,
	dirs: ReadonlyMap<DirId, DirView>,
	context: DirectoryDestinationContext,
	hereWord: string,
): { mark: string | undefined; name: string } {
	// The two arms below answer the ramp's ceiling differently, and the
	// difference is the point rather than an oversight.
	//
	// This page's own directory keeps its mark however many are held, because
	// `home` is not a slot in the ramp: it is the product's own teal, the one
	// Settings and this card have always worn, and it is not telling this
	// directory apart from any other. Asking the ceiling here would take that
	// teal off the card's field borders, its hash and its private-room prefix
	// while a single directory is held, which is every ordinary reader. That
	// repaints the ordinary view to enforce a rule about telling several
	// directories apart, and there are none to tell apart.
	//
	// The arm below does ask it, because there a color really is one directory's
	// answer against the others, and past the ramp there is no answer to give.
	if (thisDirectoryLocator(locator, context, typedAs) === "") {
		return {
			mark: context.defaultDirectory != null ? "home" : undefined,
			name: hereWord,
		};
	}
	const held = typedAs != null ? dirs.get(typedAs) : undefined;
	// The mark the rail is showing for that directory, and `unknown` when the
	// rail is showing none: past the ramp no directory wears a color of its own,
	// which puts a field aimed at one in the same position as a field aimed at an
	// address nobody here holds. Falling through to no mark instead would let the
	// card's stripe take its own fallback, which is the teal this page's own
	// directory wears, so a card aimed elsewhere would draw itself as home.
	if (held != null) {
		return {
			mark: dirMarkIn(held.id, context.home, dirs) ?? "unknown",
			name: directoryName(held.id, context.home),
		};
	}
	// Not a directory this tab holds. It may still be a perfectly good address,
	// so it is named the way any directory is named rather than read back as the
	// forty characters somebody pasted, and it is marked rather than left
	// unmarked. "Unknown" is a mark like any other: every part of the card that
	// colours itself reads one property, and an absence let each of them fall
	// back to its own answer instead.
	return {
		mark: "unknown",
		name: typedAs != null ? directoryName(typedAs, context.home) : "that directory",
	};
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
	roomPreset: Answer<RoomPreset>;
}

/** What the card shows, given how the reader got in front of it.
 *
 * The order is `intent.ts`'s and is not repeated here. What this adds is which
 * tiers each field has: a room, a locator, and a name are all worth offering
 * back from a past visit, and a lock is not. A private room is minted for good
 * on submit, so a lock quietly remembered from last week would mint one nobody
 * asked for. */
export function joinAnswers(
	act: Act,
	edits: Edits,
	memory: Remembered,
	context: DirectoryDestinationContext,
): JoinAnswers {
	const mine = current(edits, act);
	return {
		source: act.source,
		room: settle(mine.room, act.room, keepable(memory.room, JOIN_DEFAULT_ROOM), ""),
		locator: locatorAnswer(mine.locator, act.locator, memory.locator, context),
		nick: settle(mine.nick, act.nick, keepable(memory.nick, JOIN_DEFAULT_NICK), ""),
		roomPreset: settle(mine.roomPreset, act.roomPreset, undefined, "open"),
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
	context: DirectoryDestinationContext,
): Answer<string> {
	const here = (value: string) => thisDirectoryLocator(value, context);
	return settle(
		edited === undefined ? undefined : here(edited),
		given === undefined ? undefined : { value: here(given.value), firmness: given.firmness },
		keepable(here(memory), ""),
		"",
	);
}

/** What pressing the card's one button does. Reaching a directory that is
 * already on its way is the same offer as reaching one that is not: the open
 * runs once per directory and a second ask waits on the first, so the card
 * does not need a state for a wait nobody has to sit out. */
export type JoinAct = "connect" | "create" | "join";

/** What the world says about what the reader asked for.
 *
 * The answers above are intent and outlive everything: nothing here is ever
 * written back into them. A reader who chose moderated and then pointed at a
 * directory that already holds the name sees that room's own standing, and
 * still has their own the moment they point somewhere else. Resolving on every
 * render rather than remembering is what makes that true, and is why the card
 * and the rail cannot show two different answers to one question. */
export interface JoinResolution {
	/** The standing to show: the room's own where one answers, the reader's own
	 * where none does. */
	readonly standing: RoomPreset;
	/** Whether that standing is the room's own rather than a choice. Both the
	 * card and the rail draw one control for one question, so the answer is
	 * here rather than spelled at each of them, where the two would drift. An
	 * unreached directory does not fix it: the act still sends the choice and
	 * the room is still made with it, so taking the control away there would
	 * claim an authority nothing exercised. */
	readonly fixed: boolean;
	readonly act: JoinAct;
}

/** Only a reached directory has a listing that a name can be absent from. */
function reached(view: DirView | undefined): boolean {
	return view !== undefined && view.session === "connected";
}

export function resolveJoin(
	answers: JoinAnswers,
	dirs: ReadonlyMap<DirId, DirView>,
	homeDir: DirId | null,
	directoryOf: (locator: string) => DirId | null,
): JoinResolution {
	const wanted = answers.room.value.trim();
	const intended = answers.roomPreset.value;
	// An empty locator names this page's own directory, which the application
	// opens by itself. Asking a reader who has just arrived to connect that
	// before they may name a room would be asking them to do the one thing
	// nobody has to: the first act here has always been to name a room.
	const typed = answers.locator.value.trim();
	const named = typed !== "";
	const dir = named ? directoryOf(typed) : homeDir;
	const view = dir == null ? undefined : dirs.get(dir);
	// A pasted room link carries its own way in. No directory listing decides
	// anything about it, so neither phase nor standing is in question.
	if (typedRoomLink(answers.locator.value, answers.room.value) !== null) {
		return { standing: intended, fixed: false, act: "join" };
	}
	// Offering to connect is for a directory the reader named and this tab has
	// not reached. Everywhere else an unreached directory only means there is no
	// listing to say anything with, which is a reason to claim nothing about the
	// room, not a reason to stop them naming one.
	if (!reached(view)) {
		return { standing: intended, fixed: false, act: named ? "connect" : "join" };
	}
	const existing = wanted === ""
		? undefined
		: [...(view?.liveRooms.values() ?? [])].find((live) => live.name === wanted);
	return {
		standing: existing === undefined ? intended : standingOffered(existing.offers),
		fixed: existing !== undefined,
		// An empty field is not an offer to make anything.
		act: existing !== undefined || wanted === "" ? "join" : "create",
	};
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
	if (typedRoomLink(answers.locator.value, answers.room.value) !== null) {
		return `No account is required. ${aimedAt(answers, where)} Display names are not verified.`;
	}
	return `No account is required. ${aimedAt(answers, where)} A room that does not exist yet opens when ` +
		`you enter it. Display names are not verified.`;
}

function aimedAt(answers: JoinAnswers, where: string): string {
	// A link names a destination the reader has not necessarily seen yet, so it
	// speaks up. A press that already named the room does too: the card is then
	// a gate on that room, and the missing answer is the name. What this
	// browser merely remembers is an offer, and describing an offer as though
	// it were a destination is how the card would start sounding certain about
	// a guess.
	if (typedRoomLink(answers.locator.value, answers.room.value) !== null) {
		return "This is a room entry link. It opens the room it names. The name below is only what you will call it here.";
	}
	if (answers.source === "link") {
		if (answers.room.from === "named") return `This address is for #${answers.room.value} in ${where}.`;
		if (answers.locator.from === "named") return `This address is for ${where}. Name a room to enter there.`;
	}
	if (answers.source === "press" && answers.room.from === "named") {
		return `This is #${answers.room.value} in ${where}. Choose your name.`;
	}
	return "Name a room in this page's directory, paste another directory's OCapN locator, or paste a room entry link.";
}

/** Hint in an empty locator field: this page's address, shortened so it reads
 * as a locator rather than as a value already typed. `address` is the shared
 * route every other surface hands out (`peer.dirAddress`), so the hint and the
 * copyable address name the same thing; null when the page has no home
 * directory yet. */
export function joinLocatorPlaceholder(address: string | null): string {
	if (address == null) return JOIN_LOCATOR_SHAPE;
	let locator = address.trim();
	if (locator === "") return JOIN_LOCATOR_SHAPE;
	// Preserve the shared route reader's TCP host:port display form.
	locator = inspectDirectory(locator)?.address ?? locator;
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
