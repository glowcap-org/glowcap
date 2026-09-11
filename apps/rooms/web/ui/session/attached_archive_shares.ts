// Attached-view actions over archive facets held by the durable session.

import * as store from "../store.ts";
import { reconcileSharedArchive } from "./shared_archive_projection.ts";
import { ensureAttachedDirect } from "./attached_command_powers.ts";
import type { ArchiveShareKind } from "../../../lib/archive/handover.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { PageProjection } from "../store/core.ts";
import type { RoomsPageContext } from "../page.ts";
import type { RoomsSessionController } from "../controller/session.ts";
export type AttachedArchiveShareActions = Pick<
	RoomsSessionController,
	| "shareArchiveHistory"
	| "offerDurableArchive"
	| "readArchiveShare"
	| "dropArchiveShare"
	| "listIssuedArchiveShares"
	| "revokeIssuedArchiveShare"
>;

async function routeAttachedShare(
	projection: PageProjection,
	controller: AttachedRoomsController,
	key: string,
	peer: string | undefined,
	records: "line" | "standing",
): Promise<{ kind: ArchiveShareKind; conversationId: string; peer: string } | string> {
	const conversation = store.getConv(projection, key);
	if (conversation == null) return "That conversation is no longer open.";
	if (conversation.type === "directory") return "This view has no archive to share.";
	const kind: ArchiveShareKind = records === "standing"
		? "standing"
		: conversation.type === "room"
		? "room"
		: "direct";
	if (kind === "direct") return { kind, conversationId: conversation.persistId, peer: "" };
	const who = peer?.trim() ?? "";
	if (who === "") return "Name the member who should receive this archive account.";
	await ensureAttachedDirect(controller, conversation.dir, who);
	return { kind, conversationId: conversation.persistId, peer: who };
}

export function attachedArchiveShareActions(
	projection: PageProjection,
	page: RoomsPageContext,
	controller: AttachedRoomsController,
	onFailure: (error: unknown) => void,
): AttachedArchiveShareActions {
	return {
		shareArchiveHistory: async (key, peer, records = "line") => {
			try {
				const routed = await routeAttachedShare(projection, controller, key, peer, records);
				if (typeof routed === "string") return routed;
				await controller.shareArchiveHistory(routed.kind, routed.conversationId, routed.peer);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		offerDurableArchive: async (key, peer, records = "line") => {
			try {
				const routed = await routeAttachedShare(projection, controller, key, peer, records);
				if (typeof routed === "string") return routed;
				await controller.offerDurableArchive(routed.kind, routed.conversationId, routed.peer);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		readArchiveShare: async (id) => {
			try {
				const { view, records } = await controller.readArchiveShare(id);
				if (controller.closed) return "The Rooms session closed while reading the shared archive.";
				const conversation = store.convByPersistId(projection, view.conversationId);
				if (conversation == null) return "That shared archive's conversation is no longer open.";
				reconcileSharedArchive(page, conversation.key, records, view.from);
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
			try {
				await controller.dropArchiveShare(id);
				return "";
			} catch (error) {
				const reason = error instanceof Error ? error.message : String(error);
				return `History was added, but the shared-history offer could not be dismissed: ${reason}`;
			}
		},
		dropArchiveShare: (id) => {
			void controller.dropArchiveShare(id).catch(onFailure);
		},
		listIssuedArchiveShares: () => controller.listIssuedArchiveShares(),
		revokeIssuedArchiveShare: async (id) => {
			try {
				await controller.revokeIssuedArchiveShare(id);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
	};
}
