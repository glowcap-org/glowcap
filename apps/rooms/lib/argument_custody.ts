// Capability-occurrence cleanup for application protocol arguments.

import { type Argument, PSet, PStruct, Ref, retainSecondaryFailure, type Session, Tagged } from "@pancake/runtime";

const NO_CAPABILITIES: ReadonlySet<Ref> = new Set();

function visitCapabilities(value: Argument, visit: (capability: Ref) => void): void {
	if (value instanceof Ref) {
		visit(value);
		return;
	}
	if (Array.isArray(value)) {
		for (const entry of value) visitCapabilities(entry, visit);
		return;
	}
	if (value instanceof PSet) {
		for (const entry of value.items) visitCapabilities(entry, visit);
		return;
	}
	if (value instanceof Tagged) {
		for (const entry of value.value) visitCapabilities(entry, visit);
		return;
	}
	if (value instanceof PStruct) {
		for (const [, entry] of value.entries) visitCapabilities(entry, visit);
	}
}

export function hasCapabilityArguments(args: readonly Argument[]): boolean {
	let found = false;
	for (const argument of args) {
		visitCapabilities(argument, () => found = true);
		if (found) return true;
	}
	return false;
}

/** Release every capability occurrence not explicitly adopted, preserving the
 * primary failure and every cleanup failure in their observed order. */
export function releaseCapabilityArguments(
	session: Session,
	args: readonly Argument[],
	keep: ReadonlySet<Ref> = NO_CAPABILITIES,
	primary: unknown | null = null,
): unknown | null {
	let failure = primary;
	for (const argument of args) {
		visitCapabilities(argument, (capability) => {
			if (keep.has(capability)) return;
			try {
				session.release(capability);
			} catch (cleanup) {
				failure = failure == null ? cleanup : retainSecondaryFailure(failure, cleanup);
			}
		});
	}
	return failure;
}

export function refuseCapabilityArguments(session: Session, args: readonly Argument[], message: string): never {
	throw releaseCapabilityArguments(session, args, NO_CAPABILITIES, new Error(message));
}

export function throwAfterReleasingCapabilities(
	session: Session,
	args: readonly Argument[],
	failure: unknown,
): never {
	throw releaseCapabilityArguments(session, args, NO_CAPABILITIES, failure);
}

/** Release surplus occurrences while retaining the parsed capability set. A
 * cleanup refusal makes the call itself unsafe to accept, so the retained set
 * is returned too and the combined failure is surfaced. */
export function releaseUnexpectedCapabilityArguments(
	session: Session,
	args: readonly Argument[],
	keep: ReadonlySet<Ref>,
	cleanupMessage: string,
): void {
	const failure = releaseCapabilityArguments(session, args, keep);
	if (failure == null) return;
	throw releaseCapabilityArguments(
		session,
		[...keep],
		NO_CAPABILITIES,
		new Error(cleanupMessage, { cause: failure }),
	);
}

export function releaseUnclaimedCapabilityArguments(
	session: Session,
	args: readonly Argument[],
	cleanupMessage: string,
): void {
	releaseUnexpectedCapabilityArguments(session, args, NO_CAPABILITIES, cleanupMessage);
}
