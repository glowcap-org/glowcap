// Live conversation lookup and bounded waiting for session effects.

import type { Room } from "../lib/room_client.ts";
import type { DurableDirectLine } from "./direct_line.ts";
import type { LiveDirectory } from "./live.ts";
import { type DirectRealizationCallbacks, ensureDirectRoute } from "./directory_directs.ts";

const REALIZATION_WAIT_MS = 10_000;
export type DurableTypingTarget = { room: Room } | { direct: DurableDirectLine };

export function durableTypingTarget(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
): DurableTypingTarget | null {
	for (const directory of directories.values()) {
		const room = directory.roomRealization.rooms.get(conversationId);
		if (room != null) return { room: room.room };
		const direct = directory.directs.get(conversationId);
		if (direct != null) return { direct };
	}
	return null;
}

/** Wait for one in-flight reconciliation to realize a topology dependency, but
 * never let an external effect hold the session turn forever. */
export async function waitForLiveRealization<T>(
	find: () => T | null,
	pending: Promise<unknown>,
	timeoutMs = REALIZATION_WAIT_MS,
): Promise<T | null> {
	const current = find();
	if (current != null) return current;
	let timer: ReturnType<typeof setTimeout> | null = null;
	try {
		await Promise.race([
			pending,
			new Promise<void>((resolve) => {
				timer = setTimeout(resolve, timeoutMs);
			}),
		]);
	} finally {
		if (timer != null) clearTimeout(timer);
	}
	return find();
}

/** Realize one explicit user target without making intended direct state dial
 * on restore. The wait is runtime-owned and never occupies durable state. */
export async function realizeConversation(
	directories: ReadonlyMap<string, LiveDirectory>,
	pending: Promise<unknown>,
	callbacks: DirectRealizationCallbacks,
	kind: "room" | "direct",
	conversationId: string,
): Promise<void> {
	await pending;
	if (kind === "room") {
		for (const directory of directories.values()) {
			if (directory.roomRealization.rooms.has(conversationId)) return;
		}
		throw new Error("that room is not connected in this Rooms session");
	}
	let found: LiveDirectory | null = null;
	for (const directory of directories.values()) {
		if (!directory.directIntents.has(conversationId)) continue;
		found = directory;
		break;
	}
	if (found == null) throw new Error("that direct conversation is not intended in this Rooms session");
	if (found.directs.get(conversationId)?.line.live === true) return;
	await ensureDirectRoute(found, conversationId, callbacks);
	if (found.directs.get(conversationId)?.line.live !== true) {
		throw new Error("that direct conversation did not establish a live route");
	}
}
