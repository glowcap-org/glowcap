// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { Tagged } from "@glowcap/runtime";
/** Observation checks a reply without replacing the runtime's pending target. */
class Pending<T> {
	constructor(readonly raw: RemotePromise, private readonly decode: (value: Argument) => T) {}
	observe(): Promise<T> {
		return this.raw.then(this.decode);
	}
}

// Count TextEncoder's UTF-8 length without an encoded-byte allocation. Paired
// surrogates use four bytes, and each unpaired surrogate becomes U+FFFD (three).
// A maximum refuses on the first excess. A minimum alone stops once satisfied.
function text_bytes(value: string, minimum: bigint, maximum: bigint | null): void {
	// Every UTF-16 unit contributes at most three bytes. Check the counter's
	// exact range once, before scanning, rather than on each character.
	if (value.length > Number.MAX_SAFE_INTEGER / 3) throw new TypeError("text byte length exceeds exact counter");
	let bytes = 0;
	for (let index = 0; index < value.length; index++) {
		const unit = value.charCodeAt(index);
		if (unit < 0x80) bytes++;
		else if (unit < 0x800) bytes += 2;
		else {
			bytes += 3;
			if (unit >= 0xd800 && unit <= 0xdbff) {
				const next = value.charCodeAt(index + 1);
				if (next >= 0xdc00 && next <= 0xdfff) {
					bytes++;
					index++;
				}
			}
		}
		if (maximum !== null && bytes > maximum) throw new TypeError("text outside byte bounds");
		if (maximum === null && bytes >= minimum) return;
	}
	if (bytes < minimum) throw new TypeError("text outside byte bounds");
}
function integer_unbounded_unbounded(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	return value;
}
function text_1_4(value: unknown): string {
	if (typeof value !== "string") throw new TypeError("wrong scalar value");
	text_bytes(value, 1n, 4n);
	return value;
}
function integer_m2_p2(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	if (value < -2n || value > 2n) throw new TypeError("integer outside bounds");
	return value;
}
function text_3_unbounded(value: unknown): string {
	if (typeof value !== "string") throw new TypeError("wrong scalar value");
	text_bytes(value, 3n, null);
	return value;
}
type Sequence<T> = Argument & object & ArrayLike<T> & Iterable<T>;
type Compound0 = Sequence<bigint | string | Compound1> & {
	readonly length: 3;
	readonly 0: bigint;
	readonly 1: string;
	readonly 2: Compound1;
};
type Compound1 = Sequence<bigint | string> & {
	readonly length: 2;
	readonly 0: bigint;
	readonly 1: string;
};
type Compound2 = Tagged & {
	readonly tag: "bounds:mixed";
	readonly value: [bigint, string, Compound3];
};
type Compound3 = Sequence<bigint | string> & {
	readonly length: 2;
	readonly 0: bigint;
	readonly 1: string;
};
type Compound4 = Sequence<Argument>;
const MAX_REPLY_WORK = 65536;
/** A local decoder limit, independent of schema shape and collection bounds. */
class ResourceLimit extends Error {}
type DecodeBudget = { remaining: number };
// One scratch object per observation keeps the work counter shared across
// recursion. It dies on return/refusal. Arrays, Tagged objects, payloads and
// capability wrappers remain the runtime's originals, with no extra retains.
function step(budget: DecodeBudget): void {
	if (budget.remaining === 0) throw new ResourceLimit("reply decoder limit");
	budget.remaining--;
}
function compound_0(value: Argument): Compound0 {
	return compound_0_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_0_at(value: Argument, budget: DecodeBudget): Compound0 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 3) throw new TypeError("wrong reply arity");
	if (values instanceof BigInt64Array) {
		throw new TypeError("integer tuple has incompatible fields");
	} else {
		step(budget);
		integer_unbounded_unbounded(values[0]);
		step(budget);
		text_1_4(values[1]);
		compound_1_at(values[2], budget);
	}
	return value as Compound0;
}
function compound_1_at(value: Argument, budget: DecodeBudget): Compound1 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	if (values instanceof BigInt64Array) {
		throw new TypeError("integer tuple has incompatible fields");
	} else {
		step(budget);
		integer_m2_p2(values[0]);
		step(budget);
		text_3_unbounded(values[1]);
	}
	return value as Compound1;
}
function compound_2(value: Argument): Compound2 {
	return compound_2_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_2_at(value: Argument, budget: DecodeBudget): Compound2 {
	step(budget);
	if (!(value instanceof Tagged) || value.tag !== "bounds:mixed") throw new TypeError("wrong record reply");
	const values = value.value;
	if (values.length !== 3) throw new TypeError("wrong reply arity");
	step(budget);
	integer_unbounded_unbounded(values[0]);
	step(budget);
	text_1_4(values[1]);
	compound_3_at(values[2], budget);
	return value as Compound2;
}
function compound_3_at(value: Argument, budget: DecodeBudget): Compound3 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	if (values instanceof BigInt64Array) {
		throw new TypeError("integer tuple has incompatible fields");
	} else {
		step(budget);
		integer_m2_p2(values[0]);
		step(budget);
		text_3_unbounded(values[1]);
	}
	return value as Compound3;
}
function compound_4(value: Argument): Compound4 {
	return compound_4_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_4_at(value: Argument, budget: DecodeBudget): Compound4 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	return value as Compound4;
}

function call_0(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound0> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "tuple", args);
	return new Pending(raw, compound_0);
}

function call_1(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound2> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "record", args);
	return new Pending(raw, compound_2);
}

function call_2(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound4> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "values", args);
	return new Pending(raw, compound_4);
}
export { Pending };
export { ResourceLimit };
export { call_0 as tuple };
export { call_1 as record };
export { call_2 as values };
