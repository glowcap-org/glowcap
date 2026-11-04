// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { Sym } from "@glowcap/runtime";
/** Observation checks a reply without replacing the runtime's pending target. */
class Pending<T> {
	constructor(readonly raw: RemotePromise, private readonly decode: (value: Argument) => T) {}
	observe(): Promise<T> {
		return this.raw.then(this.decode);
	}
}

function boolean_value(value: Argument): boolean {
	if (typeof value !== "boolean") throw new TypeError("wrong scalar reply");
	return value;
}
function bytes_0_unbounded(value: Argument): Uint8Array {
	if (!(value instanceof Uint8Array)) throw new TypeError("wrong scalar reply");
	return value;
}
function bytes_1_4(value: Argument): Uint8Array {
	if (!(value instanceof Uint8Array)) throw new TypeError("wrong scalar reply");
	if (value.byteLength < 1n || value.byteLength > 4n) throw new TypeError("byte reply outside bounds");
	return value;
}
function symbol_value(value: Argument): Sym {
	if (!(value instanceof Sym)) throw new TypeError("wrong scalar reply");
	return value;
}
function float64_value(value: Argument): number {
	if (typeof value !== "number") throw new TypeError("wrong scalar reply");
	return value;
}
function error_value(value: Argument): Error {
	if (!(value instanceof Error)) throw new TypeError("wrong scalar reply");
	return value;
}

function call_0(
	session: Session,
	target: Ref | RemotePromise,
	arg0: boolean,
): Pending<boolean> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "boolean") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "bool_call", args);
	return new Pending(raw, boolean_value);
}

function call_1(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: boolean,
): Pending<boolean> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "boolean") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "bool_optional", args);
	return new Pending(raw, boolean_value);
}

function call_2(
	session: Session,
	target: Ref | RemotePromise,
	arg0: boolean,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "boolean") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "bool_tell", args);
}

function call_3(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: boolean,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "boolean") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "bool_optional_tell", args);
}

function call_4(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Uint8Array,
): Pending<Uint8Array> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "bytes_call", args);
	return new Pending(raw, bytes_0_unbounded);
}

function call_5(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Uint8Array,
): Pending<Uint8Array> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "bytes_optional", args);
	return new Pending(raw, bytes_0_unbounded);
}

function call_6(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Uint8Array,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "bytes_tell", args);
}

function call_7(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Uint8Array,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "bytes_optional_tell", args);
}

function call_8(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Uint8Array,
): Pending<Uint8Array> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	if (arg0.byteLength < 1n || arg0.byteLength > 4n) throw new TypeError("byte argument outside bounds");
	const raw = session.send(target, "bounded_call", args);
	return new Pending(raw, bytes_1_4);
}

function call_9(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Uint8Array,
): Pending<Uint8Array> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
		if (arg0.byteLength < 1n || arg0.byteLength > 4n) throw new TypeError("byte argument outside bounds");
	}
	const raw = session.send(target, "bounded_optional", args);
	return new Pending(raw, bytes_1_4);
}

function call_10(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Uint8Array,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	if (arg0.byteLength < 1n || arg0.byteLength > 4n) throw new TypeError("byte argument outside bounds");
	return session.tell(target, "bounded_tell", args);
}

function call_11(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Uint8Array,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Uint8Array)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
		if (arg0.byteLength < 1n || arg0.byteLength > 4n) throw new TypeError("byte argument outside bounds");
	}
	return session.tell(target, "bounded_optional_tell", args);
}

function call_12(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Sym,
): Pending<Sym> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Sym)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "symbol_call", args);
	return new Pending(raw, symbol_value);
}

function call_13(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Sym,
): Pending<Sym> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Sym)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "symbol_optional", args);
	return new Pending(raw, symbol_value);
}

function call_14(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Sym,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Sym)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "symbol_tell", args);
}

function call_15(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Sym,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Sym)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "symbol_optional_tell", args);
}

function call_16(
	session: Session,
	target: Ref | RemotePromise,
	arg0: number,
): Pending<number> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "number") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "float_call", args);
	return new Pending(raw, float64_value);
}

function call_17(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: number,
): Pending<number> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "number") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "float_optional", args);
	return new Pending(raw, float64_value);
}

function call_18(
	session: Session,
	target: Ref | RemotePromise,
	arg0: number,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "number") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "float_tell", args);
}

function call_19(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: number,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "number") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "float_optional_tell", args);
}

function call_20(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Error,
): Pending<Error> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Error)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "error_call", args);
	return new Pending(raw, error_value);
}

function call_21(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Error,
): Pending<Error> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Error)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "error_optional", args);
	return new Pending(raw, error_value);
}

function call_22(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Error,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Error)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "error_tell", args);
}

function call_23(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Error,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Error)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "error_optional_tell", args);
}
export { Pending };
export { call_0 as bool_call };
export { call_1 as bool_optional };
export { call_2 as bool_tell };
export { call_3 as bool_optional_tell };
export { call_4 as bytes_call };
export { call_5 as bytes_optional };
export { call_6 as bytes_tell };
export { call_7 as bytes_optional_tell };
export { call_8 as bounded_call };
export { call_9 as bounded_optional };
export { call_10 as bounded_tell };
export { call_11 as bounded_optional_tell };
export { call_12 as symbol_call };
export { call_13 as symbol_optional };
export { call_14 as symbol_tell };
export { call_15 as symbol_optional_tell };
export { call_16 as float_call };
export { call_17 as float_optional };
export { call_18 as float_tell };
export { call_19 as float_optional_tell };
export { call_20 as error_call };
export { call_21 as error_optional };
export { call_22 as error_tell };
export { call_23 as error_optional_tell };
