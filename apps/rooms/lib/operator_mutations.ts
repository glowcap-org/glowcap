import type { Ref, Session } from "@pancake/runtime";
import { ask } from "./ask.ts";
import type { OperatorResetScope } from "./operator_vocabulary.ts";
import type { RoomAuthorityKind } from "./room/authority.ts";
import {
	CLEAR_OPERATOR_TROUBLE,
	DISCONNECT_SESSION,
	RELEASE_OPERATOR_REFERENCE,
	REMOVE_OPERATOR_ROOM,
	RESET_OPERATOR_SCOPE,
	REVOKE_NICK,
	REVOKE_ROOM_AUTHORITY,
	REVOKE_ROOM_LINK,
} from "./protocol_operator.ts";

export async function revokeRoomLink(session: Session, cap: Ref, name: string): Promise<void> {
	await ask(session, cap, REVOKE_ROOM_LINK, [name], "the Rooms operator did not revoke the room link");
}

export async function revokeRoomAuthority(
	session: Session,
	cap: Ref,
	kind: RoomAuthorityKind,
	token: string,
): Promise<void> {
	await ask(
		session,
		cap,
		REVOKE_ROOM_AUTHORITY,
		[kind, token],
		"the Rooms operator did not revoke the current room authority",
	);
}

export async function revokeNick(session: Session, cap: Ref, nick: string, sessionId: string): Promise<void> {
	await ask(session, cap, REVOKE_NICK, [nick, sessionId], "the Rooms operator did not revoke the nickname");
}

export async function disconnectSession(session: Session, cap: Ref, id: string): Promise<void> {
	await ask(session, cap, DISCONNECT_SESSION, [id], "the Rooms operator did not disconnect the session");
}

export async function removeOperatorRoom(session: Session, cap: Ref, id: string): Promise<void> {
	await ask(session, cap, REMOVE_OPERATOR_ROOM, [id], "the Rooms operator did not remove the room");
}

export async function releaseOperatorReference(session: Session, cap: Ref, id: string): Promise<void> {
	await ask(session, cap, RELEASE_OPERATOR_REFERENCE, [id], "the Rooms operator did not release the reference");
}

export async function clearOperatorTrouble(session: Session, cap: Ref): Promise<void> {
	await ask(session, cap, CLEAR_OPERATOR_TROUBLE, [], "the Rooms operator did not clear trouble");
}

export async function resetOperatorScope(session: Session, cap: Ref, scope: OperatorResetScope): Promise<void> {
	await ask(session, cap, RESET_OPERATOR_SCOPE, [scope], "the Rooms operator did not reset the scope");
}
