// The operator inventory's row and page wire forms, both directions.
//
// Every row a directory's operator capability answers is declared here once:
// the schema that bounds it, the parser that admits its passable tuple, and
// the encoder that renders it back for a durable session facet. Keeping the
// two directions beside each other is the point of the module: they are one
// wire form, and holding them apart is how the sessions row once grew a
// caller mark on the parsing side that the encoding side did not send.

import type { Argument } from "@pancake/runtime";
import * as z from "zod/mini";
import { MAX_OPERATOR_PAGE, MAX_TROUBLE_REASON_BYTES, MAX_TROUBLE_SOURCE_BYTES } from "./limits.ts";
import { boundedText, nonemptyText, nonnegativeSafeInteger, positiveSafeInteger } from "./schema.ts";
import type { OperatorCategory } from "./operator_vocabulary.ts";

export const MAX_OPERATOR_TEXT_CHARS = 64 * 1024;
const operatorText = boundedText(MAX_OPERATOR_TEXT_CHARS);
const operatorName = nonemptyText(MAX_OPERATOR_TEXT_CHARS);
const roomVisibility = z.enum(["listed", "private"]);

export const StewardshipRowSchema = z.strictObject({
	name: operatorName,
	label: operatorText,
	visibility: roomVisibility,
	generation: nonnegativeSafeInteger,
	issued: z.boolean(),
	steward: z.nullable(operatorText),
}).check(z.refine((row) => row.issued ? row.steward != null && row.steward !== "" : row.steward == null));

export const OperatorLinkRowSchema = z.strictObject({
	name: operatorName,
	label: operatorText,
	visibility: roomVisibility,
});

export const OperatorRegistrationRowSchema = z.strictObject({
	nick: operatorText,
	sessionId: operatorText,
	/** Whether the holding session is the caller's own connection. */
	you: z.boolean(),
});
export const OperatorSessionRowSchema = z.strictObject({
	id: operatorText,
	transport: operatorText,
	nick: operatorText,
	/** Whether this row is the caller's own connection. */
	you: z.boolean(),
});

export const OperatorRoomRowSchema = z.strictObject({
	id: operatorText,
	kind: z.enum(["local", "private", "peered", "pending-peered", "irc"]),
	name: operatorText,
	origin: operatorText,
	proof: z.enum(["local", "authenticated", "session", "bridge"]),
	retainedCapabilities: z.nullable(nonnegativeSafeInteger),
	members: z.array(z.strictObject({ nick: operatorText, sessionId: operatorText, state: operatorText })).check(
		z.maxLength(MAX_OPERATOR_PAGE),
	),
	membersMore: z.boolean(),
});

export const OperatorReferenceRowSchema = z.strictObject({
	id: operatorName,
	kind: z.enum([
		"membership",
		"line",
		"upload",
		"foreign-room",
		"pending-peering",
		"registration",
		"offered-inbox",
		"signaling",
		"signal-exchange",
	]),
	owner: operatorName,
	room: operatorText,
	member: operatorText,
	detail: operatorName,
});

export const OperatorTroubleRowSchema = z.strictObject({
	source: boundedText(MAX_TROUBLE_SOURCE_BYTES),
	reason: boundedText(MAX_TROUBLE_REASON_BYTES),
	count: positiveSafeInteger,
});

export type StewardshipRow = z.infer<typeof StewardshipRowSchema>;
export type OperatorLinkRow = z.infer<typeof OperatorLinkRowSchema>;
export type OperatorRegistrationRow = z.infer<typeof OperatorRegistrationRowSchema>;
export type OperatorSessionRow = z.infer<typeof OperatorSessionRowSchema>;
export type OperatorRoomRow = z.infer<typeof OperatorRoomRowSchema>;
export type OperatorReferenceRow = z.infer<typeof OperatorReferenceRowSchema>;
export type OperatorRoomKind = OperatorRoomRow["kind"];
export type OperatorTroubleRow = z.infer<typeof OperatorTroubleRowSchema>;

