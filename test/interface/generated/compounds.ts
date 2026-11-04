// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { Sym } from "@glowcap/runtime";
/** Observation checks a reply without replacing the runtime's pending target. */
class Pending<T> {
	constructor(readonly raw: RemotePromise, private readonly decode: (value: Argument) => T) {
		raw.withGc();
	}
	observe(): Promise<T> {
		return this.raw.then(this.decode);
	}
}

function symbol_value(value: Argument): Sym {
	if (!(value instanceof Sym)) throw new TypeError("wrong scalar value");
	return value;
}
function bytes_2_2(value: Argument): Uint8Array {
	if (!(value instanceof Uint8Array)) throw new TypeError("wrong scalar value");
	if (value.byteLength < 2n || value.byteLength > 2n) throw new TypeError("byte reply outside bounds");
	return value;
}
function boolean_value(value: Argument): boolean {
	if (typeof value !== "boolean") throw new TypeError("wrong scalar value");
	return value;
}
function capability(value: Argument): Ref {
	if (!(value instanceof Ref)) throw new TypeError("expected capability reply");
	return value;
}
type Sequence<T> = Argument & object & ArrayLike<T> & Iterable<T>;
type Compound0 = Sequence<Sym>;
type Compound1 = Sequence<Sym>;
type Compound2 = Sequence<Uint8Array | Ref | boolean> & {
	readonly length: 3;
	readonly 0: Uint8Array;
	readonly 1: Ref;
	readonly 2: boolean;
};
type Compound3 = Sequence<never> & {
	readonly length: 0;
};
type Compound4 = Sequence<Compound5>;
type Compound5 = Sequence<Sym | Ref | Argument> & {
	readonly length: 3;
	readonly 0: Sym;
	readonly 1: Ref;
	readonly 2: Argument;
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
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			symbol_value(values[index]);
		}
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
	if (values.length > 2n) throw new TypeError("list reply outside bounds");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			symbol_value(values[index]);
		}
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
	if (values.length !== 3) throw new TypeError("wrong reply arity");
	if (values instanceof BigInt64Array) {
		throw new TypeError("integer tuple has incompatible fields");
	} else {
		step(budget);
		bytes_2_2(values[0]);
		step(budget);
		capability(values[1]);
		step(budget);
		boolean_value(values[2]);
	}
	return value as Compound2;
}
function compound_3(value: Argument): Compound3 {
	return compound_3_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_3_at(value: Argument, budget: DecodeBudget): Compound3 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 0) throw new TypeError("wrong reply arity");
	return value as Compound3;
}
function compound_4(value: Argument): Compound4 {
	return compound_4_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_4_at(value: Argument, budget: DecodeBudget): Compound4 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			compound_5_at(values[index], budget);
		}
	}
	return value as Compound4;
}
function compound_5_at(value: Argument, budget: DecodeBudget): Compound5 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length !== 3) throw new TypeError("wrong reply arity");
	if (values instanceof BigInt64Array) {
		throw new TypeError("integer tuple has incompatible fields");
	} else {
		step(budget);
		symbol_value(values[0]);
		step(budget);
		capability(values[1]);
	}
	return value as Compound5;
}

function call_0(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound0> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "list", args);
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
	const raw = session.send(target, "limited", args);
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
	const raw = session.send(target, "tuple", args);
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
	const raw = session.send(target, "zero", args);
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
	const raw = session.send(target, "nested", args);
	return new Pending(raw, compound_4);
}
export { Pending };
export { ResourceLimit };
export { call_0 as list };
export { call_1 as limited };
export { call_2 as tuple };
export { call_3 as zero };
export { call_4 as nested };
