// Known absence permits re-preparation only while the original selection holds.
// Uncertain admission stays with the viewer's retained request.
import type { ManagedRoomsSession } from "./session.ts";
import { ManagedOperation, WorkspaceConflict } from "./operation.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import { applicationModule } from "../../application.ts";

export async function admitCommand(
	session: ManagedRoomsSession,
	name: string,
	args: string[] = [],
	operation: string = crypto.randomUUID(),
	validate?: (snapshot: WorkspaceSnapshot) => void,
): Promise<ManagedOperation> {
	for (const pending of session.pendingOperations) {
		// Only the explicit gesture identity can select retained recovery.
		// Equal words are independent effects, including after an uncertain send.
		if (pending.id !== operation) continue;
		const original = pending.request.originalIntent();
		if (!Array.isArray(original) || original[2] !== name || JSON.stringify(original[3]) !== JSON.stringify(args)) {
			throw new Error("The retained gesture has different command contents. Recover its original receipt.");
		}
		return session.resume(operation);
	}
	let original: WorkspaceSnapshot | undefined;
	for (let attempt = 0;; attempt++) {
		try {
			return await session.perform(operation, async () => {
				// Read the authority at admission; observation is presentation.
				const snapshot = await session.refresh();
				if (
					original != null && !applicationModule().commandSelectionUnchanged(
						name,
						args,
						JSON.stringify(original.intent),
						JSON.stringify(snapshot.intent),
					)
				) throw new Error("The original command selection changed. Review it before submitting again.");
				original ??= snapshot;
				validate?.(snapshot);
				return await session.workspace.prepareCommand(operation, snapshot.revision, name, args);
			});
		} catch (error) {
			// Conflict proves no receipt or upstream effect exists. Uncertain
			// admissions keep their exact request in the viewer and never retry here.
			// Drafts owns its one rebase and compares the accepted text as well
			// as conversation authority. Generic gesture retries cannot do that.
			if (!(error instanceof WorkspaceConflict) || name === "setDraft" || attempt === 3) throw error;
		}
	}
}
