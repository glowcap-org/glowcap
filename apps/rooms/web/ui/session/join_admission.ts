// Reconcile a committed room-join intent with the room effect that answers it.

import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import { REQUEST_TIMEOUT_MS } from "../../../lib/limits.ts";

export interface JoinAdmissionFeed {
	readonly current: RoomsSessionSnapshot | null;
	onSnapshot(listener: (snapshot: RoomsSessionSnapshot) => void): () => void;
}

/** `joinRoom` commits durable intent before its effect answers. The UI asked
 * for admission, so wait until the authoritative feed shows the live room or
 * a final issue for that room or its directory. Intermediate issues coexist
 * with retained effects and are not outcomes yet. */
export function waitForRoomAdmission(
	feed: JoinAdmissionFeed,
	snapshot: RoomsSessionSnapshot,
	signal?: AbortSignal,
): Promise<RoomsSessionSnapshot> {
	const active = snapshot.checkpoint.active;
	const room = snapshot.checkpoint.conversations.find((conversation) =>
		conversation.kind === "room" && conversation.id === active
	);
	if (room?.kind !== "room") return Promise.resolve(snapshot);
	const subject = `room:${room.directory}:${room.id}`;
	const directorySubject = `directory:${room.directory}`;
	const answer = (next: RoomsSessionSnapshot): "admitted" | string | null => {
		if (next.roomViews.some((view) => view.conversationId === room.id)) return "admitted";
		if (
			next.pendingEffectDetails.some((effect) =>
				effect.subject === subject || effect.subject === directorySubject
			)
		) return null;
		return next.issues.find((issue) => issue.subject === subject || issue.subject === directorySubject)?.reason ??
			null;
	};
	const immediate = answer(snapshot);
	if (immediate === "admitted") return Promise.resolve(snapshot);
	if (immediate !== null) return Promise.reject(new Error(immediate));
	if (signal?.aborted) return Promise.reject(new Error("Rooms join cancelled"));
	return new Promise((resolve, reject) => {
		let settled = false;
		let timer: ReturnType<typeof setTimeout> | null = null;
		let stop = () => {};
		const finish = (result: { snapshot: RoomsSessionSnapshot } | { error: Error }) => {
			if (settled) return;
			settled = true;
			if (timer !== null) clearTimeout(timer);
			stop();
			signal?.removeEventListener("abort", cancelled);
			if ("snapshot" in result) resolve(result.snapshot);
			else reject(result.error);
		};
		const observe = (next: RoomsSessionSnapshot) => {
			const result = answer(next);
			if (result === "admitted") finish({ snapshot: next });
			else if (result !== null) finish({ error: new Error(result) });
		};
		const cancelled = () => finish({ error: new Error("Rooms join cancelled") });
		const subscribed = feed.onSnapshot(observe);
		stop = subscribed;
		if (settled) {
			// `onSnapshot` immediately offers the retained current value. Remove the
			// listener returned after that callback if it supplied the answer.
			subscribed();
			return;
		}
		timer = setTimeout(
			() => finish({ error: new Error("The room did not answer the join in time. Try again.") }),
			REQUEST_TIMEOUT_MS,
		);
		signal?.addEventListener("abort", cancelled, { once: true });
		// Close the check-before-listen race if cancellation happened between
		// the early check and listener installation.
		if (signal?.aborted) cancelled();
	});
}
