// The directory's room and observer publication vocabulary.
//
// This module owns the wire shape and validation of data a directory publishes.
// It does not own a session or any directory lifecycle, so clients and the
// directory wrapper can share one parser without depending on each other.

import type { Argument } from "@glowcap/runtime";
import * as z from "zod/mini";
import { MAX_DIRECTORY_DISCOVERY_ROWS, MAX_NICK, MAX_ROOM } from "./limits.ts";
import { boundedText, naturalWireNumber, nonemptyText, nonnegativeSafeInteger } from "./schema.ts";
import { isRoomMembershipKind } from "./room/membership.ts";

/** One exact room publication in the directory. */
export const RoomInfoSchema = z.strictObject({
	id: nonemptyText(128),
	name: nonemptyText(MAX_ROOM),
	kind: z.enum(["local", "foreign", "bridge"]),
	count: z.nullable(nonnegativeSafeInteger),
	origin: boundedText(256),
	proof: z.enum(["local", "authenticated", "session", "bridge"]),
	/** Membership the public registration offers, or null when it is listed for invitation only. */
	offers: z.nullable(z.enum(["observer", "participant"])),
}).check(
	z.refine((room) =>
		room.kind === "local"
			? room.count != null && room.origin === "" && room.proof === "local"
			: room.kind === "foreign"
			? room.count == null && room.origin !== "" && room.proof !== "local"
			: room.origin !== "" && room.proof === "bridge"
	),
);

export type RoomInfo = z.infer<typeof RoomInfoSchema>;
export type RoomEntryKind = RoomInfo["kind"];
export type RoomOriginProof = RoomInfo["proof"];

/** One live directory registration. `registrationId` distinguishes successive
 * holders of the same nickname without pretending to be bearer authority. */
export const RegistrationIdSchema = z.uuid();

export function isRegistrationId(raw: unknown): raw is string {
	return z.safeParse(RegistrationIdSchema, raw).success;
}

export function parseRegistrationId(raw: unknown, context: string): string {
	if (!isRegistrationId(raw)) throw new Error(`${context} did not name a valid registration ID`);
	return raw;
}

export const DirectoryMemberSchema = z.strictObject({
	name: nonemptyText(MAX_NICK),
	registrationId: RegistrationIdSchema,
});
export type DirectoryMember = z.infer<typeof DirectoryMemberSchema>;

const DirectoryMemberRowSchema = z.tuple([
	nonemptyText(MAX_NICK),
	RegistrationIdSchema,
]);
const DirectoryMemberRowsSchema = z.array(DirectoryMemberRowSchema).check(
	z.maxLength(MAX_DIRECTORY_DISCOVERY_ROWS),
	z.refine((rows) => new Set(rows.map(([name]) => name.toLowerCase())).size === rows.length),
	z.refine((rows) => new Set(rows.map(([, registrationId]) => registrationId)).size === rows.length),
);
const DirectoryWatchSnapshotWireSchema = z.tuple([
	z.array(z.custom<Argument>(() => true)).check(z.maxLength(MAX_DIRECTORY_DISCOVERY_ROWS)),
	DirectoryMemberRowsSchema,
	naturalWireNumber,
]).check(
	z.refine(([rooms, peers]) => rooms.length + peers.length <= MAX_DIRECTORY_DISCOVERY_ROWS),
);

/** A change to the directory's live state, pushed to a `watch` observer. Some
 * changes are about rooms: a room `opened` when its first member arrived,
 * `closed` when its last left, or changed its member `count`. For those, `name`
 * is the room and `count` is how many are in it. Other changes are about people:
 * a member became `registered` or `unregistered` for direct messages, and there
 * `name` is the member's nick, `registrationId` identifies that exact registration, and
 * `count` is 1 or 0. Both kinds arrive on one
 * observer, so switch on `kind` to tell them apart. */
export type RoomEvent =
	| {
		kind: "opened" | "closed" | "count";
		name: string;
		count: number | null;
		entry: RoomInfo;
	}
	| {
		kind: "registered" | "unregistered";
		name: string;
		registrationId: string;
		count: number;
		entry: null;
	}
	| {
		kind: "truncated";
		name: "";
		count: number;
		entry: null;
	};

/** Every tag a watch observer may be notified with, in the order the generated
 * client tables declare them; `test/protocol_gen_test.ts` holds the two equal. */
