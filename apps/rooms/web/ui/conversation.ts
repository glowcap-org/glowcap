// Conversation, message, and invitation state for the Rooms presentation model.

import type { RoomMemberState } from "../../lib/room_presence.ts";
import type { WorkspaceRoomIrcIdentity } from "../../lib/rooms_state.ts";
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

export interface ConvBase {
	persistId: string;
	id: string;
	key: string;
	dir: DirId;
	history: readonly Item[];
	unread: Unread;
}

export type Standing = RoomMemberState;

export function membersHere(members: ReadonlyMap<string, Standing>): number {
	let here = 0;
	for (const standing of members.values()) if (standing.online) here++;
	return here;
}

export function awayByPeer(convs: ReadonlyMap<string, Conv>): ReadonlyMap<DirId, ReadonlyMap<string, string | null>> {
	const dirs = new Map<DirId, Map<string, string | null>>();
	for (const conv of convs.values()) {
		if (conv.type !== "room") continue;
		let words = dirs.get(conv.dir);
		if (words == null) {
			words = new Map();
			dirs.set(conv.dir, words);
		}
		for (const [member, standing] of conv.members) {
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

export type Conv =
	| (ConvBase & {
		type: "room";
		membership: "joining" | "joined" | "unavailable";
		publicationId?: string;
		members: ReadonlyMap<string, Standing>;
		typers: ReadonlySet<string>;
		lineBytes?: number;
		topic?: string;
		earlierHistory: "unasked" | "loading" | "empty" | "shown" | "unavailable";
		grants: ReadonlySet<string>;
		held: boolean;
		stewardClaimable: boolean;
		link?: string;
		steward?: string;
		standing: string | null;
		irc?: WorkspaceRoomIrcIdentity | null;
		ircIssue: string;
	})
	| (ConvBase & {
		type: "dm";
		peerRegistrationId: string;
		line: DmLine;
		typers: ReadonlySet<string>;
	});

export type DmLine = "introducing" | "live" | "closed";
export type RoomConv = Extract<Conv, { type: "room" }>;
export type DmConv = Extract<Conv, { type: "dm" }>;

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
