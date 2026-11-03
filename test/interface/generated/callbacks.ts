// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";

/** Observation checks a reply without replacing the runtime's pending target. */
export class Pending<T> {
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

export function introducer_get_greeter(
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

export function factory_open(
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

export function factory_accept(
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

export function sink_push(
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

export function sink_changed(
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

export function reader_read(
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

export function reader_then(
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

export function invoke_direct(
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

export function notify_direct(
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

export function invoke_empty(
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

export function invoke_named(
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

export function presence_required(
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

export function presence_optional(
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

export function presence_suffix(
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

export function presence_pair(
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

export function presence_references(
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

export function presence_value(
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

export function presence_notify(
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
