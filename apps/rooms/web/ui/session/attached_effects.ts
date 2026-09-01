// How one durable operation is issued, driven, and named.
//
// Its own file because it is its own subject. The controller above holds the
// session's verbs — say a line, set a topic, take a room's moderator — and this
// holds what all of them do underneath: mint an identity for the operation,
// claim it while this tab is answering for it, take the answer, and let go
// either way.
//
// Kept together because the three parts only make sense as one. The identity is
// what lets a retry reach the session's durable result row rather than asking
// for a second grant; the claim is what tells the page apart an operation under
// way from one nobody is driving; and letting go is what puts a failed one back
// in front of a reader.

import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { AttachedSessionFeed } from "./attached_feed.ts";
import type { AttachedRoomsRemote } from "./remote.ts";

/** What issuing an operation needs from the session that owns it. */
export interface OperationSeat {
	readonly remote: AttachedRoomsRemote;
	readonly feed: AttachedSessionFeed;
	/** The operations this tab is answering for, which it adds to and removes
	 * from as it goes. The session reads it out for the page. */
	readonly driving: Set<string>;
}

/** Run one operation as this tab's own, and stop claiming it either way.
 *
 * The page is told again on the way out even when nothing was fetched: a
 * command that failed leaves the ledger exactly as it was, so no new
 * revision is coming to carry the news that this tab has stopped driving
 * the operation in it. */
async function drive<T>(seat: OperationSeat, operationId: string, run: () => Promise<T>): Promise<T> {
	seat.driving.add(operationId);
	try {
		return await run();
	} finally {
		seat.driving.delete(operationId);
		seat.feed.reannounce();
	}
}

/** An ordinary durable operation: one identity, one answer. */
export function runEffectCommand(
	seat: OperationSeat,
	name: string,
	args: string[],
): Promise<RoomsSessionSnapshot> {
	const operationId = crypto.randomUUID();
	return drive(seat, operationId, async () => {
		const revision = await seat.remote.command(
			operationId,
			seat.feed.requireSnapshot().revision,
			name,
			args,
		);
		return await seat.feed.settleRevision(revision);
	});
}

/** Result-bearing room authority acts retain their operation identity after
 * an answer is lost. The key is one action per conversation, so a corrected
 * moderator link replaces the prior intent while retries of the same intent
 * reach the session's durable result row. */
export function runResultCommand(
	seat: OperationSeat,
	resultOperationIds: Map<string, { args: string; id: string }>,
	name: string,
	args: string[],
): Promise<RoomsSessionSnapshot> {
	const key = `${name}\u0000${args[0] ?? ""}`;
	const material = JSON.stringify(args);
	const prior = resultOperationIds.get(key);
	const operationId = prior?.args === material ? prior.id : crypto.randomUUID();
	resultOperationIds.set(key, { args: material, id: operationId });
	return drive(seat, operationId, async () => {
		let snapshot = await seat.feed.refresh();
		for (let attempt = 0; attempt < 2; attempt += 1) {
			const pending = snapshot.pendingEffectDetails.find((effect) => effect.kind !== "external");
			if (pending != null) {
				// Resuming somebody else's leftover makes it this tab's for as
				// long as that takes, so the page stops asking about it.
				seat.driving.add(pending.id);
				try {
					const resumed = await seat.remote.resumeEffect(pending.id);
					snapshot = await seat.feed.settleRevision(resumed);
				} catch (error) {
					throw new Error(
						`Could not resume “${pending.subject}”: ${resultEffectFailure(error)}. ` +
							"It remains under Settings → Session, where you can retry or abandon it.",
						{ cause: error },
					);
				} finally {
					seat.driving.delete(pending.id);
				}
				if (resultAlreadyHeld(snapshot, name, args)) break;
			}
			try {
				const revision = await seat.remote.command(operationId, snapshot.revision, name, args);
				snapshot = await seat.feed.settleRevision(revision);
				break;
			} catch (error) {
				if (
					attempt !== 0 || !(error instanceof Error) ||
					!error.message.includes("session already has a result-bearing effect in flight")
				) throw error;
				snapshot = await seat.feed.refresh();
			}
		}
		if (resultOperationIds.get(key)?.id === operationId) resultOperationIds.delete(key);
		return snapshot;
	});
}

function resultEffectFailure(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	return message.replace(/^(?:pancake error -?\d+:\s*)+/i, "");
}

/** A resumed result may have completed the exact act the caller was about to
 * repeat. Read the durable checkpoint instead of issuing a second authority
 * request merely because a prior browser lost its answer. */
function resultAlreadyHeld(snapshot: RoomsSessionSnapshot, name: string, args: string[]): boolean {
	if (name === "openManagedRoom") {
		try {
			const intended = JSON.parse(args[0]) as { id?: unknown };
			return typeof intended.id === "string" &&
				snapshot.checkpoint.conversations.some((entry) => entry.id === intended.id);
		} catch {
			return false;
		}
	}
	const conversation = snapshot.checkpoint.conversations.find((entry) => entry.id === args[0]);
	if (conversation?.kind !== "room") return false;
	if (name === "ensureRoomLink") return conversation.link != null;
	if (name === "takeRoomModerator") {
		return conversation.steward != null && (args[1] == null || conversation.steward === args[1]);
	}
	if (name === "takeRoomManager") return conversation.manager === args[1];
	if (name === "recoverRoomManager") return conversation.manager != null;
	return false;
}
