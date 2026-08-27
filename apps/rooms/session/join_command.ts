// One atomic public or held room-join checkpoint transition.

import { RoomsRoomJoinIntentSchema, type RoomsSessionState } from "../lib/rooms_state.ts";
import { nickRefusal } from "../lib/limits.ts";
import { roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { commandJson, validatedRoomsSessionState } from "./command_data.ts";

export function applyRoomJoin(current: RoomsSessionState, args: string[]): RoomsSessionState {
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
	const existing = current.conversations.find((entry) => {
		if (entry.kind !== "room" || entry.directory !== authority) return false;
		if (!entry.held && !intent.conversation.held) {
			return entry.name.toLowerCase() === intent.conversation.name.toLowerCase();
		}
		return entry.held && intent.conversation.held && entry.link != null &&
			entry.link === intent.conversation.link;
	});
	if (
		current.conversations.some((entry) => entry.id === intent.conversation.id) &&
		existing?.id !== intent.conversation.id
	) {
		throw new Error("joinRoom reuses a conversation id for a different room");
	}
	const selected = existing?.kind === "room" ? existing : intent.conversation;
	return validatedRoomsSessionState({
		...current,
		directories: priorDirectory == null
			? [...current.directories, directory]
			: current.directories.map((entry) => entry.id === authority ? directory : entry),
		conversations: existing == null ? [...current.conversations, selected] : current.conversations,
		active: selected.id,
		join: selected.held ? current.join : {
			room: selected.name,
			locator: directory.home ? "" : directory.locator,
			nick: directory.nick,
		},
	});
}
