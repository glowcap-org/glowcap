// Conversation, message, and invitation state for the Rooms presentation model.

import type { RoomMemberState } from "../../lib/room/presence.ts";
import type { RoomCarries, RoomFacts } from "../../lib/room/message.ts";
import type { RoomFeature } from "../../lib/protocol.ts";
import type { WorkspaceRoomBridgeIntent } from "../../lib/rooms_state.ts";
import type { RoomMembershipKind } from "../../lib/room/membership.ts";
import type { RoomPolicy } from "./room_policy.ts";
import type { DirId } from "./types.ts";
import type { ArchiveCoordinates } from "../../lib/archive/protocol.ts";

/** What the page knows about a line it sent: still on its way, definitely
 * nowhere, or somewhere nobody can yet confirm. "unconfirmed" is the runtime's
 * `delivery-uncertain` evidence: the send may have reached the other side, so
 * it is drawn as unsent but never offered a blind retry. */
export type SendState = "sending" | "failed" | "unconfirmed";

export function isUnsent(state: SendState | undefined): boolean {
	return state === "failed" || state === "unconfirmed";
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
	/** Content identity for archive reconciliation, independent of file metadata. */
	archiveDigest?: string;
}

export type ViewerDirection = "previous" | "next";

export type SysAudience = "here" | "shared";

export type HistoryCoordinate = ArchiveCoordinates;

/** What a chat line carries in its text besides words: a `/me` action or a
 * `/notice`, read once where the line enters the store. The log draws from
 * this field, so a line with nothing carried has no field. */
export interface LineCarried {
	readonly kind: "action" | "notice";
	readonly text: string;
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
		/** The managed send still owns its original receipt. An echo alone does
		 * not settle upload completion or confirm its result acquisition. */
		awaitingReceipt?: boolean;
		/** A managed send recovers its exact receipt through the session owner.
		 * A bubble cannot manufacture a new request from descriptive text. */
		retryable?: boolean;
		/** The existing session receipt for this submitted line. Recovery uses
		 * this scalar identity even after the composer accepts a newer draft. */
		operation?: string;
		/** The action or notice this line's text carries, stamped by the store
		 * when the line is made or its text changes. */
		carried?: LineCarried;
		/** The id assigned by the current live room generation. Retired when that
		 * membership ends; retained text is not authority for a later generation. */
		lineId?: number;
		history?: HistoryCoordinate;
		/** Source conversation order for history reconciliation. Unlike archive
		 * coordinates, this field is ordering authority rather than identity. */
		order?: number;
		edited?: boolean;
		withdrawn?: boolean;
		held?: boolean;
		attachments?: readonly AttachmentView[];
		previewUrls?: readonly string[];
	}
	| {
		kind: "sys";
		id: number;
		text: string;
		at: number;
		audience: SysAudience;
		/** The session's own history boundary has stable semantic identity while
		 * its keeper attribution changes after each authoritative archive read. */
		historyBoundary?: "session";
		archiveSection?: Pick<ArchiveCoordinates, "source" | "generation">;
	}
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
		/** What this room keeps or relays of a message beyond its text and
		 * files, when it said: link previews, the typing signal. Absent until
		 * the room states it, and every control stays while it is. What a
		 * member can *do* is not here: that is what they hold, in `grants`. */
		carries?: RoomCarries;
		earlierHistory: "unasked" | "loading" | "empty" | "shown" | "unavailable";
		grants: ReadonlySet<string>;
		membershipKind: RoomMembershipKind;
		policy: RoomPolicy;
		/** Private or source-owned, not "this tab is presently in the room". */
		held: boolean;
		reconnect?: "manual" | "requested";
		/** Which room entry link, room manager, and room moderator this session
		 * holds for the room, as the identity the Rust application gives each
		 * one (`roomAuthorityToken`), never the sturdyref itself.
		 *
		 * A token says that an authority is held and tells one from another; it
		 * opens nothing. The bearer string stays in the Rust checkpoint, and a
		 * control that copies it asks there at press time (`session/bearer.ts`),
		 * so a rail row subscribed to this map is never handed a secret it does
		 * not draw. */
		linkToken?: string;
		managerToken?: string;
		stewardToken?: string;
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
export type { RoomCarries };

/** Whether this conversation keeps or relays one part of a message that no
 * capability stands for: the link previews a line names, or the typing
 * signal. A room answers from what it stated at arrival. A room that stated
 * nothing has not said it lacks anything, so it answers yes and keeps every
 * control; a direct line carries both; a directory carries no messages. */
export function conversationCarries(conv: Conv | null, feature: RoomFeature): boolean {
	if (conv === null || conv.type === "directory") return false;
	if (conv.type === "dm") return true;
	return conv.carries === undefined || conv.carries[feature];
}

/** Whether this conversation takes files: a direct line always does, and a
 * room does when this membership holds the files facet the room handed over
 * at subscribe. That is what the attach control, the drop target, and a
 * pasted file are drawn from, so a room that cannot hold bytes never shows
 * a way to send one. */
export function conversationTakesFiles(conv: Conv | null): boolean {
	if (conv === null || conv.type === "directory") return false;
	if (conv.type === "dm") return true;
	return conv.grants.has("files");
}
