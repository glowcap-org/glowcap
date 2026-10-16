// Coordinates describe separately held fields. They are never bearer links.
import * as z from "zod/mini";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import type { DirectoryMember, RoomEvent, RoomInfo } from "../../../../lib/directory_publications.ts";
import type { Presence } from "../../../../lib/room/presence.ts";
import type { RoomFacts } from "../../../../lib/room/message.ts";
import type { RoomPolicy } from "../../../../lib/room/policy.ts";

export type FieldKey = string;
export interface Coordinate {
	role: string;
	key: FieldKey;
}
/** Whether a parsed receipt value is a coordinate: a named role and held key. */
export function isCoordinate(raw: unknown): raw is Coordinate {
	return raw != null && typeof raw === "object" &&
		typeof (raw as Coordinate).role === "string" && typeof (raw as Coordinate).key === "string";
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
	/** Exact public generation. Descriptive even after acquiring a linked entrance. */
	publication?: string;
	seat?: FieldKey;
	subject?: FieldKey;
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
/** An archive coordinate as the wire carries it. Mirrors ArchiveCoordinates
 * in lib/archive/protocol.ts, which owns no JSON schema today. */
export const HistoryCoordinateSchema = z.object({
	source: z.string(),
	generation: z.string(),
	id: z.string(),
});

/** The activity payloads the wire produces, discriminated by their `kind`
 * tag. The schema is the one definition of these shapes: the type, the kind
 * set, and the validator all derive from it. The schema proves the envelope
 * the runtime fabricates (kind tags, strings, booleans, enums, numbers,
 * coordinates) and stays optional so a partial notice degrades to no
 * effect rather than a wrong one. Embedded domain payloads (RoomInfo,
 * DirectoryMember, RoomEvent, RoomPolicy, Presence, RoomFacts) carry their
 * producer's proof: each owns a peer-wire schema in lib/ that validated it
 * at ingress, and re-litigating those content limits here could only drop a
 * rendered line. The Rust producer in session/managed/activity/projection.rs
 * owns these shapes. Its reader merges recorded history into the line
 * notice. */
export const ActivityNoticeSchema = z.discriminatedUnion("kind", [
	z.object({ kind: z.literal("unavailable") }),
	z.object({
		kind: z.literal("discoverySnapshot"),
		snapshot: z.optional(z.object({
			rooms: z.array(z.custom<RoomInfo>(() => true)),
			peers: z.array(z.custom<DirectoryMember>(() => true)),
			omitted: z.number(),
		})),
	}),
	z.object({ kind: z.literal("discoveryChanged"), event: z.optional(z.custom<RoomEvent>(() => true)) }),
	z.object({
		kind: z.literal("registered"),
		nick: z.optional(z.string()),
		registration: z.optional(z.string()),
	}),
	z.object({
		kind: z.enum(["mintInboxFor", "directRequested", "introducible"]),
		peer: z.optional(z.string()),
		registration: z.optional(z.string()),
		opening: z.optional(z.nullable(z.string())),
	}),
	z.object({ kind: z.literal("ready") }),
	z.object({ kind: z.literal("ended"), reason: z.optional(z.string()) }),
	z.object({ kind: z.literal("policy"), policy: z.optional(z.custom<RoomPolicy>(() => true)) }),
	z.object({
		kind: z.literal("occupancy"),
		listed: z.optional(z.boolean()),
		claimable: z.optional(z.nullable(z.boolean())),
	}),
	z.object({
		kind: z.literal("authority"),
		authority: z.optional(z.enum(["room", "steward", "manager"])),
		token: z.optional(z.string()),
		claimable: z.optional(z.boolean()),
	}),
	z.object({ kind: z.literal("typing"), name: z.optional(z.string()), on: z.optional(z.boolean()) }),
	z.object({ kind: z.enum(["handRoom", "offerRoom"]), label: z.optional(z.string()) }),
	z.object({
		kind: z.enum(["handArchive", "offerArchive"]),
		directory: z.optional(z.string()),
		scope: z.optional(z.string()),
		conversation: z.optional(z.nullable(z.string())),
	}),
	z.object({
		kind: z.literal("line"),
		from: z.optional(z.string()),
		text: z.optional(z.string()),
		marker: z.optional(z.nullable(z.object({
			id: z.number(),
			change: z.enum(["said", "edited", "refiled", "withdrawn"]),
		}))),
		metadata: z.optional(z.nullable(z.object({
			presence: z.optional(z.custom<Presence>(() => true)),
			facts: z.optional(z.custom<RoomFacts>(() => true)),
			operation: z.optional(z.nullable(z.string())),
		}))),
		previewUrls: z.optional(z.array(z.string())),
		history: z.optional(z.nullable(HistoryCoordinateSchema)),
	}),
]);
export type ActivityNotice = z.infer<typeof ActivityNoticeSchema>;

/** Narrow an activity payload to a known, well-formed notice. A kind newer
 * than this build, or a malformed payload, is not acted on. Each consumer
 * then acts only on the kinds it owns. */
export function activityNotice(raw: unknown): ActivityNotice | null {
	const parsed = z.safeParse(ActivityNoticeSchema, raw);
	return parsed.success ? parsed.data : null;
}

export interface ActivityEvent<Notice = ActivityNotice | null> {
	target: { kind: "discovery" | "directory" | "room" | "direct" | "archive"; id: string };
	notice: Notice;
	files?: import("../../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedFile[];
	authority?: import("../../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedIncoming;
	route?: import("../../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsManagedIncoming;
}
export interface ActivityPage<Notice = ActivityNotice | null> {
	cursor: string;
	gap?: boolean;
	event?: ActivityEvent<Notice>;
}
