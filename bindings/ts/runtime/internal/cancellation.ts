import { CLOSED } from "@pancake/abi";
import { PancakeError } from "../errors.ts";

function cancelled(): PancakeError {
	return new PancakeError(CLOSED, "host released while dialing");
}

function abortError(signal: AbortSignal): unknown {
	const reason = signal.reason;
	return reason instanceof Error && reason.name !== "AbortError" ? reason : cancelled();
}

export function throwIfCancelled(signal?: AbortSignal): void {
	if (signal?.aborted) throw cancelled();
}

/** Reject promptly on cancellation while still taking responsibility for a
 * resource an uncancellable host promise may produce later. */
export async function abortable<T>(
	pending: Promise<T>,
	signal?: AbortSignal,
	onLateValue?: (value: T) => void,
): Promise<T> {
	if (signal == null) return await pending;
	if (signal.aborted) {
		void pending.then((value) => onLateValue?.(value), () => {});
		throw abortError(signal);
	}
	return await new Promise<T>((resolve, reject) => {
		let settled = false;
		const onAbort = (): void => {
			if (settled) return;
			settled = true;
			reject(abortError(signal));
		};
		signal.addEventListener("abort", onAbort, { once: true });
		void pending.then(
			(value) => {
				if (settled) {
					onLateValue?.(value);
					return;
				}
				settled = true;
				signal.removeEventListener("abort", onAbort);
				resolve(value);
			},
			(error) => {
				if (settled) return;
				settled = true;
				signal.removeEventListener("abort", onAbort);
				reject(error);
			},
		);
	});
}
