// History notifications carry only a scope; clients reread committed records.
import { MAX_ARCHIVE_CONTEXT_BYTES, MAX_ARCHIVE_CONVERSATION_BYTES } from "../archive/protocol.ts";
import { utf8Fits } from "../limits.ts";

/** null invalidates every conversation, including after a notification gap. */
export type HistoryChange = {
	readonly kind: "room" | "direct";
	readonly directory: string;
	readonly conversation: string;
} | null;

export function parseHistoryChange(args: readonly unknown[]): HistoryChange {
	if (args.length === 0) return null;
	const [kind, directory, conversation] = args;
	if (
		args.length !== 3 || (kind !== "room" && kind !== "direct") ||
		typeof directory !== "string" || directory.length === 0 || !utf8Fits(directory, MAX_ARCHIVE_CONTEXT_BYTES) ||
		typeof conversation !== "string" || conversation.length === 0 ||
		!utf8Fits(conversation, MAX_ARCHIVE_CONVERSATION_BYTES)
	) {
		throw new Error("the Rooms session sent an invalid history invalidation");
	}
	return { kind, directory, conversation };
}