export type OperatorPageRows =
	| StewardshipRow[]
	| OperatorLinkRow[]
	| OperatorRegistrationRow[]
	| OperatorSessionRow[]
	| OperatorRoomRow[]
	| OperatorReferenceRow[]
	| OperatorTroubleRow[];

interface OperatorPageBase {
	revision: bigint;
	next: number | null;
	/** Every row of this category matching the search, whether or not it was
	 * sent. A page is a page; this is what the directory holds. */
	total: number;
}

export type OperatorPage =
	| (OperatorPageBase & { category: "stewardships"; rows: StewardshipRow[] })
	| (OperatorPageBase & { category: "links"; rows: OperatorLinkRow[] })
	| (OperatorPageBase & { category: "registrations"; rows: OperatorRegistrationRow[] })
	| (OperatorPageBase & { category: "sessions"; rows: OperatorSessionRow[] })
	| (OperatorPageBase & { category: "rooms"; rows: OperatorRoomRow[] })
	| (OperatorPageBase & { category: "references"; rows: OperatorReferenceRow[] })
	| (OperatorPageBase & { category: "trouble"; rows: OperatorTroubleRow[] });

/** Admit one stewardship tuple, the row shape `giveSteward` also answers. */
export function parseRow(raw: unknown): StewardshipRow | null {
	if (!Array.isArray(raw) || raw.length !== 6) return null;
	const [name, label, visibility, generation, issued, steward] = raw;
	if (
		typeof name !== "string" || name === "" || typeof label !== "string" ||
		(visibility !== "listed" && visibility !== "private") || typeof generation !== "bigint" ||
		generation < 0n || generation > BigInt(Number.MAX_SAFE_INTEGER) || typeof issued !== "boolean" ||
		(steward !== null && typeof steward !== "string")
	) return null;
	if (issued ? typeof steward !== "string" || steward === "" : steward !== null) return null;
	const parsed = z.safeParse(StewardshipRowSchema, {
		name,
		label,
		visibility,
		generation: Number(generation),
		issued,
		steward,
	});
	return parsed.success ? parsed.data : null;
}

function parseRows(raw: unknown): StewardshipRow[] {
	if (!Array.isArray(raw) || raw.length > MAX_OPERATOR_PAGE) {
		throw new Error("the Rooms operator did not answer a bounded moderator-authority list");
	}
	const rows: StewardshipRow[] = [];
	for (const rawRow of raw) {
		const row = parseRow(rawRow);
		if (row == null) throw new Error("the Rooms operator answered an invalid moderator-authority row");
		rows.push(row);
	}
	return rows;
}

/** Rows of `width` strings closed by one boolean, the caller-connection mark. */
function markedRows<T>(
	raw: unknown,
	width: number,
	make: (row: string[], you: boolean) => unknown,
	schema: z.ZodMiniType<T>,
): T[] {
	if (!Array.isArray(raw) || raw.length > MAX_OPERATOR_PAGE) {
		throw new Error("the Rooms operator answered an invalid inventory");
	}
	return raw.map((entry) => {
		if (
			!Array.isArray(entry) || entry.length !== width + 1 ||
			entry.slice(0, width).some((value) => typeof value !== "string") ||
			typeof entry[width] !== "boolean"
		) {
			throw new Error("the Rooms operator answered an invalid inventory row");
		}
		const parsed = z.safeParse(schema, make(entry.slice(0, width) as string[], entry[width]));
		if (!parsed.success) throw new Error("the Rooms operator answered an out-of-bounds inventory row");
		return parsed.data;
	});
}

function stringRows<T>(
	raw: unknown,
	width: number,
	make: (row: string[]) => unknown,
	schema: z.ZodMiniType<T>,
): T[] {
	if (!Array.isArray(raw) || raw.length > MAX_OPERATOR_PAGE) {
		throw new Error("the Rooms operator answered an invalid inventory");
	}
	return raw.map((entry) => {
		if (!Array.isArray(entry) || entry.length !== width || entry.some((value) => typeof value !== "string")) {
			throw new Error("the Rooms operator answered an invalid inventory row");
		}
		const parsed = z.safeParse(schema, make(entry as string[]));
		if (!parsed.success) throw new Error("the Rooms operator answered an out-of-bounds inventory row");
		return parsed.data;
	});
}

