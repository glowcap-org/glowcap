// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { Sym } from "@glowcap/runtime";
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

function bytes_56_56(value: Argument): Uint8Array {
	if (!(value instanceof Uint8Array)) throw new TypeError("wrong scalar value");
	if (value.byteLength < 56n || value.byteLength > 56n) throw new TypeError("byte reply outside bounds");
	return value;
}
function boolean_value(value: Argument): boolean {
	if (typeof value !== "boolean") throw new TypeError("wrong scalar value");
	return value;
}
function symbol_value(value: Argument): Sym {
	if (!(value instanceof Sym)) throw new TypeError("wrong scalar value");
	return value;
}
type Sequence<T> = Argument & object & ArrayLike<T> & Iterable<T>;
type Compound0 = Tagged & {
	readonly tag: "access:observation";
	readonly value: [Uint8Array, Argument, boolean, boolean, Compound1];
};
type Compound1 = Sequence<Sym>;
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
	if (!(value instanceof Tagged) || value.tag !== "access:observation") throw new TypeError("wrong record reply");
	const values = value.value;
	if (values.length !== 5) throw new TypeError("wrong reply arity");
	step(budget);
	bytes_56_56(values[0]);
	step(budget);
	boolean_value(values[2]);
	step(budget);
	boolean_value(values[3]);
	compound_1_at(values[4], budget);
	return value as Compound0;
}
function compound_1_at(value: Argument, budget: DecodeBudget): Compound1 {
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
	return value as Compound1;
}

function call_0(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Uint8Array,
): Pending<Compound0> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
		if (arg0.byteLength < 56n || arg0.byteLength > 56n) throw new TypeError("byte argument outside bounds");
	}
	const raw = session.send(target, "poll", args);
	return new Pending(raw, compound_0);
}
export { Pending };
export { ResourceLimit };
export { call_0 as poll };
