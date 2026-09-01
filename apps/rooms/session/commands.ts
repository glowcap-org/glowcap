// Pure checkpoint commands for a durable Rooms session.

import * as z from "zod/mini";
import { type BridgeAnswers, readBridgeAnswers } from "../lib/bridge/form.ts";
import {
	RoomsIgnoredNamesSchema,
	type RoomsSessionState,
	WorkspaceDirectConversationSchema,
	WorkspaceDirectorySchema,
	WorkspaceInvitationSchema,
	type WorkspaceRoomBridgeIntent,
	WorkspaceRoomBridgeIntentSchema,
} from "../lib/rooms_state.ts";
import { vizOverrideRefusal } from "../lib/viz_publish.ts";
import { MAX_PENDING_INVITES, nickRefusal } from "../lib/limits.ts";
import { roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { roomAuthorityToken } from "../lib/room/authority.ts";
import { commandJson as jsonValue, roomConversation, validatedRoomsSessionState as validated } from "./command_data.ts";
import { applyRoomJoin } from "./join_command.ts";
import { applyPeeringCommand } from "./peering_commands.ts";

const MAX_COMMAND_TEXT = 64 * 1024;
export type RoomsCheckpointImpact = "presentation" | "standing" | "realization";
export interface RoomsSessionCommandFacts {
	roomPublicationId?(directoryId: string, roomName: string): string | null;
	/** How far one bridge answer reaches in this room, as the room stated it.
	 *
	 * A live fact rather than a checkpoint one, so it is asked for here instead
	 * of read off the conversation: a channel nobody has linked on yet has no
	 * saved intent naming its scope, and is exactly the room a spreading answer
	 * needs to reach. Absent when no live view has heard from the room, and the
	 * saved intent's scope is the fallback then. */
	roomBridgeScope?(conversationId: string): string | null;
}

/** One bridge form submission, as a durable command carries it.
 *
 * The answers and the secrets arrive apart because the client drew the form and
 * so knows which is which. The alternative was for this to fetch the form and
 * work it out, which would mean a checkpoint's contents depending on what a
 * bridge happened to answer at the time — and a bridge that changed its mind
 * about a field could turn a stored answer into a stored password.
 *
 * Nothing here judges whether the answers are any good. A form says what a
 * field is called; what makes it valid belongs to the service, and the bridge
 * checks it when this is replayed to it. */
export function parseRoomBridgeFormCommand(args: string[]): {
	conversationId: string;
	intent: WorkspaceRoomBridgeIntent;
	secrets: BridgeAnswers;
} {
	if (args.length !== 5) {
		throw new Error("submitRoomBridgeForm takes a room, scope, action, answers, and secrets");
	}
	const secrets = readBridgeAnswers(args[4]);
	const intent = z.safeParse(WorkspaceRoomBridgeIntentSchema, {
		scope: args[1],
		action: args[2],
		answers: readBridgeAnswers(args[3]),
		secretsGiven: Object.keys(secrets).length > 0,
	});
	if (!intent.success) throw new Error("submitRoomBridgeForm received an invalid submission");
	return { conversationId: args[0], intent: intent.data, secrets };
}

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

export function prepareRoomOffer(
	current: RoomsSessionState,
	args: string[],
): { roomConversationId: string; directConversationId: string; label: string; link: string | null } {
	if (args.length !== 2) throw new Error("offerRoom takes a room and direct conversation id");
	const room = current.conversations.find((entry) => entry.id === args[0]);
	const direct = current.conversations.find((entry) => entry.id === args[1]);
	if (room?.kind !== "room") {
		throw new Error("offerRoom needs a room in this session");
	}
	if (direct?.kind !== "direct" || direct.closed || direct.directory !== room.directory) {
		throw new Error("offerRoom needs an open direct conversation on the room's directory");
	}
	return { roomConversationId: room.id, directConversationId: direct.id, label: room.name, link: room.link ?? null };
}

export function applyRoomsSessionCommand(
	current: RoomsSessionState,
	command: string,
	args: string[],
	facts: RoomsSessionCommandFacts = {},
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
		return applyRoomJoin(current, args, facts.roomPublicationId);
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
	if (
		command === "publishPeeredRoom" || command === "revokePeeredRoom" ||
		command === "replaceOperationsCapabilities"
	) {
		return applyPeeringCommand(current, command, args);
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
	if (command === "dropRoomModerator") {
		if (args.length !== 2 || args[1] === "") {
			throw new Error("dropRoomModerator takes one room and moderator generation");
		}
		let found = false;
		const conversations = current.conversations.map((entry) => {
			if (entry.id !== args[0] || entry.kind !== "room") return entry;
			found = true;
			if (entry.steward == null || roomAuthorityToken(entry.steward) !== args[1]) {
				throw new Error("that room's retained moderator capability changed");
			}
			const { steward: _steward, ...withoutSteward } = entry;
			return withoutSteward;
		});
		if (!found) throw new Error("dropRoomModerator names no room in this session");
		return validated({ ...current, conversations });
	}
	if (command === "dropRoomManager") {
		if (args.length !== 2 || args[1] === "") {
			throw new Error("dropRoomManager takes one room and manager generation");
		}
		let found = false;
		const conversations = current.conversations.map((entry) => {
			if (entry.id !== args[0] || entry.kind !== "room") return entry;
			found = true;
			if (entry.manager == null || roomAuthorityToken(entry.manager) !== args[1]) {
				throw new Error("that room's retained manager capability changed");
			}
			const { manager: _manager, ...withoutManager } = entry;
			return withoutManager;
		});
		if (!found) throw new Error("dropRoomManager names no room in this session");
		return validated({ ...current, conversations });
	}
	if (command === "submitRoomBridgeForm") {
		const parsed = parseRoomBridgeFormCommand(args);
		const room = roomConversation(current, parsed.conversationId, command);
		// Every room in the same scope, because a scope is the bridge's own word
		// for how far one answer reaches: linking on one IRC channel links on
		// every channel of that network, and this is where that becomes true.
		// The room's stated scope decides, so a channel nobody has linked on yet
		// is reached too; its saved intent is the fallback when no live view has
		// heard from it.
		const inScope = (entry: RoomsSessionState["conversations"][number]): boolean =>
			entry.kind === "room" &&
			((facts.roomBridgeScope?.(entry.id) ?? null) === parsed.intent.scope ||
				entry.bridgeIntent?.scope === parsed.intent.scope);
		return validated({
			...current,
			conversations: current.conversations.map((entry) =>
				entry.id === room.id || inScope(entry) ? { ...entry, bridgeIntent: parsed.intent } : entry
			),
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
	if (command === "selectArchive") {
		if (args.length > 1) throw new Error("selectArchive takes zero or one sturdyref");
		return validated({
			...current,
			capabilities: { ...current.capabilities, archivePeer: args[0] ?? null },
		});
	}
	throw new Error(`Rooms session has no command ${command}`);
}
