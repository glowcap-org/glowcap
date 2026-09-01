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
import { isSessionConv } from "../types.ts";

const DRAFT_SAVE_DELAY_MS = 150;

export function attachedComposerActions(
	projection: PageProjection,
	controller: AttachedRoomsController,
	powers: CommandPowers,
	onFailure: (error: unknown) => void,
): Pick<RoomsSessionController, "setDraft" | "send" | "mention" | "recallLastSent"> & {
	retireConversation(conversationId: string): void;
	retireDirectory(directoryId: string): void;
} {
	let draftRevision = 0;
	const draftTimers = new Map<string, ReturnType<typeof setTimeout>>();
	const setLocalDraft = (
		conversationId: string | null,
		text: string,
		persist: boolean,
		key: string | null,
	): number => {
		draftRevision += 1;
		store.setDraft(projection, text, key);
		if (persist && conversationId != null) controller.stageDraft(conversationId, text);
		return draftRevision;
	};
	const cancelDraftSave = (conversationId: string): void => {
		const timer = draftTimers.get(conversationId);
		if (timer != null) clearTimeout(timer);
		draftTimers.delete(conversationId);
	};
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
					draftRevision === revision && projection.get().activeKey === conversationKey &&
					store.activeDraft(projection).text === text
				) setLocalDraft(conversationId, previous, true, conversationKey);
				onFailure(error);
			});
		}, DRAFT_SAVE_DELAY_MS);
		draftTimers.set(conversationId, timer);
	};
	const setDraft = (text: string): void => {
		const conversation = store.activeConv(projection);
		if (conversation == null) return;
		const previous = store.activeDraft(projection).text;
		if (!isSessionConv(conversation)) {
			setLocalDraft(null, text, false, conversation.key);
			return;
		}
		const revision = setLocalDraft(conversation.persistId, text, true, conversation.key);
		saveDraft(conversation.persistId, conversation.key, text, previous, revision);
	};
	return {
		setDraft,
		retireConversation,
		retireDirectory,
		mention: (who) => setDraft(draftWithMention(store.activeDraft(projection).text, who)),
		recallLastSent: () => {
			const conversation = store.activeConv(projection);
			if (conversation == null) return null;
			const last = recalledDraft(store.activeDraft(projection), store.lastSentFor(projection, conversation.key));
			if (last != null) setDraft(last);
			return last;
		},
		send: () => {
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
					store.toast(projection, "failure", "This shared session no longer holds authority over that line.");
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
					store.rememberLastSent(projection, conversation.key, text);
					store.cancelChange(projection);
					return controller.setDraft(conversation.persistId, "");
				}).catch((error) => {
					const revision = draftRevision;
					saveDraft(conversation.persistId, conversation.key, text, text, revision);
					onFailure(error);
				});
				return;
			}
			const prepared = interpretComposerSend(projection, conversation, draft, powers);
			if (prepared == null) return;
			if (prepared.kind === "handled") {
				finishComposerSend(projection, conversation.key, prepared.original);
				draftRevision += 1;
				if (!isSessionConv(conversation)) {
					if (prepared.retires === "directory") retireDirectory(conversation.dir);
					return;
				}
				cancelDraftSave(conversation.persistId);
				controller.stageDraft(conversation.persistId, "");
				if (prepared.retires === "directory") retireDirectory(conversation.dir);
				else if (prepared.retires === "conversation") retireConversation(conversation.persistId);
				else void controller.setDraft(conversation.persistId, "").catch(onFailure);
				return;
			}
			if (!isSessionConv(conversation)) return;
			cancelDraftSave(conversation.persistId);
			finishComposerSend(projection, conversation.key, prepared.original);
			const clearedRevision = (draftRevision += 1);
			controller.stageDraft(conversation.persistId, "");
			const sent = prepared.files.length === 0
				? controller.say(conversation.persistId, prepared.text)
				: controller.sendFiles(
					conversation.persistId,
					prepared.text,
					prepared.files.map(pickedSource),
				);
			void sent.then(() => controller.setDraft(conversation.persistId, "")).catch((error) => {
				if (
					draftRevision === clearedRevision && projection.get().activeKey === conversation.key &&
					store.activeDraft(projection).text === ""
				) {
					const revision = setLocalDraft(conversation.persistId, prepared.original, true, conversation.key);
					saveDraft(conversation.persistId, conversation.key, prepared.original, "", revision);
				}
				onFailure(error);
			});
		},
	};
}