function parseCategoryRows(category: OperatorCategory, raw: unknown): OperatorPageRows {
	if (category === "stewardships") return parseRows(raw);
	if (category === "links") {
		return stringRows(raw, 3, ([name, label, visibility]) => {
			if (visibility !== "listed" && visibility !== "private") throw new Error("invalid room-link visibility");
			return { name, label, visibility };
		}, OperatorLinkRowSchema);
	}
	if (category === "registrations") {
		return markedRows(
			raw,
			2,
			([nick, sessionId], you) => ({ nick, sessionId, you }),
			OperatorRegistrationRowSchema,
		);
	}
	if (category === "sessions") {
		return markedRows(
			raw,
			3,
			([id, transport, nick], you) => ({ id, transport, nick, you }),
			OperatorSessionRowSchema,
		);
	}
	if (!Array.isArray(raw) || raw.length > MAX_OPERATOR_PAGE) {
		throw new Error("the Rooms operator answered an invalid category page");
	}
	if (category === "rooms") {
		const rows = raw.map(parseOperatorRoom);
		if (rows.some((row) => row == null)) throw new Error("the Rooms operator answered an invalid room page");
		return rows as OperatorRoomRow[];
	}
	if (category === "references") {
		const rows = raw.map((entry) => {
			if (!Array.isArray(entry) || entry.length !== 6 || entry.some((value) => typeof value !== "string")) {
				return null;
			}
			const [id, kind, owner, room, member, detail] = entry;
			const parsed = z.safeParse(OperatorReferenceRowSchema, { id, kind, owner, room, member, detail });
			return parsed.success ? parsed.data : null;
		});
		if (rows.some((row) => row === null)) throw new Error("the Rooms operator answered an invalid reference page");
		return rows as OperatorReferenceRow[];
	}
	const rows = raw.map(parseOperatorTrouble);
	if (rows.some((row) => row == null)) throw new Error("the Rooms operator answered an invalid trouble page");
	return rows as OperatorTroubleRow[];
}

export function parseOperatorPageAnswer(category: OperatorCategory, raw: unknown): OperatorPage {
	if (
		!Array.isArray(raw) || raw.length !== 4 || typeof raw[0] !== "bigint" || raw[0] < 0n ||
		(raw[1] !== null && (typeof raw[1] !== "bigint" || raw[1] < 0n || raw[1] > BigInt(Number.MAX_SAFE_INTEGER))) ||
		typeof raw[3] !== "bigint" || raw[3] < 0n || raw[3] > BigInt(Number.MAX_SAFE_INTEGER)
	) throw new Error("the Rooms operator answered an invalid snapshot page");
	const revision = raw[0];
	const next = raw[1] == null ? null : Number(raw[1]);
	const total = Number(raw[3]);
	const rows = parseCategoryRows(category, raw[2]);
	if (category === "stewardships") return { category, revision, next, total, rows: rows as StewardshipRow[] };
	if (category === "links") return { category, revision, next, total, rows: rows as OperatorLinkRow[] };
	if (category === "registrations") {
		return { category, revision, next, total, rows: rows as OperatorRegistrationRow[] };
	}
	if (category === "sessions") return { category, revision, next, total, rows: rows as OperatorSessionRow[] };
	if (category === "rooms") return { category, revision, next, total, rows: rows as OperatorRoomRow[] };
	if (category === "references") return { category, revision, next, total, rows: rows as OperatorReferenceRow[] };
	return { category, revision, next, total, rows: rows as OperatorTroubleRow[] };
}

/** Encode a validated operator page back into its passable tuple. Durable
 * session facets use this instead of defining a second inventory schema. */
