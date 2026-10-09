// One staged value and one retained write per conversation. Projection never
// replaces a newer local edit with an older accepted snapshot.
import type { ManagedRoomsSession } from "./session.ts";
import { conversationIdentity } from "./model.ts";
import { WorkspaceConflict } from "./operation.ts";

export class ManagedDrafts {
	readonly #session: ManagedRoomsSession;
	readonly #values = new Map<string, string>();
	// At most one scalar identity and accepted-text occurrence per staged
	// conversation, bounded by the admitted workspace shape. No snapshot or
	// capability wrapper survives here. Retirement releases the same row.
	readonly #origins = new Map<string, { identity: string; accepted: string }>();
	readonly #jobs = new Map<string, Promise<void>>();
	readonly #writes = new Map<string, string>();
	#tail: Promise<void> = Promise.resolve();
	#stopped = false;
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	value(id: string, accepted: string): string {
		return this.#values.get(id) ?? accepted;
	}
	stage(id: string, text: string): void {
		if (this.#stopped) throw new Error("This workspace is closed");
		const row = this.#session.current?.intent.conversations.find((row) => row.id === id);
		if (row == null) {
			throw new Error("This conversation is no longer held");
		}
		if (!this.#values.has(id)) this.#origins.set(id, { identity: conversationIdentity(row), accepted: row.draft });
		this.#values.set(id, text);
	}
	flush(id: string): Promise<void> {
		const current = this.#jobs.get(id);
		if (current != null) return current;
		const job = this.#tail.then(() => this.#flush(id)).finally(() => this.#jobs.delete(id));
		// Workspace revisions serialize draft writes across conversations. A
		// refusal belongs to its caller and does not poison the next local edit.
		this.#tail = job.catch(() => {
			// tolerant: the flush caller owns refusal; the serialization tail must admit the next edit.
		});
		this.#jobs.set(id, job);
		return job;
	}
	async #flush(id: string): Promise<void> {
		let rebased = false;
		while (!this.#stopped && this.#values.has(id)) {
			const retained = this.#writes.get(id);
			if (retained != null) {
				await this.#session.completeOperation(retained);
				continue;
			}
			const text = this.#values.get(id)!;
			const operation = crypto.randomUUID();
			this.#writes.set(id, operation);
			try {
				await this.#session.execute(
					operation,
					() => this.#session.command("setDraft", [id, text], operation),
					async (command) => {
						await command.result();
						this.#session.finish(command);
						this.#writes.delete(id);
						if (this.#values.get(id) === text) {
							this.#values.delete(id);
							this.#origins.delete(id);
						} else {
							const origin = this.#origins.get(id);
							if (origin != null) origin.accepted = text;
						}
					},
				);
			} catch (error) {
				if (!this.#session.pending.includes(operation)) this.#writes.delete(id);
				if (error instanceof WorkspaceConflict && !rebased) {
					const row = this.#session.current?.intent.conversations.find((row) => row.id === id);
					const original = this.#origins.get(id);
					// An unrelated workspace edit can advance the revision. Rebase
					// once only after proven non-admission and an unchanged exact
					// conversation and accepted draft. A competing draft stays visible.
					if (
						row != null && original != null && conversationIdentity(row) === original.identity &&
						row.draft === original.accepted
					) {
						rebased = true;
						continue;
					}
				}
				throw error;
			}
		}
	}
	retire(id: string): void {
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
		this.#origins.clear();
		this.#writes.clear();
	}
}
