// Generated from checked interface descriptions.
import { type Argument, Ref, RemotePromise } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
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

// Count TextEncoder's UTF-8 length without an encoded-byte allocation. Paired
// surrogates use four bytes, and each unpaired surrogate becomes U+FFFD (three).
// A maximum refuses on the first excess. A minimum alone stops once satisfied.
function text_bytes(value: string, minimum: bigint, maximum: bigint | null): void {
	// Every UTF-16 unit contributes at most three bytes. Check the counter's
	// exact range once, before scanning, rather than on each character.
	if (value.length > Number.MAX_SAFE_INTEGER / 3) throw new TypeError("text byte length exceeds exact counter");
	let bytes = 0;
	for (let index = 0; index < value.length; index++) {
		const unit = value.charCodeAt(index);
		if (unit < 0x80) bytes++;
		else if (unit < 0x800) bytes += 2;
		else {
			bytes += 3;
			if (unit >= 0xd800 && unit <= 0xdbff) {
				const next = value.charCodeAt(index + 1);
				if (next >= 0xdc00 && next <= 0xdfff) {
					bytes++;
					index++;
				}
			}
		}
		if (maximum !== null && bytes > maximum) throw new TypeError("text outside byte bounds");
		if (maximum === null && bytes >= minimum) return;
	}
	if (bytes < minimum) throw new TypeError("text outside byte bounds");
}
function text_3_unbounded(value: unknown): string {
	if (typeof value !== "string") throw new TypeError("wrong scalar value");
	text_bytes(value, 3n, null);
	return value;
}
function text_0_4(value: unknown): string {
	if (typeof value !== "string") throw new TypeError("wrong scalar value");
	text_bytes(value, 0n, 4n);
	return value;
}
function text_0_0(value: unknown): string {
	if (typeof value !== "string") throw new TypeError("wrong scalar value");
	text_bytes(value, 0n, 0n);
	return value;
}
function text_1_4(value: unknown): string {
	if (typeof value !== "string") throw new TypeError("wrong scalar value");
	text_bytes(value, 1n, 4n);
	return value;
}
function text(value: Argument): string {
	if (typeof value !== "string") throw new TypeError("expected string reply");
	return value;
}

function call_0(
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
	const raw = session.send(target, "bare_call", args);
	return new Pending(raw, text);
}

function call_1(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "bare_optional", args);
	return new Pending(raw, text);
}

function call_2(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "bare_tell", args);
}

function call_3(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "bare_optional_tell", args);
}

function call_4(
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
	const raw = session.send(target, "empty_call", args);
	return new Pending(raw, text);
}

function call_5(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	const raw = session.send(target, "empty_optional", args);
	return new Pending(raw, text);
}

function call_6(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
	args[0] = arg0;
	return session.tell(target, "empty_tell", args);
}

function call_7(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		if (typeof arg0 !== "string") throw new TypeError("invalid argument 0");
		args[0] = arg0;
	}
	return session.tell(target, "empty_optional_tell", args);
}

function call_8(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_3_unbounded(arg0);
	const raw = session.send(target, "lower_call", args);
	return new Pending(raw, text_3_unbounded);
}

function call_9(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_3_unbounded(arg0);
	}
	const raw = session.send(target, "lower_optional", args);
	return new Pending(raw, text_3_unbounded);
}

function call_10(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_3_unbounded(arg0);
	return session.tell(target, "lower_tell", args);
}

function call_11(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_3_unbounded(arg0);
	}
	return session.tell(target, "lower_optional_tell", args);
}

function call_12(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_0_4(arg0);
	const raw = session.send(target, "upper_call", args);
	return new Pending(raw, text_0_4);
}

function call_13(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_0_4(arg0);
	}
	const raw = session.send(target, "upper_optional", args);
	return new Pending(raw, text_0_4);
}

function call_14(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_0_4(arg0);
	return session.tell(target, "upper_tell", args);
}

function call_15(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_0_4(arg0);
	}
	return session.tell(target, "upper_optional_tell", args);
}

function call_16(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_0_0(arg0);
	const raw = session.send(target, "zero_call", args);
	return new Pending(raw, text_0_0);
}

function call_17(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_0_0(arg0);
	}
	const raw = session.send(target, "zero_optional", args);
	return new Pending(raw, text_0_0);
}

function call_18(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_0_0(arg0);
	return session.tell(target, "zero_tell", args);
}

function call_19(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_0_0(arg0);
	}
	return session.tell(target, "zero_optional_tell", args);
}

function call_20(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_1_4(arg0);
	const raw = session.send(target, "bounded_call", args);
	return new Pending(raw, text_1_4);
}

function call_21(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_1_4(arg0);
	}
	const raw = session.send(target, "bounded_optional", args);
	return new Pending(raw, text_1_4);
}

function call_22(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_1_4(arg0);
	return session.tell(target, "bounded_tell", args);
}

function call_23(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_1_4(arg0);
	}
	return session.tell(target, "bounded_optional_tell", args);
}

function call_24(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_1_4(arg0);
	const raw = session.send(target, "alias_call", args);
	return new Pending(raw, text_1_4);
}

function call_25(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Pending<string> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_1_4(arg0);
	}
	const raw = session.send(target, "alias_optional", args);
	return new Pending(raw, text_1_4);
}

function call_26(
	session: Session,
	target: Ref | RemotePromise,
	arg0: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 1 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	args[0] = text_1_4(arg0);
	return session.tell(target, "alias_tell", args);
}

function call_27(
	session: Session,
	target: Ref | RemotePromise,
	arg0?: string,
): Promise<void> {
	const supplied = arguments.length - 2;
	if (supplied < 0 || supplied > 1) throw new TypeError("wrong argument count");
	// One array is allocated at supplied arity; packing adds no payload snapshot.
	const args = new Array<Argument>(supplied);
	if (supplied > 0) {
		args[0] = text_1_4(arg0);
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
export { call_16 as zero_call };
export { call_17 as zero_optional };
export { call_18 as zero_tell };
export { call_19 as zero_optional_tell };
export { call_20 as bounded_call };
export { call_21 as bounded_optional };
export { call_22 as bounded_tell };
export { call_23 as bounded_optional_tell };
export { call_24 as alias_call };
export { call_25 as alias_optional };
export { call_26 as alias_tell };
export { call_27 as alias_optional_tell };
