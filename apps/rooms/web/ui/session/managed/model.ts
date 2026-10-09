// Coordinates describe separately held fields. They are never bearer links.
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";

export type FieldKey = string;
export interface Coordinate {
	role: string;
	key: FieldKey;
}
export function coordinate(role: string, key: FieldKey): string {
	return JSON.stringify({ role, key });
}
export function fieldKey(): FieldKey {
	const bytes = crypto.getRandomValues(new Uint8Array(16));
	if (bytes.subarray(0, 8).every((byte) => byte === 0) || bytes.subarray(8).every((byte) => byte === 0)) {
		return fieldKey();
	}
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
export interface DirectoryIntent {
	id: string;
	access: FieldKey;
	source?: FieldKey;
	name?: FieldKey;
	inbox?: FieldKey;
	home: boolean;
	nick: string;
	assignedNick?: string;
	nickAllocation: "exact" | "automatic";
	standing: string | null;
}
export interface PostedLine {
	id: number;
	handle: FieldKey;
}
export interface RoomIntent {
	kind: "room";
	id: string;
	directory: string;
	name: string;
	source?: FieldKey;
	inbox?: FieldKey;
	access: FieldKey | null;
	accepted?: FieldKey;
	publicEntry?: { access: FieldKey };
	/** Exact public generation; descriptive even after acquiring a linked entrance. */
	publication?: string;
	seat?: FieldKey;
	topic?: FieldKey;
	files?: FieldKey;
	moderator?: FieldKey;
	control: FieldKey | null;
	lines?: PostedLine[];
	reconnect: "manual" | "requested";
	standing: string | null;
	draft: string;
}
export interface DirectIntent {
	kind: "direct";
	id: string;
	directory: string;
	peer: string;
	source?: FieldKey;
	inbox?: FieldKey;
	access: FieldKey | null;
	introduction?: { access: FieldKey; name: FieldKey; callback: FieldKey; registration: string; opening: string };
	lines?: PostedLine[];
	closed: boolean;
	draft: string;
}
export type ConversationIntent = RoomIntent | DirectIntent;
/** The exact live authority and naming selected for a conversation, independent of drafts. */
export function conversationIdentity(row: ConversationIntent): string {
	return JSON.stringify([
		row.kind,
		row.id,
		row.directory,
		row.source,
		row.kind === "room" && row.seat != null ? null : row.access,
		row.kind === "room"
			? [row.name, row.seat != null ? row.seat : [row.accepted, row.publicEntry]]
			: [row.peer, row.introduction],
	]);
}
export interface ReceivedArchive {
	id: string;
	channel: string;
	directory: string;
	kind: "room" | "direct" | "standing";
	conversation: string | null;
	from: string;
	access: FieldKey;
	source: FieldKey;
	durable: boolean;
}
export interface WorkspaceIntent {
	version: 1;
	archiveShares?: ReceivedArchive[];
	accesses?: { id: string; access?: FieldKey | null; control?: FieldKey | null }[];
	directories: DirectoryIntent[];
	conversations: ConversationIntent[];
	invitations: {
		id: string;
		directory: string;
		label: string;
		from: string;
		authority: { role: "offer" | "roomAccess"; key: FieldKey };
		source?: FieldKey;
	}[];
	active: string | null;
	standing: string;
	ignored: string[];
	keepHistory: boolean;
	historyErasure?: string;
	connection: "webrtc" | "relay";
	archive: FieldKey | null;
	archiveControl: FieldKey | null;
	operators: FieldKey[];
	operations?: {
		kind: string;
		handle: Coordinate;
		connection?: { operation: string; gateway: Coordinate; id: string };
	}[];
	peering: { id: string; directory: string; name: string; room: FieldKey; lease: FieldKey }[];
}
export interface WorkspaceSnapshot {
	revision: string;
	intent: WorkspaceIntent;
}
export interface UseView {
	status: "active" | "paused" | "revoked" | "outOfScope";
	effective?: { permissions: RoomsPermission[] };
}
export interface ObservationView {
	cursor: Uint8Array;
	source: UseView;
	changed: boolean;
	resync: boolean;
}
export interface EffectView {
	operation: string;
	status: string;
	resumable: boolean;
}
export interface ActivityPage {
	cursor: string;
	gap?: boolean;
	event?: {
		target: { kind: "discovery" | "directory" | "room" | "direct" | "archive"; id: string };
		notice: Record<string, unknown>;
		files?: import("../../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedFile[];
		authority?: import("../../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedIncoming;
		route?: import("../../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedIncoming;
	};
}
