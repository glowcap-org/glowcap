// The operator inventory's row and page wire forms, both directions.
//
// Every row a directory's operator capability answers is declared here once:
// the schema that bounds it, the parser that admits its passable tuple, and
// the encoder that renders it back for a durable session facet. The two
// directions sit together because they are one wire form. Holding them apart
// would let one side carry a field the other never sends.

import type { Argument } from "@glowcap/runtime";
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
	steward: z.nullable(operatorText),
	manager: z.nullable(operatorText),
	/** Whether an IRC bridge runs the room, so it takes a moderator link and no
	 * manager link, and only the bridge removes it. */
	bridged: z.boolean(),
}).check(
	z.refine((row) => row.steward !== "" && row.manager !== ""),
);

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

/** The rows each category's page carries. */
export interface OperatorRowsByCategory {
	stewardships: StewardshipRow[];
	links: OperatorLinkRow[];
	registrations: OperatorRegistrationRow[];
	sessions: OperatorSessionRow[];
	rooms: OperatorRoomRow[];
	references: OperatorReferenceRow[];
	trouble: OperatorTroubleRow[];
}

export type OperatorPageRows = OperatorRowsByCategory[OperatorCategory];

interface OperatorPageBase {
	revision: bigint;
	next: number | null;
	/** Every row of this category matching the search, whether or not it was
	 * sent. A page is a page, and this is what the directory holds. */
	total: number;
}

/** One category's page. */
export type OperatorPageOf<C extends OperatorCategory> = OperatorPageBase & {
	category: C;
	rows: OperatorRowsByCategory[C];
};

export type OperatorPage = { [C in OperatorCategory]: OperatorPageOf<C> }[OperatorCategory];

