// Result-bearing capability plans for a durable Rooms session.

import * as z from "zod/mini";
import { type RoomsSessionState, WorkspaceRoomConversationSchema } from "../lib/rooms_state.ts";
import { isManagedRoomId } from "../lib/limits.ts";
import { commandJson as jsonValue, roomConversation, validatedRoomsSessionState as validated } from "./command_data.ts";
import { applyRoomJoin } from "./join_command.ts";
import { parseRoomsSturdyref } from "../lib/locator.ts";
import {
	isRoomEntry,
	isRoomPolicy,
	isRoomSpeaking,
	isRoomVisibility,
	type RoomPolicy,
	RoomPolicySchema,
} from "../lib/room/policy.ts";

const MAX_BEARER_TEXT = 16 * 1024;

const sturdyrefText = z.string().check(
	z.minLength(1),
	z.maxLength(MAX_BEARER_TEXT),
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

export interface RoomsSessionResultPlan {
	readonly kind: "managed-room" | "room-link" | "room-manager" | "room-steward";
	readonly intent: string;
	readonly directory?: string;
	readonly label?: string;
	readonly recoveryKey?: string;
	readonly policy?: RoomPolicy;
	readonly conversationId?: string;
	readonly stewardLink?: string | null;
	readonly managerLink?: string;
}

interface ManagedRoomIntent {
	conversation: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>;
	recoveryKey: string;
	policy: RoomPolicy;
}

const ManagedRoomConversationSchema = WorkspaceRoomConversationSchema.check(
	z.refine((conversation) =>
		conversation.link == null && conversation.steward == null &&
		conversation.publicationId == null
	),
);
const ManagedRoomIntentSchema = z.strictObject({
	conversation: ManagedRoomConversationSchema,
	recoveryKey: z.string().check(z.refine(isManagedRoomId)),
	policy: RoomPolicySchema,
});

const RoomAuthorityIntentSchema = z.strictObject({
	conversation: WorkspaceRoomConversationSchema,
	stewardLink: z.optional(sturdyrefText),
	managerLink: z.optional(sturdyrefText),
});
const RoomLinkResultSchema = z.strictObject({ roomLink: sturdyrefText });
const RoomStewardResultSchema = z.strictObject({ roomLink: sturdyrefText, stewardLink: sturdyrefText });
const RoomManagerResultSchema = z.strictObject({ roomLink: sturdyrefText, managerLink: sturdyrefText });

function managedRoomIntent(intentText: string): ManagedRoomIntent {
	return jsonValue(intentText, "managed-room result", ManagedRoomIntentSchema);
}

type RoomAuthorityIntent = z.infer<typeof RoomAuthorityIntentSchema>;

function roomAuthorityIntent(intentText: string): RoomAuthorityIntent {
	return jsonValue(intentText, "room authority result", RoomAuthorityIntentSchema);
}

function roomCapabilitySturdyref(raw: string, command: string, kind: "manager" | "moderator"): string {
	const parsed = z.safeParse(sturdyrefText, raw);
	if (!parsed.success) throw new Error(`${command} needs a valid room ${kind} capability`);
	return parsed.data;
}

export function prepareRoomsSessionResult(
	current: RoomsSessionState,
	command: string,
	args: string[],
	allowExisting = false,
): RoomsSessionResultPlan {
	if (
		command === "ensureRoomLink" || command === "linkRoom" || command === "takeRoomModerator" ||
		command === "takeRoomManager" || command === "recoverRoomManager"
	) {
		const takingModerator = command === "takeRoomModerator";
		const takingManager = command === "takeRoomManager";
		const recoveringManager = command === "recoverRoomManager";
		if (
			(takingModerator && (args.length < 1 || args.length > 2)) || (takingManager && args.length !== 2) ||
			(!takingModerator && !takingManager && args.length !== 1)
		) {
			throw new Error(`${command} takes a room${takingModerator ? " and optional moderator" : ""}`);
		}
		const conversation = roomConversation(current, args[0], command);
		if (!takingModerator && !takingManager && !recoveringManager && conversation.link != null && !allowExisting) {
			throw new Error("ensureRoomLink names a room that already has a durable link");
		}
		const stewardLink = takingModerator
			? args[1] == null ? conversation.steward : roomCapabilitySturdyref(args[1], command, "moderator")
			: undefined;
		const managerLink = takingManager ? roomCapabilitySturdyref(args[1], command, "manager") : undefined;
		return {
			kind: takingModerator ? "room-steward" : takingManager || recoveringManager ? "room-manager" : "room-link",
			intent: JSON.stringify({
				conversation,
				...(stewardLink == null ? {} : { stewardLink }),
				...(managerLink == null ? {} : { managerLink }),
			}),
			directory: conversation.directory,
			conversationId: conversation.id,
			stewardLink,
			managerLink,
		};
	}
	if (command !== "openManagedRoom") throw new Error(`Rooms session has no result-bearing command ${command}`);
	if (
		args.length !== 5 || !isManagedRoomId(args[1]) || !isRoomVisibility(args[2]) ||
		!isRoomEntry(args[3]) || !isRoomSpeaking(args[4])
	) {
		throw new Error("openManagedRoom takes one room record, opaque room id, and three policy modes");
	}
	const candidate = { visibility: args[2], entry: args[3], speaking: args[4] };
	if (!isRoomPolicy(candidate)) throw new Error("openManagedRoom names no supported room access state");
	const policy: RoomPolicy = candidate;
	const conversation = jsonValue(args[0], command, ManagedRoomConversationSchema);
	if (conversation.held !== (policy.visibility === "secret")) {
		throw new Error("openManagedRoom room custody disagrees with its visibility");
	}
	const existing = current.conversations.find((entry) => entry.id === conversation.id);
	let planned = conversation;
	if (existing != null) {
		if (!allowExisting || existing.kind !== "room" || existing.link == null) {
			throw new Error("openManagedRoom names a different conversation in this session");
		}
		if (
			existing.directory !== conversation.directory || existing.name !== conversation.name ||
			existing.held !== (policy.visibility === "secret")
		) {
			throw new Error("openManagedRoom changed its room record");
		}
	} else {
		const candidate = validated({ ...current, conversations: [...current.conversations, conversation] });
		const accepted = candidate.conversations.at(-1);
		if (accepted?.kind !== "room") throw new Error("openManagedRoom did not produce a room record");
		planned = accepted;
	}
	const directory = current.directories.find((entry) => entry.id === planned.directory);
	if (directory == null || directory.nick === "") {
		throw new Error("openManagedRoom needs a named directory in this session");
	}
	const intent = JSON.stringify({ conversation: planned, recoveryKey: args[1], policy });
	return {
		kind: "managed-room",
		intent,
		directory: planned.directory,
		label: planned.name,
		recoveryKey: args[1],
		policy,
	};
}

export function applyRoomsSessionResult(
	current: RoomsSessionState,
	kind: string,
	intentText: string,
	result: string,
): RoomsSessionState {
	if (kind === "room-link" || kind === "room-manager" || kind === "room-steward") {
		const intent = roomAuthorityIntent(intentText);
		let roomLink: string;
		let stewardLink: string | null;
		let managerLink: string | null = null;
		if (kind === "room-steward") {
			const authority = jsonValue(result, "room authority result", RoomStewardResultSchema);
			roomLink = authority.roomLink;
			stewardLink = authority.stewardLink;
		} else if (kind === "room-manager") {
			const authority = jsonValue(result, "room manager result", RoomManagerResultSchema);
			roomLink = authority.roomLink;
			managerLink = authority.managerLink;
			stewardLink = null;
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
		if (kind === "room-manager" && existing.manager != null && existing.manager !== managerLink) {
			throw new Error("room manager result changed the manager capability");
		}
		if (kind === "room-steward" && existing.steward != null && existing.steward !== stewardLink) {
			throw new Error("room authority result changed the moderator capability");
		}
		if (kind === "room-steward" && intent.stewardLink != null && intent.stewardLink !== stewardLink) {
			throw new Error("room authority result did not retain the requested moderator capability");
		}
		const { reconnect: _reconnect, ...reconnected } = existing;
		const updated = {
			...reconnected,
			link: roomLink,
			...(kind === "room-manager" && managerLink != null ? { manager: managerLink } : {}),
			...(kind === "room-steward" && stewardLink != null ? { steward: stewardLink } : {}),
		};
		return validated({
			...current,
			conversations: current.conversations.map((entry) => entry.id === existing.id ? updated : entry),
		});
	}
	if (kind !== "managed-room") throw new Error(`Rooms session cannot apply result kind ${kind}`);
	const privateAuthority = jsonValue(result, "managed-room result", RoomManagerResultSchema);
	const saved = managedRoomIntent(intentText).conversation;
	const conversation = {
		kind: "room" as const,
		id: saved.id,
		directory: saved.directory,
		name: saved.name,
		held: saved.held,
		link: privateAuthority.roomLink,
		manager: privateAuthority.managerLink,
		standing: saved.standing,
		draft: saved.draft,
	};
	const id = saved.id;
	const existing = current.conversations.find((entry) => entry.id === id);
	if (existing != null) {
		if (current.active === id && JSON.stringify(existing) === JSON.stringify(conversation)) return current;
		throw new Error("managed-room result conflicts with the current checkpoint");
	}
	const directory = current.directories.find((entry) => entry.id === conversation.directory);
	if (directory == null) throw new Error("managed-room result names no current directory");
	return applyRoomJoin(current, [JSON.stringify({
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
	if (kind === "room-link" || kind === "room-manager" || kind === "room-steward") {
		const intent = roomAuthorityIntent(intentText);
		const args = kind === "room-manager" && intent.managerLink != null
			? [intent.conversation.id, intent.managerLink]
			: kind === "room-steward" && intent.stewardLink != null
			? [intent.conversation.id, intent.stewardLink]
			: [intent.conversation.id];
		return prepareRoomsSessionResult(
			current,
			kind === "room-link"
				? "ensureRoomLink"
				: kind === "room-manager"
				? intent.managerLink == null ? "recoverRoomManager" : "takeRoomManager"
				: "takeRoomModerator",
			args,
			true,
		);
	}
	if (kind !== "managed-room") throw new Error(`Rooms session cannot resume result kind ${kind}`);
	const intent = managedRoomIntent(intentText);
	return prepareRoomsSessionResult(
		current,
		"openManagedRoom",
		[
			JSON.stringify(intent.conversation),
			intent.recoveryKey,
			intent.policy.visibility,
			intent.policy.entry,
			intent.policy.speaking,
		],
		true,
	);
}

/** The one wording for an effect whose intent this module cannot describe:
 * an unknown kind, or a recorded effect that kept no intent text. */
export const EXTERNAL_SESSION_OPERATION = "Recover an external session operation";

export function describeRoomsSessionResult(kind: string, intentText: string): string {
	if (kind === "room-link") {
		return `Save a durable link for room "${roomAuthorityIntent(intentText).conversation.name}"`;
	}
	if (kind === "room-steward") {
		return `Take the moderator capability for room "${roomAuthorityIntent(intentText).conversation.name}"`;
	}
	if (kind === "room-manager") {
		const intent = roomAuthorityIntent(intentText);
		return `${
			intent.managerLink == null ? "Recover" : "Take"
		} the manager capability for room "${intent.conversation.name}"`;
	}
	if (kind !== "managed-room") return EXTERNAL_SESSION_OPERATION;
	return `Create managed room "${managedRoomIntent(intentText).conversation.name}"`;
}
