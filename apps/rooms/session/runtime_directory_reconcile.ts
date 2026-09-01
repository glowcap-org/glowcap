// Bounded, supersedable directory realization for one durable Rooms runtime.

import type { WorkspaceConversation, WorkspaceDirectory } from "../lib/rooms_state.ts";
import type { LiveDirectory } from "./live.ts";
import type { RoomPublicationResolution } from "./state_sync.ts";
import { roomsDirectoryConnectionTopology } from "./topology.ts";

const RECONNECT_CONCURRENCY = 4;

export function roomPublicationId(
	live: ReadonlyMap<string, LiveDirectory>,
	directoryId: string,
	roomName: string,
): string | null {
	const held = live.get(directoryId);
	return held == null ? null : publicationIdIn(held, roomName);
}

function publicationIdIn(held: LiveDirectory, roomName: string): string | null {
	const room = held.view.roomNamed(roomName);
	return room != null && room.kind !== "local" ? room.id : null;
}

/** The first public conversation whose connected directory can supply a
 * current non-local publication. A retired generation may move to a new
 * publication of the same source name; a still-listed old generation cannot. */
export function unresolvedRoomPublication(
	conversations: readonly WorkspaceConversation[],
	held: LiveDirectory,
): RoomPublicationResolution | null {
	for (const conversation of conversations) {
		if (conversation.kind !== "room" || conversation.directory !== held.id || conversation.held) continue;
		const publicationId = publicationIdIn(held, conversation.name);
		const expectedPublicationId = conversation.publicationId ?? null;
		if (publicationId == null || publicationId === expectedPublicationId) continue;
		if (expectedPublicationId != null && held.view.room(expectedPublicationId) != null) continue;
		return { type: "room-publication", conversationId: conversation.id, expectedPublicationId, publicationId };
	}
	return null;
}

interface DirectoryReconciliation {
	readonly wanted: readonly WorkspaceDirectory[];
	readonly live: Map<string, LiveDirectory>;
	current(): boolean;
	release(id: string): Promise<void>;
	connect(directory: WorkspaceDirectory): Promise<LiveDirectory>;
	close(directory: LiveDirectory): Promise<void>;
	changed(): void;
	setIssue(subject: string, error: unknown | null): boolean;
}

/** Reconcile only directory connections. False means a newer checkpoint
 * superseded this plan; any late connection has been closed before insertion. */
export async function reconcileRuntimeDirectories(options: DirectoryReconciliation): Promise<boolean> {
	const wanted = new Map(options.wanted.map((directory) => [directory.id, directory]));
	for (const [id, held] of options.live) {
		if (!options.current()) return false;
		const saved = wanted.get(id);
		if (saved != null && held.topology === roomsDirectoryConnectionTopology(saved)) continue;
		await options.release(id);
		options.live.delete(id);
		options.changed();
		await options.close(held);
		if (!options.current()) return false;
		if (saved == null) {
			options.setIssue(`directory:${id}`, null);
			options.setIssue(`directory-view:${id}`, null);
		}
	}

	const reconnect = options.wanted.filter((saved) => !options.live.has(saved.id));
	let next = 0;
	const worker = async () => {
		while (next < reconnect.length) {
			if (!options.current()) return;
			const saved = reconnect[next++];
			try {
				const connected = await options.connect(saved);
				if (!options.current()) {
					await options.close(connected);
					return;
				}
				options.live.set(saved.id, connected);
				options.changed();
				options.setIssue(`directory:${saved.id}`, null);
			} catch (error) {
				if (options.setIssue(`directory:${saved.id}`, error)) {
					console.error(
						`rooms session: could not restore ${saved.locator}: ${
							error instanceof Error ? error.message : error
						}`,
					);
				}
			}
		}
	};
	await Promise.all(Array.from({ length: Math.min(RECONNECT_CONCURRENCY, reconnect.length) }, worker));
	return options.current();
}
