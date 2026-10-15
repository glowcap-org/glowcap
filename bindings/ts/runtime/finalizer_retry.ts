/** Failure-cold retry authority for FFI releases refused from implicit
 * finalizers. A runtime boundary claims one finite batch; a callback that is
 * refused again re-enqueues itself for a later boundary rather than spinning. */

export type FinalizerRetry = () => void;

const pending = new Set<FinalizerRetry>();
let draining = false;

export function deferFinalizerRetry(retry: FinalizerRetry): void {
	pending.add(retry);
}

export function drainFinalizerRetries(): void {
	if (draining || pending.size === 0) return;
	draining = true;
	try {
		const claimed = [...pending];
		pending.clear();
		for (const retry of claimed) retry();
	} finally {
		draining = false;
	}
}

/** Package-internal recurring-evidence hook. */
export function pendingFinalizerRetryCount(): number {
	return pending.size;
}
