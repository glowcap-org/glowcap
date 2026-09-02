import { CLOSED } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { recordProcessBindingFailure } from "../context.ts";

function cancelled(): GlowcapError {
	return new GlowcapError(CLOSED, "host released while dialing");
}

export function cancellationError(signal: AbortSignal): unknown {
	const reason = signal.reason;
	return reason instanceof Error && reason.name !== "AbortError" ? reason : cancelled();
}

export function throwIfCancelled(signal?: AbortSignal): void {
	if (signal?.aborted) throw cancelled();
}

type LateValueOwner<T> = (value: T) => void | Promise<void>;
type LateFailureRecipient = (error: unknown) => void;

function ownLateValue<T>(
	value: T,
	owner: LateValueOwner<T>,
	recipient: LateFailureRecipient,
): void {
	let result: void | Promise<void>;
	try {
		result = owner(value);
	} catch (error) {
		reportLateFailure(recipient, error);
		return;
	}
	void Promise.resolve(result).catch((error) => reportLateFailure(recipient, error));
}

function reportLateFailure(recipient: LateFailureRecipient, error: unknown): void {
	try {
		recipient(error);
	} catch (observerError) {
		// A process fallback is the last surviving owner if a package-supplied
		// diagnostic observer itself refuses. Neither failure may change the
		// cancellation result that the caller already received.
		recordProcessBindingFailure("abortable.late-cleanup.diagnostic", error);
		recordProcessBindingFailure("abortable.late-cleanup.diagnostic-observer", observerError);
	}
}

/** Reject promptly on cancellation while still taking responsibility for an
 * uncancellable host promise's eventual outcome. A cancellation recipient is
 * mandatory whenever a signal can win: a late rejection has no return caller,
 * and a late value owner may itself refuse. */
export function abortable<T>(pending: Promise<T>): Promise<T>;
export function abortable<T>(
	pending: Promise<T>,
	signal: AbortSignal | undefined,
	onLateFailure: LateFailureRecipient,
	onLateValue?: LateValueOwner<T>,
): Promise<T>;
export async function abortable<T>(
	pending: Promise<T>,
	signal?: AbortSignal,
	onLateFailure?: LateFailureRecipient,
	onLateValue?: LateValueOwner<T>,
): Promise<T> {
	if (signal != null && onLateFailure == null) {
		throw new TypeError("cancellable operation requires a late failure recipient");
	}
	const ownLate = (value: T): void => {
		if (onLateValue != null && onLateFailure != null) {
			ownLateValue(value, onLateValue, onLateFailure);
		}
	};
	const failLate = (error: unknown): void => {
		if (onLateFailure != null) reportLateFailure(onLateFailure, error);
	};
	if (signal == null) return await pending;
	if (signal.aborted) {
		void pending.then(ownLate, failLate);
		throw cancellationError(signal);
	}
	return await new Promise<T>((resolve, reject) => {
		let settled = false;
		const onAbort = (): void => {
			if (settled) return;
			settled = true;
			reject(cancellationError(signal));
		};
		signal.addEventListener("abort", onAbort, { once: true });
		void pending.then(
			(value) => {
				if (settled) {
					ownLate(value);
					return;
				}
				settled = true;
				signal.removeEventListener("abort", onAbort);
				resolve(value);
			},
			(error) => {
				if (settled) {
					failLate(error);
					return;
				}
				settled = true;
				signal.removeEventListener("abort", onAbort);
				reject(error);
			},
		);
	});
}
