// Bounded wire answers and callbacks for a durable Rooms session.

import type { Argument } from "@glowcap/runtime";
import * as z from "zod/mini";
import { type Attachment, ATTACHMENT_RECORD_SPAN, readAttachments } from "../attachment.ts";
import { type ArchiveCoordinates, parseArchiveCoordinates } from "../archive/protocol.ts";
import { DiagnosticRowSchema } from "../diagnostics.ts";
import { DirectoryMemberSchema, RoomInfoSchema } from "../directory_publications.ts";
import { BridgeGatewaySchema } from "../bridge/gateway.ts";
import { ListenerRowSchema } from "../listeners.ts";
import {
	lineCost,
	MAX_ACTIVE_SESSION_GRANTS,
	MAX_LINE,
	MAX_NICK,
	MAX_OPERATIONS_ROWS,
	MAX_PENDING_ARCHIVE_SHARES,
	MAX_PENDING_INVITES,
	MAX_ROSTER_SEEN,
	MAX_SESSION_DIRECTORY_ROWS,
	MAX_SESSION_ROOM_MEMBERS,
	MAX_TOPIC,
} from "../limits.ts";
import {
	type RoomsSessionAccess,
	RoomsSessionAccessSchema,
	type RoomsSessionGrantView,
	RoomsSessionGrantViewSchema,
} from "./grants.ts";
import { type RoomsSessionWorkspaceAdoption, RoomsSessionWorkspaceAdoptionSchema } from "./adoption.ts";
import { PresenceSchema, RoomMemberStateSchema } from "../room/presence.ts";
import { BridgeFactsSchema, RoomFactsSchema } from "../room/message.ts";
import { RoomPolicySchema } from "../room/policy.ts";
import {
	MAX_WORKSPACE_CONVERSATIONS,
	MAX_WORKSPACE_DIRECTORIES,
	MAX_WORKSPACE_OPERATION_CREDENTIALS,
	parseRoomsSessionState,
	type RoomsSessionState,
} from "../rooms_state.ts";
import { boundedText, nonemptyText, positiveSafeInteger } from "../schema.ts";

const MAX_WIRE_TEXT_CHARS = 64 * 1024;
const MAX_BEARER_CHARS = 16 * 1024;
const MAX_OPERATIONS_SNAPSHOT_CHARS = 512 * 1024;
const MAX_SESSION_PENDING_EFFECTS = 256;
export const ROOMS_SESSION_SNAPSHOT_VERSION = 1;
export const MAX_SESSION_ISSUES = MAX_WORKSPACE_CONVERSATIONS + MAX_WORKSPACE_DIRECTORIES +
	MAX_WORKSPACE_OPERATION_CREDENTIALS + 16;

const wireText = (max = MAX_WIRE_TEXT_CHARS) => boundedText(max);
const nonemptyWireText = (max = MAX_WIRE_TEXT_CHARS) => nonemptyText(max);
const positiveInt = positiveSafeInteger;

export const RoomsSessionPendingEffectSchema = z.strictObject({
	id: wireText(),
	kind: wireText(),
	subject: wireText(),
	phase: z.enum(["unresolved", "prepared", "completed", "applied"]),
});

export const RoomsSessionIssueSchema = z.strictObject({
	subject: wireText(),
	reason: wireText(),
});

export const RoomsSessionPresenceSchema = PresenceSchema;

export const RoomsSessionRoomFactsSchema = RoomFactsSchema;

export const RoomsSessionRoomViewSchema = z.strictObject({
	conversationId: nonemptyWireText(),
	membershipKind: z.enum(["observer", "participant"]),
	policy: RoomPolicySchema,
	members: z.array(z.tuple([nonemptyWireText(MAX_NICK), RoomMemberStateSchema])).check(
		z.maxLength(MAX_ROSTER_SEEN),
		z.refine((members) => new Set(members.map(([name]) => name)).size === members.length),
	),
	membersMore: z.optional(z.boolean()),
	topic: z.nullable(wireText(MAX_TOPIC)),
	lineBytes: z.nullable(positiveInt),
	/** See `readBridge`. Carried on the view so an attached reader who reloads
	 * still knows which of its names are not the room's own. */
	bridge: z.optional(z.nullable(BridgeFactsSchema)),
	canSetTopic: z.optional(z.boolean()),
	canModerate: z.optional(z.boolean()),
});

