// A line this reader sent, named by its commit receipt and settled by result
// acquisition, with the room's echo of it folded into the one bubble.

import type { ChatItem, HistoryCoordinate } from "../types.ts";
import type { PageProjection } from "./core.ts";
import { foldLine, historyOf, lineByCoordinate, lineByLineId, updateItem } from "./items.ts";

/** The room's names for a committed send. */
export interface SentLineReceipt {
	id: number;
	history?: HistoryCoordinate | null;
}

/** Name a send at its commit receipt, before result acquisition settles it, so
 * the room's echo lands on this bubble. */
export function nameSentLine(projection: PageProjection, key: string, id: number, receipt: SentLineReceipt): void {
	adoptSentLine(projection, key, id, receipt, null);
}

/** The committed receipt identifies the original send, including archive replay
 * or a normalized server echo that arrived first. Transfer that custody once. */
export function confirmSentLine(
	projection: PageProjection,
	key: string,
	id: number,
	receipt: SentLineReceipt & { held: boolean },
): void {
	adoptSentLine(projection, key, id, receipt, {
		state: undefined,
		awaitingReceipt: undefined,
		operation: undefined,
		retryable: undefined,
		held: receipt.held,
	});
}

/** Name the original send and fold in an echo already stored under those names,
 * keeping the original's id and time. Null `settled` keeps its send state. */
function adoptSentLine(
	projection: PageProjection,
	key: string,
	id: number,
	receipt: SentLineReceipt,
	settled: Partial<ChatItem> | null,
): void {
	const history = historyOf(projection, key);
	const original = history.find((item) => item.id === id && item.kind === "chat");
	if (original?.kind !== "chat") return;
	const echo = receipt.history == null
		? lineByLineId(history, receipt.id)
		: lineByCoordinate(history, receipt.history);
	const named = {
		...(settled ?? {}),
		lineId: receipt.id,
		...(receipt.history == null ? {} : { history: receipt.history }),
	};
	if (echo == null || echo.id === id || (receipt.history == null && !echo.mine)) {
		updateItem(projection, key, id, named);
		return;
	}
	const sending = settled != null ? {} : {
		state: original.state,
		awaitingReceipt: original.awaitingReceipt,
		operation: original.operation,
		retryable: original.retryable,
	};
	foldLine(
		projection,
		key,
		original,
		{ ...echo, ...sending, ...named, id, at: original.at, mine: original.mine },
		echo,
	);
}

/** The reader let a send's receipt go. Its outcome stays unknown for good, so
 * the bubble says it was not confirmed and offers no retry. */
export function releaseSentLine(projection: PageProjection, operation: string): void {
	for (const [key, history] of projection.get().histories) {
		for (const item of history) {
			if (item.kind !== "chat" || item.operation !== operation) continue;
			updateItem(projection, key, item.id, {
				state: "unconfirmed",
				awaitingReceipt: undefined,
				operation: undefined,
				retryable: false,
			});
		}
	}
}
