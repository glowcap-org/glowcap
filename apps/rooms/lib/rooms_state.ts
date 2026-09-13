// The bounded, versioned document that can leave and re-enter a Rooms browser.

import * as z from "zod/mini";
import { OPERATIONS_CAPABILITIES, type OperationsCapability } from "./boot_caps.ts";
import { MAX_FORM_SCOPE, MAX_PENDING_INVITES, MAX_ROOM, nickRefusal } from "./limits.ts";
import { BridgeAnswersSchema } from "./bridge/form.ts";
import { RegistrationIdSchema } from "./directory_publications.ts";
import { parseRoomsSturdyref, roomsLocator } from "./locator.ts";
import { roomsPeerAuthority } from "./routes.ts";
import { boundedText as boundedSchemaText, nonemptyText as nonemptySchemaText } from "./schema.ts";
import { traceOverrideRefusal } from "./trace_publish.ts";

export const WORKSPACE_STATE_KEY = "rooms.workspace-state";
export const WORKSPACE_STATE_VERSION = 1;
export const ROOMS_SESSION_STATE_VERSION = 1;
export const MAX_WORKSPACE_DOCUMENT_CHARS = 512 * 1024;
export const MAX_WORKSPACE_DIRECTORIES = 32;
export const MAX_WORKSPACE_CONVERSATIONS = 256;
export const MAX_WORKSPACE_IGNORED_NAMES = 512;
export const MAX_WORKSPACE_OPERATION_CREDENTIALS = 64;
export const MAX_WORKSPACE_INVITATIONS = MAX_PENDING_INVITES;
export const MAX_WORKSPACE_PEERING = 256;
const MAX_FIELD_CHARS = 64 * 1024;
const MAX_BEARER_CHARS = 16 * 1024;

const boundedText = (max = MAX_FIELD_CHARS) => boundedSchemaText(max);
const nonemptyText = (max = MAX_FIELD_CHARS) => nonemptySchemaText(max);
const nullableText = z.nullable(boundedText());
const sturdyrefText = boundedText(MAX_BEARER_CHARS).check(
	z.startsWith("ocapn://"),
	z.includes("/s/"),
	z.refine((value) => {
		try {
			return parseRoomsSturdyref(value).swissnum.length > 0;
		} catch {
			return false;
		}
	}),
);
const optionalSturdyrefText = z.optional(z.pipe(
	z.nullable(sturdyrefText),
	z.transform((value) => value ?? undefined),
));
const nickText = boundedText().check(z.refine((value) => value === "" || nickRefusal(value) == null));
const peerText = nonemptyText().check(z.refine((value) => nickRefusal(value) == null));
const operationsSwissText = boundedText(MAX_BEARER_CHARS).check(
	z.overwrite((value) => value.trim()),
	z.refine((value) => value.length > 0),
	z.refine((value) => !value.includes("://") && !/\s/.test(value)),
);
const operationsCapability = z.custom<OperationsCapability>((value) =>
	(OPERATIONS_CAPABILITIES as readonly unknown[]).includes(value)
);

export const WorkspaceOperationCredentialSchema = z.strictObject({
	capability: operationsCapability,
	scope: nonemptyText(MAX_BEARER_CHARS),
	swiss: operationsSwissText,
});

export const WorkspaceDirectorySchema = z.strictObject({
	id: nonemptyText(),
	locator: nonemptyText(),
	home: z.boolean(),
	/** Whether a browser has ever received a successful answer from this route.
	 * Absent is the conservative value for pre-field persisted documents. */
	reached: z.optional(z.boolean()),
	nick: nickText,
	nickAllocation: z.optional(z.enum(["exact", "automatic"])),
	standing: nullableText,
});

/** A bridge form a reader answered, kept so a reconnect can answer it again.
 *
 * What is kept is what the reader chose: which action, within which of the
 * bridge's own scopes, and the answers that are not secrets. A secret is never
 * checkpointed — it lives in the runtime until every room in its scope has read
 * it, and a reconnect without one asks the reader again rather than guessing.
 *
 * `scope` is the bridge's word for how far one answer reaches, so a reader who
 * linked an identity on one channel finds it on the others without this having
 * to know why. */
