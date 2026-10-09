// Startup restores original receipts and retires completed diagnostic wrappers.
import type {
	RoomsManagedCommand,
	RoomsManagedRecoveredEffect,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ManagedOperation, readResult, ResultExpired, TerminalObservationError } from "./operation.ts";

export async function discloseFailure(request: Pick<RoomsManagedCommand, "result">, retire: () => void): Promise<void> {
	try {
		await readResult(request);
	} catch (error) {
		if (error instanceof TerminalObservationError) retire();
		throw error;
	}
}

export async function resumeEffect(request: RoomsManagedRecoveredEffect, retire: () => void): Promise<string> {
	const status = await request.status();
	try {
		// Unknown can mean a paused executor with no result yet. Resume checks
		// that exact owner; a speculative result read would prevent its recovery.
		return await request.resume();
	} catch (error) {
		if (status === "unknown") {
			try {
				await discloseFailure(request, retire);
			} catch (diagnostic) {
				if (diagnostic instanceof TerminalObservationError) throw diagnostic;
			}
		}
		throw error;
	}
}

/** Give up on one receipt for good. The workspace forgets it and a held copy
 * is finished here, so nothing resumes or resubmits its operation. */
export async function releaseEffect(
	workspace: RoomsManagedWorkspace,
	id: string,
	held: ManagedOperation | undefined,
	finish: (operation: ManagedOperation) => void,
): Promise<void> {
	const effect = await workspace.recoverEffect(id);
	try {
		await effect?.release();
	} finally {
		effect?.free();
	}
	if (held != null) finish(held);
}

export interface Recovery {
	workspace: RoomsManagedWorkspace;
	retain(operation: ManagedOperation): void;
	finish(operation: ManagedOperation): void;
	complete(operation: ManagedOperation): Promise<unknown>;
	report(error: unknown): void;
}

export async function restoreEffects(viewer: Recovery): Promise<void> {
	for (const receipt of await viewer.workspace.effects()) {
		if (receipt.status === "unsent") continue;
		const recovered = await viewer.workspace.recoverEffect(receipt.operation);
		if (recovered == null) continue;
		const operation = new ManagedOperation(receipt.operation, recovered);
		viewer.retain(operation);
		if (receipt.status === "pending") continue;
		try {
			if (receipt.status === "unknown") await operation.result();
			else await viewer.complete(operation);
		} catch (error) {
			if (error instanceof TerminalObservationError || error instanceof ResultExpired) {
				viewer.finish(operation);
				viewer.report(error);
				continue;
			}
			// Another viewer can adopt and retire a receipt during a result read.
			// Confirm exact absence; an interrupted read keeps the original owner.
			const retained = await viewer.workspace.recoverEffect(receipt.operation);
			if (retained == null) viewer.finish(operation);
			else {
				retained.free();
				viewer.report(error);
			}
		}
	}
}
