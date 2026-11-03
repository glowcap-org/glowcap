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

export function invoke_text(
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
	const raw = session.send(target, null, args);
	return new Pending(raw, nothing);
}

export function accept_text(
	session: Session,
	target: Ref | RemotePromise,
	arg0: Ref | RemotePromise,
	arg1: Ref | RemotePromise,
): Pending<void> {
	const supplied = arguments.length - 2;
	if (supplied < 2 || supplied > 2) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (!(arg0 instanceof Ref) && !(arg0 instanceof RemotePromise)) throw new TypeError("invalid argument 0");
	args[0] = arg0;
	if (!(arg1 instanceof Ref) && !(arg1 instanceof RemotePromise)) throw new TypeError("invalid argument 1");
	args[1] = arg1;
	const raw = session.send(target, "accept", args);
	return new Pending(raw, nothing);
}