export const WorkspaceRoomBridgeIntentSchema = z.strictObject({
	scope: nonemptyText(MAX_FORM_SCOPE),
	action: nonemptyText(MAX_FIELD_CHARS),
	answers: BridgeAnswersSchema,
	/** Whether the reader answered a secret field.
	 *
	 * The secret itself is never here, so without this a replay could not tell a
	 * submission that needed none from one whose password is simply missing, and
	 * would send a blank where a credential was. Both replays read it: a browser
	 * that holds nothing asks the reader again, and a durable runtime looks in
	 * its own custody first. */
	secretsGiven: z.boolean(),
	/** Opaque command identity for matching separately held credentials. It is
	 * public but contains no credential-derived material. */
	credentialRevision: z.optional(nonemptyText(128)),
}).check(z.refine(
	(intent) => intent.credentialRevision === undefined || intent.secretsGiven,
	"a bridge credential revision requires separately held credentials",
));

export const WorkspaceRoomConversationSchema = z.strictObject({
	kind: z.literal("room"),
	/** Durable conversation id. The presentation store copies this to `persistId`. */
	id: nonemptyText(),
	directory: nonemptyText(),
	/** What the reader sees as the room's name. Presentation `id`. */
	name: nonemptyText(MAX_ROOM),
	/** Private or source-owned. Not "this session is presently in the room". */
	held: z.boolean(),
	/** A definitive authority retirement requires an explicit rejoin choice.
	 * `requested` is the durable half-commit while a fresh realization proves
	 * that choice; success clears it and failure returns to `manual`. */
	reconnect: z.optional(z.enum(["manual", "requested"])),
	link: optionalSturdyrefText,
	manager: optionalSturdyrefText,
	steward: optionalSturdyrefText,
	publicationId: z.optional(z.pipe(
		z.nullable(boundedText()),
		z.transform((value) => value ?? undefined),
	)),
	standing: nullableText,
	draft: boundedText(),
	// Missing keeps the bridge's automatic projected seat. Null is the user's
	// durable Rooms-only choice. An identity asks for that exact IRC login.
	/** The bridge form this room's reader answered, null when they chose to
	 * answer nothing, and absent when they never have. */
	bridgeIntent: z.optional(z.nullable(WorkspaceRoomBridgeIntentSchema)),
});

/** Desired foreign-room publication. The lease and DirectoryPeering stay live
 * in the session runtime; this row is the restartable operation intent. */
export const WorkspacePeeringIntentSchema = z.strictObject({
	id: nonemptyText(),
	destination: nonemptyText(MAX_BEARER_CHARS),
	source: nonemptyText(),
	name: nonemptyText(MAX_ROOM),
});

export const WorkspaceDirectConversationSchema = z.strictObject({
	kind: z.literal("direct"),
	/** Durable conversation id. The presentation store copies this to `persistId`
	 * and calls the row `type: "dm"`. */
	id: nonemptyText(),
	directory: nonemptyText(),
	/** What the reader sees as the peer's nick. Presentation `id`. */
	peer: peerText,
	peerRegistrationId: RegistrationIdSchema,
	closed: z.boolean(),
	draft: boundedText(),
});

export const WorkspaceConversationSchema = z.union([
	WorkspaceRoomConversationSchema,
	WorkspaceDirectConversationSchema,
]);

export const RoomsRoomJoinIntentSchema = z.strictObject({
	locator: nonemptyText(MAX_BEARER_CHARS),
	nick: nickText,
	nickAllocation: z.optional(z.enum(["exact", "automatic"])),
	conversation: WorkspaceRoomConversationSchema,
});

export const WorkspaceInvitationSchema = z.strictObject({
	kind: z.literal("room-link"),
	id: nonemptyText(),
	directory: nonemptyText(),
	locator: nonemptyText(MAX_BEARER_CHARS),
	nick: nickText,
	label: boundedText(),
	from: boundedText(),
	link: sturdyrefText,
});

export const WorkspaceOperationCredentialsSchema = z.array(WorkspaceOperationCredentialSchema).check(
	z.maxLength(MAX_WORKSPACE_OPERATION_CREDENTIALS),
);
export const RoomsIgnoredNamesSchema = z.array(boundedText()).check(z.maxLength(MAX_WORKSPACE_IGNORED_NAMES));

