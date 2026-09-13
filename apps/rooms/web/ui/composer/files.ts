// File-picker admission and composer feedback; Rust owns the submitted files.
import * as store from "../store.ts";
import { MAX_MESSAGE_FILES } from "../limits.ts";
import type { RoomsPageContext } from "../page.ts";
import { conversationTakesFiles } from "../types.ts";
import { filesLeftOut, filesNotCarried, tooManyFiles } from "../../../lib/text/attached.ts";

/** Put files on the draft, whichever way they arrived: the picker, a paste,
 * or a drop. This is the one admission for all three, so a conversation
 * that has no way to carry a file answers them all the same way: the attach
 * control is absent there, and a file that arrives anyway is told why in the
 * log rather than silently ignored. */
export function addFiles(page: RoomsPageContext, files: readonly File[]): void {
	const projection = page.projection;
	if (files.length === 0) return;
	const conv = store.activeConv(projection);
	if (!conversationTakesFiles(conv)) {
		store.deliverActive(
			projection,
			store.sysItem(projection, filesNotCarried(conv?.type === "room" ? conv.bridge?.badge ?? null : null)),
		);
		return;
	}
	const room = MAX_MESSAGE_FILES - store.activeDraft(projection).files.length;
	if (room <= 0) {
		store.deliverActive(
			projection,
			store.sysItem(
				projection,
				tooManyFiles(MAX_MESSAGE_FILES),
			),
		);
		return;
	}
	store.addDraftFiles(projection, files.slice(0, room));
	const over = files.length - room;
	if (over > 0) {
		store.deliverActive(
			projection,
			store.sysItem(
				projection,
				filesLeftOut(MAX_MESSAGE_FILES, over),
			),
		);
	}
}
