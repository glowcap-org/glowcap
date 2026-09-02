// The operator reads and retirements an admin facet answers for.
//
// Every verb here validates its arguments, then relays to the runtime's own
// operator surface. Only an admin facet reaches any of them, and the facet
// behavior refuses everything else before this dispatcher is asked.

import type { Argument, Behavior } from "@glowcap/runtime";
import {
	ROOMS_SESSION_OPERATIONS_SNAPSHOT,
	ROOMS_SESSION_OPERATOR_PAGE,
	ROOMS_SESSION_OPERATOR_RETIRE,
	ROOMS_SESSION_OPERATOR_SNAPSHOT,
	type RoomsSessionAccess,
} from "../lib/session/client.ts";
import {
	isOperatorReferenceKind,
	OPERATOR_CATEGORIES,
	operatorPageAnswer,
	type OperatorReferenceKind,
	operatorRetireAnswer,
} from "../lib/operator.ts";
import { MAX_OPERATOR_QUERY, MAX_OPERATOR_RETIRE_BATCH } from "../lib/limits.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";

export const OPERATOR_VERB_UNHANDLED = Symbol("operator verb unhandled");

export function dispatchOperatorVerb(
	rights: RoomsSessionAccess,
	verb: string,
	args: Argument[],
	runtime: DurableRoomsRuntime,
): ReturnType<Behavior> | typeof OPERATOR_VERB_UNHANDLED {
	if (verb === ROOMS_SESSION_OPERATOR_SNAPSHOT) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot inspect operator authority");
		if (
			args.length < 1 || args.length > 3 || typeof args[0] !== "string" ||
			(args.length >= 2 && (typeof args[1] !== "string" || args[1].length > MAX_OPERATOR_QUERY)) ||
			(args.length === 3 && !isOperatorReferenceKind(args[2]))
		) {
			throw new Error("operatorSnapshot takes a capability scope and an optional search");
		}
		return runtime.operatorSnapshot(
			args[0],
			args.length >= 2 ? args[1] as string : "",
			args.length === 3 ? args[2] as OperatorReferenceKind : null,
		).then((
			snapshot,
		) => JSON.stringify(
			snapshot,
			(_key, value) => typeof value === "bigint" ? value.toString() : value,
		)) as ReturnType<Behavior>;
	}
	if (verb === ROOMS_SESSION_OPERATOR_RETIRE) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot change operator authority");
		if (
			(args.length !== 4 && args.length !== 5) || typeof args[0] !== "string" ||
			typeof args[1] !== "string" ||
			!OPERATOR_CATEGORIES.some((category) => category === args[1]) || typeof args[2] !== "string" ||
			args[2].length > MAX_OPERATOR_QUERY || typeof args[3] !== "bigint" || args[3] < 1n ||
			args[3] > BigInt(MAX_OPERATOR_RETIRE_BATCH) ||
			(args.length === 5 && (!isOperatorReferenceKind(args[4]) || args[1] !== "references"))
		) throw new Error("operatorRetire takes a scope, category, search, and batch limit");
		return runtime.operatorRetireMatching(
			args[0],
			args[1] as (typeof OPERATOR_CATEGORIES)[number],
			args[2],
			Number(args[3]),
			args.length === 5 ? args[4] as OperatorReferenceKind : null,
		).then(operatorRetireAnswer) as ReturnType<Behavior>;
	}
	if (verb === ROOMS_SESSION_OPERATIONS_SNAPSHOT) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot inspect operations authority");
		if (
			args.length !== 2 || typeof args[0] !== "string" ||
			(args[1] !== "listeners" && args[1] !== "diagnostics" && args[1] !== "irc" &&
				args[1] !== "peering" &&
				args[1] !== "viz")
		) throw new Error("operationsSnapshot takes a scope and supported capability name");
		if (args[1] === "viz") {
			const snapshot = runtime.vizSnapshot(args[0]);
			return JSON.stringify({
				url: snapshot.url,
				connected: snapshot.connected,
				refusal: snapshot.refusal,
			});
		}
		if (args[1] === "peering") return JSON.stringify(runtime.peeringSnapshot(args[0]));
		return runtime.operationsSnapshot(args[0], args[1]).then((snapshot) =>
			JSON.stringify(snapshot.capability === "irc" ? snapshot.snapshot : snapshot.rows)
		) as ReturnType<Behavior>;
	}
	if (verb === ROOMS_SESSION_OPERATOR_PAGE) {
		if (rights !== "admin") throw new Error("this Rooms session facet cannot inspect operator authority");
		if (
			args.length < 3 || args.length > 5 || typeof args[0] !== "string" || typeof args[1] !== "string" ||
			!OPERATOR_CATEGORIES.some((category) => category === args[1]) || typeof args[2] !== "bigint" ||
			args[2] < 0n || args[2] > BigInt(Number.MAX_SAFE_INTEGER) ||
			(args.length >= 4 && (typeof args[3] !== "string" || args[3].length > MAX_OPERATOR_QUERY)) ||
			(args.length === 5 && (!isOperatorReferenceKind(args[4]) || args[1] !== "references"))
		) throw new Error("operatorPage takes a capability scope, category, cursor, and optional search");
		return runtime.operatorPage(
			args[0],
			args[1] as (typeof OPERATOR_CATEGORIES)[number],
			Number(args[2]),
			args.length >= 4 ? args[3] as string : "",
			args.length === 5 ? args[4] as OperatorReferenceKind : null,
		)
			.then(operatorPageAnswer) as ReturnType<Behavior>;
	}
	return OPERATOR_VERB_UNHANDLED;
}