const EstablishedRoomsControllerSelectionSchema = z.union([
	z.strictObject({ kind: z.literal("local") }),
	z.strictObject({ kind: z.literal("attached"), sturdyref: sturdyrefText }),
	z.strictObject({ kind: z.literal("hosted"), sturdyref: sturdyrefText }),
]);
export const RoomsControllerSelectionSchema = z.union([
	z.strictObject({ kind: z.literal("none") }),
	EstablishedRoomsControllerSelectionSchema,
]);

const RoomsSessionStateShapeSchema = z.strictObject({
	version: z.literal(ROOMS_SESSION_STATE_VERSION),
	directories: z.array(WorkspaceDirectorySchema).check(z.maxLength(MAX_WORKSPACE_DIRECTORIES)),
	conversations: z.array(WorkspaceConversationSchema).check(z.maxLength(MAX_WORKSPACE_CONVERSATIONS)),
	invitations: z.array(WorkspaceInvitationSchema).check(z.maxLength(MAX_PENDING_INVITES)),
	active: z.nullable(boundedText()),
	standing: boundedText(),
	ignored: RoomsIgnoredNamesSchema,
	keepHistory: z.boolean(),
	join: z.strictObject({ room: boundedText(), locator: boundedText(), nick: boundedText() }),
	dmMode: z.enum(["webrtc", "relay"]),
	traceOverride: boundedText(),
	capabilities: z.strictObject({
		operations: WorkspaceOperationCredentialsSchema,
		archivePeer: z.nullable(sturdyrefText),
	}),
	peering: z.array(WorkspacePeeringIntentSchema).check(z.maxLength(MAX_WORKSPACE_PEERING)),
});

type RoomsSessionStateShape = z.infer<typeof RoomsSessionStateShapeSchema>;

export const RoomsSessionStateSchema = RoomsSessionStateShapeSchema.check(
	z.refine(hasValidSessionRelations),
	z.refine((state) => traceOverrideRefusal(state.traceOverride) == null),
);

export const RoomsViewStateSchema = z.strictObject({
	theme: z.enum(["light", "dark"]),
	notifyOn: z.boolean(),
	railOpen: z.boolean(),
	rosterOpen: z.boolean(),
	settingsTab: z.enum(["session", "holdings", "reachability"]),
	opsPane: operationsCapability,
});

const RoomsWorkspaceStateShapeSchema = z.strictObject({
	version: z.literal(WORKSPACE_STATE_VERSION),
	/** The page directory a local browser explicitly gave back. Missing keeps
	 * the pre-field behavior of opening the directory that serves this page. */
	leftPageDirectory: z.optional(nonemptyText()),
	controller: RoomsControllerSelectionSchema,
	session: RoomsSessionStateSchema,
	view: RoomsViewStateSchema,
});

function isTraceScope(scope: string): boolean {
	try {
		const url = new URL(scope);
		return (url.protocol === "ws:" || url.protocol === "wss:") && url.href === scope;
	} catch {
		return false;
	}
}

