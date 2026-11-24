// One staged value and one retained write per conversation. Projection never
// replaces a newer local edit with an older accepted snapshot.
import { conversationById } from "./conversation_lookup.ts";
import type { ManagedRoomsSession } from "./session.ts";
import { conversationIdentity, type WorkspaceSnapshot } from "./model.ts";
import { LocalRefusal, refusalText } from "../../../../lib/text/failure.ts";
import { WorkspaceConflict } from "./operation.ts";

/** What a staged conversation's draft was, as this tab knows it. */
interface Origin {
	readonly identity: string;
	/** The draft the session last confirmed holding. */
	accepted: string;
	/** The text of each write of this tab whose link was lost before the
	 * session confirmed it, so the session may hold any one of them. One entry
	 * per distinct text and lost link since `accepted` was last confirmed, and
	 * a confirmed write clears them. */
	readonly lost: Set<string>;
}

export class ManagedDrafts {
	readonly #session: ManagedRoomsSession;
	readonly #values = new Map<string, string>();
	// At most one scalar identity and accepted-text occurrence per staged
	// conversation, bounded by the admitted workspace shape. No snapshot or
	// capability wrapper survives here. Retirement releases the same row.
	readonly #origins = new Map<string, Origin>();
	readonly #jobs = new Map<string, Promise<void>>();
	/** This tab's draft write that is under way or that the session holds, by
	 * conversation, and the text it carries. */
	readonly #writes = new Map<string, { operation: string; text: string }>();
	#stopped = false;
	/** Why each failed write failed, and whether the link caused it. */
	readonly #failures = new Map<string, { readonly text: string; readonly linkCaused: boolean }>();
	failure(id: string): string {
		return this.#failures.get(id)?.text ?? "";
	}
	sync(id: string): void {
		if (this.#failures.has(id)) return;
		this.#background(id);
	}
	/** The link to the session was replaced. Every edit whose write the link
	 * ended is written again. One the session refused waits for the person. */
	resume(): void {
		for (const [id, failure] of [...this.#failures]) if (failure.linkCaused) this.#background(id);
	}
	/** Whether a reload would drop an edit: one being written, or one the
	 * session does not provably hold. It holds an edit its snapshot shows, or
	 * one carried by a write it confirmed, which the reloaded page adopts. */
	get reloadLoses(): boolean {
		if (this.#jobs.size > 0) return true;
		for (const [id, text] of this.#values) if (!this.#held(id, text)) return true;
		return false;
	}
	#held(id: string, text: string): boolean {
		if (conversationById(this.#session.current, id)?.draft === text) return true;
		const write = this.#writes.get(id);
		if (write?.text !== text) return false;
		for (const operation of this.#session.pendingOperations) {
			if (operation.id === write.operation) return operation.committed;
		}
		return false;
	}
	#background(id: string): void {
		void this.flush(id).catch(() => {
			// The persistent composer notice owns this failed background sync.
		});
	}
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	value(id: string, accepted: string): string {
		return this.#values.get(id) ?? accepted;
	}
	stage(id: string, text: string): void {
		if (this.#stopped) throw new LocalRefusal("session-closed");
		const row = conversationById(this.#session.current, id);
		if (row == null) {
			throw new LocalRefusal("conversation-gone");
		}
		if (!this.#values.has(id)) {
			this.#origins.set(id, { identity: conversationIdentity(row), accepted: row.draft, lost: new Set() });
		}
		this.#values.set(id, text);
	}
	flush(id: string): Promise<void> {
		const current = this.#jobs.get(id);
		if (current != null) return current;
		const job = Promise.resolve().then(() => this.#flush(id)).then(() => {
			this.#failures.delete(id);
		}, (error: unknown) => {
			// Only a write the link ended is written again over a new link.
			this.#failures.set(id, { text: refusalText(error), linkCaused: this.#session.linkEnded(error) });
			throw error;
		}).finally(() => {
			this.#jobs.delete(id);
			this.#session.acquisitionChanged();
		});
		// The shared admission owner serializes revisions; other drafts settle independently.
		this.#jobs.set(id, job);
		return job;
	}
	async #flush(id: string): Promise<void> {
		let rebased = false;
		while (!this.#stopped) {
			const text = this.#values.get(id);
			if (text == null) return;
			const retained = this.#writes.get(id);
			if (retained != null) {
				await this.#complete(id, retained);
				continue;
			}
			const operation = crypto.randomUUID();
			this.#writes.set(id, { operation, text });
			// Raised at admission when another draft took the row's place.
			const competing = new WorkspaceConflict();
			const writable = (snapshot: WorkspaceSnapshot) => {
				if (!this.#writesOver(snapshot, id, text)) throw competing;
			};
			try {
				await this.#session.execute(
					operation,
					() => this.#session.command("setDraft", [id, text], operation, writable),
					async (command) => {
						await command.result();
						this.#session.finish(command);
						this.#writes.delete(id);
						if (this.#values.get(id) === text) {
							this.#values.delete(id);
							this.#origins.delete(id);
						} else {
							const origin = this.#origins.get(id);
							if (origin != null) {
								origin.accepted = text;
								origin.lost.clear();
							}
						}
					},
				);
			} catch (error) {
				if (!this.#session.pending.includes(operation)) this.#writes.delete(id);
				// The session fences a draft write on the draft it was prepared
				// over, so the lost write landing later loses to this one. The
				// loop comes back here only on another lost link.
				if (LocalRefusal.is(error, "receipt-lost")) {
					this.#origins.get(id)?.lost.add(text);
					rebased = false;
					continue;
				}
				// An unrelated workspace edit can advance the revision, and the
				// workspace can change while a write waits for the link. Either
				// proves the write was not admitted. It is prepared once more over
				// what the session holds now, and admission checks the draft again.
				const moved = (error instanceof WorkspaceConflict && error !== competing) ||
					LocalRefusal.is(error, "command-selection-changed");
				if (moved && !rebased) {
					rebased = true;
					continue;
				}
				throw error;
			}
		}
	}
	/** Settle this tab's write the session held when its link was lost. Its
	 * completion clears it. A write that settles any other way, because another
	 * viewer retired it or its result expired, or whose record the session no
	 * longer holds, is let go, and the loop writes the text again. The session
	 * may hold the text it carried, so that write may replace it. */
	async #complete(id: string, retained: { operation: string; text: string }): Promise<void> {
		try {
			await this.#session.completeOperation(retained.operation);
		} catch (error) {
			if (!LocalRefusal.is(error, "receipt-lost")) throw error;
		}
		if (this.#writes.get(id) !== retained) return;
		this.#writes.delete(id);
		this.#origins.get(id)?.lost.add(retained.text);
	}
	/** Whether a write of `text` may replace the draft `snapshot` holds. It may
	 * over the draft the session last confirmed, over any write of this tab the
	 * session may hold, and over the same text. A draft another tab wrote since
	 * stays, and so does a conversation replaced under the same id. A row the
	 * snapshot does not hold is the session's to refuse. Admission reads this on
	 * every write, the first one over a new link among them. */
	#writesOver(snapshot: WorkspaceSnapshot, id: string, text: string): boolean {
		const row = conversationById(snapshot, id);
		const origin = this.#origins.get(id);
		if (row == null || origin == null) return true;
		return conversationIdentity(row) === origin.identity &&
			(row.draft === origin.accepted || origin.lost.has(row.draft) || row.draft === text);
	}
	retire(id: string): void {
		this.#failures.delete(id);
		this.#values.delete(id);
		this.#origins.delete(id);
	}
	stop(): void {
		this.#stopped = true;
	}
	async close(): Promise<void> {
		this.stop();
		await Promise.allSettled(this.#jobs.values());
		this.#values.clear();
		this.#failures.clear();
		this.#origins.clear();
		this.#writes.clear();
	}
}
