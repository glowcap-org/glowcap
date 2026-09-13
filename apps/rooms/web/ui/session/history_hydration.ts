// Reading each conversation's kept history in behind its live log.
//
// A session that keeps history hands it over one conversation at a time, on
// request. This owns which conversations have been read, which are being read
// now, and which reads failed, so a snapshot can ask for everything and get
// only the reads that are still owed, a few at a time.

import * as store from "../store.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { RoomsSessionState, WorkspaceConversation } from "../../../lib/rooms_state.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import type { RoomsPageContext } from "../page.ts";
import { reconcileAttachedHistory } from "./history_reconciliation.ts";
import { refusalText } from "../../../lib/text/failure.ts";

/** How many conversations are read at once. */
const HISTORY_RECONCILE_CONCURRENCY = 4;

export class HistoryHydration {
	readonly #page: RoomsPageContext;
	readonly #files: AttachedSessionFiles | null;
	readonly #keyOf: (conversationId: string) => string | null;
	/** Each conversation read or being read, with the token of its read. A
	 * later invalidation retires the token, and the read that carries it lands
	 * nothing. */
	readonly #loads = new Map<string, symbol>();
	readonly #reads = new Set<string>();
	readonly #failures = new Set<string>();
	#cursor = 0;
	#request: { controller: AttachedRoomsController; session: RoomsSessionState } | null = null;

	constructor(
		page: RoomsPageContext,
		files: AttachedSessionFiles | null,
		keyOf: (conversationId: string) => string | null,
	) {
		this.#page = page;
		this.#files = files;
		this.#keyOf = keyOf;
	}

	/** Forget one conversation's read, so the next hydrate reads it again. */
	forget(conversationId: string): void {
		this.#loads.delete(conversationId);
	}

	/** Forget every read, which a recovered session calls for. */
	forgetAll(): void {
		this.#loads.clear();
	}

	/** Keep only the reads of conversations the session still names. */
	retain(wanted: ReadonlySet<string>): void {
		for (const id of this.#loads.keys()) if (!wanted.has(id)) this.#loads.delete(id);
	}

	/** Drop everything, for a controller going away. */
	reset(): void {
		this.#request = null;
		this.#loads.clear();
		this.#failures.clear();
	}

	/** Read whatever the session names that has not been read. A failed read
	 * retries on the next outside observation, never in the drain loop. */
	hydrate(controller: AttachedRoomsController, session: RoomsSessionState): void {
		for (const id of this.#failures) this.#loads.delete(id);
		this.#failures.clear();
		this.#request = { controller, session };
		this.#drain();
	}

	#drain(): void {
		const request = this.#request;
		if (request == null) return;
		const conversations = request.session.conversations;
		const start = this.#cursor;
		// A busy conversation cannot consume every newly available read slot.
		for (let offset = 0; offset < conversations.length; offset++) {
			if (this.#reads.size === HISTORY_RECONCILE_CONCURRENCY) break;
			const index = (start + offset) % conversations.length;
			const conversation = conversations[index];
			if (this.#loads.has(conversation.id) || this.#keyOf(conversation.id) == null) continue;
			const identity = JSON.stringify([conversation.kind, conversation.directory, conversation.id]);
			if (this.#reads.has(identity)) continue;
			this.#reads.add(identity);
			this.#cursor = index + 1;
			void this.#hydrateConversation(request.controller, conversation).finally(() => {
				this.#reads.delete(identity);
				this.#drain();
			});
		}
	}

	async #hydrateConversation(
		controller: AttachedRoomsController,
		conversation: WorkspaceConversation,
	): Promise<void> {
		const key = this.#keyOf(conversation.id);
		if (key == null || this.#loads.has(conversation.id)) return;
		const token = Symbol(conversation.id);
		this.#loads.set(conversation.id, token);
		const room = store.getConv(this.#page.projection, key);
		const awaitingHistory = room?.type === "room";
		if (awaitingHistory && room.earlierHistory === "unasked") {
			store.setEarlierHistory(this.#page.projection, key, "loading");
		}
		try {
			const records = await controller.readHistory(
				conversation.kind,
				conversation.directory,
				conversation.id,
			);
			if (this.#loads.get(conversation.id) !== token || this.#keyOf(conversation.id) !== key) {
				return;
			}
			const retained = reconcileAttachedHistory(this.#page, key, records, this.#files);
			if (awaitingHistory) {
				store.setEarlierHistory(this.#page.projection, key, retained ? "shown" : "empty");
			}
		} catch (error) {
			if (this.#loads.get(conversation.id) !== token) return;
			this.#failures.add(conversation.id);
			if (awaitingHistory) store.setEarlierHistory(this.#page.projection, key, "unavailable");
			store.noteTrouble(
				this.#page.projection,
				"shared session archive",
				refusalText(error),
			);
		}
	}
}
