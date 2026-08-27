import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import type { Message } from "../lib/room_client.ts";
import type { ArchiveCoordinates } from "../lib/archive.ts";
import type { DurableRoomsArchive } from "./archive.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import { type RoomDrainCallbacks, RoomRealization } from "./room_realization.ts";

export interface RoomReconcileCallbacks extends RoomDrainCallbacks {
	setIssue(subject: string, error: unknown | null): boolean;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
}

export type RoomMessageReceiver = (
	conversationId: string,
	message: Message,
	editable: boolean,
	files: RuntimeAttachment[],
	history: ArchiveCoordinates | null,
) => void;

interface RoomCallbackOptions {
	held: LiveDirectory;
	archive: DurableRoomsArchive;
	keepHistory: () => boolean;
	receivers: ReadonlySet<RoomMessageReceiver>;
	release(live: LiveRoom): void;
	retry(): void;
	notifyView(): void;
	setIssue(subject: string, error: unknown | null): boolean;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
}

export function reconcileRooms(
	realization: RoomRealization,
	held: LiveDirectory,
	conversations: readonly WorkspaceConversation[],
	callbacks: RoomReconcileCallbacks,
): Promise<void> {
	return realization.reconcileAndDrain(
		held,
		conversations,
		callbacks.setIssue,
		callbacks.cleanup,
		callbacks.release,
		callbacks,
	);
}

export function emitRoomMessage(
	archive: DurableRoomsArchive,
	keep: boolean,
	receivers: ReadonlySet<RoomMessageReceiver>,
	held: LiveDirectory,
	conversationId: string,
	message: Message,
	editable: boolean,
	files: RuntimeAttachment[],
	generation: string | null,
): void {
	const history = archive.recordMessage({
		keep,
		generation,
		kind: "room",
		directory: held.id,
		conversation: conversationId,
		nick: held.nick,
		message,
		files,
	});
	for (const receive of receivers) receive(conversationId, message, editable, files, history);
}

export function makeRoomCallbacks(
	options: RoomCallbackOptions,
): RoomReconcileCallbacks {
	return {
		release: options.release,
		message: (conversationId, message, editable, files, generation) =>
			emitRoomMessage(
				options.archive,
				options.keepHistory(),
				options.receivers,
				options.held,
				conversationId,
				message,
				editable,
				files,
				generation,
			),
		scheduleRetry: options.retry,
		scheduleRoomViewNotify: options.notifyView,
		setIssue: options.setIssue,
		cleanup: options.cleanup,
	};
}
