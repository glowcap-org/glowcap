// Attached-view actions over archive facets held by the durable session.

import type { RoomsSessionController } from "../controller/session.ts";
import * as store from "../store.ts";
import { prependSharedArchive } from "../net/history.ts";
import type { AttachedRoomsController } from "./attached.ts";

export type AttachedArchiveShareActions = Pick<
	RoomsSessionController,
	"shareArchiveHistory" | "readArchiveShare" | "dropArchiveShare"
>;

export function attachedArchiveShareActions(
	controller: AttachedRoomsController,
	onFailure: (error: unknown) => void,
): AttachedArchiveShareActions {
	return {
		shareArchiveHistory: async (key) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "dm") return "Only a direct conversation can share its history.";
			try {
				await controller.shareArchiveHistory(conversation.persistId);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		readArchiveShare: async (id) => {
			try {
				const { view, records } = await controller.readArchiveShare(id);
				const conversation = [...store.get().convs.values()].find((entry) =>
					entry.persistId === view.conversationId
				);
				if (conversation == null) return "That shared archive's conversation is no longer open.";
				prependSharedArchive(conversation.key, records, view.from);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		dropArchiveShare: (id) => {
			void controller.dropArchiveShare(id).catch(onFailure);
		},
	};
}
