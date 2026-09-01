// The stewardship inventory: which rooms this server owns, and whether each
// one has an issued moderator capability.
//
// It is built from two places that must agree — the live rooms and the durable
// room publications — so it lives beside the operator rather than inside its
// verb dispatch, where the same rows are read by the inventory, by a search,
// and by the answer a give or a revoke returns.

import type { Argument, Session } from "@pancake/runtime";
import { isManagedRoomId } from "../../lib/limits.ts";
import type { RoomServerContext } from "../context.ts";
import { roomKey, type RoomState } from "../registry.ts";
import { roomIsListed } from "../../lib/room/policy.ts";
import type { RoomLinks } from "../room_links.ts";
import type { IrcBridgeAuthorities } from "../irc_gateway/authority.ts";

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

export function liveRoom(ctx: RoomServerContext, name: string): RoomState | null {
	const exact = ctx.live.rooms.get(name.toLowerCase());
	if (exact != null) return exact;
	const listed = ctx.live.publicRooms.get(roomKey(name));
	return listed?.kind === "local" ? listed.state : null;
}

function compareRows(a: StewardshipRow, b: StewardshipRow): number {
	const left = (a.label || a.name).toLowerCase();
	const right = (b.label || b.name).toLowerCase();
	return left < right ? -1 : left > right ? 1 : a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

/** Build the bounded operator inventory from each room source that can issue
 * moderation: native room registrations and the IRC bridge authority owner.
 * Peered rooms remain with their remote source. */
export function stewardshipRows(
	ctx: RoomServerContext,
	links: RoomLinks,
	session: Session,
	bridges: IrcBridgeAuthorities | null = null,
): StewardshipRow[] {
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
	for (const state of ctx.live.rooms.values()) {
		add(state.key, state.name, roomIsListed(state.policy) ? "listed" : "private");
	}
	for (const { name } of links.named()) {
		if (out.has(name.toLowerCase())) continue;
		const managed = links.managedRoom(name);
		add(
			name,
			managed?.name ?? (isManagedRoomId(name) ? "" : name),
			managed == null
				? (isManagedRoomId(name) ? "private" : "listed")
				: roomIsListed(managed.policy)
				? "listed"
				: "private",
		);
	}
	for (const authority of authorities.values()) {
		if (out.has(authority.name.toLowerCase())) continue;
		const managed = links.managedRoom(authority.name);
		add(
			authority.name,
			managed?.name ?? (isManagedRoomId(authority.name) ? "" : authority.name),
			managed == null
				? (isManagedRoomId(authority.name) ? "private" : "listed")
				: roomIsListed(managed.policy)
				? "listed"
				: "private",
		);
	}
	for (const authority of bridges?.stewardships(session) ?? []) {
		out.set(authority.name, authority);
	}
	return [...out.values()].sort(compareRows);
}

export function wireStewardshipRow(row: StewardshipRow): Argument {
	return [row.name, row.label, row.visibility, BigInt(row.generation), row.issued, row.steward] as Argument;
}
