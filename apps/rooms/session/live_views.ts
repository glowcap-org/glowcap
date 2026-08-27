// Aggregate-bounded live directory and room facts for one session snapshot.

import { MAX_SESSION_DIRECTORY_ROWS, MAX_SESSION_ROOM_MEMBERS } from "../lib/limits.ts";
import type { RoomsSessionDirectoryView, RoomsSessionRoomView } from "../lib/rooms_session.ts";
import type { LiveDirectory } from "./live.ts";
import { projectRoomView } from "./room_view.ts";

export function projectDirectoryViews(directories: ReadonlyMap<string, LiveDirectory>): RoomsSessionDirectoryView[] {
	let remaining = MAX_SESSION_DIRECTORY_ROWS;
	return [...directories.values()].map((directory) => {
		const view = directory.view.snapshot(remaining);
		remaining -= view.rooms.length + view.peers.length;
		return view;
	});
}

export function projectRoomViews(directories: ReadonlyMap<string, LiveDirectory>): RoomsSessionRoomView[] {
	let remaining = MAX_SESSION_ROOM_MEMBERS;
	const views: RoomsSessionRoomView[] = [];
	for (const directory of directories.values()) {
		for (const [conversationId, room] of directory.roomRealization.rooms) {
			const view = projectRoomView(
				conversationId,
				room.view,
				room.room.canSetTopic,
				room.room.canKick,
				remaining,
			);
			remaining -= view.members.length;
			views.push(view);
		}
	}
	return views;
}
