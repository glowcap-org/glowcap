// Reading what a room said on one line.
//
// A room states more than the words: which line this is, whether it changes one
// already on screen, who is here, what the room is about, and what it will
// carry. All of it rides after the display text as structured arguments. A
// client that does not know a fact still shows the line, so a room can add a
// fact without every client being rebuilt first.
//
// Each reader answers "did the room say this" and never throws, because the
// arguments are a peer's and a malformed one means the room said nothing.

import type { Argument } from "@glowcap/runtime";
import * as z from "zod/mini";
import type { Attachment } from "../attachment.ts";
import {
	MAX_FORM_SCOPE,
	MAX_NICK,
	MAX_ROOM,
	MAX_ROOM_FEATURE,
	MAX_ROOM_FEATURES,
	MAX_ROOM_OFFLINE,
	MAX_SEAT_BADGE,
	MAX_SEAT_PREFIX,
	MAX_SEAT_SAID,
	MAX_TOPIC,
} from "../limits.ts";
import type { Presence } from "./presence.ts";
import { boundedText, nonemptyText, positiveSafeInteger } from "../schema.ts";
import {
	AWAY,
	CARRIES,
	EDITED,
	LINE,
	LINE_BYTES,
	LISTED,
	REFILED,
	ROOM_FEATURES,
	type RoomFeature,
	TOPIC,
	UNLISTED,
	WITHDRAWN,
} from "../protocol.ts";
import { BRIDGE, SEAT } from "../protocol_irc.ts";

/** One line in the room. `system` is true for the room's own announcements (a
 * member joining, your welcome). Otherwise `from` is the member who said it.
 * `presence` is set on a system line that is a membership change, such as the
 * roster on arrival or a join or leave. It is carried as structured wire args
 * and never scraped from the text. */
export interface Message {
	from: string;
	text: string;
	system: boolean;
	presence?: Presence;
	/** What the room said about itself on this line, if anything. A room states
	 * these as it states a membership change: as structured args after the
	 * text, so a client that does not know a fact still shows the line. */
	facts?: RoomFacts;
	/** The id this room knows this line by, when it said one. */
	lineId?: number;
	/** Whether this line is new, or changes one already on screen. Absent on a
	 * line the room did not name. `refiled` replaces the line's file set with
	 * whatever `attachments` this message carried. */
	change?: "said" | "edited" | "refiled" | "withdrawn";
	/** The files this message carried, in the order they were staged. Empty
	 * for an ordinary line. Fetch the bytes with `Room.fetch`. */
	attachments: Attachment[];
}

/** How a room named this line, when it named one.
 *
 * Ordinary lines carry their id so a later edit or withdrawal can refer to
 * one. A client that ignores this still draws every line but cannot be told
 * that one changed. */
export function readLineId(args: Argument[]): number | undefined {
	if (args[2] !== LINE && args[2] !== EDITED && args[2] !== REFILED && args[2] !== WITHDRAWN) return undefined;
	const id = args[3];
	const named = typeof id === "bigint" ? Number(id) : typeof id === "number" ? id : NaN;
	return Number.isSafeInteger(named) && named > 0 ? named : undefined;
}

/** What this line does to the one it names: replaces its text, replaces its
 * files, takes it back, or stands as a line of its own. */
export function readLineChange(args: Argument[]): "said" | "edited" | "refiled" | "withdrawn" | undefined {
	if (readLineId(args) === undefined) return undefined;
	if (args[2] === EDITED) return "edited";
	if (args[2] === REFILED) return "refiled";
	if (args[2] === WITHDRAWN) return "withdrawn";
	return "said";
}

/** Where a room notification's file records begin. A named line, one the room
 * tagged and gave an id, carries its records after that id. Everything else
 * (a record-free file post, or a line with no records) is read from the place a
 * presence change would sit. So a file line and a text line share one shape and
 * the reader tells them apart by whether records follow. */
export function roomRecordAt(args: Argument[]): number {
	return readLineId(args) !== undefined ? 4 : 2;
}

/** What a bridged room says about the bridge behind it.
 *
 * Two surfaces carry it: the facts a room states on a line, and the view an
 * attached session rebuilds a room from after a reload. One shared type keeps
 * the two from disagreeing about what a bridge may say. */
export const BridgeFactsSchema = z.strictObject({
	prefix: nonemptyText(MAX_SEAT_PREFIX),
	badge: nonemptyText(MAX_SEAT_BADGE),
	said: nonemptyText(MAX_SEAT_SAID),
	/** How far one identity on this bridge reaches, in the bridge's word for
	 * it. IRC answers with its network, because one identity there serves every
	 * channel on it. A bridge that shares nothing between rooms answers with the
	 * room.
	 *
	 * The room states it instead of inferring it from whoever has already
	 * linked, so a channel nobody has linked on yet still knows which identity
	 * is already its own. It matches the `scope` on the form the same bridge
	 * declares. */
	scope: nonemptyText(MAX_FORM_SCOPE),
});

