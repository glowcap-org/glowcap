// The operator console's reads, asked of a Rooms session.
//
// Three questions about the same subject — what a scope currently holds, one
// page of it, and retiring everything a query matches — kept together and away
// from the session client, which is otherwise about the workspace rather than
// about administering what it points at.

import type { Ref, Session } from "@pancake/runtime";
import { ask } from "../ask.ts";
import {
	type OperatorCategory,
	type OperatorPage,
	type OperatorReferenceKind,
	type OperatorRetireBatch,
	type OperatorSnapshot,
	parseOperatorPageAnswer,
	parseOperatorRetireAnswer,
	parseOperatorSnapshotJson,
} from "../operator.ts";
import {
	ROOMS_SESSION_OPERATOR_PAGE,
	ROOMS_SESSION_OPERATOR_RETIRE,
	ROOMS_SESSION_OPERATOR_SNAPSHOT,
} from "./verbs.ts";

export async function askOperatorSnapshot(
	session: Session,
	capability: Ref,
	scope: string,
	query = "",
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorSnapshot> {
	const raw = await ask(
		session,
		capability,
		ROOMS_SESSION_OPERATOR_SNAPSHOT,
		referenceKind === null ? (query === "" ? [scope] : [scope, query]) : [scope, query, referenceKind],
		"the Rooms session did not answer operator state",
	);
	if (typeof raw !== "string") throw new Error("the Rooms session answered invalid operator state");
	return parseOperatorSnapshotJson(raw);
}

export async function askOperatorRetire(
	session: Session,
	capability: Ref,
	scope: string,
	category: OperatorCategory,
	query: string,
	limit: number,
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorRetireBatch> {
	const raw = await ask(
		session,
		capability,
		ROOMS_SESSION_OPERATOR_RETIRE,
		[scope, category, query, BigInt(limit), ...(referenceKind === null ? [] : [referenceKind])],
		"the Rooms session did not answer the operator retire",
	);
	return parseOperatorRetireAnswer(raw);
}

export async function askOperatorPage(
	session: Session,
	capability: Ref,
	scope: string,
	category: OperatorCategory,
	cursor: number,
	query = "",
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorPage> {
	const raw = await ask(
		session,
		capability,
		ROOMS_SESSION_OPERATOR_PAGE,
		[scope, category, BigInt(cursor), query, ...(referenceKind === null ? [] : [referenceKind])],
		"the Rooms session did not answer the operator page",
	);
	return parseOperatorPageAnswer(category, raw);
}
