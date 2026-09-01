// Failure reporting and retained-line cleanup for durable runtime resources.

import { cleanupSettledBySessionClose, settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import type { DurableRoomsArchiveShares } from "./archive_shares.ts";
import { cancelDirectRouteAttempts } from "./directory_directs.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import type { DurableRoomsOperations } from "./operations.ts";

export class RuntimeCleanupFailures {
	readonly #errors: Error[] = [];
	readonly #closedSessionIsSettled: boolean;

	constructor(closedSessionIsSettled = true) {
		this.#closedSessionIsSettled = closedSessionIsSettled;
	}

	async attempt(label: string, work: () => unknown | Promise<unknown>): Promise<void> {
		try {
			await work();
		} catch (error) {
			if (this.#closedSessionIsSettled && cleanupSettledBySessionClose(error)) return;
			this.#errors.push(
				new Error(`Rooms session ${label}: ${error instanceof Error ? error.message : error}`, {
					cause: error,
				}),
			);
		}
	}

	finish(): void {
		if (this.#errors.length === 1) throw this.#errors[0];
		if (this.#errors.length > 1) throw new AggregateError(this.#errors, "Rooms session cleanup failed");
	}
}

export async function cleanupRuntime(work: Promise<unknown>, label: string): Promise<void> {
	await cleanupRuntimeAction(() => work, label);
}

export async function cleanupRuntimeAction(
	work: () => unknown | Promise<unknown>,
	label: string,
): Promise<void> {
	try {
		await work();
	} catch (error) {
		if (cleanupSettledBySessionClose(error)) return;
		console.error(`rooms session: ${label}: ${error instanceof Error ? error.message : error}`);
	}
}

export function releaseRoomResources(live: LiveRoom): void {
	for (const line of live.postedLines.values()) {
		settleCapabilityCleanup("room posted-line release failed", () => line.release());
	}
	live.postedLines.clear();
	live.pendingLines.length = 0;
	live.files.close();
}

export async function closeRuntimeDirectories(
	directories: Map<string, LiveDirectory>,
	operations: DurableRoomsOperations,
	archiveShares: DurableRoomsArchiveShares,
): Promise<void> {
	const cleanup = new RuntimeCleanupFailures();
	await cleanup.attempt("operations capabilities would not close", () => operations.close());
	const live = [...directories.values()].reverse();
	directories.clear();
	for (const held of live) {
		await cleanup.attempt(`directory ${held.id} would not close`, () => closeRuntimeDirectory(held, archiveShares));
	}
	cleanup.finish();
}

export async function closeRuntimeDirectory(
	held: LiveDirectory,
	archiveShares: DurableRoomsArchiveShares,
): Promise<void> {
	const cleanup = new RuntimeCleanupFailures();
	await cleanup.attempt("directory close observer would not stop", () => held.stopClose());
	held.directIntents.clear();
	held.directConversationByRegistration.clear();
	const openings = cancelDirectRouteAttempts(held);
	await cleanup.attempt("archive shares would not release", () => archiveShares.releaseDirectory(held.id));
	await cleanup.attempt("direct inbox offerer would not close", () => held.offerer.close());
	for (const direct of [...held.directs.values()].reverse()) {
		await cleanup.attempt("direct conversation would not close", () => direct.close());
	}
	await held.roomRealization.close(
		releaseRoomResources,
		(work, label) => cleanup.attempt(label, () => work),
	);
	await cleanup.attempt("WebRTC signaling would not close", () => held.signaling?.close() ?? Promise.resolve());
	await cleanup.attempt("directory would not close", () => held.directory.close());
	await cleanup.attempt("direct route openings would not settle", () => openings);
	cleanup.finish();
}
