// The client side of the Rooms operator capability.

import { type Ref, retainCleanupFailures, type Session } from "@pancake/runtime";
import * as z from "zod/mini";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";
import {
	MAX_OPERATOR_PAGE,
	MAX_OPERATOR_QUERY,
	MAX_OPERATOR_RETIRE_BATCH,
	MAX_TROUBLE_REASON_BYTES,
	MAX_TROUBLE_SOURCE_BYTES,
} from "./limits.ts";
import { boundedText, nonemptyText, nonnegativeSafeInteger, positiveSafeInteger } from "./schema.ts";
import {
	CLEAR_OPERATOR_TROUBLE,
	DISCONNECT_SESSION,
	GIVE_STEWARD,
	isOperatorCategory,
	OPERATOR_CATEGORIES,
	OPERATOR_CHANGED,
	OPERATOR_RETIRE_MATCHING,
	OPERATOR_SNAPSHOT,
	OPERATOR_UNWATCH,
	OPERATOR_WATCH,
	type OperatorCategory,
	RELEASE_OPERATOR_REFERENCE,
	REMOVE_OPERATOR_ROOM,
	RESET_OPERATOR_SCOPE,
	REVOKE_NICK,
	REVOKE_ROOM_LINK,
	REVOKE_STEWARD,
} from "./protocol.ts";
import { cleanupSettledBySessionClose } from "./capability_cleanup.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";

export { isOperatorCategory, OPERATOR_CATEGORIES, type OperatorCategory } from "./protocol.ts";

const MAX_OPERATOR_TEXT_CHARS = 64 * 1024;
const MAX_OPERATOR_SNAPSHOT_CHARS = 512 * 1024;
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

