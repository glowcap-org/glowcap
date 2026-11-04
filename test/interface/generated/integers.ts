// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
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
function integer_m2_unbounded(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	if (value < -2n) throw new TypeError("integer outside bounds");
	return value;
}
function integer_unbounded_p2(value: unknown): bigint {
	if (typeof value !== "bigint") throw new TypeError("wrong scalar value");
	if (value > 2n) throw new TypeError("integer outside bounds");
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

function call_0(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_unbounded_unbounded(arg0);
	const raw = session.send(target, "bare_call", args);
	return new Pending(raw, integer_unbounded_unbounded);
}

function call_1(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_unbounded_unbounded(arg0);
	}
	const raw = session.send(target, "bare_optional", args);
	return new Pending(raw, integer_unbounded_unbounded);
}

function call_2(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_unbounded_unbounded(arg0);
	return session.tell(target, "bare_tell", args);
}

function call_3(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_unbounded_unbounded(arg0);
	}
	return session.tell(target, "bare_optional_tell", args);
}

function call_4(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_unbounded_unbounded(arg0);
	const raw = session.send(target, "empty_call", args);
	return new Pending(raw, integer_unbounded_unbounded);
}

function call_5(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_unbounded_unbounded(arg0);
	}
	const raw = session.send(target, "empty_optional", args);
	return new Pending(raw, integer_unbounded_unbounded);
}

function call_6(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_unbounded_unbounded(arg0);
	return session.tell(target, "empty_tell", args);
}

function call_7(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_unbounded_unbounded(arg0);
	}
	return session.tell(target, "empty_optional_tell", args);
}

function call_8(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m2_unbounded(arg0);
	const raw = session.send(target, "lower_call", args);
	return new Pending(raw, integer_m2_unbounded);
}

function call_9(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m2_unbounded(arg0);
	}
	const raw = session.send(target, "lower_optional", args);
	return new Pending(raw, integer_m2_unbounded);
}

function call_10(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m2_unbounded(arg0);
	return session.tell(target, "lower_tell", args);
}

function call_11(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m2_unbounded(arg0);
	}
	return session.tell(target, "lower_optional_tell", args);
}

function call_12(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_unbounded_p2(arg0);
	const raw = session.send(target, "upper_call", args);
	return new Pending(raw, integer_unbounded_p2);
}

function call_13(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_unbounded_p2(arg0);
	}
	const raw = session.send(target, "upper_optional", args);
	return new Pending(raw, integer_unbounded_p2);
}

function call_14(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_unbounded_p2(arg0);
	return session.tell(target, "upper_tell", args);
}

function call_15(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_unbounded_p2(arg0);
	}
	return session.tell(target, "upper_optional_tell", args);
}

function call_16(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m9223372036854775808_p9223372036854775807(arg0);
	const raw = session.send(target, "signed_call", args);
	return new Pending(raw, integer_m9223372036854775808_p9223372036854775807);
}

function call_17(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m9223372036854775808_p9223372036854775807(arg0);
	}
	const raw = session.send(target, "signed_optional", args);
	return new Pending(raw, integer_m9223372036854775808_p9223372036854775807);
}

function call_18(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m9223372036854775808_p9223372036854775807(arg0);
	return session.tell(target, "signed_tell", args);
}

function call_19(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m9223372036854775808_p9223372036854775807(arg0);
	}
	return session.tell(target, "signed_optional_tell", args);
}

function call_20(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m2_p2(arg0);
	const raw = session.send(target, "narrow_call", args);
	return new Pending(raw, integer_m2_p2);
}

function call_21(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m2_p2(arg0);
	}
	const raw = session.send(target, "narrow_optional", args);
	return new Pending(raw, integer_m2_p2);
}

function call_22(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m2_p2(arg0);
	return session.tell(target, "narrow_tell", args);
}

function call_23(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m2_p2(arg0);
	}
	return session.tell(target, "narrow_optional_tell", args);
}

function call_24(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m2_p2(arg0);
	const raw = session.send(target, "alias_call", args);
	return new Pending(raw, integer_m2_p2);
}

function call_25(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Pending<bigint> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m2_p2(arg0);
	}
	const raw = session.send(target, "alias_optional", args);
	return new Pending(raw, integer_m2_p2);
}

function call_26(
	session: Session,
	target: Ref | RemotePromise,
	arg0: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = integer_m2_p2(arg0);
	return session.tell(target, "alias_tell", args);
}

function call_27(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: bigint,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = integer_m2_p2(arg0);
	}
	return session.tell(target, "alias_optional_tell", args);
}
export { Pending };
export { call_0 as bare_call };
export { call_1 as bare_optional };
export { call_2 as bare_tell };
export { call_3 as bare_optional_tell };
export { call_4 as empty_call };
export { call_5 as empty_optional };
export { call_6 as empty_tell };
export { call_7 as empty_optional_tell };
export { call_8 as lower_call };
export { call_9 as lower_optional };
export { call_10 as lower_tell };
export { call_11 as lower_optional_tell };
export { call_12 as upper_call };
export { call_13 as upper_optional };
export { call_14 as upper_tell };
export { call_15 as upper_optional_tell };
export { call_16 as signed_call };
export { call_17 as signed_optional };
export { call_18 as signed_tell };
export { call_19 as signed_optional_tell };
export { call_20 as narrow_call };
export { call_21 as narrow_optional };
export { call_22 as narrow_tell };
export { call_23 as narrow_optional_tell };
export { call_24 as alias_call };
export { call_25 as alias_optional };
export { call_26 as alias_tell };
export { call_27 as alias_optional_tell };
