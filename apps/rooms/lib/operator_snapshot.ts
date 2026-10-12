// Bounded operator facts shared by protocol clients and managed presentation.
import * as z from "zod/mini";
import { MAX_OPERATOR_PAGE } from "./limits.ts";
import { nonnegativeSafeInteger } from "./schema.ts";
import type { OperatorCategory } from "./operator_vocabulary.ts";
import {
	type OperatorLinkRow,
	OperatorLinkRowSchema,
	type OperatorReferenceRow,
	OperatorReferenceRowSchema,
	type OperatorRegistrationRow,
	OperatorRegistrationRowSchema,
	type OperatorRoomRow,
	OperatorRoomRowSchema,
	type OperatorSessionRow,
	OperatorSessionRowSchema,
	type OperatorTroubleRow,
	OperatorTroubleRowSchema,
	type StewardshipRow,
	StewardshipRowSchema,
} from "./operator_rows.ts";
const MAX_OPERATOR_SNAPSHOT_CHARS = 512 * 1024;

export interface OperatorSnapshot {
	revision: bigint;
	stewardships: StewardshipRow[];
	links: OperatorLinkRow[];
	registrations: OperatorRegistrationRow[];
	sessions: OperatorSessionRow[];
	rooms: OperatorRoomRow[];
	references: OperatorReferenceRow[];
	trouble: OperatorTroubleRow[];
	next: Record<OperatorCategory, number | null>;
	/** Every row each category holds that matches the search in force, whether
	 * or not it was sent. The page's counts and its bulk acts speak from this,
	 * and the row arrays are one page. */
	totals: Record<OperatorCategory, number>;
}

export const OperatorSnapshotJsonSchema = z.strictObject({
	revision: z.string().check(z.maxLength(32), z.regex(/^\d+$/)),
	stewardships: z.array(StewardshipRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	links: z.array(OperatorLinkRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	registrations: z.array(OperatorRegistrationRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	sessions: z.array(OperatorSessionRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	rooms: z.array(OperatorRoomRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	references: z.array(OperatorReferenceRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	trouble: z.array(OperatorTroubleRowSchema).check(z.maxLength(MAX_OPERATOR_PAGE)),
	next: z.strictObject({
		stewardships: z.nullable(nonnegativeSafeInteger),
		links: z.nullable(nonnegativeSafeInteger),
		registrations: z.nullable(nonnegativeSafeInteger),
		sessions: z.nullable(nonnegativeSafeInteger),
		rooms: z.nullable(nonnegativeSafeInteger),
		references: z.nullable(nonnegativeSafeInteger),
		trouble: z.nullable(nonnegativeSafeInteger),
	}),
	totals: z.strictObject({
		stewardships: nonnegativeSafeInteger,
		links: nonnegativeSafeInteger,
		registrations: nonnegativeSafeInteger,
		sessions: nonnegativeSafeInteger,
		rooms: nonnegativeSafeInteger,
		references: nonnegativeSafeInteger,
		trouble: nonnegativeSafeInteger,
	}),
});

export function parseOperatorSnapshotJson(raw: string): OperatorSnapshot {
	if (raw.length > MAX_OPERATOR_SNAPSHOT_CHARS) {
		throw new Error("the Rooms session answered operator state beyond its size limit");
	}
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error("the Rooms session answered operator state that is not JSON");
	}
	const parsed = z.safeParse(OperatorSnapshotJsonSchema, decoded);
	if (!parsed.success) {
		throw new Error(`the Rooms session answered invalid operator state:\n${z.prettifyError(parsed.error)}`);
	}
	return { ...parsed.data, revision: BigInt(parsed.data.revision) };
}
