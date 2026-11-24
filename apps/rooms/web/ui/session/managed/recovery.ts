// The session's receipts over the page's link: startup adopts the ones this
// page holds no record of, a held one resumes or discloses its failure, and one
// given up is released.
import type {
	RoomsManagedCommand,
	RoomsManagedRecoveredEffect,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { connectionLost } from "../../../../lib/text/failure.ts";
import type { LinkPort } from "./link_port.ts";
import { type ReleaseBound, type ReleaseEnd, releaseReceipt, type ReleaseWait } from "./release.ts";
import {
	ManagedOperation,
	readResult,
	ResultAcquisitionError,
	ResultExpired,
	standsAfterCommit,
	TerminalObservationError,
} from "./operation.ts";

export async function discloseFailure(request: Pick<RoomsManagedCommand, "result">, retire: () => void): Promise<void> {
	try {
		await readResult(request);
	} catch (error) {
		if (error instanceof TerminalObservationError) retire();
		throw error;
	}
}

export async function resumeEffect(
	request: RoomsManagedRecoveredEffect,
	retire: () => void,
	observe?: (status: string) => void,
): Promise<string> {
	const status = await request.status();
	observe?.(status);
	try {
		// Unknown can mean a paused executor with no result yet. Resume checks
		// that exact owner; a speculative result read would prevent its recovery.
		const resumed = await request.resume();
		observe?.(resumed);
		return resumed;
	} catch (error) {
		if (status === "unknown") {
			try {
				await discloseFailure(request, retire);
			} catch (diagnostic) {
				if (diagnostic instanceof TerminalObservationError) throw diagnostic;
			}
		}
		throw status === "committed" && !standsAfterCommit(error)
			? new ResultAcquisitionError(undefined, error, "resume-effect")
			: error;
	}
}

/** Give up on one receipt for good, and say how the session answered. The
 * workspace forgets it and a held copy is finished here, so nothing resumes
 * or resubmits its operation. A receipt whose job still runs is asked again
 * until it ends (`releaseReceipt`). A receipt whose result was adopted
 * answers `kept`: the workspace holds what it returned. A release a lost
 * connection or a newer link ended is asked again over the next link within
 * the same bound. A receipt the session already released is gone from it
 * there, so asking again lets it go once. */
export async function releaseEffect(
	page: Pick<LinkPort, "over" | "relinkedAfter"> & ReleaseWait,
	id: string,
	held: ManagedOperation | undefined,
	finish: (operation: ManagedOperation) => void,
): Promise<ReleaseEnd> {
	const since: ReleaseBound = { deadline: null };
	// Each pass ends released or kept, or with a failure no relink answers,
	// which includes a closed page.
	let answer: ReleaseEnd | null = null;
	while (answer == null) {
		try {
			answer = await page.over(async (link): Promise<ReleaseEnd> => {
				const effect = await link.workspace.recoverEffect(id);
				if (effect == null) return "released";
				try {
					return await releaseReceipt(effect, link, page, "change-busy", since);
				} finally {
					effect.free();
				}
			});
		} catch (error) {
			if (!await page.relinkedAfter(error)) throw error;
		}
	}
	if (held != null) finish(held);
	return answer;
}

interface Recovery {
	/** The page's link, whose handle each call reads at the call. */
	port: Pick<LinkPort, "current" | "isCurrent" | "over" | "overStamped">;
	/** Whether this viewer already holds a record of the receipt. */
	known(id: string): boolean;
	retain(operation: ManagedOperation): void;
	orphan?(operation: ManagedOperation): void;
	finish(operation: ManagedOperation): void;
	complete(operation: ManagedOperation): Promise<unknown>;
	report(error: unknown): void;
}

/** A pass over one link that a newer link replaced. */
class PassEnded extends Error {}

/** Adopt each receipt the session holds that this viewer has no record of, in
 * one pass over the current link, and say whether the pass finished. A lost
 * connection or a newer link ends the pass unfinished, and a pass over the
 * next link adopts the rest. A receipt adopted before the pass ended is held,
 * so no later pass adopts it again. */
export async function restoreEffects(viewer: Recovery): Promise<boolean> {
	const { port } = viewer;
	const pass = port.current();
	const onPass = <T>(call: (workspace: RoomsManagedWorkspace) => Promise<T>): Promise<T> =>
		port.isCurrent(pass) ? port.over((link) => call(link.workspace)) : Promise.reject(new PassEnded());
	try {
		for (const receipt of await onPass((workspace) => workspace.effects())) {
			if (receipt.status === "unsent" || receipt.released || viewer.known(receipt.operation)) continue;
			const recovered = await onPass((workspace) => workspace.recoverEffect(receipt.operation));
			if (recovered == null) continue;
			// A newer link, or a move for it, may have taken this receipt up meanwhile.
			if (!port.isCurrent(pass) || viewer.known(receipt.operation)) {
				recovered.free();
				continue;
			}
			const operation = new ManagedOperation(receipt.operation, recovered, pass, receipt.status);
			viewer.retain(operation);
			if (receipt.status === "pending") {
				viewer.orphan?.(operation);
				continue;
			}
			try {
				await port.overStamped(
					operation.stamp,
					() => receipt.status === "unknown" ? operation.result() : viewer.complete(operation),
				);
			} catch (error) {
				if (error instanceof TerminalObservationError || error instanceof ResultExpired) {
					viewer.finish(operation);
					viewer.report(error);
					continue;
				}
				// The receipt is held, and whoever next asks for it moves it.
				if (connectionLost(error)) return false;
				// Another viewer can adopt and retire a receipt during a result read.
				// Confirm exact absence; an interrupted read keeps the original owner.
				const retained = await onPass((workspace) => workspace.recoverEffect(receipt.operation));
				if (retained == null) viewer.finish(operation);
				else {
					retained.free();
					viewer.report(error);
				}
			} finally {
				viewer.orphan?.(operation);
			}
		}
		// A receipt skipped because a newer link came is the next pass's.
		return port.isCurrent(pass);
	} catch (error) {
		if (error instanceof PassEnded || connectionLost(error)) return false;
		throw error;
	}
}
