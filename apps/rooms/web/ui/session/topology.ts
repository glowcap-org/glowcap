// Making the store's directories and conversations match a session
// checkpoint's: which exist, under which keys, and which one is on screen.
//
// Runs only when the checkpoint's topology moved. Presentation state on a
// conversation that still exists is reconciled elsewhere; this decides what
// exists at all, and repairs a selection that named something gone.

import * as store from "../store.ts";
import type { RoomsPageContext } from "../page.ts";
import type { HistoryHydration } from "./history_hydration.ts";
import type { RoomsSessionState, WorkspaceConversation } from "../../../lib/rooms_state.ts";
import { type Conv, dirId, isSessionConv, type SessionConv } from "../types.ts";
import { sameConversationIdentity } from "./checkpoint_identity.ts";
import { ignoredButYou } from "../../../lib/text/attached.ts";

export type SelectionRepair =
	| { readonly kind: "unchanged" }
	| { readonly kind: "replaced"; readonly key: string | null };

/** What the reconciliation reads and writes beside the store: the map from
 * checkpoint conversation ids to this tab's keys, the history reads to
 * retire with a conversation, and the session's ignore list. */
export interface TopologyOwner {
	readonly page: RoomsPageContext;
	readonly keys: Map<string, string>;
	readonly history: HistoryHydration;
	ignoredNickname(conversationId: string): string | undefined;
}

export function reconcileTopology(owner: TopologyOwner, session: RoomsSessionState): SelectionRepair {
	const projection = owner.page.projection;
	const selected = store.activeConv(projection);
	let selectedReplaced = false;
	const wantedConversations = new Set(session.conversations.map((entry) => entry.id));
	const wantedDirectories = new Set(session.directories.map((entry) => dirId(entry.id)));
	owner.history.retain(wantedConversations);
	// A directory view is this tab's, not a checkpoint row. Forgetting every
	// persistId the session does not name would delete it on the next join.
	for (const conversation of projection.get().convs.values()) {
		if (!isSessionConv(conversation)) {
			if (!wantedDirectories.has(conversation.dir)) {
				if (conversation.key === selected?.key) selectedReplaced = true;
				store.forgetConv(projection, conversation.key);
			}
			continue;
		}
		if (!wantedConversations.has(conversation.persistId)) {
			if (conversation.key === selected?.key) selectedReplaced = true;
			store.forgetConv(projection, conversation.key);
		}
	}
	for (const directory of projection.get().dirs.keys()) {
		if (!wantedDirectories.has(directory)) store.forgetDir(projection, directory);
	}
	for (const directory of session.directories) {
		const id = dirId(directory.id);
		store.openDir(projection, id, directory.locator);
		// The connection words (`session`, `statusText`, `nick`) are written once
		// per snapshot by the projection's own pass, from the live directory
		// set; writing a provisional phase here too would replace the map twice
		// for one tick.
		store.patchDir(projection, id, {
			requestedNick: directory.nick,
			standing: directory.standing,
			reached: directory.reached ?? false,
		});
		if (directory.home) store.setHomeDir(projection, id);
	}
	owner.keys.clear();
	const existingConversations = new Map<string, SessionConv>();
	for (const conversation of projection.get().convs.values()) {
		if (isSessionConv(conversation)) existingConversations.set(conversation.persistId, conversation);
	}
	for (const conversation of session.conversations) {
		const existing = existingConversations.get(conversation.id);
		let restored: Conv | undefined = existing ?? undefined;
		if (existing != null && !sameConversationIdentity(existing, conversation)) {
			if (existing.key === selected?.key) selectedReplaced = true;
			store.forgetConv(projection, existing.key);
			owner.history.forget(conversation.id);
			restored = undefined;
		}
		if (restored == null) restored = restoreConversation(owner.page, conversation) ?? undefined;
		if (restored != null) {
			owner.keys.set(conversation.id, restored.key);
			if (!existingConversations.has(conversation.id)) {
				const ignored = owner.ignoredNickname(conversation.id);
				if (ignored != null) {
					store.deliver(projection, restored.key, store.sysItem(projection, ignoredButYou(ignored)));
				}
			}
		}
	}
	return selectedReplaced
		? {
			kind: "replaced",
			key: selected == null || !isSessionConv(selected) ? null : owner.keys.get(selected.persistId) ?? null,
		}
		: { kind: "unchanged" };
}

function restoreConversation(page: RoomsPageContext, conversation: WorkspaceConversation) {
	const directory = dirId(conversation.directory);
	if (conversation.kind === "direct") {
		return store.restoreDm(
			page.projection,
			directory,
			conversation.peer,
			conversation.peerRegistrationId,
			conversation.id,
			conversation.closed,
		);
	}
	return store.ensureRoom(page.projection, directory, conversation.name, {
		persistId: conversation.id,
		key: conversation.held ? `held:${conversation.id}` : undefined,
		held: conversation.held,
		reconnect: conversation.reconnect,
		link: conversation.link,
		manager: conversation.manager,
		steward: conversation.steward,
		publicationId: conversation.publicationId,
		bridgeIntent: conversation.bridgeIntent,
	});
}
