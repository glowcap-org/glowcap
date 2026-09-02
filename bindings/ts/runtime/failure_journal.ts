import { DEFAULT_FAILURE_CAPACITY, DEFAULT_FAILURE_PAYLOAD_CAP, OK, TIMEOUT } from "@glowcap/abi";

export type FailureLayer = "core" | "driver" | "transport" | "binding" | "application-observer";
export type FailureScope = "process" | "context" | "host" | "session" | "listener" | "transport" | "operation";

/** One failure that had no remaining deterministic return recipient. */
export interface FailureEvent {
	readonly sequence: bigint;
	readonly droppedBefore: bigint;
	readonly layer: FailureLayer;
	readonly scope: FailureScope;
	readonly scopeId: bigint;
	readonly operationId: bigint;
	readonly primaryResult: number;
	readonly secondaryResult: number;
	readonly secondaryCount: number;
	readonly truncatedFields: number;
	readonly operation: string;
	readonly primaryName: string;
	readonly primaryMessage: string;
	readonly secondaryName: string;
	readonly secondaryMessage: string;
}

/** Package-internal input for a callback seam whose failure cannot return. */
export interface FailureReport {
	readonly layer: FailureLayer;
	readonly scope: FailureScope;
	readonly operation: string;
	readonly primaryName: string;
	readonly primaryResult: number;
	readonly primaryMessage?: string;
	readonly scopeId?: bigint;
	readonly operationId?: bigint;
	readonly secondaryResult?: number;
	readonly secondaryName?: string;
	readonly secondaryMessage?: string;
	readonly secondaryCount?: number;
}

const U64_MAX = (1n << 64n) - 1n;
const failureTextEncoder = new TextEncoder();
const failureTextDecoder = new TextDecoder();
const runtimeFailures: FailureEvent[] = [];
let nextRuntimeFailureSequence = 1n;

function boundedFailureText(fields: readonly string[]): { fields: string[]; truncatedFields: number } {
	let remaining = DEFAULT_FAILURE_PAYLOAD_CAP;
	let truncatedFields = 0;
	return {
		fields: fields.map((field, index) => {
			const encoded = failureTextEncoder.encode(field);
			let copied = Math.min(encoded.byteLength, remaining);
			while (copied > 0 && copied < encoded.byteLength && (encoded[copied] & 0xc0) === 0x80) copied--;
			const retained = encoded.subarray(0, copied);
			remaining -= copied;
			if (retained.byteLength !== encoded.byteLength) truncatedFields |= 1 << index;
			return failureTextDecoder.decode(retained);
		}),
		truncatedFields,
	};
}

function isStableResult(value: number): boolean {
	return Number.isInteger(value) && value <= OK && value >= TIMEOUT;
}

export function validateFailureReport(input: FailureReport): FailureReport {
	if (input.operation.length === 0 || input.primaryName.length === 0) {
		throw new TypeError("failure operation and primaryName must be non-empty");
	}
	if (!isStableResult(input.primaryResult)) throw new TypeError("invalid primary failure result");
	const secondaryResult = input.secondaryResult ?? OK;
	const secondaryName = input.secondaryName ?? "";
	const secondaryMessage = input.secondaryMessage ?? "";
	const secondaryCount = input.secondaryCount ?? 0;
	if (!Number.isInteger(secondaryCount) || secondaryCount < 0 || secondaryCount > 0xffff_ffff) {
		throw new TypeError("invalid secondary failure count");
	}
	if (secondaryCount === 0) {
		if (secondaryResult !== OK || secondaryName.length !== 0 || secondaryMessage.length !== 0) {
			throw new TypeError("secondary failure fields require a nonzero count");
		}
	} else if (!isStableResult(secondaryResult) || secondaryName.length === 0) {
		throw new TypeError("a secondary failure count requires one named stable cause");
	}
	return input;
}

function minU64(value: bigint): bigint {
	return value > U64_MAX ? U64_MAX : value;
}

export function recordRuntimeFailure(input: FailureReport): void {
	const bounded = boundedFailureText([
		input.operation,
		input.primaryName,
		input.primaryMessage ?? "",
		input.secondaryName ?? "",
		input.secondaryMessage ?? "",
	]);
	let droppedBefore = 0n;
	if (runtimeFailures.length === DEFAULT_FAILURE_CAPACITY) {
		const dropped = (runtimeFailures.shift()?.droppedBefore ?? 0n) + 1n;
		if (runtimeFailures.length > 0) {
			runtimeFailures[0] = {
				...runtimeFailures[0],
				droppedBefore: minU64(runtimeFailures[0].droppedBefore + dropped),
			};
		} else droppedBefore = minU64(dropped);
	}
	const [operation, primaryName, primaryMessage, secondaryName, secondaryMessage] = bounded.fields;
	runtimeFailures.push({
		sequence: nextRuntimeFailureSequence,
		droppedBefore,
		layer: input.layer,
		scope: "process",
		scopeId: 0n,
		operationId: 0n,
		primaryResult: input.primaryResult,
		secondaryResult: input.secondaryResult ?? OK,
		secondaryCount: input.secondaryCount ?? 0,
		truncatedFields: bounded.truncatedFields,
		operation,
		primaryName,
		primaryMessage,
		secondaryName,
		secondaryMessage,
	});
	nextRuntimeFailureSequence = minU64(nextRuntimeFailureSequence + 1n);
}

/** Atomically claim failures that outlived a usable Context owner. */
export function takeRuntimeFailures(): FailureEvent[] {
	return runtimeFailures.splice(0);
}
