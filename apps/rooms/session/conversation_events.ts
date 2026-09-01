// Ephemeral and durable events projected from one live conversation.

import type { ArchiveCoordinates } from "../lib/archive/protocol.ts";
import type { Message } from "../lib/room/client.ts";
import type { RuntimeAttachment } from "./room_files.ts";

export type ConversationEventObserver = (
	conversationId: string,
	message: Message,
	editable: boolean,
	files: RuntimeAttachment[],
	history: ArchiveCoordinates | null,
) => void;

export function typingMessage(peer: string, on: boolean): Message {
	return {
		from: peer,
		text: "",
		system: true,
		presence: { kind: "typing", name: peer, on },
		attachments: [],
	};
}

/** Project a live typing level without admitting it to durable history. Each
 * attached view owns its bounded auto-clear timer; this owner only fans out the
 * room/direct fact through the same ordered event channel as conversation
 * lines. */
export function emitTypingEvent(
	receivers: ReadonlySet<ConversationEventObserver>,
	conversationId: string,
	peer: string,
	on: boolean,
): void {
	for (const receive of receivers) {
		receive(
			conversationId,
			typingMessage(peer, on),
			false,
			[],
			null,
		);
	}
}
