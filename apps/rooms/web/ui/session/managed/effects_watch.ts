// Watching one receipt until it settles: the session's own status says whether a
// change committed, is still pending, or left nothing to confirm.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type { ManagedEffects } from "./effects.ts";
import type { OperationLifecycle } from "./lifecycle.ts";
import { type ManagedOperation, readResult, TerminalObservationError, UnsentEffectError } from "./operation.ts";
import { discloseFailure } from "./recovery.ts";

/** Wait on `operation` until its status is final, and return it once committed. */
export async function watchReceipt(
	effects: ManagedEffects,
	lifecycle: OperationLifecycle,
	operation: ManagedOperation,
): Promise<ManagedOperation> {
	const { environment } = effects;
	while (!environment.stopped()) {
		const change = environment.change();
		const status = await operation.status();
		lifecycle.outcome = status === "committed" ? "committed" : status === "pending" ? "pending" : "unknown";
		if (status === "committed") {
			// This read is the receipt's own acquisition, not a follow-up: its failure
			// is the receipt's recovery verdict (`addressed-snapshot`), so it stays
			// raw and never falls back to a notice.
			try {
				await effects.readNow();
			} catch (error) {
				environment.changed();
				throw operation.completionError(error, "addressed-snapshot");
			}
			return operation;
		}
		if (status !== "pending") {
			if (status === "unsent") {
				// Admission refusal proves no dispatch and retains its exact
				// diagnostic. A locally unsent receipt may have no such result.
				try {
					await readResult(operation.request);
				} catch (error) {
					if (error instanceof TerminalObservationError) {
						throw new UnsentEffectError(error.message, error.failure);
					}
					throw error;
				} finally {
					effects.finish(operation);
				}
				throw new LocalRefusal("not-sent");
			}
			// Failed observations disclose their reason through the exact
			// original receipt, with current authority checked again.
			if (status === "unknown") {
				await discloseFailure(operation.request, () => effects.finish(operation));
			}
			throw new LocalRefusal("change-unconfirmed", {
				cause: `retained operation is ${status}`,
			});
		}
		if (environment.observationFailure() != null) throw environment.observationFailure();
		if (change !== environment.change()) continue;
		operation.observe(() => environment.changed());
		await environment.wait(change);
		if (environment.stopped()) {
			throw new LocalRefusal("session-closed");
		}
	}
	throw new LocalRefusal("session-closed");
}
