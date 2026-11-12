import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { recordCallerlessFailure } from "../context.ts";
import { type HostFinalizerState, retireHostFinalizerState } from "../host/finalizer.ts";
import { traceDetachHost, traceDrainHost } from "../trace.ts";
import { driverRelease } from "../internal/driver_failure.ts";
import { deferFinalizerRetry, type FinalizerRetry } from "../finalizer_retry.ts";

export interface DriverLoopFinalizerState {
	handle: Ptr;
	host: HostFinalizerState;
	releaseFailureReported: boolean;
	retry?: FinalizerRetry;
}

function releaseDriverLoopFinalizerState(state: DriverLoopFinalizerState): void {
	if (state.handle === NULL) return;
	const hostRaw = state.host.raw;
	traceDrainHost(hostRaw);
	const outcome = driverRelease("driver-loop.finalizer.release", state.handle);
	const rc = outcome.code;
	if (outcome.error !== null) {
		const consumed = outcome.consumed;
		if (!state.releaseFailureReported) {
			state.releaseFailureReported = true;
			recordCallerlessFailure(state.host.context, {
				layer: "binding",
				scope: "host",
				scopeId: state.host.diagnosticId,
				operation: "driver-loop.finalizer.release",
				primaryName: outcome.failure?.primaryName ??
					(consumed ? "DriverLoopReleaseFailed" : "DriverLoopReleaseRefused"),
				primaryResult: outcome.error.code,
				primaryMessage: outcome.error.detail ?? `driver release failed (code ${rc})`,
				secondaryName: outcome.failure?.secondaryName,
				secondaryResult: outcome.failure?.secondaryResult,
				secondaryCount: outcome.failure?.secondaryCount,
			});
		}
		if (!consumed) {
			state.retry ??= () => releaseDriverLoopFinalizerState(state);
			deferFinalizerRetry(state.retry);
			return;
		}
	}
	state.handle = NULL;
	traceDetachHost(hostRaw);
	retireHostFinalizerState(state.host);
}

const driverLoopFinalizer = new FinalizationRegistry<DriverLoopFinalizerState>((state) => {
	releaseDriverLoopFinalizerState(state);
});

export function registerDriverLoopFinalizer(
	owner: object,
	handle: Ptr,
	host: HostFinalizerState,
): DriverLoopFinalizerState {
	const state = { handle, host, releaseFailureReported: false };
	driverLoopFinalizer.register(owner, state, owner);
	return state;
}

/** Mark the FFI lease consumed before unregistering the implicit owner. */
export function retireDriverLoopFinalizer(
	owner: object,
	state: DriverLoopFinalizerState | null,
): void {
	if (state != null) state.handle = NULL;
	driverLoopFinalizer.unregister(owner);
}