/** Admit one stewardship tuple, the row shape `giveSteward` also answers. */
export function parseRow(raw: unknown): StewardshipRow | null {
	if (!Array.isArray(raw) || raw.length !== 7) return null;
	const [name, label, visibility, generation, steward, manager, bridged] = raw;
	if (
		typeof name !== "string" || name === "" || typeof label !== "string" ||
		(visibility !== "listed" && visibility !== "private") || typeof generation !== "bigint" ||
		generation < 0n || generation > BigInt(Number.MAX_SAFE_INTEGER) ||
		(manager !== null && typeof manager !== "string") || (steward !== null && typeof steward !== "string") ||
		typeof bridged !== "boolean"
	) return null;
	const parsed = z.safeParse(StewardshipRowSchema, {
		name,
		label,
		visibility,
		generation: Number(generation),
		steward,
		manager,
		bridged,
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

/** `entry` as strings, or null when any of it is not one. */
function strings(entry: readonly unknown[]): string[] | null {
	const out: string[] = [];
	for (const value of entry) {
		if (typeof value !== "string") return null;
		out.push(value);
	}
	return out;
}

/** Every row of a bounded page, or a refusal naming the page. */
function pageRows<T>(raw: unknown, parse: (entry: unknown) => T | null, what: string): T[] {
	if (!Array.isArray(raw) || raw.length > MAX_OPERATOR_PAGE) {
		throw new Error("the Rooms operator answered an invalid category page");
	}
	const rows: T[] = [];
	for (const entry of raw) {
		const row = parse(entry);
		if (row == null) throw new Error(`the Rooms operator answered an invalid ${what} page`);
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
		const row = Array.isArray(entry) && entry.length === width + 1 ? strings(entry.slice(0, width)) : null;
		const you = Array.isArray(entry) ? entry[width] : undefined;
		if (row == null || typeof you !== "boolean") {
			throw new Error("the Rooms operator answered an invalid inventory row");
		}
		const parsed = z.safeParse(schema, make(row, you));
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
		const row = Array.isArray(entry) && entry.length === width ? strings(entry) : null;
		if (row == null) throw new Error("the Rooms operator answered an invalid inventory row");
		const parsed = z.safeParse(schema, make(row));
		if (!parsed.success) throw new Error("the Rooms operator answered an out-of-bounds inventory row");
		return parsed.data;
	});
}

function parseReference(entry: unknown): OperatorReferenceRow | null {
	const row = Array.isArray(entry) && entry.length === 6 ? strings(entry) : null;
	if (row == null) return null;
	const [id, kind, owner, room, member, detail] = row;
	const parsed = z.safeParse(OperatorReferenceRowSchema, { id, kind, owner, room, member, detail });
	return parsed.success ? parsed.data : null;
}

/** Each category's row parser, keyed so a category's rows keep its type. */
const ROW_PARSERS: { readonly [C in OperatorCategory]: (raw: unknown) => OperatorRowsByCategory[C] } = {
	stewardships: parseRows,
	links: (raw) =>
		stringRows(raw, 3, ([name, label, visibility]) => {
			if (visibility !== "listed" && visibility !== "private") throw new Error("invalid room-link visibility");
			return { name, label, visibility };
		}, OperatorLinkRowSchema),
	registrations: (raw) =>
		markedRows(raw, 2, ([nick, sessionId], you) => ({ nick, sessionId, you }), OperatorRegistrationRowSchema),
	sessions: (raw) =>
		markedRows(raw, 3, ([id, transport, nick], you) => ({ id, transport, nick, you }), OperatorSessionRowSchema),
	rooms: (raw) => pageRows(raw, parseOperatorRoom, "room"),
	references: (raw) => pageRows(raw, parseReference, "reference"),
	trouble: (raw) => pageRows(raw, parseOperatorTrouble, "trouble"),
};

/** Admit one category's page answer, `[revision, next, rows, total]`. */
export function parseOperatorPageAnswer<C extends OperatorCategory>(category: C, raw: unknown): OperatorPageOf<C> {
	if (
		!Array.isArray(raw) || raw.length !== 4 || typeof raw[0] !== "bigint" || raw[0] < 0n ||
		(raw[1] !== null && (typeof raw[1] !== "bigint" || raw[1] < 0n || raw[1] > BigInt(Number.MAX_SAFE_INTEGER))) ||
		typeof raw[3] !== "bigint" || raw[3] < 0n || raw[3] > BigInt(Number.MAX_SAFE_INTEGER)
	) throw new Error("the Rooms operator answered an invalid snapshot page");
	const next = raw[1] == null ? null : Number(raw[1]);
	return { category, revision: raw[0], next, total: Number(raw[3]), rows: ROW_PARSERS[category](raw[2]) };
}

/** Encode a validated operator page back into its passable tuple. Durable
 * session facets use this instead of defining a second inventory schema. */
export function operatorPageAnswer(page: OperatorPage): Argument {
	return [page.revision, page.next == null ? null : BigInt(page.next), rowsAnswer(page), BigInt(page.total)];
}

function rowsAnswer(page: OperatorPage): Argument[] {
	switch (page.category) {
		case "stewardships":
			return page.rows.map((row) => [
				row.name,
				row.label,
				row.visibility,
				BigInt(row.generation),
				row.steward,
				row.manager,
				row.bridged,
			]);
		case "links":
			return page.rows.map((row) => [row.name, row.label, row.visibility]);
		case "registrations":
			return page.rows.map((row) => [row.nick, row.sessionId, row.you]);
		case "sessions":
			return page.rows.map((row) => [row.id, row.transport, row.nick, row.you]);
		case "rooms":
			return page.rows.map((row) => [
				row.id,
				row.kind,
				row.name,
				row.origin,
				row.proof,
				row.retainedCapabilities == null ? null : BigInt(row.retainedCapabilities),
				row.members.map((member) => [member.nick, member.sessionId, member.state]),
				row.membersMore,
			]);
		case "references":
			return page.rows.map((row) => [row.id, row.kind, row.owner, row.room, row.member, row.detail]);
		case "trouble":
			return page.rows.map((row) => [row.source, row.reason, BigInt(row.count)]);
	}
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
	const members: { nick: string; sessionId: string; state: string }[] = [];
	for (const member of rawMembers) {
		const fields = Array.isArray(member) && member.length === 3 ? strings(member) : null;
		if (fields == null) return null;
		const [nick, sessionId, state] = fields;
		members.push({ nick, sessionId, state });
	}
	const parsed = z.safeParse(OperatorRoomRowSchema, {
		id,
		kind,
		name,
		origin,
		proof,
		retainedCapabilities: retained === null ? null : Number(retained),
		members,
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
