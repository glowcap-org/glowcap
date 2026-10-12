// A withdrawal hides only its own line while the exact receipt settles. The
// accepted line is untouched until commitment, so refusal never restores a snapshot.
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import { refusalText } from "../../../../lib/text/failure.ts";

export async function withdrawLine(
	page: RoomsPageContext,
	session: ManagedRoomsSession,
	key: string,
	id: number,
): Promise<void> {
	const projection = page.projection;
	const row = store.getConv(projection, key);
	const item = store.historyOf(projection, key).find((line) => line.id === id);
	if (row == null || row.type === "directory" || item?.kind !== "chat" || item.lineId == null || item.withdrawn) {
		return;
	}
	if (item.withdrawal != null) {
		if (session.recoverable.includes(item.withdrawal)) await session.completeOperation(item.withdrawal);
		return;
	}
	const operation = crypto.randomUUID();
	const current = () => store.historyOf(projection, key).find((line) => line.id === id);
	const patch = (fields: Partial<typeof item>) => {
		const now = current();
		if (now?.kind === "chat" && now.lineId === item.lineId && now.withdrawal === operation) {
			store.updateItem(projection, key, id, fields);
		}
	};
	session.effects.reserve(operation, "withdrawLine", [row.persistId, String(item.lineId)]);
	store.updateItem(projection, key, id, { withdrawal: operation, withdrawalFailure: undefined });
	try {
		await session.execute(
			operation,
			() => session.command("withdrawLine", [row.persistId, String(item.lineId)], operation),
			async (command) => {
				await command.result();
				patch({ withdrawn: true, withdrawal: undefined, withdrawalFailure: undefined });
				session.finish(command);
			},
		);
	} catch (error) {
		patch({
			withdrawal: session.pending.includes(operation) ? operation : undefined,
			withdrawalFailure: refusalText(error),
		});
		// The original line owns the refusal; do not repeat it in a toast.
	}
}
