// Known absence permits re-preparation only while the original selection holds.
// Uncertain admission stays with the viewer's retained request.
import type { ManagedRoomsSession } from "./session.ts";
import { ManagedOperation, WorkspaceConflict } from "./operation.ts";
import { MAX_CONFLICT_REPREPARATIONS } from "./acquisition.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import { applicationModule } from "../../application.ts";

/** Layout of the tuple returned by `pending.request.originalIntent()`: the
 * producer serializes `(id, base, name, args)` with the workspace base
 * revision as a JSON number (application/src/session/command.rs). */
export type RetainedCommandIntent = readonly [
	id: string,
	base: number,
	name: string,
	args: readonly unknown[],
];

/** Whether a value from `originalIntent()` has the retained tuple layout. */
export function isRetainedCommandIntent(raw: unknown): raw is RetainedCommandIntent {
	return Array.isArray(raw) && raw.length >= 4 &&
		typeof raw[0] === "string" && typeof raw[1] === "number" &&
		typeof raw[2] === "string" && Array.isArray(raw[3]);
}

/** The conversation a retained intent names: the first argument of the tuple
 * layout, or the conversation field of an object intent. */
export function retainedIntentConversation(raw: unknown): unknown {
	if (isRetainedCommandIntent(raw)) return raw[3][0];
	if (raw != null && typeof raw === "object" && !Array.isArray(raw)) {
		return (raw as { conversation?: unknown }).conversation;
	}
	return undefined;
}

function matchesRetainedCommand(
	raw: unknown,
	expectedName: string,
	expectedArgs: readonly string[],
): boolean {
	if (!isRetainedCommandIntent(raw)) return false;
	const [, , commandName, commandArgs] = raw;
	return commandName === expectedName && JSON.stringify(commandArgs) === JSON.stringify(expectedArgs);
}

export async function admitCommand(
	session: ManagedRoomsSession,
	name: string,
	args: string[] = [],
	operation: string = crypto.randomUUID(),
	validate?: (snapshot: WorkspaceSnapshot) => void,
	signal?: AbortSignal,
): Promise<ManagedOperation> {
	for (const pending of session.pendingOperations) {
		// Only the explicit gesture identity can select retained recovery.
		// Equal words are independent effects, including after an uncertain send.
		if (pending.id !== operation) continue;
		if (!matchesRetainedCommand(pending.request.originalIntent(), name, args)) {
			throw new Error("The retained gesture has different command contents. Recover its original receipt.");
		}
		return session.resume(operation);
	}
	// Capture the accepted selection on the press, before joining the admission
	// queue. A refresh may advance revision, but cannot change this intent's
	// authority while the reader is waiting.
	let original: WorkspaceSnapshot | undefined = session.current ?? undefined;
	let acceptedIntentJson: string | null = original == null ? null : JSON.stringify(original.intent);

	for (let attempt = 0; attempt < MAX_CONFLICT_REPREPARATIONS; attempt++) {
		try {
			return await session.perform(operation, async () => {
				// Read the authority at admission; observation is presentation.
				const snapshot = await session.refresh();
				const currentIntentJson = JSON.stringify(snapshot.intent);
				if (
					acceptedIntentJson != null && acceptedIntentJson !== currentIntentJson &&
					!applicationModule().commandSelectionUnchanged(
						name,
						args,
						acceptedIntentJson,
						currentIntentJson,
					)
				) throw new Error("The original command selection changed. Review it before submitting again.");
				if (original == null) {
					original = snapshot;
					acceptedIntentJson = currentIntentJson;
				}
				validate?.(snapshot);
				signal?.throwIfAborted();
				const request = await session.workspace.prepareCommand(operation, snapshot.revision, name, args);
				if (signal?.aborted) {
					request.free();
					signal.throwIfAborted();
				}
				return request;
			});
		} catch (error) {
			// Conflict proves no receipt or upstream effect exists. Uncertain
			// admissions keep their exact request in the viewer and never retry here.
			// Drafts owns its one rebase and compares the accepted text as well
			// as conversation authority. Generic gesture retries cannot do that.
			const canRetry = error instanceof WorkspaceConflict && name !== "setDraft" &&
				attempt + 1 < MAX_CONFLICT_REPREPARATIONS;
			if (!canRetry) throw error;
		}
	}
	throw new Error("Command admission exceeded conflict re-preparation attempts.");
}
