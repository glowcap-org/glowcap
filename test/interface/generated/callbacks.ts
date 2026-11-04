// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";

/** Observation checks a reply without replacing the runtime's pending target. */
class Pending<T> {
	constructor(readonly raw: RemotePromise, private readonly decode: (value: Argument) => T) {}
	observe(): Promise<T> {
		return this.raw.then(this.decode);
	}
}

function capability(value: Argument): Ref {
	if (!(value instanceof Ref)) throw new TypeError("expected capability reply");
	return value;
}
function text(value: Argument): string {
	if (typeof value !== "string") throw new TypeError("expected string reply");
	return value;
}
function nothing(value: Argument): void {
	// The existing TypeScript binding represents the profile's void value as null.
	if (value !== null) throw new TypeError("expected void reply");
}

function call_0(
	session: Session,
	target: Ref | RemotePromise,
): Pending<Ref> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "get-greeter", args);
	return new Pending(raw, capability);
}

function call_1(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Ref | RemotePromise,
): Pending<Ref> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Ref) && !(arg0 instanceof RemotePromise)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "open", args);
	return new Pending(raw, capability);
}

function call_2(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Ref | RemotePromise,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Ref) && !(arg0 instanceof RemotePromise)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "accept", args);
	return new Pending(raw, nothing);
}

function call_3(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Ref | RemotePromise,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Ref) && !(arg0 instanceof RemotePromise)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, "push", args);
	return new Pending(raw, nothing);
}

function call_4(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Argument,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (arg0 === undefined) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "changed", args);
}

function call_5(
	session: Session,
	target: Ref | RemotePromise,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "read", args);
	return new Pending(raw, text);
}

function call_6(
	session: Session,
	target: Ref | RemotePromise,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "then", args);
	return new Pending(raw, text);
}

function call_7(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	const raw = session.send(target, null, args);
	return new Pending(raw, text);
}

function call_8(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Argument,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (arg0 === undefined) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, null, args);
}

function call_9(
	session: Session,
	target: Ref | RemotePromise,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "", args);
	return new Pending(raw, text);
}

function call_10(
	session: Session,
	target: Ref | RemotePromise,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "then", args);
	return new Pending(raw, text);
}

function call_11(
	session: Session,
	target: Ref | RemotePromise,
	arg0: undefined,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (arg0 !== undefined) throw new TypeError("invalid argument 0");
	args[0] = null;
	const raw = session.send(target, "required", args);
	return new Pending(raw, nothing);
}

function call_12(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: undefined,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (arg0 !== undefined) throw new TypeError("invalid argument 0");
		args[0] = null;
	}
	const raw = session.send(target, "optional", args);
	return new Pending(raw, nothing);
}

function call_13(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
	arg1?: undefined,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 2) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	if (supplied > 1) {
		if (arg1 !== undefined) throw new TypeError("invalid argument 1");
		args[1] = null;
	}
	const raw = session.send(target, "suffix", args);
	return new Pending(raw, nothing);
}

function call_14(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
	arg1?: string,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 2) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	if (supplied > 1) {
		if (typeof arg1 !== "string") throw new TypeError("invalid argument 1");
		args[1] = arg1;
	}
	const raw = session.send(target, "pair", args);
	return new Pending(raw, nothing);
}

function call_15(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Ref | RemotePromise,
	arg1?: Ref | RemotePromise,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 2) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (!(arg0 instanceof Ref) && !(arg0 instanceof RemotePromise)) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	if (supplied > 1) {
		if (!(arg1 instanceof Ref) && !(arg1 instanceof RemotePromise)) throw new TypeError("invalid argument 1");
		args[1] = arg1;
	}
	const raw = session.send(target, "references", args);
	return new Pending(raw, nothing);
}

function call_16(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: Argument,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (arg0 === undefined) throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "value", args);
	return new Pending(raw, nothing);
}

function call_17(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: undefined,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (arg0 !== undefined) throw new TypeError("invalid argument 0");
		args[0] = null;
	}
	return session.tell(target, "notify", args);
}
export { Pending };
export { call_0 as introducer_get_greeter };
export { call_1 as factory_open };
export { call_2 as factory_accept };
export { call_3 as sink_push };
export { call_4 as sink_changed };
export { call_5 as reader_read };
export { call_6 as reader_then };
export { call_7 as invoke_direct };
export { call_8 as notify_direct };
export { call_9 as invoke_empty };
export { call_10 as invoke_named };
export { call_11 as presence_required };
export { call_12 as presence_optional };
export { call_13 as presence_suffix };
export { call_14 as presence_pair };
export { call_15 as presence_references };
export { call_16 as presence_value };
export { call_17 as presence_notify };
