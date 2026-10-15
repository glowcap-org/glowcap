import { OK } from "@glowcap/abi";
import { Context, recordCallerlessFailure, releaseContext } from "../context.ts";
import { GlowcapError, hostLastError } from "../errors.ts";
import { deferFinalizerRetry, type FinalizerRetry } from "../finalizer_retry.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { releaseConsumed } from "../lifecycle.ts";
import { traceDetachHost, traceDrainHost } from "../trace.ts";
import { unregisterBehavior } from "../trampoline.ts";

export interface HostFinalizerState {
	raw: Ptr;
	/** Stable identity in the retained Context's diagnostic namespace. */
	diagnosticId: bigint;
	/** Process-global trampoline rows owned by this Host. */
	behaviorIds: Set<bigint>;
	/** Allocation policy retained until FFI Host release consumes ownership. */
	context: Context | null;
	releaseFailureReported: boolean;
	retry?: FinalizerRetry;
}

export function retireHostFinalizerState(state: HostFinalizerState): void {
	state.raw = NULL;
	for (const ctx of state.behaviorIds) unregisterBehavior(ctx);
	state.behaviorIds.clear();
	const context = state.context;
	state.context = null;
	if (context != null) releaseContext(context);
}

export function releaseHostState(
	state: HostFinalizerState,
	checked = false,
	transferRefusal = !checked,
): void {
	if (state.raw === NULL) return;
	const rc = hostS.glowcap_host_release(state.raw);
	if (rc === OK) {
		retireHostFinalizerState(state);
		return;
	}
	const failure = new GlowcapError(rc, hostLastError() ?? `FFI Host release failed (code ${rc})`);
	const consumed = releaseConsumed(rc);
	if (!checked && !state.releaseFailureReported && state.context != null) {
		state.releaseFailureReported = true;
		recordCallerlessFailure(state.context, {
			layer: "binding",
			scope: "host",
			scopeId: state.diagnosticId,
			operation: "host.finalizer.release",
			primaryName: consumed ? "HostReleaseFailed" : "HostReleaseRefused",
			primaryResult: rc,
			primaryMessage: failure.detail ?? failure.message,
		});
	}
	if (consumed) retireHostFinalizerState(state);
	else if (transferRefusal) {
		state.retry ??= () => releaseHostState(state);
		deferFinalizerRetry(state.retry);
	}
	if (checked) throw failure;
}

const hostFinalizer = new FinalizationRegistry<HostFinalizerState>((state) => {
	traceDrainHost(state.raw);
	traceDetachHost(state.raw);
	releaseHostState(state);
});

export function registerHostFinalizer(owner: object, state: HostFinalizerState): void {
	hostFinalizer.register(owner, state, owner);
}

export function unregisterHostFinalizer(owner: object): void {
	hostFinalizer.unregister(owner);
}
