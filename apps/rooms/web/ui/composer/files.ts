// File-picker admission and composer feedback; Rust owns the submitted files.
import * as store from "../store.ts";
import { MAX_MESSAGE_FILES } from "../limits.ts";
import type { RoomsPageContext } from "../page.ts";

export function addFiles(page: RoomsPageContext, files: readonly File[]): void {
	const projection = page.projection;
	if (files.length === 0) return;
	const room = MAX_MESSAGE_FILES - store.activeDraft(projection).files.length;
	if (room <= 0) {
		store.deliverActive(
			projection,
			store.sysItem(
				projection,
				`This message already carries ${MAX_MESSAGE_FILES} files, which is as many as one can.`,
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
				`A message may carry at most ${MAX_MESSAGE_FILES} files, so ${
					over === 1 ? "one file was" : over + " files were"
				} left out. ` +
					`Send this one and the rest can follow.`,
			),
		);
	}
}
