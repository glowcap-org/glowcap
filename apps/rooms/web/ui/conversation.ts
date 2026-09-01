// Conversation, message, and invitation state for the Rooms presentation model.

import type { RoomMemberState } from "../../lib/room/presence.ts";
import type { RoomFacts } from "../../lib/room/message.ts";
import type { WorkspaceRoomBridgeIntent } from "../../lib/rooms_state.ts";
import type { RoomMembershipKind } from "../../lib/room/membership.ts";
import type { RoomPolicy } from "../../lib/room/policy.ts";
import type { DirId } from "./types.ts";

export type SendState = "sending" | "failed" | "refused";

export function isUnsent(state: SendState | undefined): boolean {
	return state === "failed" || state === "refused";
}

export function canRetry(state: SendState | undefined): boolean {
	return state === "failed";
}

export interface AttachmentView {
	id: number;
	name: string;
	mime: string;
	size: number;
	width?: number;
	height?: number;
	url?: string;
	got?: number;
	error?: string;
	lost?: boolean;
}

export type ViewerDirection = "previous" | "next";

export type SysAudience = "here" | "shared";

export interface HistoryCoordinate {
	readonly source: string;
	readonly generation: string;
	readonly id: string;
}

export type Item =
	| {
		kind: "chat";
		id: number;
		from: string;
		text: string;
		mine: boolean;
		at: number;
		state?: SendState;
		/** The id assigned by the current live room generation. Retired when that
		 * membership ends; retained text is not authority for a later generation. */
		lineId?: number;
		history?: HistoryCoordinate;
		edited?: boolean;
		withdrawn?: boolean;
		held?: boolean;
		attachments?: readonly AttachmentView[];
	}
	| { kind: "sys"; id: number; text: string; at: number; audience: SysAudience }
	| { kind: "action"; id: number; from: string; text: string; at: number };

export type ChatItem = Extract<Item, { kind: "chat" }>;

export function silencedByIgnore(item: Item, ignored: ReadonlySet<string>): boolean {
	if (item.kind === "sys") return false;
	return silencedFrom(item.from, item.kind === "chat" && item.mine, ignored);
}

export function silencedFrom(from: string, mine: boolean, ignored: ReadonlySet<string>): boolean {
	return !mine && ignored.has(from.toLowerCase());
}

export type Unread =
	| { kind: "caught-up" }
	| { kind: "rule-only"; from: number }
	| { kind: "unread"; count: number; from: number };

/** Shared empty log, so a conversation with nothing said and a missing row
 * compare equal by identity rather than allocating an array per read. */
export const NO_HISTORY: readonly Item[] = [];

/** Shared caught-up mark, for the same reason. */
export const CAUGHT_UP: Unread = { kind: "caught-up" };

export interface ConvBase {
	/** What the reader sees: a room's name, or a DM peer's nick. */
	id: string;
	/** This tab's map key. Distinct from `id` (display). A room or DM also has a
	 * durable `persistId`; a directory conversation does not. */
	key: string;
	dir: DirId;
}

export type Standing = RoomMemberState;

export function membersHere(members: ReadonlyMap<string, Standing>): number {
	let here = 0;
	for (const standing of members.values()) if (standing.online) here++;
	return here;
}

export function awayByPeer(
	convs: ReadonlyMap<string, Conv>,
	members: ReadonlyMap<string, ReadonlyMap<string, Standing>>,
): ReadonlyMap<DirId, ReadonlyMap<string, string | null>> {
	const dirs = new Map<DirId, Map<string, string | null>>();
	for (const conv of convs.values()) {
		if (conv.type !== "room") continue;
		let words = dirs.get(conv.dir);
		if (words == null) {
			words = new Map();
			dirs.set(conv.dir, words);
		}
		for (const [member, standing] of members.get(conv.key) ?? []) {
			if (!standing.online) continue;
			const name = member.toLowerCase();
			if (standing.away === "") words.set(name, null);
			else if (!words.has(name)) words.set(name, standing.away);
		}
	}
	return dirs;
}

export function awayOf(
	words: ReadonlyMap<DirId, ReadonlyMap<string, string | null>>,
	dir: DirId,
	name: string,
): string | null {
	return words.get(dir)?.get(name.toLowerCase()) ?? null;
}

/** One conversation this tab can show. Session checkpoints say `kind: "direct"`
 * for the same row this union calls `type: "dm"`. A directory conversation is
 * this tab's view of a held directory, not a checkpoint row, and has no
 * `persistId`: session commands cannot name it. */
export type Conv =
	| (ConvBase & {
		type: "room";
		/** Durable session / checkpoint id. Session commands name this. */
		persistId: string;
		membership: "joining" | "joined" | "unavailable";
		membershipIssue: string;
		publicationId?: string;
		lineBytes?: number;
		topic?: string;
		/** What the bridge behind this room calls its own, when one said so: the
		 * prefix its foreign members' names carry, and the badge and sentence for
		 * one of them. Absent in an ordinary room, which is most of them. */
		bridge?: BridgeFacts;
		earlierHistory: "unasked" | "loading" | "empty" | "shown" | "unavailable";
		grants: ReadonlySet<string>;
		membershipKind: RoomMembershipKind;
		policy: RoomPolicy;
		/** Private or source-owned, not "this tab is presently in the room". */
		held: boolean;
		reconnect?: "manual" | "requested";
		link?: string;
		manager?: string;
		steward?: string;
		standing: string | null;
		bridgeIntent?: WorkspaceRoomBridgeIntent | null;
		bridgeIssue: string;
	})
	| (ConvBase & {
		type: "dm";
		/** Durable session / checkpoint id. Session commands name this. */
		persistId: string;
		peerRegistrationId: string;
		line: DmLine;
	})
	| (ConvBase & { type: "directory" });

export type DmLine = "introducing" | "live" | "closed";
export type RoomConv = Extract<Conv, { type: "room" }>;
export type DmConv = Extract<Conv, { type: "dm" }>;
export type DirectoryConv = Extract<Conv, { type: "directory" }>;
/** A room or a direct line: the conversations a session checkpoint can name. */
export type SessionConv = RoomConv | DmConv;

export function isSessionConv(conv: Conv): conv is SessionConv {
	return conv.type !== "directory";
}

export type RoomReentry =
	| { kind: "name"; name: string; publicationId?: string }
	| { kind: "link"; link: string; label: string; key: string }
	| { kind: "lost" };

export function roomReentry(conv: RoomConv): RoomReentry {
	if (!conv.held) return { kind: "name", name: conv.id, publicationId: conv.publicationId };
	if (conv.link != null) return { kind: "link", link: conv.link, label: conv.id, key: conv.key };
	return { kind: "lost" };
}

export interface Invitation {
	id: string;
	/** Handed offers use the arrival session; durable links use their target authority. */
	dir: DirId;
	locator?: string;
	nick?: string;
	way: "handed" | "link";
	label: string;
	from: string;
	link: string;
}

/** The bridge half of a room's standing facts. */
export type BridgeFacts = NonNullable<RoomFacts["bridge"]>;