export const OperatorRegistrationRowSchema = z.strictObject({ nick: operatorText, sessionId: operatorText });
export const OperatorSessionRowSchema = z.strictObject({
	id: operatorText,
	transport: operatorText,
	nick: operatorText,
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

export type OperatorResetScope = "links" | "registrations" | "sessions" | "rooms" | "runtime" | "all";

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
	 * or not it was sent. The pane's counts and its bulk acts speak from this;
	 * the row arrays are one page. */
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

function parseRow(raw: unknown): StewardshipRow | null {
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
		return stringRows(raw, 2, ([nick, sessionId]) => ({ nick, sessionId }), OperatorRegistrationRowSchema);
	}
	if (category === "sessions") {
		return stringRows(raw, 3, ([id, transport, nick]) => ({ id, transport, nick }), OperatorSessionRowSchema);
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

export async function operatorPage(
	session: Session,
	cap: Ref,
	category: OperatorCategory,
	cursor = 0,
	query = "",
): Promise<OperatorPage> {
	const raw = await ask(
		session,
		cap,
		OPERATOR_SNAPSHOT,
		[category, BigInt(cursor), BigInt(MAX_OPERATOR_PAGE), query.slice(0, MAX_OPERATOR_QUERY)],
		"the Rooms operator did not answer",
	);
	return parseOperatorPageAnswer(category, raw);
}

/** What one bounded sweep of a bulk retire did. `remaining` is what still
 * matches the search after it, so a caller runs again until it is zero, and a
 * reader watches a real number fall. */
export interface OperatorRetireBatch {
	retired: number;
	remaining: number;
	/** The first row-level refusal this sweep met, or empty. */
	refused: string;
}

export async function operatorRetireMatching(
	session: Session,
	cap: Ref,
	category: OperatorCategory,
	query: string,
	limit = MAX_OPERATOR_RETIRE_BATCH,
): Promise<OperatorRetireBatch> {
	const raw = await ask(
		session,
		cap,
		OPERATOR_RETIRE_MATCHING,
		[category, query.slice(0, MAX_OPERATOR_QUERY), BigInt(Math.min(limit, MAX_OPERATOR_RETIRE_BATCH))],
		"the Rooms operator did not answer",
	);
	return parseOperatorRetireAnswer(raw);
}

/** The answer a bulk retire gives, whether it came from the operator itself or
 * was relayed by a durable session. */
export function parseOperatorRetireAnswer(raw: unknown): OperatorRetireBatch {
	if (
		!Array.isArray(raw) || raw.length !== 3 || typeof raw[0] !== "bigint" || typeof raw[1] !== "bigint" ||
		typeof raw[2] !== "string" || raw[0] < 0n || raw[1] < 0n
	) throw new Error("the Rooms operator answered an invalid retire batch");
	return { retired: Number(raw[0]), remaining: Number(raw[1]), refused: raw[2] };
}

/** Encode a retire batch back into its passable tuple, for a durable session
 * relaying the operator's own answer. */
export function operatorRetireAnswer(batch: OperatorRetireBatch): import("@pancake/runtime").Argument {
	return [BigInt(batch.retired), BigInt(batch.remaining), batch.refused];
}

export async function snapshotOperator(session: Session, cap: Ref, query = ""): Promise<OperatorSnapshot> {
	const raw = await ask(
		session,
		cap,
		OPERATOR_SNAPSHOT,
		query === "" ? [] : [query.slice(0, MAX_OPERATOR_QUERY)],
		"the Rooms operator did not answer",
	);
	if (
		!Array.isArray(raw) || raw.length !== 2 || typeof raw[0] !== "bigint" || raw[0] < 0n ||
		!Array.isArray(raw[1]) || raw[1].length !== OPERATOR_CATEGORIES.length
	) {
		throw new Error("the Rooms operator answered an invalid snapshot");
	}
	const revision = raw[0];
	const byCategory = new Map<OperatorCategory, OperatorPage>();
	for (const rawPage of raw[1]) {
		if (!Array.isArray(rawPage) || rawPage.length !== 4 || !isOperatorCategory(rawPage[0])) {
			throw new Error("the Rooms operator answered an invalid snapshot category");
		}
		const category = rawPage[0];
		if (byCategory.has(category)) throw new Error("the Rooms operator repeated a snapshot category");
		byCategory.set(category, parseOperatorPageAnswer(category, [revision, rawPage[1], rawPage[2], rawPage[3]]));
	}
	if (byCategory.size !== OPERATOR_CATEGORIES.length) {
		throw new Error("the Rooms operator omitted a snapshot category");
	}
	const page = (category: OperatorCategory): OperatorPage => {
		const found = byCategory.get(category);
		if (found == null) throw new Error(`the Rooms operator omitted the ${category} snapshot`);
		return found;
	};
	return {
		revision,
		stewardships: page("stewardships").rows as StewardshipRow[],
		links: page("links").rows as OperatorLinkRow[],
		registrations: page("registrations").rows as OperatorRegistrationRow[],
		sessions: page("sessions").rows as OperatorSessionRow[],
		rooms: page("rooms").rows as OperatorRoomRow[],
		references: page("references").rows as OperatorReferenceRow[],
		trouble: page("trouble").rows as OperatorTroubleRow[],
		next: Object.fromEntries(
			OPERATOR_CATEGORIES.map((category) => [category, page(category).next]),
		) as Record<OperatorCategory, number | null>,
		totals: Object.fromEntries(
			OPERATOR_CATEGORIES.map((category) => [category, page(category).total]),
		) as Record<OperatorCategory, number>,
	};
}

/** Subscribe one operator holder to monotonic inventory revisions. The returned
 * stop action removes the server watcher before the caller releases the cap. */
export async function subscribeOperator(
	session: Session,
	cap: Ref,
	changed: (revision: bigint) => void,
): Promise<() => void> {
	const observer = session.spawn((verb, args) => {
		releaseUnclaimedCapabilityArguments(
			session,
			args,
			"the Rooms operator observer could not return an unexpected capability",
		);
		if (verb !== OPERATOR_CHANGED || args.length !== 1 || typeof args[0] !== "bigint" || args[0] < 0n) {
			throw new Error("the Rooms operator sent an invalid revision notification");
		}
		changed(args[0]);
		return null;
	});
	try {
		const raw = await ask(session, cap, OPERATOR_WATCH, [observer], "the Rooms operator did not accept watching");
		if (typeof raw !== "bigint" || raw < 0n) {
			throw new Error("the Rooms operator answered an invalid watch revision");
		}
		session.release(observer);
		let stopped = false;
		return () => {
			if (stopped) return;
			stopped = true;
			void ask(session, cap, OPERATOR_UNWATCH, [], "the Rooms operator did not stop watching").catch((error) => {
				if (cleanupSettledBySessionClose(error)) return;
				console.error(
					`Rooms operator watcher cleanup failed: ${error instanceof Error ? error.message : error}`,
				);
			});
		};
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(observer)]);
	}
}

/** Encode a validated operator page back into its passable tuple. Durable
 * session facets use this instead of defining a second inventory schema. */
export function operatorPageAnswer(page: OperatorPage): import("@pancake/runtime").Argument {
	const rows: import("@pancake/runtime").Argument[] = page.rows.map((raw) => {
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
			return [row.nick, row.sessionId];
		}
		if (page.category === "sessions") {
			const row = raw as OperatorSessionRow;
			return [row.id, row.transport, row.nick];
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

/** Fetch the operator capability and take its first inventory. */
export async function takeRoomsOperator(session: Session, pasted: string): Promise<{
	cap: Ref;
	snapshot: OperatorSnapshot;
}> {
	const { cap, taken } = await takeOperationsCap(session, pasted, (fetched) => snapshotOperator(session, fetched));
	return { cap, snapshot: taken };
}

export async function revokeRoomLink(session: Session, cap: Ref, name: string): Promise<void> {
	await ask(session, cap, REVOKE_ROOM_LINK, [name], "the Rooms operator did not revoke the room link");
}

export async function revokeNick(session: Session, cap: Ref, nick: string, sessionId: string): Promise<void> {
	await ask(session, cap, REVOKE_NICK, [nick, sessionId], "the Rooms operator did not revoke the nickname");
}

export async function disconnectSession(session: Session, cap: Ref, id: string): Promise<void> {
	await ask(session, cap, DISCONNECT_SESSION, [id], "the Rooms operator did not disconnect the session");
}

export async function removeOperatorRoom(session: Session, cap: Ref, id: string): Promise<void> {
	await ask(session, cap, REMOVE_OPERATOR_ROOM, [id], "the Rooms operator did not remove the room");
}

export async function releaseOperatorReference(session: Session, cap: Ref, id: string): Promise<void> {
	await ask(session, cap, RELEASE_OPERATOR_REFERENCE, [id], "the Rooms operator did not release the reference");
}

export async function clearOperatorTrouble(session: Session, cap: Ref): Promise<void> {
	await ask(session, cap, CLEAR_OPERATOR_TROUBLE, [], "the Rooms operator did not clear trouble");
}

export async function resetOperatorScope(
	session: Session,
	cap: Ref,
	scope: OperatorResetScope,
): Promise<void> {
	await ask(session, cap, RESET_OPERATOR_SCOPE, [scope], "the Rooms operator did not reset the scope");
}

export async function giveStewardship(session: Session, cap: Ref, name: string): Promise<StewardshipRow> {
	const row = parseRow(
		await ask(session, cap, GIVE_STEWARD, [name], `the Rooms operator did not give stewardship for "${name}"`),
	);
	if (row === null) throw new Error("the Rooms operator answered give without a stewardship row");
	return row;
}

export async function revokeStewardship(session: Session, cap: Ref, name: string): Promise<StewardshipRow> {
	const row = parseRow(
		await ask(
			session,
			cap,
			REVOKE_STEWARD,
			[name],
			`the Rooms operator did not revoke stewardship for "${name}"`,
		),
	);
	if (row === null) throw new Error("the Rooms operator answered revoke without a stewardship row");
	return row;
}
