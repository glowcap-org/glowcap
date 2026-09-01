// One atomic public or held room-join checkpoint transition.

import { RoomsRoomJoinIntentSchema, type RoomsSessionState } from "../lib/rooms_state.ts";
import { nickRefusal } from "../lib/limits.ts";
import { parseRoomsSturdyref, roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { commandJson, validatedRoomsSessionState } from "./command_data.ts";

export function applyRoomJoin(
	current: RoomsSessionState,
	args: string[],
	publicationIdFor?: (directoryId: string, roomName: string) => string | null,
): RoomsSessionState {
	if (args.length !== 1) throw new Error("joinRoom takes one room-join intent");
	const intent = commandJson(
		args[0],
		"joinRoom",
		RoomsRoomJoinIntentSchema,
		"joinRoom requires the current locator, nick, and conversation intent; the Rooms client and session may be from different builds",
	);
	const why = intent.nick === "" ? "Choose a nickname before joining a room." : nickRefusal(intent.nick);
	if (why != null) throw new Error(why);
	let authority: string;
	try {
		authority = roomsPeerAuthority(roomsLocator(intent.locator));
	} catch (error) {
		throw new Error(
			`joinRoom received an invalid directory route: ${error instanceof Error ? error.message : error}`,
		);
	}
	if (authority !== intent.conversation.directory) {
		throw new Error("joinRoom's route names a different directory");
	}
	const priorDirectory = current.directories.find((entry) => entry.id === authority);
	const directory = priorDirectory == null
		? {
			id: authority,
			locator: intent.locator,
			home: current.directories.length === 0,
			nick: intent.nick,
			standing: null,
		}
		: { ...priorDirectory, locator: intent.locator, nick: intent.nick };
	const byId = current.conversations.find((entry) => entry.id === intent.conversation.id);
	const recovering = byId?.kind === "room" && byId.reconnect === "manual" ? byId : null;
	const resolvedPublication = intent.conversation.held
		? null
		: publicationIdFor?.(authority, intent.conversation.name) ?? null;
	if (recovering?.publicationId != null && resolvedPublication == null) {
		throw new Error("this room's source has no current publication by that name");
	}
	if (
		recovering?.publicationId == null &&
		resolvedPublication != null && intent.conversation.publicationId != null &&
		resolvedPublication !== intent.conversation.publicationId
	) throw new Error("joinRoom's publication identity is not current");
	const conversation = recovering?.publicationId != null
		? { ...intent.conversation, publicationId: resolvedPublication! }
		: resolvedPublication == null || intent.conversation.publicationId != null
		? intent.conversation
		: { ...intent.conversation, publicationId: resolvedPublication };
	if (recovering != null) {
		if (
			recovering.directory !== conversation.directory || recovering.name !== conversation.name ||
			recovering.held !== conversation.held
		) throw new Error("joinRoom changed the room being recovered");
		if (recovering.held) {
			if (conversation.link == null) throw new Error("this private room needs a current room link");
			if (roomsPeerAuthority(parseRoomsSturdyref(conversation.link).locator) !== authority) {
				throw new Error("the current room link names a different directory");
			}
		}
	}
	const existing = recovering ?? current.conversations.find((entry) => {
		if (entry.kind !== "room" || entry.directory !== authority) return false;
		if (!entry.held && !conversation.held) {
			return entry.name.toLowerCase() === conversation.name.toLowerCase();
		}
		return entry.held && conversation.held && entry.link != null &&
			entry.link === conversation.link;
	});
	if (
		current.conversations.some((entry) => entry.id === conversation.id) &&
		existing?.id !== conversation.id
	) {
		throw new Error("joinRoom reuses a conversation id for a different room");
	}
	const selected = existing?.kind === "room" ? existing : conversation;
	const rejoined = recovering == null ? selected : {
		...recovering,
		...(recovering.held
			? conversation.link == null ? {} : { link: conversation.link }
			: { publicationId: conversation.publicationId }),
		reconnect: "requested" as const,
	};
	return validatedRoomsSessionState({
		...current,
		directories: priorDirectory == null
			? [...current.directories, directory]
			: current.directories.map((entry) => entry.id === authority ? directory : entry),
		conversations: existing == null
			? [...current.conversations, rejoined]
			: current.conversations.map((entry) => entry.id === rejoined.id ? rejoined : entry),
		active: rejoined.id,
		join: rejoined.held ? current.join : {
			room: rejoined.name,
			locator: directory.home ? "" : directory.locator,
			nick: directory.nick,
		},
	});
}
