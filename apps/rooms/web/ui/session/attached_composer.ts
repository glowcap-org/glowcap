// Attached composer state and bounded send/refile effects.
// Send commits through `commit.ts`, then this file talks to the session.

import * as store from "../store.ts";
import { composerLineRefusal } from "../composer/send.ts";
import { finishComposerSend, interpretComposerSend } from "../composer/commit.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { pickedSource } from "../file_source.ts";
import { draftWithMention, recalledDraft } from "../composer/draft.ts";
import type { PageProjection } from "../store/core.ts";
import type { CommandPowers } from "../commands.ts";
import { isSessionConv, type SendState, type SessionConv } from "../types.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { lineAuthorityLost, notInRoomNow } from "../../../lib/text/attached.ts";
import { DELIVERY_UNCERTAIN, roomsErrorInMessage } from "../../../lib/error_codes.ts";

export function attachedComposerActions(
	projection: PageProjection,
	controller: AttachedRoomsController,
	powers: CommandPowers,
	reportFailure: (error: unknown) => void,
	recoverSends = false,
): Pick<RoomsSessionController, "setDraft" | "send" | "mention" | "recallLastSent"> & {
	retireConversation(conversationId: string): void;
	retireDirectory(directoryId: string): void;
	retry(key: string, id: number): void;
} {
	const onFailure = (error: unknown): void => {
		if (!controller.closed) reportFailure(error);
	};
	const setLocalDraft = (
		conversationId: string | null,
		text: string,
		persist: boolean,
		key: string | null,
	): void => {
		store.setDraft(projection, text, key);
		if (persist && conversationId != null) controller.stageDraft(conversationId, text);
	};
	const cancelDraftSave = (conversationId: string): void => controller.cancelDraftSave(conversationId);
	const retireConversation = (conversationId: string): void => {
		cancelDraftSave(conversationId);
		controller.retireDraft(conversationId);
	};
	const retireDirectory = (directoryId: string): void => {
		for (const conversation of projection.get().convs.values()) {
			if (isSessionConv(conversation) && conversation.dir === directoryId) {
				retireConversation(conversation.persistId);
			}
		}
	};
	const saveDraft = (conversationId: string, conversationKey: string, text: string): void => {
		const submitted = store.draftFor(projection, conversationKey);
		void controller.scheduleDraft(conversationId, text).catch((error) => {
			if (controller.closed) return;
			// A storage refusal does not revoke the reader's unsaved text.
			// Keep it staged for the next explicit edit or selection flush.
			if (store.draftFor(projection, conversationKey) === submitted) controller.stageDraft(conversationId, text);
			onFailure(error);
		});
	};
	const markPending = (key: string, id: number, state: SendState): boolean => {
		const item = store.historyOf(projection, key).find((candidate) => candidate.id === id);
		if (item?.kind !== "chat") return false;
		if (state !== "sending" && item.state !== "sending") return false;
		store.updateItem(projection, key, id, { state });
		return true;
	};
	const notInRoom = (key: string, id: number): boolean => {
		const conversation = store.getConv(projection, key);
		if (conversation?.type !== "room" || conversation.membership === "joined") return false;
		markPending(key, id, "failed");
		store.deliver(
			projection,
			key,
			store.sysItem(
				projection,
				notInRoomNow,
			),
		);
		return true;
	};
	const sendText = (conversation: SessionConv, id: number): void => {
		if (notInRoom(conversation.key, id)) return;
		const item = store.historyOf(projection, conversation.key).find((candidate) => candidate.id === id);
		if (item?.kind !== "chat") return;
		void controller.say(conversation.persistId, item.text, item.previewUrls ?? []).catch((error) => {
			if (controller.closed || !markPending(conversation.key, id, "failed")) return;
			reportFailure(error);
		});
	};
	const setDraft = (text: string): void => {
		const conversation = store.activeConv(projection);
		if (conversation == null) return;
		if (!isSessionConv(conversation)) {
			setLocalDraft(null, text, false, conversation.key);
			return;
		}
		setLocalDraft(conversation.persistId, text, true, conversation.key);
		saveDraft(conversation.persistId, conversation.key, text);
	};
	return {
		setDraft,
		retireConversation,
		retireDirectory,
		retry: (key, id) => {
			if (!recoverSends) return;
			const conversation = store.getConv(projection, key);
			const item = store.historyOf(projection, key).find((candidate) => candidate.id === id);
			if (
				conversation == null || !isSessionConv(conversation) || item?.kind !== "chat" || item.state !== "failed"
			) {
				return;
			}
			markPending(key, id, "sending");
			sendText(conversation, id);
		},
		mention: (who) => setDraft(draftWithMention(store.activeDraft(projection).text, who)),
		recallLastSent: () => {
			const conversation = store.activeConv(projection);
			if (conversation == null) return null;
			const last = recalledDraft(store.activeDraft(projection), store.lastSentFor(projection, conversation.key));
			if (last != null) setDraft(last);
			return last;
		},
		send: () => {
			try {
				const conversation = store.activeConv(projection);
				if (conversation == null) return;
				const draft = store.activeDraft(projection);
				if (draft.changing != null) {
					if (!isSessionConv(conversation)) return;
					const text = draft.text;
					const refusal = composerLineRefusal(conversation, text);
					if (refusal != null) {
						store.deliverActive(projection, store.sysItem(projection, refusal));
						return;
					}
					const item = store.historyOf(projection, conversation.key).find((row) => row.id === draft.changing);
					if (item?.kind !== "chat" || item.lineId == null) {
						store.toast(
							projection,
							"failure",
							lineAuthorityLost,
						);
						return;
					}
					const lineId = item.lineId;
					const keep = (item.attachments ?? []).flatMap((file, index) =>
						draft.keeping?.some((kept) => kept.id === file.id) ? [index] : []
					);
					cancelDraftSave(conversation.persistId);
					const changed = draft.keeping == null
						? controller.editLine(conversation.persistId, lineId, text)
						: Promise.all(draft.files.map(pickedSource)).then((files) =>
							controller.refileLine(
								conversation.persistId,
								lineId,
								text,
								keep,
								files,
							)
						);
					void changed.then(() => {
						if (controller.closed) return;
						store.rememberLastSent(projection, conversation.key, text);
						// Only the submitted draft may be completed. Selection and later edits
						// can change while the session is acknowledging this operation.
						if (store.draftFor(projection, conversation.key) !== draft) return;
						store.cancelChange(projection, conversation.key);
						return controller.setDraft(conversation.persistId, "");
					}, (error) => {
						if (controller.closed) return;
						if (store.draftFor(projection, conversation.key) === draft) {
							saveDraft(conversation.persistId, conversation.key, text);
						}
						onFailure(error);
					}).catch(onFailure);
					return;
				}
				const prepared = interpretComposerSend(projection, conversation, draft, powers);
				if (prepared == null) return;
				if (prepared.kind === "handled") {
					const complete = () => {
						if (controller.closed) return;
						if (prepared.retires === "directory") retireDirectory(conversation.dir);
						else if (prepared.retires === "conversation" && isSessionConv(conversation)) {
							retireConversation(conversation.persistId);
						}
						if (store.draftFor(projection, conversation.key) !== draft) return;
						finishComposerSend(projection, conversation.key, prepared.original);
						if (!isSessionConv(conversation) || prepared.retires != null) return;
						cancelDraftSave(conversation.persistId);
						controller.stageDraft(conversation.persistId, "");
						return controller.setDraft(conversation.persistId, "");
					};
					if (prepared.completion != null) {
						void prepared.completion.then(complete, (error) => {
							if (controller.closed) return;
							if (projection.get().convs.has(conversation.key)) {
								store.deliver(
									projection,
									conversation.key,
									store.sysItem(projection, refusalText(error)),
								);
							} else onFailure(error);
						}).catch(onFailure);
					} else void Promise.resolve(complete()).catch(onFailure);
					return;
				}
				if (!isSessionConv(conversation)) return;
				cancelDraftSave(conversation.persistId);
				const optimistic = prepared.files.length === 0
					? store.chatItem(
						projection,
						store.dirNick(projection, conversation.dir),
						prepared.text,
						true,
						"sending",
						undefined,
						undefined,
						prepared.previewUrls,
					)
					: null;
				if (optimistic != null) store.deliver(projection, conversation.key, optimistic);
				finishComposerSend(projection, conversation.key, prepared.original);
				const clearedDraft = store.draftFor(projection, conversation.key);
				controller.stageDraft(conversation.persistId, "");
				const sent = prepared.files.length === 0
					? controller.say(conversation.persistId, prepared.text, prepared.previewUrls)
					: Promise.all(prepared.files.map(pickedSource)).then((files) =>
						controller.sendFiles(
							conversation.persistId,
							prepared.text,
							prepared.previewUrls,
							files,
						)
					);
				void sent.then(
					() => controller.closed ? undefined : controller.clearSentDraft(conversation.persistId),
					(error) => {
						if (controller.closed) return;
						// An unconfirmed send may already have reached the other
						// side. The line drawn for it stays, marked unconfirmed, with
						// no draft put back to send it twice from. A send with files
						// draws no line, so there the text comes back rather than
						// being lost, and the failure's own words say why.
						const unconfirmed = roomsErrorInMessage(error)?.code === DELIVERY_UNCERTAIN;
						if (optimistic != null) {
							markPending(conversation.key, optimistic.id, unconfirmed ? "unconfirmed" : "failed");
						}
						if (
							!(optimistic != null && (recoverSends || unconfirmed)) &&
							store.replaceDraft(projection, conversation.key, clearedDraft, draft)
						) {
							controller.stageDraft(conversation.persistId, draft.text);
							saveDraft(conversation.persistId, conversation.key, draft.text);
						}
						onFailure(error);
					},
				).catch(onFailure);
			} catch (error) {
				onFailure(error);
			}
		},
	};
}