export type BridgeFacts = z.infer<typeof BridgeFactsSchema>;

/** What a room carries of a message beyond its text and files, as booleans a
 * surface can switch on. See `readCarries`. Every field is present, so a
 * reader across a JSON boundary needs no default to tell "not carried" from
 * "not said". A room that never said is an absent `carries`, not a false one. */
export const RoomCarriesSchema = z.strictObject({
	previews: z.boolean(),
	typing: z.boolean(),
});

export type RoomCarries = z.infer<typeof RoomCarriesSchema>;

/** Standing facts a room states about itself, as against the things said in it.
 *
 * All are optional and independent. A line carries whichever the room chose to
 * put on it, usually the welcome, and none the rest of the time. */
export const RoomFactsSchema = z.strictObject({
	/** See `readTopic`. An empty string is a topic that was taken down. */
	topic: z.optional(boundedText(MAX_TOPIC)),
	/** See `readLineBytes`. */
	lineBytes: z.optional(positiveSafeInteger),
	/** See `readListed`. Whether this occupancy is a name on the directory. */
	listed: z.optional(z.boolean()),
	/** See `readBridge`. What the bridge behind this room calls itself. */
	bridge: z.optional(BridgeFactsSchema),
	/** See `readCarries`. What this room keeps or relays of a message. */
	carries: z.optional(RoomCarriesSchema),
});

export type RoomFacts = z.infer<typeof RoomFactsSchema>;

/** Everything a room said about itself on one line, or nothing.
 *
 * Returns undefined instead of an empty object when the line said nothing, so
 * the common case costs no allocation and a caller can ask `if (facts)`
 * without probing each field. */
export function readRoomFacts(args: Argument[]): RoomFacts | undefined {
	const topic = readTopic(args);
	const lineBytes = readLineBytes(args);
	const listed = readListed(args);
	const bridge = readBridge(args);
	const carries = readCarries(args);
	if (
		topic === undefined && lineBytes === undefined && listed === undefined && bridge === undefined &&
		carries === undefined
	) {
		return undefined;
	}
	return {
		...(topic === undefined ? {} : { topic }),
		...(lineBytes === undefined ? {} : { lineBytes }),
		...(listed === undefined ? {} : { listed }),
		...(bridge === undefined ? {} : { bridge }),
		...(carries === undefined ? {} : { carries }),
	};
}

/** What this room carries of a message beyond its text and files, if it says,
 * as `notify("room", "", "carries", ...features)`.
 *
 * This is description, not authority. What a member can do is what they hold
 * (a participant seat, the topic facet, the files facet), and nothing they
 * hold could say whether the room keeps a line's link previews or relays the
 * typing signal. A feature named is carried and one not named is not, so a
 * room bridged to IRC states an empty list and a native room states both. A
 * word this client does not know is skipped, so a room may say something new
 * before every client is rebuilt. A statement that carries something that is
 * not a word, or runs past its bounds, is malformed, and the right reading of
 * that is that the room said nothing. */
export function readCarries(args: Argument[]): RoomCarries | undefined {
	if (args[2] !== CARRIES) return undefined;
	const words = args.slice(3);
	if (words.length > MAX_ROOM_FEATURES) return undefined;
	const carries: RoomCarries = { previews: false, typing: false };
	for (const word of words) {
		if (!bounded(word, MAX_ROOM_FEATURE)) return undefined;
		if ((ROOM_FEATURES as readonly string[]).includes(word)) carries[word as RoomFeature] = true;
	}
	return carries;
}

/** What the bridge behind this room calls its own, as
 * `notify(from, text, "bridge", prefix, badge, said)`.
 *
 * The prefix is what a foreign member's roster name carries, so a reader can be
 * told which rows are not native without the page knowing that `irc/` ever
 * existed. All three are the bridge's words and are read as every other
 * inbound string is. A room that says any of it malformed has said none of it,
 * because a half-read prefix would mislabel a roster instead of leaving it
 * plain. */
export function readBridge(args: Argument[]): RoomFacts["bridge"] {
	if (args[2] !== BRIDGE) return undefined;
	if (!bounded(args[3], MAX_SEAT_PREFIX)) return undefined;
	if (!bounded(args[4], MAX_SEAT_BADGE) || !bounded(args[5], MAX_SEAT_SAID)) return undefined;
	if (!bounded(args[6], MAX_FORM_SCOPE)) return undefined;
	return { prefix: args[3], badge: args[4], said: args[5], scope: args[6] };
}

/** Whether this occupancy is a directory name, if the room said so, as
 * `notify(from, text, "listed")` or `"unlisted"`.
 *
 * A sturdyref does not carry this, and the name it answers with does not
 * either, since a public room and a private one may share a label. Subscribe is
 * when the occupancy can say, so `/join` of a locator seats from this instead
 * of asking a method that an older room does not have. A client that predates
 * the tags skips them. */
