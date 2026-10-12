// Pending text is a presentation layer over the accepted line. A refusal drops
// only that layer. An incoming update wins over an older local completion.
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import { refusalText } from "../../../../lib/text/failure.ts";

export async function editLine(
	page: RoomsPageContext,
	session: ManagedRoomsSession,
	key: string,
	id: number,
	text: string,
	after: () => Promise<void> = () => Promise.resolve(),
): Promise<void> {
	const projection = page.projection;
	const row = store.getConv(projection, key);
	const item = store.historyOf(projection, key).find((line) => line.id === id);
	if (row == null || row.type === "directory" || item?.kind !== "chat" || item.lineId == null || !item.held) {
		throw new Error("The original line authority is no longer held");
	}
	if (item.pendingEdit != null) {
		if (item.pendingEdit.text !== text) {
			throw new Error("Finish or recover the original edit before changing this line again");
		}
		await session.completeOperation(item.pendingEdit.operation);
		return;
	}
	const operation = crypto.randomUUID();
	const args = [row.persistId, String(item.lineId), text];
	session.effects.reserve(operation, "editLine", args);
	const current = () => store.historyOf(projection, key).find((line) => line.id === id);
	store.updateItem(projection, key, id, { pendingEdit: { operation, text }, editFailure: undefined });
	let installed = current();
	const patch = (committed: boolean, failure?: string) => {
		const now = current();
		if (now?.kind !== "chat" || now.lineId !== item.lineId || now.pendingEdit?.operation !== operation) return;
		const untouched = now === installed;
		store.updateItem(projection, key, id, {
			pendingEdit: !committed && session.pending.includes(operation) ? now.pendingEdit : undefined,
			editFailure: failure,
			...(committed && untouched ? { text, edited: true } : {}),
		});
		if (untouched) installed = current();
	};
	try {
		await session.execute(operation, () => session.command("editLine", args, operation), async (command) => {
			await command.result();
			patch(true);
			session.finish(command);
			await after();
		});
	} catch (error) {
		patch(false, refusalText(error));
		// The line owns this refusal, including an unknown retained outcome.
	}
}
