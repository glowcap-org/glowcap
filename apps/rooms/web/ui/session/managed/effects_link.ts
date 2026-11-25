// What a retained change does when the link to its session is replaced under it.
// The session's own record of the change is found again by its operation id over
// the new link, and the work goes on with that record. Nothing is sent a second
// time.
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import type { ManagedEffects } from "./effects.ts";
import { ManagedOperation, ResultExpired } from "./operation.ts";
import { resumeEffect } from "./recovery.ts";
import type { ReleaseBound } from "./release.ts";

/** Run `work` over the receipt `id`, and again over the new link each time a
 * lost connection ends it, for as long as the page is dialing. The work is run
 * more than once, so it is safe to run twice. Any other
 * failure ends the work. Its runs share one release bound
 * (`ManagedOperation.releaseBound`), which ends with the gesture however it
 * ends. */
export async function surviving<T>(
	effects: ManagedEffects,
	id: string,
	held: ManagedOperation | null,
	work: (operation: ManagedOperation) => Promise<T>,
): Promise<T> {
	const { environment } = effects;
	const bound: ReleaseBound = { deadline: null };
	const ran = new Set<ManagedOperation>();
	let operation = held;
	let current: ManagedOperation | null = null;
	try {
		while (!environment.stopped()) {
			try {
				operation ??= await effects.resume(id);
				const running = operation;
				current = running;
				ran.add(running);
				running.releaseBound = bound;
				return await environment.overStamped(running.stamp, () => work(running));
			} catch (error) {
				if (!await environment.relinkedAfter(error)) throw error;
				// A receipt the page finished is kept: its result is in place, and the work
				// that is left needs no lookup of it over the new link.
				operation = current?.finished ? current : null;
			}
		}
		throw new LocalRefusal("session-closed");
	} finally {
		for (const run of ran) if (run.releaseBound === bound) run.releaseBound = null;
	}
}

/** Move a receipt held over a replaced link onto the current one, so whoever
 * settles or completes the operation goes on with it. A lookup the new link
 * drops under is made again over the next one. With no record there, the page
 * cannot tell whether the change landed, and never sends it again, because the
 * session forbids a second submission under one id. The record is forgotten
 * only once its absence is proved, and that verdict is what the gesture hears,
 * whatever the read after it meets. */
export async function rehome(effects: ManagedEffects, operation: ManagedOperation): Promise<ManagedOperation> {
	const { environment } = effects;
	while (!environment.stopped()) {
		if (environment.isCurrent(operation.stamp)) return operation;
		try {
			const { recovered, link } = await environment.over(async (link) => ({
				recovered: await link.workspace.recoverEffect(operation.id),
				link,
			}));
			if (!environment.isCurrent(link) || environment.isCurrent(operation.stamp)) {
				// Another path moved it, or the link was replaced again meanwhile.
				recovered?.free();
				continue;
			}
			if (recovered == null) return absent(effects, operation);
			await operation.rebind(recovered, link);
			await environment.overStamped(link, () =>
				resumeEffect(
					recovered,
					() => effects.finish(operation),
					(observed) => operation.observeStatus(observed),
				));
			return operation;
		} catch (error) {
			if (!await environment.relinkedAfter(error)) throw error;
		}
	}
	throw new LocalRefusal("session-closed");
}

/** The session holds no record of `operation`: forget it, redraw what the
 * session holds, and throw what the gesture hears. */
async function absent(effects: ManagedEffects, operation: ManagedOperation): Promise<never> {
	const committed = operation.committed;
	effects.finish(operation);
	// Tolerant by design, unlike `Committed.readOr`: the verdict thrown below is
	// the gesture's outcome whatever this read meets, and a loss here must not
	// replace it with a rerun of a gesture that has no record to rerun.
	await effects.readNow().catch((error: unknown) => {
		// A lost connection was charged where it happened, and the link's notice
		// says so. The next answer redraws the page.
		if (!connectionLost(error)) effects.environment.report(managedText.resultRecovery, error);
	});
	throw committed ? new ResultExpired() : new LocalRefusal("receipt-lost");
}
