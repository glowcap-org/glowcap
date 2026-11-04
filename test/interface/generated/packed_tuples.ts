// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { Tagged } from "@glowcap/runtime";
/** Observation checks a reply without replacing the runtime's pending target. */
class Pending<T> {
	constructor(readonly raw: RemotePromise, private readonly decode: (value: Argument) => T) {
		raw.withGc();
	}
	observe(): Promise<T> {
		return this.raw.then(this.decode);
	}
}

function integer_unbounded_unbounded(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	return value;
}
function integer_m2_p2(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	if (value < -2n || value > 2n) throw new TypeError("integer outside bounds");
	return value;
}
function text(value: Argument): string {
	if (typeof value !== "string") throw new TypeError("expected string reply");
	return value;
}
type Sequence<T> = Argument & object & ArrayLike<T> & Iterable<T>;
type Compound0 = Sequence<bigint | bigint | Argument> & {
	readonly length: 3;
	readonly 0: bigint;
	readonly 1: bigint;
	readonly 2: Argument;
};
type Compound1 = Sequence<bigint | Argument> & {
	readonly length: 2;
	readonly 0: bigint;
	readonly 1: Argument;
};
type Compound2 = Sequence<never> & {
	readonly length: 0;
};
type Compound3 = Sequence<bigint | string> & {
	readonly length: 2;
	readonly 0: bigint;
	readonly 1: string;
};
type Compound4 = Sequence<Argument | Argument> & {
	readonly length: 2;
	readonly 0: Argument;
	readonly 1: Argument;
};
type Compound5 = Sequence<Compound6>;
type Compound6 = Sequence<bigint | Argument> & {
	readonly length: 2;
	readonly 0: bigint;
	readonly 1: Argument;
};
type Compound7 = Tagged & {
	readonly tag: "packed:record";
	readonly value: [Compound8, Compound9];
};
type Compound8 = Sequence<bigint>;
type Compound9 = Sequence<bigint | Argument> & {
	readonly length: 2;
	readonly 0: bigint;
	readonly 1: Argument;
};
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
		step(budget);
		if (values[1] < -2n || values[1] > 2n) throw new TypeError("integer outside bounds");
	} else {
		step(budget);
		integer_unbounded_unbounded(values[0]);
		step(budget);
		integer_m2_p2(values[1]);
	}
	return value as Compound0;
}
function compound_1(value: Argument): Compound1 {
	return compound_1_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_1_at(value: Argument, budget: DecodeBudget): Compound1 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	if (!(values instanceof BigInt64Array)) {
		step(budget);
		integer_unbounded_unbounded(values[0]);
	}
	return value as Compound1;
}
function compound_2(value: Argument): Compound2 {
	return compound_2_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_2_at(value: Argument, budget: DecodeBudget): Compound2 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 0) throw new TypeError("wrong reply arity");
	return value as Compound2;
}
function compound_3(value: Argument): Compound3 {
	return compound_3_at(value, { remaining: MAX_REPLY_WORK });
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
		integer_unbounded_unbounded(values[0]);
		step(budget);
		text(values[1]);
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
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	return value as Compound4;
}
function compound_5(value: Argument): Compound5 {
	return compound_5_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_5_at(value: Argument, budget: DecodeBudget): Compound5 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			compound_6_at(values[index], budget);
		}
	}
	return value as Compound5;
}
function compound_6_at(value: Argument, budget: DecodeBudget): Compound6 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	if (!(values instanceof BigInt64Array)) {
		step(budget);
		integer_unbounded_unbounded(values[0]);
	}
	return value as Compound6;
}
function compound_7(value: Argument): Compound7 {
	return compound_7_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_7_at(value: Argument, budget: DecodeBudget): Compound7 {
	step(budget);
	if (!(value instanceof Tagged) || value.tag !== "packed:record") throw new TypeError("wrong record reply");
	const values = value.value;
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	compound_8_at(values[0], budget);
	compound_9_at(values[1], budget);
	return value as Compound7;
}
function compound_8_at(value: Argument, budget: DecodeBudget): Compound8 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (!(values instanceof BigInt64Array)) {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			integer_unbounded_unbounded(values[index]);
		}
	}
	return value as Compound8;
}
function compound_9_at(value: Argument, budget: DecodeBudget): Compound9 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 2) throw new TypeError("wrong reply arity");
	if (!(values instanceof BigInt64Array)) {
		step(budget);
		integer_unbounded_unbounded(values[0]);
	}
	return value as Compound9;
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
): Pending<Compound1> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "wideTuple", args);
	return new Pending(raw, compound_1);
}

function call_2(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound2> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "zero", args);
	return new Pending(raw, compound_2);
}

function call_3(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound3> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "incompatible", args);
	return new Pending(raw, compound_3);
}

function call_4(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound4> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "opaqueTuple", args);
	return new Pending(raw, compound_4);
}

function call_5(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound5> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "nestedTuples", args);
	return new Pending(raw, compound_5);
}

function call_6(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound7> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "record", args);
	return new Pending(raw, compound_7);
}
export { Pending };
export { ResourceLimit };
export { call_0 as tuple };
export { call_1 as wideTuple };
export { call_2 as zero };
export { call_3 as incompatible };
export { call_4 as opaqueTuple };
export { call_5 as nestedTuples };
export { call_6 as record };