export const RoomsSessionDirectoryViewSchema = z.strictObject({
	directoryId: nonemptyWireText(),
	rooms: z.array(RoomInfoSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
	peers: z.array(DirectoryMemberSchema).check(
		z.maxLength(MAX_OPERATIONS_ROWS),
		z.refine((peers) => new Set(peers.map((peer) => peer.name.toLowerCase())).size === peers.length),
	),
	truncated: z.boolean(),
});

export const RoomsSessionArchiveShareSchema = z.strictObject({
	id: nonemptyWireText(),
	directory: nonemptyWireText(),
	conversationId: nonemptyWireText(),
	from: nonemptyWireText(MAX_NICK),
	status: z.enum(["offered", "reading", "unavailable"]),
	error: wireText(),
	kind: z.enum(["direct", "room", "standing"]),
	scopeConversation: z.nullable(z.string()),
	custody: z.enum(["live", "durable"]),
	sturdyref: wireText(),
});

const RoomsSessionArchiveSharesSchema = z.array(RoomsSessionArchiveShareSchema).check(
	z.maxLength(MAX_PENDING_ARCHIVE_SHARES),
);

export const RoomsSessionHandedRoomSchema = z.strictObject({
	id: nonemptyWireText(),
	directory: nonemptyWireText(),
	label: wireText(),
	from: nonemptyWireText(MAX_NICK),
});
const RoomsSessionHandedRoomsSchema = z.array(RoomsSessionHandedRoomSchema).check(z.maxLength(MAX_PENDING_INVITES));

const RoomsSessionRoomViewsSchema = z.array(RoomsSessionRoomViewSchema).check(
	z.maxLength(MAX_WORKSPACE_CONVERSATIONS),
	z.refine((views) => new Set(views.map((view) => view.conversationId)).size === views.length),
	z.refine((views) => views.reduce((total, view) => total + view.members.length, 0) <= MAX_SESSION_ROOM_MEMBERS),
);

const RoomsSessionDirectoryViewsSchema = z.array(RoomsSessionDirectoryViewSchema).check(
	z.maxLength(MAX_WORKSPACE_DIRECTORIES),
	z.refine((views) => new Set(views.map((view) => view.directoryId)).size === views.length),
	z.refine((views) =>
		views.reduce((total, view) => total + view.rooms.length + view.peers.length, 0) <= MAX_SESSION_DIRECTORY_ROWS
	),
);

const RoomsSessionGrantViewsSchema: z.ZodMiniType<RoomsSessionGrantView[]> = z.array(
	RoomsSessionGrantViewSchema,
).check(
	z.maxLength(MAX_ACTIVE_SESSION_GRANTS),
	z.refine((grants) => new Set(grants.map((grant) => grant.id)).size === grants.length),
);

const RoomsSessionAccessWireSchema = z.strictObject({
	version: z.literal(ROOMS_SESSION_SNAPSHOT_VERSION),
	rights: RoomsSessionAccessSchema,
	workspaceAdoption: RoomsSessionWorkspaceAdoptionSchema,
	grants: RoomsSessionGrantViewsSchema,
	suspendedNote: z.optional(z.string()),
});

const ListenerSnapshotSchema = z.strictObject({
	capability: z.literal("listeners"),
	rows: z.array(ListenerRowSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
});
const DiagnosticsSnapshotSchema = z.strictObject({
	capability: z.literal("diagnostics"),
	rows: z.array(DiagnosticRowSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
});
const IrcSnapshotSchema = z.strictObject({
	capability: z.literal("irc"),
	gateway: BridgeGatewaySchema,
});
const VizSnapshotSchema = z.strictObject({
	capability: z.literal("viz"),
	url: nonemptyWireText(),
	connected: z.boolean(),
	refusal: z.nullable(nonemptyWireText()),
});
const PeeringSnapshotSchema = z.strictObject({
	capability: z.literal("peering"),
	rows: z.array(z.strictObject({
		id: nonemptyWireText(),
		name: nonemptyWireText(),
		source: nonemptyWireText(),
		phase: z.enum(["publishing", "live", "revoking", "failed"]),
	})).check(z.maxLength(MAX_WORKSPACE_CONVERSATIONS)),
});

export const RoomsOperationsSnapshotSchema = z.union([
	ListenerSnapshotSchema,
	DiagnosticsSnapshotSchema,
	IrcSnapshotSchema,
	PeeringSnapshotSchema,
	VizSnapshotSchema,
]);

export type RoomsSessionPendingEffect = z.infer<typeof RoomsSessionPendingEffectSchema>;
export type RoomsSessionIssue = z.infer<typeof RoomsSessionIssueSchema>;
export type RoomsSessionPresence = z.infer<typeof RoomsSessionPresenceSchema>;
export type RoomsSessionRoomFacts = z.infer<typeof RoomsSessionRoomFactsSchema>;
export type RoomsSessionRoomView = z.infer<typeof RoomsSessionRoomViewSchema>;
export type RoomsSessionDirectoryView = z.infer<typeof RoomsSessionDirectoryViewSchema>;
export type RoomsSessionArchiveShare = z.infer<typeof RoomsSessionArchiveShareSchema>;
export type RoomsSessionHandedRoom = z.infer<typeof RoomsSessionHandedRoomSchema>;

export function parseRoomsSessionArchiveShare(raw: unknown): RoomsSessionArchiveShare {
	const parsed = z.safeParse(RoomsSessionArchiveShareSchema, raw);
	if (!parsed.success) throw new Error("the Rooms session answered an invalid archive-share view");
	return parsed.data;
}
export type RoomsOperationsSnapshot = z.infer<typeof RoomsOperationsSnapshotSchema>;

export interface RoomsSessionSnapshot {
	revision: number;
	checkpoint: RoomsSessionState;
	pendingEffects: string[];
	pendingEffectDetails: RoomsSessionPendingEffect[];
	issues: RoomsSessionIssue[];
	connectedDirectories: string[];
	memberLocator: string | null;
	roomViews: RoomsSessionRoomView[];
	archiveShares: RoomsSessionArchiveShare[];
	directoryViews: RoomsSessionDirectoryView[];
	access: RoomsSessionAccess;
	/** Why this view carries nothing, when it carries nothing. Absent otherwise,
	 * because most views are not suspended and an empty string standing in for
	 * "no reason" is a second way of saying the same thing as `access`. */
	suspendedNote?: string;
	workspaceAdoption: RoomsSessionWorkspaceAdoption;
	grants: RoomsSessionGrantView[];
	handedRooms: RoomsSessionHandedRoom[];
}

export interface RoomsSessionLineEvent {
	source: string;
	sequence: number;
	conversationId: string;
	from: string;
	text: string;
	at: number;
	lineId: number | null;
	change: "said" | "edited" | "refiled" | "withdrawn" | null;
	editable: boolean;
	history: ArchiveCoordinates | null;
	system: boolean;
	presence?: RoomsSessionPresence;
	facts?: RoomsSessionRoomFacts;
	attachments: Attachment[];
}

function jsonText<T>(raw: unknown, max: number, what: string, schema: z.ZodMiniType<T>): T {
	if (typeof raw !== "string" || raw.length > max) {
		throw new Error(`the Rooms session answered invalid ${what}`);
	}
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error(`the Rooms session answered ${what} that is not JSON`);
	}
	const parsed = z.safeParse(schema, decoded);
	if (!parsed.success) throw new Error(`the Rooms session answered invalid ${what}`);
	return parsed.data;
}

export function parseOperationsSnapshot(
	capability: RoomsOperationsSnapshot["capability"],
	raw: unknown,
): RoomsOperationsSnapshot {
	const rows = jsonText(raw, MAX_OPERATIONS_SNAPSHOT_CHARS, `${capability} snapshot`, z.unknown());
	if (capability === "viz") {
		if (typeof rows !== "object" || rows == null || Array.isArray(rows)) {
			throw new Error("the Rooms session answered an invalid visualizer snapshot");
		}
		const parsed = z.safeParse(VizSnapshotSchema, { capability, ...rows });
		if (!parsed.success) throw new Error("the Rooms session answered an invalid visualizer snapshot");
		return parsed.data;
	}
	if (capability === "peering") {
		const parsed = z.safeParse(PeeringSnapshotSchema, { capability, rows });
		if (!parsed.success) throw new Error("the Rooms session answered an invalid peering row list");
		return parsed.data;
	}
	if (capability === "irc") {
		if (typeof rows !== "object" || rows == null || Array.isArray(rows)) {
			throw new Error("the Rooms session answered an invalid gateway snapshot");
		}
		const parsed = z.safeParse(BridgeGatewaySchema, rows);
		if (!parsed.success) throw new Error("the Rooms session answered an invalid gateway snapshot");
		return { capability: "irc", gateway: parsed.data };
	}
	const schema = capability === "listeners" ? ListenerSnapshotSchema : DiagnosticsSnapshotSchema;
	const parsed = z.safeParse(schema, { capability, rows });
	if (!parsed.success) throw new Error(`the Rooms session answered an invalid ${capability} row list`);
	return parsed.data;
}

export function parseLineEvent(args: unknown[]): RoomsSessionLineEvent {
	if (
		args.length < 15 || (args.length - 15) % ATTACHMENT_RECORD_SPAN !== 0 ||
		typeof args[0] !== "string" || args[0] === "" || args[0].length > MAX_WIRE_TEXT_CHARS ||
		typeof args[1] !== "bigint" || args[1] < 1n || args[1] > BigInt(Number.MAX_SAFE_INTEGER) ||
		typeof args[2] !== "string" || args[2].length > MAX_WIRE_TEXT_CHARS ||
		typeof args[3] !== "string" || args[3].length > MAX_NICK ||
		typeof args[4] !== "string" || lineCost(args[4]) > MAX_LINE ||
		typeof args[5] !== "bigint" || args[5] < 0n || args[5] > BigInt(Number.MAX_SAFE_INTEGER) ||
		(args[6] !== null &&
			(typeof args[6] !== "bigint" || args[6] < 1n || args[6] > BigInt(Number.MAX_SAFE_INTEGER))) ||
		(args[7] !== null && args[7] !== "said" && args[7] !== "edited" && args[7] !== "refiled" &&
			args[7] !== "withdrawn") ||
		typeof args[8] !== "boolean" || typeof args[12] !== "boolean"
	) throw new Error("the Rooms session answered an invalid line event");
	const history = args[9] === null && args[10] === null && args[11] === null
		? null
		: parseArchiveCoordinates(args[9], args[10], args[11]);
	const presence = parseEventPresence(args[13]);
	const facts = parseEventFacts(args[14]);
	const attachments = readAttachments(args as Argument[], 15);
	if (attachments.length * ATTACHMENT_RECORD_SPAN !== args.length - 15) {
		throw new Error("the Rooms session answered malformed line attachments");
	}
	const lineId = args[6] == null ? null : Number(args[6]);
	const change = args[7] as RoomsSessionLineEvent["change"];
	if ((change === "edited" || change === "refiled" || change === "withdrawn") && lineId == null) {
		throw new Error("the Rooms session answered a line mutation without a line id");
	}
	if ((change === "edited" || change === "withdrawn" || args[12]) && attachments.length > 0) {
		throw new Error("the Rooms session answered attachments on a line that cannot carry files");
	}
	return {
		source: args[0],
		sequence: Number(args[1]),
		conversationId: args[2],
		from: args[3],
		text: args[4],
		at: Number(args[5]),
		lineId,
		change,
		editable: args[8],
		history,
		system: args[12],
		...(presence == null ? {} : { presence }),
		...(facts == null ? {} : { facts }),
		attachments,
	};
}

function parseEventPresence(raw: unknown): RoomsSessionPresence | undefined {
	return raw == null ? undefined : jsonText(raw, MAX_WIRE_TEXT_CHARS, "room presence", RoomsSessionPresenceSchema);
}

function parseEventFacts(raw: unknown): RoomsSessionRoomFacts | undefined {
	return raw == null ? undefined : jsonText(raw, MAX_WIRE_TEXT_CHARS, "room facts", RoomsSessionRoomFactsSchema);
}

function boundedStringArray(raw: unknown, max: number): raw is string[] {
	return Array.isArray(raw) && raw.length <= max &&
		raw.every((value) => typeof value === "string" && value.length <= MAX_WIRE_TEXT_CHARS);
}

export function parseRoomsSessionSnapshot(raw: unknown): RoomsSessionSnapshot {
	if (
		!Array.isArray(raw) || raw.length !== 12 ||
		typeof raw[0] !== "bigint" || raw[0] < 0n ||
		raw[0] > BigInt(Number.MAX_SAFE_INTEGER) || typeof raw[1] !== "string" ||
		!boundedStringArray(raw[2], MAX_SESSION_PENDING_EFFECTS) || !Array.isArray(raw[3]) ||
		raw[3].length > MAX_SESSION_ISSUES ||
		raw[3].some((issue) =>
			!Array.isArray(issue) || issue.length !== 2 || typeof issue[0] !== "string" ||
			issue[0].length > MAX_WIRE_TEXT_CHARS || typeof issue[1] !== "string" ||
			issue[1].length > MAX_WIRE_TEXT_CHARS
		) || !boundedStringArray(raw[4], MAX_WORKSPACE_DIRECTORIES) || !Array.isArray(raw[5]) ||
		raw[5].length > MAX_SESSION_PENDING_EFFECTS ||
		raw[5].some((effect) =>
			!Array.isArray(effect) || effect.length !== 4 ||
			effect.slice(0, 3).some((value) => typeof value !== "string" || value.length > MAX_WIRE_TEXT_CHARS) ||
			!(effect[3] === "unresolved" || effect[3] === "prepared" || effect[3] === "completed" ||
				effect[3] === "applied")
		) || (raw[6] !== null && (typeof raw[6] !== "string" || raw[6].length > MAX_BEARER_CHARS))
	) throw new Error("the Rooms session answered an invalid snapshot");
	const checkpoint = parseRoomsSessionState(raw[1]);
	if (checkpoint == null) throw new Error("the Rooms session answered an invalid checkpoint");
	return {
		revision: Number(raw[0]),
		checkpoint,
		pendingEffects: raw[2],
		pendingEffectDetails: (raw[5] as [string, string, string, RoomsSessionPendingEffect["phase"]][]).map(
			([id, kind, subject, phase]) => ({ id, kind, subject, phase }),
		),
		issues: (raw[3] as [string, string][]).map(([subject, reason]) => ({ subject, reason })),
		connectedDirectories: raw[4],
		memberLocator: raw[6],
		roomViews: parseRoomViews(raw[7]),
		archiveShares: jsonText(raw[8], 128 * 1024, "archive shares", RoomsSessionArchiveSharesSchema),
		directoryViews: parseDirectoryViews(raw[9]),
		...(() => {
			const access = jsonText(raw[10], 640 * 1024, "session access", RoomsSessionAccessWireSchema);
			return {
				access: access.rights,
				suspendedNote: access.suspendedNote,
				workspaceAdoption: access.workspaceAdoption,
				grants: access.grants,
			};
		})(),
		handedRooms: jsonText(raw[11], 128 * 1024, "handed room invitations", RoomsSessionHandedRoomsSchema),
	};
}

function parseRoomViews(raw: unknown): RoomsSessionRoomView[] {
	return jsonText(raw, 512 * 1024, "live room state", RoomsSessionRoomViewsSchema);
}

function parseDirectoryViews(raw: unknown): RoomsSessionDirectoryView[] {
	return jsonText(raw, 2 * 1024 * 1024, "live directory state", RoomsSessionDirectoryViewsSchema);
}