function hasValidSessionRelations(session: RoomsSessionStateShape): boolean {
	const directories = new Map<string, WorkspaceDirectory>();
	let homes = 0;
	for (const directory of session.directories) {
		if (directories.has(directory.id)) return false;
		if (routeAuthority(directory.locator) !== directory.id) return false;
		directories.set(directory.id, directory);
		if (directory.home) homes += 1;
	}
	if (homes > 1) return false;

	const conversations = new Map<string, WorkspaceConversation>();
	const publicRooms = new Set<string>();
	const heldRoomLinks = new Set<string>();
	const openDirects = new Set<string>();
	for (const conversation of session.conversations) {
		const directory = directories.get(conversation.directory);
		if (directory == null || conversations.has(conversation.id)) return false;
		if (conversation.kind === "direct") {
			if (conversation.peer.toLowerCase() === directory.nick.toLowerCase()) return false;
			if (!conversation.closed) {
				const key = `${conversation.directory}\u0000${conversation.peerRegistrationId}`;
				if (openDirects.has(key)) return false;
				openDirects.add(key);
			}
		} else {
			if (conversation.link != null && sturdyrefAuthority(conversation.link) !== conversation.directory) {
				return false;
			}
			if (conversation.manager != null && sturdyrefAuthority(conversation.manager) !== conversation.directory) {
				return false;
			}
			if (conversation.steward != null) {
				if (conversation.link == null || sturdyrefAuthority(conversation.steward) !== conversation.directory) {
					return false;
				}
			}
			if (!conversation.held) {
				const key = `${conversation.directory}\u0000${conversation.name.toLowerCase()}`;
				if (publicRooms.has(key)) return false;
				publicRooms.add(key);
			} else if (conversation.link != null) {
				if (heldRoomLinks.has(conversation.link)) return false;
				heldRoomLinks.add(conversation.link);
			}
		}
		conversations.set(conversation.id, conversation);
	}
	if (session.active != null && !conversations.has(session.active)) return false;
	const invitationIds = new Set<string>();
	for (const invitation of session.invitations) {
		// A pending invitation is the durable route to a directory that may not
		// have been joined yet. Acceptance is the authority boundary that checks
		// the route and materializes that directory record.
		if (invitationIds.has(invitation.id) || sturdyrefAuthority(invitation.link) !== invitation.directory) {
			return false;
		}
		invitationIds.add(invitation.id);
	}

	const operationKeys = new Set<string>();
	let visualizers = 0;
	for (const credential of session.capabilities.operations) {
		const key = `${credential.capability}\u0000${credential.scope}`;
		if (operationKeys.has(key)) return false;
		if (credential.capability === "trace" ? !isTraceScope(credential.scope) : !directories.has(credential.scope)) {
			return false;
		}
		if (credential.capability === "trace" && ++visualizers > 1) return false;
		operationKeys.add(key);
	}
	const peeringIds = new Set<string>();
	const peeringNames = new Set<string>();
	for (const intent of session.peering) {
		const source = conversations.get(intent.source);
		if (
			peeringIds.has(intent.id) || !directories.has(intent.destination) || source?.kind !== "room" ||
			source.directory === intent.destination ||
			!sessionOperationsAuthorizePeering(session.capabilities.operations, intent)
		) return false;
		const nameKey = `${intent.destination}\u0000${intent.name.toLowerCase()}`;
		if (peeringNames.has(nameKey)) return false;
		peeringIds.add(intent.id);
		peeringNames.add(nameKey);
	}
	return true;
}

function sessionOperationsAuthorizePeering(
	operations: readonly { capability: string; scope: string }[],
	intent: { destination: string },
): boolean {
	return operations.some((entry) => entry.capability === "peering" && entry.scope === intent.destination);
}

export function peeringIntentsForOperations(
	operations: readonly { capability: string; scope: string }[],
	peering: readonly WorkspacePeeringIntent[],
): WorkspacePeeringIntent[] {
	return peering.filter((intent) => sessionOperationsAuthorizePeering(operations, intent));
}

/** Resolve the authority carried by a durable route without making the schema
 * parser responsible for dialing it. This low-frequency check is shared by
 * workspace/session imports and every command that validates a new aggregate. */
function routeAuthority(locator: string): string | null {
	try {
		return roomsPeerAuthority(roomsLocator(locator));
	} catch {
		return null;
	}
}

function sturdyrefAuthority(sturdyref: string): string | null {
	try {
		return roomsPeerAuthority(parseRoomsSturdyref(sturdyref).locator);
	} catch {
		return null;
	}
}

export const RoomsWorkspaceStateSchema = RoomsWorkspaceStateShapeSchema;

