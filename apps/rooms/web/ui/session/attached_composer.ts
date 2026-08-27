// Attached composer state and bounded send/refile effects.

import type { CommandPowers } from "../commands.ts";
import { composerLineRefusal, prepareComposerSend } from "../composer/send.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import * as store from "../store.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { pickedSource } from "../file_source.ts";
import { draftWithMention, recalledDraft } from "../composer/draft.ts";

const DRAFT_SAVE_DELAY_MS = 150;

export function attachedComposerActions(
	controller: AttachedRoomsController,
	powers: CommandPowers,
	onFailure: (error: unknown) => void,
): Pick<RoomsSessionController, "setDraft" | "send" | "mention" | "recallLastSent"> {
	let draftRevision = 0;
	const draftTimers = new Map<string, ReturnType<typeof setTimeout>>();
	const setLocalDraft = (conversationId: string, text: string): number => {
		draftRevision += 1;
		store.setDraft(text);
		controller.stageDraft(conversationId, text);
		return draftRevision;
	};
	const cancelDraftSave = (conversationId: string): void => {
		const timer = draftTimers.get(conversationId);
		if (timer != null) clearTimeout(timer);
		draftTimers.delete(conversationId);
	};
	const saveDraft = (
		conversationId: string,
		conversationKey: string,
		text: string,
		previous: string,
		revision: number,
	): void => {
		cancelDraftSave(conversationId);
		const timer = setTimeout(() => {
			draftTimers.delete(conversationId);
			void controller.setDraft(conversationId, text).catch((error) => {
				if (
					draftRevision === revision && store.get().activeKey === conversationKey &&
					store.activeDraft().text === text
				) setLocalDraft(conversationId, previous);
				onFailure(error);
			});
		}, DRAFT_SAVE_DELAY_MS);
		draftTimers.set(conversationId, timer);
	};
	const setDraft = (text: string): void => {
		const conversation = store.activeConv();
		if (conversation == null) return;
		const previous = store.activeDraft().text;
		const revision = setLocalDraft(conversation.persistId, text);
		saveDraft(conversation.persistId, conversation.key, text, previous, revision);
	};
	return {
		setDraft,
		mention: (who) => setDraft(draftWithMention(store.activeDraft().text, who)),
		recallLastSent: () => {
			const conversation = store.activeConv();
			if (conversation == null) return null;
			const last = recalledDraft(store.activeDraft(), store.lastSentFor(conversation.key));
			if (last != null) setDraft(last);
			return last;
		},
		send: () => {
			const conversation = store.activeConv();
			if (conversation == null) return;
			const draft = store.activeDraft();
			if (draft.changing != null) {
				const text = draft.text;
				const refusal = composerLineRefusal(conversation, text);
				if (refusal != null) {
					store.deliverActive(store.sysItem(refusal));
					return;
				}
				const item = conversation.history.find((row) => row.id === draft.changing);
				if (item?.kind !== "chat" || item.lineId == null) {
					store.toast("failure", "This shared session no longer holds authority over that line.");
					return;
				}
				cancelDraftSave(conversation.persistId);
				const changed = draft.keeping == null
					? controller.editLine(conversation.persistId, item.lineId, text)
					: controller.refileLine(
						conversation.persistId,
						item.lineId,
						text,
						(item.attachments ?? []).flatMap((file, index) =>
							draft.keeping?.some((kept) => kept.id === file.id) ? [index] : []
						),
						draft.files.map(pickedSource),
					);
				void changed.then(() => {
					store.rememberLastSent(conversation.key, text);
					store.cancelChange();
					return controller.setDraft(conversation.persistId, "");
				}).catch((error) => {
					const revision = draftRevision;
					saveDraft(conversation.persistId, conversation.key, text, text, revision);
					onFailure(error);
				});
				return;
			}
			const prepared = prepareComposerSend(conversation, draft, powers);
			if (prepared.kind === "nothing") return;
			if (prepared.kind === "refused") {
				store.deliverActive(store.sysItem(prepared.why));
				return;
			}
			cancelDraftSave(conversation.persistId);
			const clearDraft = () => {
				store.rememberLastSent(conversation.key, prepared.original);
				const revision = setLocalDraft(conversation.persistId, "");
				store.clearDraftFiles();
				return revision;
			};
			if (prepared.kind === "handled") {
				clearDraft();
				void controller.setDraft(conversation.persistId, "").catch(onFailure);
				return;
			}
			const sent = prepared.files.length === 0
				? controller.say(conversation.persistId, prepared.text)
				: controller.sendFiles(
					conversation.persistId,
					prepared.text,
					prepared.files.map(pickedSource),
				);
			const clearedRevision = clearDraft();
			void sent.then(() => controller.setDraft(conversation.persistId, "")).catch((error) => {
				if (
					draftRevision === clearedRevision && store.get().activeKey === conversation.key &&
					store.activeDraft().text === ""
				) {
					const revision = setLocalDraft(conversation.persistId, prepared.original);
					saveDraft(conversation.persistId, conversation.key, prepared.original, "", revision);
				}
				onFailure(error);
			});
		},
	};
}
