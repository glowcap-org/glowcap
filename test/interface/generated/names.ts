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
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 0) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	const raw = session.send(target, "read", args);
	return new Pending(raw, text);
}

function call_1(
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

function call_2(
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

function call_3(
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

function call_4(
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

function call_7(
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

function call_8(
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
export { Pending };
export { call_0 as text };
export { call_1 as __glowcap };
export { call_2 as __glowcap_1 };
export { call_3 as call_0 };
export { call_4 as Session };
export { call_5 as Ref };
export { call_6 as capability };
export { call_7 as nothing };
export { call_8 as Observation };