export const ROOM_EVENT_KINDS: readonly string[] = [
	"opened",
	"closed",
	"count",
	"registered",
	"unregistered",
	"truncated",
];

/** Parse one directory observer notification, or null when its wire shape is
 * not a supported publication. */
export function readRoomEvent(args: Argument[]): RoomEvent | null {
	const kind = args[0];
	if (kind === "truncated") {
		if (args.length !== 2) return null;
		const count = naturalNumber(args[1]);
		return count == null ? null : { kind, name: "", count, entry: null };
	}
	const name = args[1];
	if (typeof kind !== "string" || !ROOM_EVENT_KINDS.includes(kind)) return null;
	if (typeof name !== "string") return null;
	const about = kind === "registered" || kind === "unregistered" ? MAX_NICK : MAX_ROOM;
	if (name.length === 0 || name.length > about) return null;
	const memberEvent = kind === "registered" || kind === "unregistered";
	if (memberEvent) {
		if (args.length !== 4 || typeof args[3] !== "string") return null;
		const count = naturalNumber(args[2]);
		const parsed = z.safeParse(DirectoryMemberSchema, { name, registrationId: args[3] });
		if (count == null || !parsed.success) return null;
		return { kind, name: parsed.data.name, registrationId: parsed.data.registrationId, count, entry: null };
	}
	const entry = parseRoom(args.slice(1));
	if (entry === null) return null;
	return { kind: kind as "opened" | "closed" | "count", name, count: entry.count, entry };
}

function naturalNumber(raw: Argument): number | null {
	if (typeof raw !== "number" && typeof raw !== "bigint") return null;
	const count = Number(raw);
	return Number.isSafeInteger(count) && count >= 0 ? count : null;
}

function parseRoom(raw: Argument): RoomInfo | null {
	if (!Array.isArray(raw) || (raw.length !== 2 && raw.length !== 7)) return null;
	if (raw.length === 2) {
		const [name, countRaw] = raw;
		if (typeof name !== "string" || name.length === 0 || name.length > MAX_ROOM) return null;
		const count = countRaw === null ? null : naturalNumber(countRaw);
		if (countRaw !== null && count === null) return null;
		const parsed = z.safeParse(RoomInfoSchema, {
			id: name,
			name,
			kind: "local",
			count,
			origin: "",
			proof: "local",
			offers: "participant",
		});
		return parsed.success ? parsed.data : null;
	}
	const [name, countRaw, id, kind, origin, proof, offers] = raw;
	if (typeof name !== "string" || name.length === 0 || name.length > MAX_ROOM) return null;
	if (typeof id !== "string" || id.length === 0 || id.length > 128) return null;
	let count: number | null = null;
	if (countRaw !== null) {
		count = naturalNumber(countRaw);
		if (count === null) return null;
	}
	if (offers !== null && !isRoomMembershipKind(offers)) return null;
	const parsed = z.safeParse(RoomInfoSchema, { id, name, kind, count, origin, proof, offers });
	return parsed.success ? parsed.data : null;
}

/** Parse one complete bounded list/watch snapshot. A malformed row invalidates
 * the answer rather than quietly turning server corruption into a partial view. */
export function parseRooms(raw: Argument): RoomInfo[] {
	if (!Array.isArray(raw) || raw.length > MAX_DIRECTORY_DISCOVERY_ROWS) {
		throw new Error("the directory answered an invalid or oversized room list");
	}
	const out: RoomInfo[] = [];
	const ids = new Set<string>();
	for (const item of raw) {
		const room = parseRoom(item);
		if (room == null || ids.has(room.id)) throw new Error("the directory answered an invalid room-list row");
		ids.add(room.id);
		out.push(room);
	}
	return out;
}

export function parseDirectoryWatchSnapshot(raw: Argument): {
	rooms: RoomInfo[];
	peers: DirectoryMember[];
	omitted: number;
} {
	const parsed = z.safeParse(DirectoryWatchSnapshotWireSchema, raw);
	if (!parsed.success) {
		throw new Error(
			"the directory answered an invalid watch snapshot; the directory and Rooms session may be running different protocol builds",
		);
	}
	const [roomRows, memberRows, omitted] = parsed.data;
	return {
		rooms: parseRooms(roomRows),
		peers: memberRows.map(([name, registrationId]) => ({ name, registrationId })),
		omitted,
	};
}
