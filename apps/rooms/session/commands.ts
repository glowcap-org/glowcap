// Pure checkpoint commands for a durable Rooms session.

import * as z from "zod/mini";
import {
	peeringIntentsForOperations,
	RoomsIgnoredNamesSchema,
	type RoomsSessionState,
	WorkspaceDirectConversationSchema,
	WorkspaceDirectorySchema,
	WorkspaceInvitationSchema,
	WorkspaceOperationCredentialsSchema,
	WorkspacePeeringIntentSchema,
	WorkspaceRoomConversationSchema,
	WorkspaceRoomIrcIdentitySchema,
} from "../lib/rooms_state.ts";
import { vizOverrideRefusal } from "../lib/viz_publish.ts";
import { isPrivateRoomKey, MAX_PENDING_INVITES, nickRefusal } from "../lib/limits.ts";
import { validateIrcNick, validateSaslPlain } from "../irc/registration.ts";
import { roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { commandJson as jsonValue, validatedRoomsSessionState as validated } from "./command_data.ts";
import { applyRoomJoin } from "./join_command.ts";

const MAX_COMMAND_TEXT = 64 * 1024;
const MAX_BEARER_TEXT = 16 * 1024;

export type RoomsCheckpointImpact = "presentation" | "standing" | "realization";

/** Name which runtime owner a pure checkpoint command can affect. This keeps a
 * draft or selection change from projecting every directory and conversation
 * merely to rediscover that no network fact changed. */
export function roomsSessionCommandImpact(command: string): RoomsCheckpointImpact {
	if (command === "setStanding" || command === "setDirectoryStanding" || command === "setRoomStanding") {
		return "standing";
	}
	if (
		command === "setDraft" || command === "select" || command === "dismissInvitation" ||
		command === "receiveRoomLinkInvitation" || command === "setIgnoredNames" ||
		command === "chooseHistoryRetention" || command === "chooseConnection"
	) return "presentation";
	return "realization";
}

const sturdyrefText = z.string().check(
	z.minLength(1),
	z.maxLength(MAX_BEARER_TEXT),
	z.startsWith("ocapn://"),
	z.includes("/s/"),
);

export interface RoomsSessionResultPlan {
	readonly kind: "private-room" | "room-link" | "room-steward";
	readonly intent: string;
	readonly directory?: string;
	readonly label?: string;
	readonly recoveryKey?: string;
	readonly conversationId?: string;
	readonly stewardLink?: string | null;
}

interface PrivateRoomIntent {
	conversation: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>;
	recoveryKey: string;
}

const PrivateRoomConversationSchema = WorkspaceRoomConversationSchema.check(
	z.refine((conversation) =>
		conversation.held && conversation.link == null && conversation.steward == null &&
		conversation.publicationId == null
	),
);
const PrivateRoomIntentSchema = z.strictObject({
	conversation: PrivateRoomConversationSchema,
	recoveryKey: z.string().check(z.refine(isPrivateRoomKey)),
});

const RoomAuthorityIntentSchema = z.strictObject({
	conversation: WorkspaceRoomConversationSchema,
	stewardLink: z.optional(sturdyrefText),
});
const RoomLinkResultSchema = z.strictObject({ roomLink: sturdyrefText });
const RoomStewardResultSchema = z.strictObject({ roomLink: sturdyrefText, stewardLink: sturdyrefText });

function privateRoomIntent(intentText: string): PrivateRoomIntent {
	return jsonValue(intentText, "private-room result", PrivateRoomIntentSchema);
}

type RoomAuthorityIntent = z.infer<typeof RoomAuthorityIntentSchema>;

function roomAuthorityIntent(intentText: string): RoomAuthorityIntent {
	return jsonValue(intentText, "room authority result", RoomAuthorityIntentSchema);
}

function roomModeratorSturdyref(raw: string, command: string): string {
	const parsed = z.safeParse(sturdyrefText, raw);
	if (!parsed.success) throw new Error(`${command} needs a valid room moderator sturdyref`);
	return parsed.data;
}

function roomConversation(
	current: RoomsSessionState,
	conversationId: string,
	command: string,
): Extract<RoomsSessionState["conversations"][number], { kind: "room" }> {
	const conversation = current.conversations.find((entry) => entry.id === conversationId);
	if (conversation?.kind !== "room") throw new Error(`${command} names no room in this session`);
	const directory = current.directories.find((entry) => entry.id === conversation.directory);
	if (directory == null || directory.nick === "") {
		throw new Error(`${command} needs a named directory in this session`);
	}
	return conversation;
}

export function prepareRoomOffer(
	current: RoomsSessionState,
	args: string[],
): { roomConversationId: string; directConversationId: string; label: string; link: string } {
	if (args.length !== 2) throw new Error("offerRoom takes a room and direct conversation id");
	const room = current.conversations.find((entry) => entry.id === args[0]);
	const direct = current.conversations.find((entry) => entry.id === args[1]);
	if (room?.kind !== "room" || room.link == null) {
		throw new Error("offerRoom needs a room with a durable link");
	}
	if (direct?.kind !== "direct" || direct.closed || direct.directory !== room.directory) {
		throw new Error("offerRoom needs an open direct conversation on the room's directory");
	}
	return { roomConversationId: room.id, directConversationId: direct.id, label: room.name, link: room.link };
}

export function prepareRoomsSessionResult(
	current: RoomsSessionState,
	command: string,
	args: string[],
	allowExisting = false,
): RoomsSessionResultPlan {
	if (command === "ensureRoomLink" || command === "linkRoom" || command === "takeRoomModerator") {
		const takingModerator = command === "takeRoomModerator";
		if ((takingModerator && (args.length < 1 || args.length > 2)) || (!takingModerator && args.length !== 1)) {
			throw new Error(`${command} takes a room${takingModerator ? " and optional moderator" : ""}`);
		}
		const conversation = roomConversation(current, args[0], command);
		if (!takingModerator && conversation.link != null && !allowExisting) {
			throw new Error("ensureRoomLink names a room that already has a durable link");
		}
		const stewardLink = takingModerator
			? args[1] == null ? conversation.steward : roomModeratorSturdyref(args[1], command)
			: undefined;
		return {
			kind: takingModerator ? "room-steward" : "room-link",
			intent: JSON.stringify({ conversation, ...(stewardLink == null ? {} : { stewardLink }) }),
			directory: conversation.directory,
			conversationId: conversation.id,
			stewardLink,
		};
	}
	if (command !== "openPrivateRoom") throw new Error(`Rooms session has no result-bearing command ${command}`);
	if (args.length !== 2 || !isPrivateRoomKey(args[1])) {
		throw new Error("openPrivateRoom takes one room record and an opaque recovery key");
	}
	const conversation = jsonValue(args[0], command, PrivateRoomConversationSchema);
	const existing = current.conversations.find((entry) => entry.id === conversation.id);
	let planned = conversation;
	if (existing != null) {
		if (!allowExisting || existing.kind !== "room" || existing.link == null) {
			throw new Error("openPrivateRoom names a different conversation in this session");
		}
		if (
			existing.directory !== conversation.directory || existing.name !== conversation.name ||
			existing.held !== true
		) {
			throw new Error("openPrivateRoom changed its room record");
		}
	} else {
		const candidate = validated({ ...current, conversations: [...current.conversations, conversation] });
		const accepted = candidate.conversations.at(-1);
		if (accepted?.kind !== "room") throw new Error("openPrivateRoom did not produce a room record");
		planned = accepted;
	}
	const directory = current.directories.find((entry) => entry.id === planned.directory);
	if (directory == null || directory.nick === "") {
		throw new Error("openPrivateRoom needs a named directory in this session");
	}
	const intent = JSON.stringify({ conversation: planned, recoveryKey: args[1] });
	return {
		kind: "private-room",
		intent,
		directory: planned.directory,
		label: planned.name,
		recoveryKey: args[1],
	};
}

export function applyRoomsSessionResult(
	current: RoomsSessionState,
	kind: string,
	intentText: string,
	result: string,
): RoomsSessionState {
	if (kind === "room-link" || kind === "room-steward") {
		const intent = roomAuthorityIntent(intentText);
		let roomLink: string;
		let stewardLink: string | null;
		if (kind === "room-steward") {
			const authority = jsonValue(result, "room authority result", RoomStewardResultSchema);
			roomLink = authority.roomLink;
			stewardLink = authority.stewardLink;
		} else {
			roomLink = jsonValue(result, "room authority result", RoomLinkResultSchema).roomLink;
			stewardLink = null;
		}
		const existing = current.conversations.find((entry) => entry.id === intent.conversation.id);
		if (existing?.kind !== "room") throw new Error("room authority result names no current room");
		if (
			existing.directory !== intent.conversation.directory || existing.name !== intent.conversation.name ||
			existing.held !== intent.conversation.held || existing.publicationId !== intent.conversation.publicationId
		) throw new Error("room authority result conflicts with the current checkpoint");
		if (existing.link != null && existing.link !== roomLink) {
			throw new Error("room authority result changed the room link");
		}
		if (kind === "room-steward" && existing.steward != null && existing.steward !== stewardLink) {
			throw new Error("room authority result changed the moderator capability");
		}
		if (kind === "room-steward" && intent.stewardLink != null && intent.stewardLink !== stewardLink) {
			throw new Error("room authority result did not retain the requested moderator capability");
		}
		const updated = {
			...existing,
			link: roomLink,
			...(kind === "room-steward" && stewardLink != null ? { steward: stewardLink } : {}),
		};
		return validated({
			...current,
			conversations: current.conversations.map((entry) => entry.id === existing.id ? updated : entry),
		});
	}
	if (kind !== "private-room") throw new Error(`Rooms session cannot apply result kind ${kind}`);
	const privateLink = jsonValue(result, "private-room result", sturdyrefText);
	const saved = privateRoomIntent(intentText).conversation;
	const conversation = {
		kind: "room" as const,
		id: saved.id,
		directory: saved.directory,
		name: saved.name,
		held: true,
		link: privateLink,
		standing: saved.standing,
		draft: saved.draft,
	};
	const id = saved.id;
	const existing = current.conversations.find((entry) => entry.id === id);
	if (existing != null) {
		if (current.active === id && JSON.stringify(existing) === JSON.stringify(conversation)) return current;
		throw new Error("private-room result conflicts with the current checkpoint");
	}
	const directory = current.directories.find((entry) => entry.id === conversation.directory);
	if (directory == null) throw new Error("private-room result names no current directory");
	return applyRoomsSessionCommand(current, "joinRoom", [JSON.stringify({
		locator: directory.locator,
		nick: directory.nick,
		conversation,
	})]);
}

export function resumeRoomsSessionResult(
	current: RoomsSessionState,
	kind: string,
	intentText: string,
): RoomsSessionResultPlan {
	if (kind === "room-link" || kind === "room-steward") {
		const intent = roomAuthorityIntent(intentText);
		const args = kind === "room-steward" && intent.stewardLink != null
			? [intent.conversation.id, intent.stewardLink]
			: [intent.conversation.id];
		return prepareRoomsSessionResult(
			current,
			kind === "room-link" ? "ensureRoomLink" : "takeRoomModerator",
			args,
			true,
		);
	}
	if (kind !== "private-room") throw new Error(`Rooms session cannot resume result kind ${kind}`);
	const intent = privateRoomIntent(intentText);
	return prepareRoomsSessionResult(
		current,
		"openPrivateRoom",
		[JSON.stringify(intent.conversation), intent.recoveryKey],
		true,
	);
}

export function describeRoomsSessionResult(kind: string, intentText: string): string {
	if (kind === "room-link") {
		return `Save a durable link for room "${roomAuthorityIntent(intentText).conversation.name}"`;
	}
	if (kind === "room-steward") {
		return `Take the moderator capability for room "${roomAuthorityIntent(intentText).conversation.name}"`;
	}
	if (kind !== "private-room") return "Recover an external session operation";
	return `Create private room "${privateRoomIntent(intentText).conversation.name}"`;
}

export function applyRoomsSessionCommand(
	current: RoomsSessionState,
	command: string,
	args: string[],
): RoomsSessionState {
	if (command === "setDraft") {
		if (args.length !== 2 || args[1].length > MAX_COMMAND_TEXT) {
			throw new Error("setDraft takes a conversation id and bounded text");
		}
		let found = false;
		const conversations = current.conversations.map((conversation) => {
			if (conversation.id !== args[0]) return conversation;
			found = true;
			return { ...conversation, draft: args[1] };
		});
		if (!found) throw new Error("setDraft names no conversation in this session");
		return validated({ ...current, conversations });
	}
	if (command === "select") {
		if (args.length > 1) throw new Error("select takes zero or one conversation id");
		const selected = args[0] ?? null;
		if (selected != null && !current.conversations.some((conversation) => conversation.id === selected)) {
			throw new Error("select names no conversation in this session");
		}
		return validated({ ...current, active: selected });
	}
	if (command === "acceptInvitation") {
		if (args.length !== 2) throw new Error("acceptInvitation takes an invitation id and conversation id");
		const invitation = current.invitations.find((entry) => entry.id === args[0]);
		if (invitation == null) throw new Error("that room-link invitation is no longer available");
		let directoryAuthority: string;
		try {
			directoryAuthority = roomsPeerAuthority(roomsLocator(invitation.locator));
		} catch (error) {
			throw new Error(
				`that room-link invitation has an invalid directory route: ${
					error instanceof Error ? error.message : error
				}`,
			);
		}
		if (directoryAuthority !== invitation.directory) {
			throw new Error("that room-link invitation's route names a different directory");
		}
		if (invitation.nick === "" || nickRefusal(invitation.nick) != null) {
			throw new Error("that room-link invitation has no acceptable nickname; choose one before accepting it");
		}
		const existingDirectory = current.directories.find((entry) => entry.id === invitation.directory);
		if (existingDirectory != null && existingDirectory.nick !== "" && existingDirectory.nick !== invitation.nick) {
			throw new Error(
				`that room-link invitation requests nickname "${invitation.nick}", but this directory uses "${existingDirectory.nick}"`,
			);
		}
		const existing = current.conversations.find((entry) => entry.id === args[1]);
		if (
			existing != null &&
			(existing.kind !== "room" || existing.directory !== invitation.directory ||
				existing.link !== invitation.link)
		) {
			throw new Error("room-link invitation conflicts with an existing conversation");
		}
		const conversation = existing ?? {
			kind: "room" as const,
			id: args[1],
			directory: invitation.directory,
			name: invitation.label || "private room",
			held: true,
			link: invitation.link,
			standing: null,
			draft: "",
		};
		return validated({
			...current,
			directories: existingDirectory == null
				? [...current.directories, {
					id: invitation.directory,
					locator: invitation.locator,
					home: false,
					nick: invitation.nick,
					standing: null,
				}]
				: current.directories.map((entry) =>
					entry.id === invitation.directory && entry.nick === "" ? { ...entry, nick: invitation.nick } : entry
				),
			conversations: existing == null ? [...current.conversations, conversation] : current.conversations,
			invitations: current.invitations.filter((entry) => entry.id !== invitation.id),
			active: conversation.id,
		});
	}
	if (command === "dismissInvitation") {
		if (args.length !== 1) throw new Error("dismissInvitation takes one invitation id");
		if (!current.invitations.some((entry) => entry.id === args[0])) {
			throw new Error("that room-link invitation is no longer available");
		}
		return validated({ ...current, invitations: current.invitations.filter((entry) => entry.id !== args[0]) });
	}
	if (command === "receiveRoomLinkInvitation") {
		if (args.length !== 1) throw new Error("receiveRoomLinkInvitation takes one invitation record");
		const invitation = jsonValue(args[0], command, WorkspaceInvitationSchema);
		if (current.invitations.some((entry) => entry.id === invitation.id || entry.link === invitation.link)) {
			return current;
		}
		if (current.invitations.length >= MAX_PENDING_INVITES) {
			throw new Error("the room-link invitation list is full");
		}
		return validated({ ...current, invitations: [...current.invitations, invitation] });
	}
	if (command === "setStanding") {
		if (args.length !== 1 || args[0].length > MAX_COMMAND_TEXT) {
			throw new Error("setStanding takes one bounded value");
		}
		return validated({ ...current, standing: args[0] });
	}
	if (command === "joinDirectory") {
		if (args.length !== 1) throw new Error("joinDirectory takes one directory record");
		const directory = jsonValue(args[0], command, WorkspaceDirectorySchema);
		if (current.directories.some((entry) => entry.id === directory.id)) {
			throw new Error("joinDirectory names a directory already in this session");
		}
		if (directory?.home === true && current.directories.some((entry) => entry.home)) {
			throw new Error("joinDirectory cannot replace the home directory implicitly");
		}
		return validated({ ...current, directories: [...current.directories, directory] });
	}
	if (command === "leaveDirectory") {
		if (args.length !== 1 || !current.directories.some((entry) => entry.id === args[0])) {
			throw new Error("leaveDirectory takes one directory in this session");
		}
		const removed = new Set(
			current.conversations.filter((entry) => entry.directory === args[0]).map((entry) => entry.id),
		);
		const peering = current.peering.filter((intent) =>
			intent.destination !== args[0] && !removed.has(intent.source)
		);
		return validated({
			...current,
			directories: current.directories.filter((entry) => entry.id !== args[0]),
			conversations: current.conversations.filter((entry) => entry.directory !== args[0]),
			invitations: current.invitations.filter((entry) => entry.directory !== args[0]),
			active: current.active != null && removed.has(current.active) ? null : current.active,
			capabilities: {
				...current.capabilities,
				operations: current.capabilities.operations.filter((entry) => entry.scope !== args[0]),
			},
			peering,
		});
	}
	if (command === "setDirectoryNick") {
		if (args.length !== 2) throw new Error("setDirectoryNick takes a directory and nickname");
		const why = args[1] === "" ? null : nickRefusal(args[1]);
		if (why != null) throw new Error(why);
		let found = false;
		const directories = current.directories.map((entry) => {
			if (entry.id !== args[0]) return entry;
			found = true;
			return { ...entry, nick: args[1] };
		});
		if (!found) throw new Error("setDirectoryNick names no directory in this session");
		return validated({ ...current, directories });
	}
	if (command === "joinRoom") {
		return applyRoomJoin(current, args);
	}
	if (command === "startDirect" || command === "openDirect") {
		if (args.length !== 1) throw new Error(`${command} takes one conversation record`);
		const conversation = jsonValue(args[0], command, WorkspaceDirectConversationSchema);
		if (current.conversations.some((entry) => entry.id === conversation.id)) {
			throw new Error(`${command} names a conversation already in this session`);
		}
		const directory = current.directories.find((entry) => entry.id === conversation.directory);
		if (directory == null) throw new Error(`${command} names no directory in this session`);
		return validated({
			...current,
			conversations: [...current.conversations, conversation],
			active: command === "startDirect" ? current.active : conversation.id,
		});
	}
	if (command === "publishPeeredRoom") {
		if (args.length !== 1) throw new Error("publishPeeredRoom takes one publication intent");
		const intent = jsonValue(args[0], command, WorkspacePeeringIntentSchema);
		if (
			!current.capabilities.operations.some((entry) =>
				entry.capability === "peering" && entry.scope === intent.destination
			)
		) {
			throw new Error("publishPeeredRoom needs a peering capability for its destination");
		}
		if (current.peering.some((entry) => entry.id === intent.id)) {
			const existing = current.peering.find((entry) => entry.id === intent.id);
			if (JSON.stringify(existing) !== JSON.stringify(intent)) {
				throw new Error("publishPeeredRoom reuses an id for different intent");
			}
			return current;
		}
		return validated({ ...current, peering: [...current.peering, intent] });
	}
	if (command === "revokePeeredRoom") {
		if (args.length !== 1) throw new Error("revokePeeredRoom takes one publication id");
		if (!current.peering.some((entry) => entry.id === args[0])) {
			throw new Error("revokePeeredRoom names no publication in this session");
		}
		return validated({ ...current, peering: current.peering.filter((entry) => entry.id !== args[0]) });
	}
	if (command === "leaveConversation") {
		if (args.length !== 1 || !current.conversations.some((entry) => entry.id === args[0])) {
			throw new Error("leaveConversation takes one conversation in this session");
		}
		return validated({
			...current,
			conversations: current.conversations.filter((entry) => entry.id !== args[0]),
			active: current.active === args[0] ? null : current.active,
			peering: current.peering.filter((intent) => intent.source !== args[0]),
		});
	}
	if (command === "closeDirect") {
		if (args.length !== 1) throw new Error("closeDirect takes one direct conversation");
		let found = false;
		const conversations = current.conversations.map((entry) => {
			if (entry.id !== args[0] || entry.kind !== "direct") return entry;
			found = true;
			return { ...entry, closed: true };
		});
		if (!found) throw new Error("closeDirect names no direct conversation in this session");
		return validated({ ...current, conversations });
	}
	if (command === "setDirectoryStanding") {
		if (args.length < 1 || args.length > 2) {
			throw new Error("setDirectoryStanding takes a directory and optional value");
		}
		let found = false;
		const directories = current.directories.map((entry) => {
			if (entry.id !== args[0]) return entry;
			found = true;
			return { ...entry, standing: args[1] ?? null };
		});
		if (!found) throw new Error("setDirectoryStanding names no directory in this session");
		return validated({ ...current, directories });
	}
	if (command === "setRoomStanding") {
		if (args.length < 1 || args.length > 2) throw new Error("setRoomStanding takes a room and optional value");
		let found = false;
		const conversations = current.conversations.map((entry) => {
			if (entry.id !== args[0] || entry.kind !== "room") return entry;
			found = true;
			return { ...entry, standing: args[1] ?? null };
		});
		if (!found) throw new Error("setRoomStanding names no room in this session");
		return validated({ ...current, conversations });
	}
	if (command === "connectRoomIrc") {
		if (args.length !== 4) throw new Error("connectRoomIrc takes a room, IRC nick, account, and password");
		const room = roomConversation(current, args[0], command);
		validateIrcNick(args[1]);
		if (args[2] !== "") validateSaslPlain({ account: args[2], password: args[3] });
		const identity = z.safeParse(WorkspaceRoomIrcIdentitySchema, {
			nick: args[1],
			account: args[2],
			password: args[3],
		});
		if (!identity.success) throw new Error("connectRoomIrc received invalid IRC identity data");
		return validated({
			...current,
			conversations: current.conversations.map((entry) =>
				entry.id === room.id ? { ...entry, irc: identity.data } : entry
			),
		});
	}
	if (command === "disconnectRoomIrc") {
		if (args.length !== 1) throw new Error("disconnectRoomIrc takes one room");
		const room = roomConversation(current, args[0], command);
		return validated({
			...current,
			conversations: current.conversations.map((entry) => entry.id === room.id ? { ...entry, irc: null } : entry),
		});
	}
	if (command === "setIgnoredNames") {
		if (args.length !== 1) throw new Error("setIgnoredNames takes one name list");
		return validated({ ...current, ignored: jsonValue(args[0], command, RoomsIgnoredNamesSchema) });
	}
	if (command === "chooseHistoryRetention") {
		if (args.length !== 1 || (args[0] !== "true" && args[0] !== "false")) {
			throw new Error("chooseHistoryRetention takes true or false");
		}
		return validated({ ...current, keepHistory: args[0] === "true" });
	}
	if (command === "chooseConnection") {
		if (args.length !== 2 || (args[0] !== "webrtc" && args[0] !== "relay")) {
			throw new Error("chooseConnection takes a direct-message mode and visualizer override");
		}
		const vizRefusal = vizOverrideRefusal(args[1]);
		if (vizRefusal != null) throw new Error(vizRefusal);
		return validated({ ...current, dmMode: args[0], vizOverride: args[1] });
	}
	if (command === "replaceOperationsCapabilities") {
		if (args.length !== 1) throw new Error("replaceOperationsCapabilities takes one credential list");
		const operations = jsonValue(args[0], command, WorkspaceOperationCredentialsSchema);
		return validated({
			...current,
			peering: peeringIntentsForOperations(operations, current.peering),
			capabilities: {
				...current.capabilities,
				operations,
			},
		});
	}
	if (command === "selectArchive") {
		if (args.length > 1) throw new Error("selectArchive takes zero or one sturdyref");
		return validated({
			...current,
			capabilities: { ...current.capabilities, archivePeer: args[0] ?? null },
		});
	}
	throw new Error(`Rooms session has no command ${command}`);
}
