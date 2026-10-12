// A line this reader sent, named by its commit receipt and settled by result
// acquisition, with the room's echo of it folded into the one bubble.

import type { HistoryCoordinate } from "../types.ts";
import type { PageProjection } from "./core.ts";
import { foldLine, historyOf, lineByCoordinate, lineByLineId, updateItem } from "./items.ts";

/** The room's names for a committed send. */
export interface SentLineReceipt {
	id?: number;
	history?: HistoryCoordinate | null;
}

/** Commit observation proves delivery before returned names or controls can be
 * read. Consume the operation association without inventing either identity. */
export function confirmSentOperations(projection: PageProjection, operations: ReadonlySet<string>): void {
	for (const [key, history] of projection.get().histories) {
		for (const item of history) {
			if (item.kind !== "chat" || item.operation == null || !operations.has(item.operation)) continue;
			updateItem(projection, key, item.id, {
				state: undefined,
				awaitingReceipt: undefined,
				correlation: item.correlation ?? item.operation,
				operation: undefined,
				retryable: undefined,
			});
		}
	}
}

/** Settle delivery after acquisition. Only an acquired live field permits a
 * numeric name. Archive coordinates remain exact after membership retirement. */
export function confirmSentLine(
	projection: PageProjection,
	key: string,
	id: number,
	receipt: SentLineReceipt & { held: boolean },
): void {
	const history = historyOf(projection, key);
	const original = history.find((item) => item.id === id && item.kind === "chat");
	if (original?.kind !== "chat") return;
	const conversation = projection.get().convs.get(key);
	// An ended notice can retire membership before the next workspace snapshot.
	const liveId = conversation?.type === "room" && conversation.membership !== "joined" ? undefined : receipt.id;
	const echo = receipt.history != null
		? lineByCoordinate(history, receipt.history)
		: liveId == null
		? undefined
		: lineByLineId(history, liveId);
	const named = {
		state: undefined,
		awaitingReceipt: undefined,
		operation: undefined,
		correlation: liveId != null || receipt.history != null ? undefined : original.correlation ?? original.operation,
		retryable: undefined,
		// An archive match may already have a live name from the current
		// membership. An older receipt cannot take that identity away.
		lineId: liveId ?? echo?.lineId,
		held: liveId == null ? echo?.held ?? false : receipt.held,
		...(receipt.history == null ? {} : { history: receipt.history }),
	};
	if (echo == null || echo.id === id || (receipt.history == null && !echo.mine)) {
		updateItem(projection, key, id, named);
		return;
	}
	foldLine(projection, key, original, { ...echo, ...named, id, at: original.at, mine: original.mine }, echo);
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
