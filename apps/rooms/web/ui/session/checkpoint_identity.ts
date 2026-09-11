// Equality at the durable-checkpoint boundary. These comparisons deliberately
// name which fields change topology or capability custody; presentation state
// is reconciled elsewhere and must not make a checkpoint look like a new
// identity merely because its outcome arrived.
import type {
	RoomsSessionState,
	WorkspaceConversation,
	WorkspaceOperationCredential,
} from "../../../lib/rooms_state.ts";
import { dirId, type SessionConv } from "../types.ts";

export function sameOperations(
	left: readonly WorkspaceOperationCredential[],
	right: readonly WorkspaceOperationCredential[],
): boolean {
	return left.length === right.length && left.every((operation, index) => {
		const other = right[index];
		return other != null && operation.capability === other.capability && operation.scope === other.scope &&
			operation.swiss === other.swiss;
	});
}

function sameConversationTopology(left: WorkspaceConversation, right: WorkspaceConversation): boolean {
	if (left.kind !== right.kind || left.id !== right.id || left.directory !== right.directory) return false;
	if (left.kind === "direct" && right.kind === "direct") {
		return left.peer === right.peer && left.peerRegistrationId === right.peerRegistrationId;
	}
	if (left.kind !== "room" || right.kind !== "room") return false;
	return left.name === right.name && left.held === right.held &&
		(left.reconnect ?? null) === (right.reconnect ?? null) &&
		(left.publicationId ?? null) === (right.publicationId ?? null);
}

export function sameTopology(left: RoomsSessionState, right: RoomsSessionState): boolean {
	return left.directories.length === right.directories.length &&
		left.directories.every((directory, index) => {
			const other = right.directories[index];
			return other != null && directory.id === other.id && directory.locator === other.locator &&
				directory.home === other.home && directory.nick === other.nick;
		}) &&
		left.conversations.length === right.conversations.length &&
		left.conversations.every((conversation, index) => {
			const other = right.conversations[index];
			return other != null && sameConversationTopology(conversation, other);
		});
}

export function sameConversationIdentity(existing: SessionConv, intended: WorkspaceConversation): boolean {
	if (existing.persistId !== intended.id || existing.dir !== dirId(intended.directory)) return false;
	if (intended.kind === "direct") {
		return existing.type === "dm" && existing.id === intended.peer &&
			existing.peerRegistrationId === intended.peerRegistrationId;
	}
	return existing.type === "room" && existing.id === intended.name && existing.held === intended.held &&
		(existing.publicationId ?? null) === (intended.publicationId ?? null);
}
