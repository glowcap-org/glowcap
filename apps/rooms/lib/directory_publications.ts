// The directory's room and observer publication vocabulary.
//
// This module owns the wire shape and validation of data a directory publishes.
// It does not own a session or any directory lifecycle, so clients and the
// directory wrapper can share one parser without depending on each other.

import type { Argument } from "@pancake/runtime";
import { MAX_NICK, MAX_ROOM } from "./limits.ts";

export type RoomEntryKind = "local" | "foreign" | "bridge";
export type RoomOriginProof = "local" | "authenticated" | "session" | "bridge";

/** One exact room publication in the directory. */
export interface RoomInfo {
	id: string;
	name: string;
	kind: RoomEntryKind;
	count: number | null;
	origin: string;
	proof: RoomOriginProof;
}

/** A change to the directory's live state, pushed to a `watch` observer. Some
 * changes are about rooms: a room `opened` when its first member arrived,
 * `closed` when its last left, or changed its member `count`. For those, `name`
 * is the room and `count` is how many are in it. Other changes are about people:
 * a member became `registered` or `unregistered` for direct messages, and there
 * `name` is the member's nick and `count` is 1 or 0. Both kinds arrive on one
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
		count: number;
		entry: null;
	};

const ROOM_EVENT_KINDS: readonly string[] = ["opened", "closed", "count", "registered", "unregistered"];

/** Parse one directory observer notification, or null when its wire shape is
 * not a supported publication. */
export function readRoomEvent(args: Argument[]): RoomEvent | null {
	const kind = args[0];
	const name = args[1];
	if (typeof kind !== "string" || !ROOM_EVENT_KINDS.includes(kind)) return null;
	if (typeof name !== "string") return null;
	const about = kind === "registered" || kind === "unregistered" ? MAX_NICK : MAX_ROOM;
	if (name.length === 0 || name.length > about) return null;
	const memberEvent = kind === "registered" || kind === "unregistered";
	if (memberEvent) {
		const count = naturalNumber(args[2]);
		if (count === null) return null;
		return { kind, name, count, entry: null };
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
	if (!Array.isArray(raw) || raw.length < 2) return null;
	if (raw.length < 6) {
		const [name, countRaw] = raw;
		if (typeof name !== "string" || name.length === 0 || name.length > MAX_ROOM) return null;
		const count = countRaw === null ? null : naturalNumber(countRaw);
		if (countRaw !== null && count === null) return null;
		return { id: name, name, kind: "local", count, origin: "", proof: "local" };
	}
	const [name, countRaw, id, kind, origin, proof] = raw;
	if (typeof name !== "string" || name.length === 0 || name.length > MAX_ROOM) return null;
	if (typeof id !== "string" || id.length === 0 || id.length > 128) return null;
	if (kind !== "local" && kind !== "foreign" && kind !== "bridge") return null;
	if (typeof origin !== "string" || origin.length > 256) return null;
	if (proof !== "local" && proof !== "authenticated" && proof !== "session" && proof !== "bridge") return null;
	let count: number | null = null;
	if (countRaw !== null) {
		count = naturalNumber(countRaw);
		if (count === null) return null;
	}
	if (kind === "local" && (count === null || origin !== "" || proof !== "local")) return null;
	if (kind === "foreign" && (count !== null || origin === "" || proof === "local")) return null;
	// A bridged channel is the gateway's observation of another protocol: no
	// native occupancy count, and its origin and proof both say bridge.
	if (kind === "bridge" && (count !== null || origin === "" || proof !== "bridge")) return null;
	return { id, name, kind, count, origin, proof };
}

/** Parse the canonical list/watch snapshot records. */
export function parseRooms(raw: Argument): RoomInfo[] {
	if (!Array.isArray(raw)) return [];
	const out: RoomInfo[] = [];
	for (const item of raw) {
		const room = parseRoom(item);
		if (room !== null) out.push(room);
	}
	return out;
}
