// Delivery is permanent evidence. A numeric line name is usable only while
// the exact field acquired from that receipt remains in the same membership.
import * as z from "zod/mini";
import { conversationIdentity, HistoryCoordinateSchema, type WorkspaceSnapshot } from "./model.ts";

/** The schema is the one definition of a command's line receipt: the type
 * and the validator both derive from it. A receipt may omit fields. It may
 * not lie about them. */
export const LineResultSchema = z.object({
	id: z.optional(z.nullable(z.number())),
	line: z.optional(z.nullable(z.string())),
	history: z.optional(z.nullable(HistoryCoordinateSchema)),
});
export type LineResult = z.infer<typeof LineResultSchema>;

/** Whether a command receipt has the line-result shape. */
export function isLineResult(raw: unknown): raw is LineResult {
	return z.safeParse(LineResultSchema, raw).success;
}
export interface LineAdoption {
	conversation: string;
	identity: string;
	inbox?: string;
	handle: string;
}

export class CompletedLine {
	constructor(readonly result: LineResult | null, readonly adoption?: LineAdoption) {}
	/** Read immediately before presentation, with no asynchronous work between. */
	receipt(snapshot: WorkspaceSnapshot | null) {
		const row = snapshot?.intent.conversations.find((row) => row.id === this.adoption?.conversation);
		const live = row != null && this.adoption != null &&
			conversationIdentity(row) === this.adoption.identity && row.inbox === this.adoption.inbox &&
			(row.kind === "room" ? row.seat != null : !row.closed) &&
			row.lines?.some((line) => line.id === this.result?.id && line.handle === this.adoption!.handle) === true;
		return { id: live ? this.result?.id ?? undefined : undefined, history: this.result?.history, held: live };
	}
}
