// Realize the workspace's layered standing intent on connected rooms.

import type { RoomsSessionState } from "../lib/rooms_state.ts";
import type { LiveDirectory } from "./live.ts";

export async function reconcileRoomStanding(
	checkpoint: RoomsSessionState,
	directories: ReadonlyMap<string, LiveDirectory>,
	setIssue: (subject: string, error: unknown | null) => boolean,
	subjects: Iterable<string>,
): Promise<void> {
	const savedDirectories = new Map(checkpoint.directories.map((directory) => [directory.id, directory]));
	const wanted = new Set(
		checkpoint.conversations.flatMap((conversation) =>
			conversation.kind === "room" ? [`standing:${conversation.directory}:${conversation.id}`] : []
		),
	);
	for (const subject of subjects) {
		if (subject.startsWith("standing:") && !wanted.has(subject)) setIssue(subject, null);
	}
	for (const conversation of checkpoint.conversations) {
		if (conversation.kind !== "room") continue;
		const subject = `standing:${conversation.directory}:${conversation.id}`;
		const live = directories.get(conversation.directory)?.roomRealization.rooms.get(conversation.id);
		if (live == null) {
			setIssue(subject, null);
			continue;
		}
		const standing = conversation.standing ??
			savedDirectories.get(conversation.directory)?.standing ?? checkpoint.standing;
		if (live.standing === standing) continue;
		try {
			await live.room.away(standing);
			live.standing = standing;
			setIssue(subject, null);
		} catch (error) {
			setIssue(subject, error);
		}
	}
}
