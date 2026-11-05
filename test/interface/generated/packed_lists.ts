// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { Sym } from "@glowcap/runtime";
/** Observation checks a reply without replacing the runtime's pending target. */
class Pending<T> implements PromiseLike<T> {
	constructor(readonly raw: RemotePromise, private readonly decode: (value: Argument) => T) {
		raw.withGc();
	}
	observe(): Promise<T> {
		return this.raw.then(this.decode);
	}
	then<Fulfilled = T, Rejected = never>(
		onFulfilled?: ((value: T) => Fulfilled | PromiseLike<Fulfilled>) | null,
		onRejected?: ((reason: unknown) => Rejected | PromiseLike<Rejected>) | null,
	): Promise<Fulfilled | Rejected> {
		// The chained Promise carries decoder failures into await's rejection callback.
		return this.observe().then(onFulfilled, onRejected);
	}
}

function integer_unbounded_unbounded(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	return value;
}
function integer_m9223372036854775808_p9223372036854775807(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	if (value < -9223372036854775808n || value > 9223372036854775807n) throw new TypeError("integer outside bounds");
	return value;
}
function integer_m2_p2(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	if (value < -2n || value > 2n) throw new TypeError("integer outside bounds");
	return value;
}
function symbol_value(value: Argument): Sym {
	if (!(value instanceof Sym)) throw new TypeError("wrong scalar value");
	return value;
}
function float64_value(value: Argument): number {
	if (typeof value !== "number") throw new TypeError("wrong scalar value");
	return value;
}
function boolean_value(value: Argument): boolean {
	if (typeof value !== "boolean") throw new TypeError("wrong scalar value");
	return value;
}
function bytes_0_unbounded(value: Argument): Uint8Array {
	if (!(value instanceof Uint8Array)) throw new TypeError("wrong scalar value");
	return value;
}
function capability(value: Argument): Ref {
	if (!(value instanceof Ref)) throw new TypeError("expected capability reply");
	return value;
}
function text(value: Argument): string {
	if (typeof value !== "string") throw new TypeError("expected string reply");
	return value;
}
type Sequence<T> = Argument & object & ArrayLike<T> & Iterable<T>;
type Compound0 = Sequence<bigint>;
type Compound1 = Sequence<bigint>;
type Compound2 = Sequence<bigint>;
type Compound3 = Sequence<Argument>;
type Compound4 = Sequence<Sym>;
type Compound5 = Sequence<number>;
type Compound6 = Sequence<Ref>;
type Compound7 = Sequence<string>;
type Compound8 = Sequence<boolean>;
type Compound9 = Sequence<Uint8Array>;
type Compound10 = Sequence<Compound11>;
type Compound11 = Sequence<bigint>;
type Compound12 = Sequence<bigint>;
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
	if (!(values instanceof BigInt64Array)) {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			integer_unbounded_unbounded(values[index]);
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
	if (!(values instanceof BigInt64Array)) {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			integer_m9223372036854775808_p9223372036854775807(values[index]);
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
	if (values instanceof BigInt64Array) {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			if (values[index] < -2n || values[index] > 2n) throw new TypeError("integer outside bounds");
		}
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			integer_m2_p2(values[index]);
		}
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
			step(budget);
			symbol_value(values[index]);
		}
	}
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
			step(budget);
			float64_value(values[index]);
		}
	}
	return value as Compound5;
}
function compound_6(value: Argument): Compound6 {
	return compound_6_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_6_at(value: Argument, budget: DecodeBudget): Compound6 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			capability(values[index]);
		}
	}
	return value as Compound6;
}
function compound_7(value: Argument): Compound7 {
	return compound_7_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_7_at(value: Argument, budget: DecodeBudget): Compound7 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			text(values[index]);
		}
	}
	return value as Compound7;
}
function compound_8(value: Argument): Compound8 {
	return compound_8_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_8_at(value: Argument, budget: DecodeBudget): Compound8 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			boolean_value(values[index]);
		}
	}
	return value as Compound8;
}
function compound_9(value: Argument): Compound9 {
	return compound_9_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_9_at(value: Argument, budget: DecodeBudget): Compound9 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			bytes_0_unbounded(values[index]);
		}
	}
	return value as Compound9;
}
function compound_10(value: Argument): Compound10 {
	return compound_10_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_10_at(value: Argument, budget: DecodeBudget): Compound10 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values instanceof BigInt64Array) {
		if (values.length !== 0) throw new TypeError("integer list has incompatible elements");
	} else {
		for (let index = 0; index < values.length; index++) {
			compound_11_at(values[index], budget);
		}
	}
	return value as Compound10;
}
function compound_11_at(value: Argument, budget: DecodeBudget): Compound11 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (!(values instanceof BigInt64Array)) {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			integer_unbounded_unbounded(values[index]);
		}
	}
	return value as Compound11;
}
function compound_12(value: Argument): Compound12 {
	return compound_12_at(value, { remaining: MAX_REPLY_WORK });
}
function compound_12_at(value: Argument, budget: DecodeBudget): Compound12 {
	step(budget);
	const values = value;
	if (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError("expected list reply");
	if (values.length > 2n) throw new TypeError("list reply outside bounds");
	if (values instanceof BigInt64Array) {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			if (values[index] < -2n || values[index] > 2n) throw new TypeError("integer outside bounds");
		}
	} else {
		for (let index = 0; index < values.length; index++) {
			step(budget);
			integer_m2_p2(values[index]);
		}
	}
	return value as Compound12;
}

function call_0(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound0> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "integers", args);
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
	const raw = session.send(target, "signed", args);
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
	const raw = session.send(target, "narrow", args);
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
	const raw = session.send(target, "values", args);
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
	const raw = session.send(target, "symbols", args);
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
	const raw = session.send(target, "floats", args);
	return new Pending(raw, compound_5);
}

function call_6(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound6> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "targets", args);
	return new Pending(raw, compound_6);
}

function call_7(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound7> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "texts", args);
	return new Pending(raw, compound_7);
}

function call_8(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound8> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "booleans", args);
	return new Pending(raw, compound_8);
}

function call_9(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound9> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "byteArrays", args);
	return new Pending(raw, compound_9);
}

function call_10(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound10> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "nested", args);
	return new Pending(raw, compound_10);
}

function call_11(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Compound12> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "limited", args);
	return new Pending(raw, compound_12);
}
export { Pending };
export { ResourceLimit };
export { call_0 as integers };
export { call_1 as signed };
export { call_2 as narrow };
export { call_3 as values };
export { call_4 as symbols };
export { call_5 as floats };
export { call_6 as targets };
export { call_7 as texts };
export { call_8 as booleans };
export { call_9 as byteArrays };
export { call_10 as nested };
export { call_11 as limited };