export type RoomsSettingsTab = z.infer<typeof RoomsViewStateSchema>["settingsTab"];
export type WorkspaceOperationCredential = z.infer<typeof WorkspaceOperationCredentialSchema>;
export type WorkspaceDirectory = z.infer<typeof WorkspaceDirectorySchema>;
export type WorkspaceRoomConversation = z.infer<typeof WorkspaceRoomConversationSchema>;
export type WorkspaceDirectConversation = z.infer<typeof WorkspaceDirectConversationSchema>;
export type WorkspaceConversation = z.infer<typeof WorkspaceConversationSchema>;
export type RoomsRoomJoinIntent = z.infer<typeof RoomsRoomJoinIntentSchema>;
export type WorkspaceRoomBridgeIntent = z.infer<typeof WorkspaceRoomBridgeIntentSchema>;
export type WorkspacePeeringIntent = z.infer<typeof WorkspacePeeringIntentSchema>;
export type WorkspaceInvitation = z.infer<typeof WorkspaceInvitationSchema>;
export type RoomsControllerSelection = z.infer<typeof RoomsControllerSelectionSchema>;
/** A capability-named shared session this browser is attached to or hosting. */
export type SharedRoomsControllerSelection = Extract<
	RoomsControllerSelection,
	{ kind: "attached" } | { kind: "hosted" }
>;
export type RoomsWorkspaceState = z.infer<typeof RoomsWorkspaceStateSchema>;
export type RoomsSessionState = z.infer<typeof RoomsSessionStateSchema>;
export type RoomsViewState = z.infer<typeof RoomsViewStateSchema>;

export { sharedRoomsSession } from "./workspace_view.ts";

export function parseWorkspaceOperationCredentials(raw: unknown): WorkspaceOperationCredential[] | null {
	const parsed = z.safeParse(WorkspaceOperationCredentialsSchema, raw);
	return parsed.success ? parsed.data : null;
}

export const DEFAULT_ROOMS_VIEW_STATE: RoomsViewState = {
	/* Syrup, the same face a reader who has never touched the switch opens on.
	   A workspace that carries no view section is answering the same question
	   a first visit asks, so it has to give the same answer: light here would
	   mean importing an old document quietly turned the page over. */
	theme: "dark",
	notifyOn: false,
	railOpen: true,
	rosterOpen: true,
	settingsTab: "session",
	opsPane: "listeners",
};

export function emptyRoomsSessionState(): RoomsSessionState {
	return {
		version: ROOMS_SESSION_STATE_VERSION,
		directories: [],
		conversations: [],
		invitations: [],
		active: null,
		standing: "",
		ignored: [],
		keepHistory: true,
		join: { room: "", locator: "", nick: "" },
		dmMode: "webrtc",
		traceOverride: "",
		capabilities: { operations: [], archivePeer: null },
		peering: [],
	};
}

function decodedJson(raw: string | null, max: number): unknown | null {
	if (raw == null || raw.length === 0 || raw.length > max) return null;
	try {
		return JSON.parse(raw);
	} catch {
		return null;
	}
}

/** Parse and validate the complete document or refuse it as one unit. */
export function parseWorkspaceState(raw: string | null): RoomsWorkspaceState | null {
	const decoded = decodedJson(raw, MAX_WORKSPACE_DOCUMENT_CHARS);
	if (decoded == null) return null;
	const parsed = z.safeParse(RoomsWorkspaceStateSchema, decoded);
	return parsed.success ? parsed.data : null;
}

export function parseRoomsSessionStateValue(decoded: unknown): RoomsSessionState | null {
	const parsed = z.safeParse(RoomsSessionStateSchema, decoded);
	return parsed.success ? parsed.data : null;
}

export function parseRoomsSessionState(raw: string | null): RoomsSessionState | null {
	const decoded = decodedJson(raw, MAX_WORKSPACE_DOCUMENT_CHARS);
	return decoded == null ? null : parseRoomsSessionStateValue(decoded);
}

export function redactRoomsSessionCapabilities(session: RoomsSessionState): RoomsSessionState {
	return {
		...session,
		conversations: session.conversations.map((conversation) => {
			if (conversation.kind === "direct") return conversation;
			const { link: _link, manager: _manager, steward: _steward, bridgeIntent: _bridgeIntent, ...redacted } =
				conversation;
			return redacted;
		}),
		invitations: [],
		capabilities: { operations: [], archivePeer: null },
		peering: [],
	};
}

/** Produce a portable workspace without bearer authority. Private and handed
 * rooms remain visible but require authority to be supplied again. */
export function redactWorkspaceCapabilities(document: RoomsWorkspaceState): RoomsWorkspaceState {
	return {
		...document,
		controller: { kind: "local" },
		session: redactRoomsSessionCapabilities(document.session),
	};
}
