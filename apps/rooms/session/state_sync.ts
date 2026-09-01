// Pure reducers for network facts reconciled into one durable Rooms checkpoint.

import type { RoomAuthorityChange } from "../lib/room/authority.ts";
import { roomAuthorityToken } from "../lib/room/authority.ts";
import type { RoomsSessionState } from "../lib/rooms_state.ts";
import type { RoomsCheckpointImpact } from "./commands.ts";

export interface RoomAuthorityRetirement extends RoomAuthorityChange {
	readonly conversationId: string;
}

export interface DirectoryReached {
	readonly type: "directory-reached";
	readonly directoryId: string;
	readonly locator: string;
}

export interface RoomReconnectResult {
	readonly type: "room-reconnect";
	readonly conversationId: string;
	readonly connected: boolean;
}

export interface RoomAuthorityAcquisition {
	readonly type: "room-authority-acquired";
	readonly conversationId: string;
	readonly roomLink: string;
	readonly managerLink: string;
}

export interface RoomPublicationResolution {
	readonly type: "room-publication";
	readonly conversationId: string;
	readonly expectedPublicationId: string | null;
	readonly publicationId: string;
}

export interface DirectConversationAcceptance {
	readonly type: "direct-accepted";
	readonly conversationId: string;
	readonly directoryId: string;
	readonly peer: string;
	readonly peerRegistrationId: string;
}

export type RuntimeStateReconciliation =
	| ({ readonly type: "room-authority" } & RoomAuthorityRetirement)
	| RoomAuthorityAcquisition
	| DirectConversationAcceptance
	| RoomPublicationResolution
	| DirectoryReached
	| RoomReconnectResult;

export function runtimeStateImpact(change: RuntimeStateReconciliation): RoomsCheckpointImpact {
	return change.type === "room-authority" || change.type === "room-authority-acquired" ||
			change.type === "direct-accepted" || change.type === "room-publication"
		? "realization"
		: "presentation";
}

/** Apply one exact network fact to the bounded checkpoint. This is the shared
 * online/offline synchronization seam: live owners push facts here while
 * connected, and reconnect validation submits the same facts lazily. */
export function reconcileRuntimeState(
	checkpoint: RoomsSessionState,
	change: RuntimeStateReconciliation,
): RoomsSessionState | null {
	if (change.type === "room-authority") return reconcileRoomAuthority(checkpoint, change);
	if (change.type === "direct-accepted") return reconcileDirectAcceptance(checkpoint, change);
	if (change.type === "room-authority-acquired") {
		const conversation = checkpoint.conversations.find((entry) => entry.id === change.conversationId);
		if (conversation?.kind !== "room") return null;
		if (conversation.link === change.roomLink && conversation.manager === change.managerLink) return null;
		if (conversation.link != null && conversation.link !== change.roomLink) {
			throw new Error("room creation changed an existing room link");
		}
		if (conversation.manager != null && conversation.manager !== change.managerLink) {
			throw new Error("room creation changed an existing manager capability");
		}
		return {
			...checkpoint,
			conversations: checkpoint.conversations.map((entry) =>
				entry.id === conversation.id
					? { ...conversation, link: change.roomLink, manager: change.managerLink }
					: entry
			),
		};
	}
	if (change.type === "room-publication") {
		const conversation = checkpoint.conversations.find((entry) => entry.id === change.conversationId);
		if (
			conversation?.kind !== "room" || conversation.held ||
			(conversation.publicationId ?? null) !== change.expectedPublicationId
		) return null;
		return {
			...checkpoint,
			conversations: checkpoint.conversations.map((entry) =>
				entry.id === conversation.id ? { ...conversation, publicationId: change.publicationId } : entry
			),
		};
	}
	if (change.type === "room-reconnect") return reconcileRoomReconnect(checkpoint, change);
	const at = checkpoint.directories.findIndex((directory) => directory.id === change.directoryId);
	const directory = checkpoint.directories[at];
	if (directory == null || directory.locator !== change.locator || directory.reached === true) return null;
	return {
		...checkpoint,
		directories: checkpoint.directories.map((entry, index) => index === at ? { ...entry, reached: true } : entry),
	};
}

function reconcileDirectAcceptance(
	checkpoint: RoomsSessionState,
	accepted: DirectConversationAcceptance,
): RoomsSessionState | null {
	if (!checkpoint.directories.some((directory) => directory.id === accepted.directoryId && directory.nick !== "")) {
		throw new Error("an incoming direct conversation names no active directory membership");
	}
	const existing = checkpoint.conversations.find((conversation) =>
		conversation.kind === "direct" && !conversation.closed && conversation.directory === accepted.directoryId &&
		conversation.peerRegistrationId === accepted.peerRegistrationId
	);
	if (existing != null) return null;
	if (checkpoint.conversations.some((conversation) => conversation.id === accepted.conversationId)) {
		throw new Error("an incoming direct conversation reused an existing identity");
	}
	return {
		...checkpoint,
		conversations: [...checkpoint.conversations, {
			kind: "direct",
			id: accepted.conversationId,
			directory: accepted.directoryId,
			peer: accepted.peer,
			peerRegistrationId: accepted.peerRegistrationId,
			closed: false,
			draft: "",
		}],
	};
}

function reconcileRoomReconnect(
	checkpoint: RoomsSessionState,
	result: RoomReconnectResult,
): RoomsSessionState | null {
	const at = checkpoint.conversations.findIndex((conversation) => conversation.id === result.conversationId);
	const conversation = checkpoint.conversations[at];
	if (conversation?.kind !== "room" || conversation.reconnect !== "requested") return null;
	const next = result.connected
		? (() => {
			const { reconnect: _reconnect, ...connected } = conversation;
			return connected;
		})()
		: { ...conversation, reconnect: "manual" as const };
	return {
		...checkpoint,
		conversations: checkpoint.conversations.map((entry, index) => index === at ? next : entry),
	};
}

/** Clear only the exact retired bearer. The token comparison is the stale
 * event barrier: a pushed notice delayed past reissue becomes a no-op. */
function reconcileRoomAuthority(
	checkpoint: RoomsSessionState,
	retired: RoomAuthorityRetirement,
): RoomsSessionState | null {
	const at = checkpoint.conversations.findIndex((conversation) => conversation.id === retired.conversationId);
	const conversation = checkpoint.conversations[at];
	if (conversation?.kind !== "room") return null;
	const bearer = retired.kind === "room"
		? conversation.link
		: retired.kind === "manager"
		? conversation.manager
		: conversation.steward;
	if (bearer == null || roomAuthorityToken(bearer) !== retired.token) return null;
	if (retired.kind === "manager") {
		const { manager: _manager, ...withoutManager } = conversation;
		return {
			...checkpoint,
			conversations: checkpoint.conversations.map((entry, index) => index === at ? withoutManager : entry),
		};
	}
	const { steward: _steward, ...withoutSteward } = conversation;
	const next = retired.kind === "room"
		? (() => {
			const { link: _link, ...withoutLink } = withoutSteward;
			return { ...withoutLink, reconnect: "manual" as const };
		})()
		: withoutSteward;
	return {
		...checkpoint,
		conversations: checkpoint.conversations.map((entry, index) => index === at ? next : entry),
	};
}