export function operatorPageAnswer(page: OperatorPage): Argument {
	const rows: Argument[] = page.rows.map((raw) => {
		if (page.category === "stewardships") {
			const row = raw as StewardshipRow;
			return [row.name, row.label, row.visibility, BigInt(row.generation), row.issued, row.steward];
		}
		if (page.category === "links") {
			const row = raw as OperatorLinkRow;
			return [row.name, row.label, row.visibility];
		}
		if (page.category === "registrations") {
			const row = raw as OperatorRegistrationRow;
			return [row.nick, row.sessionId, row.you];
		}
		if (page.category === "sessions") {
			const row = raw as OperatorSessionRow;
			return [row.id, row.transport, row.nick, row.you];
		}
		if (page.category === "rooms") {
			const row = raw as OperatorRoomRow;
			return [
				row.id,
				row.kind,
				row.name,
				row.origin,
				row.proof,
				row.retainedCapabilities == null ? null : BigInt(row.retainedCapabilities),
				row.members.map((member) => [member.nick, member.sessionId, member.state]),
				row.membersMore,
			];
		}
		if (page.category === "references") {
			const row = raw as OperatorReferenceRow;
			return [row.id, row.kind, row.owner, row.room, row.member, row.detail];
		}
		const row = raw as OperatorTroubleRow;
		return [row.source, row.reason, BigInt(row.count)];
	});
	return [page.revision, page.next == null ? null : BigInt(page.next), rows, BigInt(page.total)];
}

function parseOperatorRoom(raw: unknown): OperatorRoomRow | null {
	if (!Array.isArray(raw) || raw.length !== 8) return null;
	const [id, kind, name, origin, proof, retained, rawMembers, membersMore] = raw;
	if (
		typeof id !== "string" || id === "" ||
		(kind !== "local" && kind !== "private" && kind !== "peered" && kind !== "pending-peered" && kind !== "irc") ||
		typeof name !== "string" || typeof origin !== "string" ||
		(proof !== "local" && proof !== "authenticated" && proof !== "session" && proof !== "bridge") ||
		(retained !== null &&
			(typeof retained !== "bigint" || retained < 0n || retained > BigInt(Number.MAX_SAFE_INTEGER))) ||
		!Array.isArray(rawMembers) || rawMembers.length > MAX_OPERATOR_PAGE || typeof membersMore !== "boolean"
	) return null;
	const members = rawMembers.map((member) => {
		if (
			!Array.isArray(member) || member.length !== 3 ||
			typeof member[0] !== "string" || typeof member[1] !== "string" || typeof member[2] !== "string"
		) return null;
		return { nick: member[0], sessionId: member[1], state: member[2] };
	});
	if (members.some((member) => member === null)) return null;
	const parsed = z.safeParse(OperatorRoomRowSchema, {
		id,
		kind,
		name,
		origin,
		proof,
		retainedCapabilities: retained === null ? null : Number(retained),
		members: members as { nick: string; sessionId: string; state: string }[],
		membersMore,
	});
	return parsed.success ? parsed.data : null;
}

function parseOperatorTrouble(raw: unknown): OperatorTroubleRow | null {
	if (
		!Array.isArray(raw) || raw.length !== 3 || typeof raw[0] !== "string" || typeof raw[1] !== "string" ||
		typeof raw[2] !== "bigint" || raw[2] < 1n || raw[2] > BigInt(Number.MAX_SAFE_INTEGER)
	) return null;
	const encoder = new TextEncoder();
	if (
		encoder.encode(raw[0]).length > MAX_TROUBLE_SOURCE_BYTES ||
		encoder.encode(raw[1]).length > MAX_TROUBLE_REASON_BYTES
	) {
		return null;
	}
	const parsed = z.safeParse(OperatorTroubleRowSchema, {
		source: raw[0],
		reason: raw[1],
		count: Number(raw[2]),
	});
	return parsed.success ? parsed.data : null;
}