export function readListed(args: Argument[]): boolean | undefined {
	if (args[2] === LISTED) return true;
	if (args[2] === UNLISTED) return false;
	return undefined;
}

/** A nonempty wire string within its bound. The seat's badge and sentence
 * are a bridge's words, not this room's, so they are read as every other
 * inbound string is: length-checked here, drawn as text everywhere. */
function bounded(value: Argument | undefined, most: number): value is string {
	return typeof value === "string" && value.length > 0 && value.length <= most;
}

/** Read the structured presence a room line carries after its display text:
 * `notify("room", text, "roster", ...names)` or `notify("room", text, kind, nick)`.
 * Ordinary chat lines carry none. */
export function readPresence(args: Argument[]): Presence | undefined {
	const kind = args[2];
	// A name longer than any this protocol grants is not a name, whoever sent it,
	// and the roster draws a row for every one it is given.
	const named = (value: Argument): value is string => typeof value === "string" && value.length <= MAX_NICK;
	const network = (value: Argument): value is string => typeof value === "string" && value.length <= MAX_ROOM;
	if (kind === "roster") {
		return { kind: "roster", names: args.slice(3).filter(named) };
	}
	if (kind === "offline") {
		const names = args.slice(3);
		if (names.length <= MAX_ROOM_OFFLINE && names.every((name): name is string => named(name) && name !== "")) {
			return { kind, names };
		}
		return undefined;
	}
	if ((kind === "join" || kind === "leave") && named(args[3])) {
		return { kind, name: args[3] };
	}
	if (kind === AWAY && typeof args[3] === "string") {
		return { kind: "away", name: args[3], reason: typeof args[4] === "string" ? args[4] : "" };
	}
	if (kind === "typing" && typeof args[3] === "string" && typeof args[4] === "boolean") {
		return { kind, name: args[3], on: args[4] };
	}
	if (
		kind === SEAT && named(args[3]) &&
		(args[4] === "rooms" || args[4] === "connecting" || args[4] === "linked" || args[4] === "failed") &&
		named(args[5]) && network(args[6]) &&
		// The bridge's badge and sentence are required. A seat nobody has words
		// for cannot be drawn, and a client that invented them would be guessing
		// at what the bridge is.
		bounded(args[7], MAX_SEAT_BADGE) && bounded(args[8], MAX_SEAT_SAID)
	) {
		return {
			kind,
			name: args[3],
			state: args[4],
			nick: args[5],
			network: args[6],
			badge: args[7],
			said: args[8],
		};
	}
	return undefined;
}

/** The longest line this room will carry, if it says so, in bytes.
 *
 * Read from the same structured tail a presence change rides in, as
 * `notify(from, text, "line-bytes", n)`. A room with nothing to say about it
 * sends nothing and is not capped by this at all.
 *
 * It exists for a room that is somebody else's as well as its own. A room
 * bridged to IRC has to fit each line into a protocol that allows 512 bytes for
 * the whole thing, envelope included, so it can carry less than this app would
 * otherwise allow. A reader should be told that while writing, not by having
 * the end of a sentence disappear on the far side.
 *
 * The IRC bridge states it at arrival, beside what the room carries. A cap is a
 * fact a room states about itself, not a mode anybody switches on, so two rooms
 * in one tab can answer differently. */
export function readLineBytes(args: Argument[]): number | undefined {
	if (args[2] !== LINE_BYTES) return undefined;
	const said = args[3];
	const bytes = typeof said === "bigint" ? Number(said) : typeof said === "number" ? said : NaN;
	// A cap has to be a positive whole number of bytes to mean anything.
	// Anything else is malformed, and the right reading of that is that the
	// room said nothing.
	return Number.isSafeInteger(bytes) && bytes > 0 ? bytes : undefined;
}

/** What the room says it is about, if it says anything, as
 * `notify(from, text, "topic", "…")`.
 *
 * An empty topic is a topic being cleared, so it reads as an empty string and
 * not as nothing said. That separates "this room is about nothing in
 * particular now" from "this notify was not about the topic at all", and
 * without it clearing a topic would be impossible.
 *
 * A room states this on arrival when it has one, and again whenever it changes.
 * The tags are read as a bridge's would be, so a bridged room stating its own
 * topic needs nothing new here. */
export function readTopic(args: Argument[]): string | undefined {
	if (args[2] !== TOPIC) return undefined;
	const said = args[3];
	// A topic sits on screen for as long as the room is open, so a topic longer
	// than a topic may be is something this cannot show. Read it as a malformed
	// cap is read: the room said nothing. That leaves the last topic a reader
	// could see in place and does not replace it with something unreadable.
	return typeof said === "string" && said.length <= MAX_TOPIC ? said : undefined;
}
