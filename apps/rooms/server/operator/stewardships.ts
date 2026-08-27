// The stewardship inventory: which rooms this server owns, and whether each
// one has an issued moderator capability.
//
// It is built from two places that must agree — the live rooms and the durable
// room publications — so it lives beside the operator rather than inside its
// verb dispatch, where the same rows are read by the inventory, by a search,
// and by the answer a give or a revoke returns.

import type { Argument, Session } from "@pancake/runtime";
import { isPrivateRoomKey } from "../../lib/limits.ts";
import { roomKey, rooms, type RoomState } from "../registry.ts";
import type { RoomLinks } from "../room_links.ts";

export type StewardshipVisibility = "listed" | "private";

export interface StewardshipRow {
	/** The durable room name the operator verbs accept. For a private room this
	 * is its opaque room key, never its human label. */
	name: string;
	/** What a live room calls itself. Empty after an empty private room has been
	 * restored from durable state, because its label was never its identity. */
	label: string;
	visibility: StewardshipVisibility;
	/** Monotonic durable state revision. Every issue or revoke advances it, so
	 * an older answer cannot rewind a newer operator row. */
	generation: number;
	issued: boolean;
	/** The current steward sturdyref, present exactly while `issued` is true. */
	steward: string | null;
}

export function liveRoom(name: string): RoomState | null {
	const privateRoom = rooms.get(name);
	if (privateRoom?.private === true) return privateRoom;
	const listed = rooms.get(roomKey(name));
	return listed?.private === false ? listed : null;
}

function compareRows(a: StewardshipRow, b: StewardshipRow): number {
	const left = (a.label || a.name).toLowerCase();
	const right = (b.label || b.name).toLowerCase();
	return left < right ? -1 : left > right ? 1 : a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

/** Build the bounded operator inventory from live local rooms and durable room
 * publications. Foreign and IRC-bridged rooms never enter either table: their
 * source owns their moderation, so this server has no steward to hand out. */
export function stewardshipRows(links: RoomLinks, session: Session): StewardshipRow[] {
	const authorities = new Map(links.stewardships(session).map((row) => [row.name.toLowerCase(), row]));
	const out = new Map<string, StewardshipRow>();
	const add = (name: string, label: string, visibility: StewardshipVisibility): void => {
		const authority = authorities.get(name.toLowerCase());
		out.set(name.toLowerCase(), {
			name,
			label,
			visibility,
			generation: authority?.generation ?? 0,
			issued: authority?.issued ?? false,
			steward: authority?.steward ?? null,
		});
	};
	for (const state of rooms.values()) {
		add(state.private ? state.key : state.name, state.name, state.private ? "private" : "listed");
	}
	for (const { name } of links.named()) {
		if (out.has(name.toLowerCase())) continue;
		const isPrivate = isPrivateRoomKey(name);
		add(name, isPrivate ? "" : name, isPrivate ? "private" : "listed");
	}
	for (const authority of authorities.values()) {
		if (out.has(authority.name.toLowerCase())) continue;
		const isPrivate = isPrivateRoomKey(authority.name);
		add(
			authority.name,
			isPrivate ? "" : authority.name,
			isPrivate ? "private" : "listed",
		);
	}
	return [...out.values()].sort(compareRows);
}

export function wireStewardshipRow(row: StewardshipRow): Argument {
	return [row.name, row.label, row.visibility, BigInt(row.generation), row.issued, row.steward] as Argument;
}
