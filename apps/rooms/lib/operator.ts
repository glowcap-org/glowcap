// The client side of the Rooms operator capability.

import { type Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";
import { MAX_OPERATOR_PAGE, MAX_OPERATOR_QUERY, MAX_OPERATOR_RETIRE_BATCH } from "./limits.ts";
import {
	GIVE_MANAGER,
	GIVE_STEWARD,
	OPERATOR_CHANGED,
	OPERATOR_RETIRE_MATCHING,
	OPERATOR_SNAPSHOT,
	OPERATOR_UNWATCH,
	OPERATOR_WATCH,
	REVOKE_STEWARD,
} from "./protocol_operator.ts";
import {
	isOperatorCategory,
	OPERATOR_CATEGORIES,
	type OperatorCategory,
	type OperatorReferenceKind,
} from "./operator_vocabulary.ts";
export {
	clearOperatorTrouble,
	disconnectSession,
	releaseOperatorReference,
	removeOperatorRoom,
	resetOperatorScope,
	revokeNick,
	revokeRoomAuthority,
	revokeRoomLink,
} from "./operator_mutations.ts";
import { cleanupSettledBySessionClose } from "./capability_cleanup.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";

export {
	isOperatorCategory,
	isOperatorReferenceKind,
	OPERATOR_CATEGORIES,
	type OperatorCategory,
	type OperatorReferenceKind,
	type OperatorResetScope,
} from "./operator_vocabulary.ts";

export {
	type OperatorLinkRow,
	OperatorLinkRowSchema,
	type OperatorPage,
	operatorPageAnswer,
	type OperatorPageOf,
	type OperatorPageRows,
	type OperatorReferenceRow,
	OperatorReferenceRowSchema,
	type OperatorRegistrationRow,
	OperatorRegistrationRowSchema,
	type OperatorRoomKind,
	type OperatorRoomRow,
	OperatorRoomRowSchema,
	type OperatorSessionRow,
	OperatorSessionRowSchema,
	type OperatorTroubleRow,
	OperatorTroubleRowSchema,
	parseOperatorPageAnswer,
	type StewardshipRow,
	StewardshipRowSchema,
} from "./operator_rows.ts";
import {
	type OperatorPage,
	type OperatorPageOf,
	parseOperatorPageAnswer,
	parseRow,
	type StewardshipRow,
} from "./operator_rows.ts";

export { type OperatorSnapshot, OperatorSnapshotJsonSchema, parseOperatorSnapshotJson } from "./operator_snapshot.ts";
import type { OperatorSnapshot } from "./operator_snapshot.ts";

export async function operatorPage<C extends OperatorCategory>(
	session: Session,
	cap: Ref,
	category: C,
	cursor = 0,
	query = "",
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorPageOf<C>> {
	const raw = await ask(
		session,
		cap,
		OPERATOR_SNAPSHOT,
		[
			category,
			BigInt(cursor),
			BigInt(MAX_OPERATOR_PAGE),
			query.slice(0, MAX_OPERATOR_QUERY),
			...(category === "references" && referenceKind !== null ? [referenceKind] : []),
		],
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
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorRetireBatch> {
	const raw = await ask(
		session,
		cap,
		OPERATOR_RETIRE_MATCHING,
		[
			category,
			query.slice(0, MAX_OPERATOR_QUERY),
			BigInt(Math.min(limit, MAX_OPERATOR_RETIRE_BATCH)),
			...(category === "references" && referenceKind !== null ? [referenceKind] : []),
		],
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

export async function snapshotOperator(
	session: Session,
	cap: Ref,
	query = "",
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorSnapshot> {
	const raw = await ask(
		session,
		cap,
		OPERATOR_SNAPSHOT,
		referenceKind === null ? (query === "" ? [] : [query.slice(0, MAX_OPERATOR_QUERY)]) : [
			query.slice(0, MAX_OPERATOR_QUERY),
			referenceKind,
		],
		"the Rooms operator did not answer",
	);
	if (
		!Array.isArray(raw) || raw.length !== 2 || typeof raw[0] !== "bigint" || raw[0] < 0n ||
		!Array.isArray(raw[1]) || raw[1].length !== OPERATOR_CATEGORIES.length
	) {
		throw new Error("the Rooms operator answered an invalid snapshot");
	}
	const revision = raw[0];
	const answers = new Map<OperatorCategory, unknown[]>();
	for (const rawPage of raw[1]) {
		if (!Array.isArray(rawPage) || rawPage.length !== 4 || !isOperatorCategory(rawPage[0])) {
			throw new Error("the Rooms operator answered an invalid snapshot category");
		}
		const category = rawPage[0];
		if (answers.has(category)) throw new Error("the Rooms operator repeated a snapshot category");
		answers.set(category, [revision, rawPage[1], rawPage[2], rawPage[3]]);
	}
	if (answers.size !== OPERATOR_CATEGORIES.length) {
		throw new Error("the Rooms operator omitted a snapshot category");
	}
	const page = <C extends OperatorCategory>(category: C): OperatorPageOf<C> => {
		const answer = answers.get(category);
		if (answer == null) throw new Error(`the Rooms operator omitted the ${category} snapshot`);
		return parseOperatorPageAnswer(category, answer);
	};
	const pages = {
		stewardships: page("stewardships"),
		links: page("links"),
		registrations: page("registrations"),
		sessions: page("sessions"),
		rooms: page("rooms"),
		references: page("references"),
		trouble: page("trouble"),
	} satisfies Record<OperatorCategory, OperatorPage>;
	const each = <T>(read: (page: OperatorPage) => T): Record<OperatorCategory, T> => ({
		stewardships: read(pages.stewardships),
		links: read(pages.links),
		registrations: read(pages.registrations),
		sessions: read(pages.sessions),
		rooms: read(pages.rooms),
		references: read(pages.references),
		trouble: read(pages.trouble),
	});
	return {
		revision,
		stewardships: pages.stewardships.rows,
		links: pages.links.rows,
		registrations: pages.registrations.rows,
		sessions: pages.sessions.rows,
		rooms: pages.rooms.rows,
		references: pages.references.rows,
		trouble: pages.trouble.rows,
		next: each((page) => page.next),
		totals: each((page) => page.total),
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
		await retainCleanupFailures(error, [() => session.release(observer)]);
		throw error;
	}
}

/** Fetch the operator capability and take its first inventory. */
export async function takeRoomsOperator(session: Session, pasted: string): Promise<{
	cap: Ref;
	snapshot: OperatorSnapshot;
}> {
	const { cap, taken } = await takeOperationsCap(session, pasted, (fetched) => snapshotOperator(session, fetched));
	return { cap, snapshot: taken };
}

export async function giveStewardship(session: Session, cap: Ref, name: string): Promise<StewardshipRow> {
	const row = parseRow(
		await ask(session, cap, GIVE_STEWARD, [name], `the Rooms operator did not give stewardship for "${name}"`),
	);
	if (row === null) throw new Error("the Rooms operator answered give without a stewardship row");
	return row;
}

export async function giveRoomManager(session: Session, cap: Ref, roomIdentity: string): Promise<string> {
	const answer = await ask(
		session,
		cap,
		GIVE_MANAGER,
		[roomIdentity],
		"the Rooms operator did not give room management",
	);
	if (typeof answer !== "string" || answer === "") {
		throw new Error("the Rooms operator answered no manager sturdyref");
	}
	return answer;
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
