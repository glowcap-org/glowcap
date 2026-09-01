// Bring one directory's live rooms into line with the checkpoint's intended rooms.

import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import type { Message } from "../lib/room/client.ts";
import type { DurableRoomsArchive } from "./archive.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import { type RoomDrainCallbacks, RoomRealization } from "./room_realization.ts";
import type { RoomAuthorityAcquisition, RoomAuthorityRetirement, RoomReconnectResult } from "./state_sync.ts";
import { type ConversationEventObserver, emitTypingEvent } from "./conversation_events.ts";

export interface RoomReconcileCallbacks extends RoomDrainCallbacks {
	current(): boolean;
	setIssue(subject: string, error: unknown | null): boolean;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
	reconcileAuthority(retired: RoomAuthorityRetirement): Promise<void>;
	reconcileAcquisition(acquired: RoomAuthorityAcquisition): Promise<void>;
	reconcileReconnect(result: RoomReconnectResult): Promise<void>;
	bridgeSecrets(directoryId: string, scope: string): Record<string, string> | null;
}

interface RoomCallbackOptions {
	held: LiveDirectory;
	archive: DurableRoomsArchive;
	keepHistory: () => boolean;
	receivers: ReadonlySet<ConversationEventObserver>;
	release(live: LiveRoom): void;
	retry(): void;
	notifyView(): void;
	setIssue(subject: string, error: unknown | null): boolean;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
	reconcileAuthority(retired: RoomAuthorityRetirement): Promise<void>;
	reconcileAcquisition(acquired: RoomAuthorityAcquisition): Promise<void>;
	reconcileReconnect(result: RoomReconnectResult): Promise<void>;
	bridgeSecrets(directoryId: string, scope: string): Record<string, string> | null;
	current(): boolean;
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
		callbacks.reconcileAuthority,
		callbacks.reconcileAcquisition,
		callbacks.reconcileReconnect,
		callbacks.current,
		callbacks.scheduleRoomViewNotify,
		callbacks.bridgeSecrets,
		callbacks,
	);
}

function emitRoomMessage(
	archive: DurableRoomsArchive,
	keep: boolean,
	receivers: ReadonlySet<ConversationEventObserver>,
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
		typing: (conversationId, peer, on) => emitTypingEvent(options.receivers, conversationId, peer, on),
		scheduleRetry: options.retry,
		scheduleRoomViewNotify: options.notifyView,
		setIssue: options.setIssue,
		cleanup: options.cleanup,
		reconcileAuthority: options.reconcileAuthority,
		reconcileAcquisition: options.reconcileAcquisition,
		reconcileReconnect: options.reconcileReconnect,
		bridgeSecrets: options.bridgeSecrets,
		current: options.current,
	};
}
