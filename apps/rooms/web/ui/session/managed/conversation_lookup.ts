// Each accepted read owns one conversation index until the next acceptance.
// Candidate snapshots remain mutable, so their lookups are never cached.
import type { ConversationIntent, WorkspaceSnapshot } from "./model.ts";

const accepted = new WeakMap<readonly ConversationIntent[], ReadonlyMap<string, ConversationIntent>>();

/** Prepare derived lookup state before a session publishes an accepted read,
 * including when an adapter reuses its conversation array between reads. */
export function indexAcceptedConversations(snapshot: WorkspaceSnapshot): void {
	const rows = snapshot.intent.conversations;
	const byId = new Map<string, ConversationIntent>();
	for (const row of rows) {
		const id = row.id;
		if (!byId.has(id)) byId.set(id, row);
	}
	accepted.set(rows, byId);
}

/** Borrow the exact row from this snapshot. Mutable candidates are searched
 * directly, including after insertion or removal within the same gesture. */
export function conversationById(
	snapshot: WorkspaceSnapshot | null | undefined,
	id: string | undefined,
): ConversationIntent | undefined {
	if (snapshot == null || id == null) return undefined;
	const rows = snapshot.intent.conversations;
	const byId = accepted.get(rows);
	return byId == null ? rows.find((row) => row.id === id) : byId.get(id);
}
