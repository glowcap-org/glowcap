// What a retained change does when the link to its session is replaced under it.
// The session's own record of the change is found again by its operation id over
// the new link, and the work goes on with that record. Nothing is prepared or
// sent a second time.
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type { RoomsManagedCommand } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedEffects } from "./effects.ts";
import { isRetainedCommandIntent } from "./admission.ts";
import { ManagedOperation, ReceiptRetired } from "./operation.ts";
import { resumeEffect } from "./recovery.ts";

/** Run `work` over the receipt `id`, and again over the new link each time a
 * lost connection ends it, for as long as the page is dialing. Any other
 * failure ends the work. */
export async function surviving<T>(
	effects: ManagedEffects,
	id: string,
	held: ManagedOperation | null,
	work: (operation: ManagedOperation) => Promise<T>,
): Promise<T> {
	let operation = held;
	while (!effects.environment.stopped()) {
		try {
			operation ??= await effects.resume(id);
			return await work(operation);
		} catch (error) {
			if (!await returned(effects, operation ?? effects.held(id), error)) throw error;
			operation = null;
		}
	}
	throw new LocalRefusal("session-closed");
}

/** Whether `error` was a lost connection, and a new link is now live. */
export async function returned(
	effects: ManagedEffects,
	operation: ManagedOperation | undefined,
	error: unknown,
): Promise<boolean> {
	if (!connectionLost(error)) return false;
	effects.environment.lost(error, operation?.link ?? effects.environment.generation());
	return await effects.environment.relinked();
}

/** Move a receipt held over a replaced link onto the new one, and say whether
 * the session still holds it. The session's record is resumed, and becomes
 * what the same operation reads, so whoever settles or completes the operation
 * goes on with it. False is exact absence. */
async function reclaim(effects: ManagedEffects, operation: ManagedOperation): Promise<boolean> {
	const { environment } = effects;
	while (!environment.stopped()) {
		const link = environment.generation();
		if (operation.link === link) return true;
		const recovered = await effects.workspace.recoverEffect(operation.id);
		if (link !== environment.generation() || operation.link === link) {
			// Another path moved it, or the link was replaced again meanwhile.
			recovered?.free();
			continue;
		}
		if (recovered == null) return false;
		await operation.rebind(recovered, link);
		await resumeEffect(recovered, () => effects.finish(operation), (observed) => operation.observeStatus(observed));
		return true;
	}
	throw new LocalRefusal("session-closed");
}

/** Move a receipt onto the new link. Exact absence means another viewer adopted
 * and retired it. */
export async function rehome(effects: ManagedEffects, operation: ManagedOperation): Promise<ManagedOperation> {
	if (await reclaim(effects, operation)) return operation;
	effects.finish(operation);
	await effects.refresh();
	throw new ReceiptRetired();
}

/** How a command sent as its link broke goes out again, or null when the
 * session holds a trace of it, which is then adopted and settles it. With no
 * trace the old request is released, and the same operation id is prepared again
 * over the new link. A plain command keeps its original base, so the session
 * lands it once or refuses it as stale. Any other change prepares as it first
 * did, which reads the session's state anew. */
export async function resend(
	effects: ManagedEffects,
	held: ManagedOperation | undefined,
	prepare: () => Promise<RoomsManagedCommand>,
): Promise<(() => Promise<RoomsManagedCommand>) | null> {
	if (held == null || await reclaim(effects, held)) return null;
	const intent = held.request.originalIntent();
	held.finish();
	if (!isRetainedCommandIntent(intent)) return prepare;
	const args = intent[3].filter((arg): arg is string => typeof arg === "string");
	if (args.length !== intent[3].length) return prepare;
	return () => effects.workspace.prepareCommand(held.id, String(intent[1]), intent[2], args);
}
