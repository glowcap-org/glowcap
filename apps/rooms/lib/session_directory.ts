// Pure directory transitions over the durable Rooms checkpoint.

import type { RoomsSessionState } from "./rooms_state.ts";

export interface RoomsSessionDirectoryRetirement {
	session: RoomsSessionState;
	/** Live occurrences realizing these intents must be released after commit. */
	retiredPeering: RoomsSessionState["peering"];
}

/** Prepare removal of one directory and every durable fact whose authority or
 * identity depends on it. Durable controllers and local browsers share this
 * answer; the browser also consumes the retired intents for live teardown. */
export function prepareRoomsSessionDirectoryRetirement(
	current: RoomsSessionState,
	directoryId: string,
): RoomsSessionDirectoryRetirement {
	const removed = new Set(
		current.conversations.filter((entry) => entry.directory === directoryId).map((entry) => entry.id),
	);
	const peering: RoomsSessionState["peering"] = [];
	const retiredPeering: RoomsSessionState["peering"] = [];
	for (const intent of current.peering) {
		(intent.destination === directoryId || removed.has(intent.source) ? retiredPeering : peering).push(intent);
	}
	return {
		session: {
			...current,
			directories: current.directories.filter((entry) => entry.id !== directoryId),
			conversations: current.conversations.filter((entry) => entry.directory !== directoryId),
			invitations: current.invitations.filter((entry) => entry.directory !== directoryId),
			active: current.active != null && removed.has(current.active) ? null : current.active,
			capabilities: {
				...current.capabilities,
				operations: current.capabilities.operations.filter((entry) => entry.scope !== directoryId),
			},
			peering,
		},
		retiredPeering,
	};
}
