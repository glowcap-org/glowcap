// Visible selection changes immediately. One retained command and one latest
// scalar choice settle in order. An older acknowledgment cannot move the view.
import type { ManagedRoomsSession } from "./session.ts";
import { WorkspaceConflict } from "./operation.ts";
import { MAX_CONFLICT_REPREPARATIONS } from "./acquisition.ts";
import { conversationNoLongerOpen } from "../../../../lib/text/attached.ts";

// Selection exercises no authority. It refuses only when the chosen row is
// gone. The shared admission fence keeps that row's identity across conflicts,
// and supervisor churn never refuses it.
type Choice = { id: string; operation: string };
export class ManagedNavigation {
	readonly #session: ManagedRoomsSession;
	readonly #changed: () => void;
	#desired: Choice | null = null;
	#pending: Choice | null = null;
	#running: Promise<void> | null = null;
	#stopped = false;
	constructor(session: ManagedRoomsSession, changed = () => {}) {
		this.#session = session;
		this.#changed = changed;
	}
	get selected(): string | undefined {
		return this.choice?.id;
	}
	get choice(): Readonly<Choice> | undefined {
		return this.#desired ?? this.#pending ?? undefined;
	}
	select(id: string): Promise<void> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		if (this.#session.current == null) return Promise.reject(new Error("This workspace has no accepted selection"));
		this.#desired = { id, operation: crypto.randomUUID() };
		this.#changed();
		return this.#running ??= this.#drain().finally(() => {
			this.#running = null;
		});
	}
	async #drain(): Promise<void> {
		while (!this.#stopped && (this.#pending != null || this.#desired != null)) {
			const choice = this.#pending ??= this.#desired!;
			let conflicts = 0;
			while (conflicts < MAX_CONFLICT_REPREPARATIONS) {
				try {
					await this.#session.execute(
						choice.operation,
						() =>
							this.#session.command("select", [choice.id], choice.operation, (snapshot) => {
								if (!snapshot.intent.conversations.some((row) => row.id === choice.id)) {
									throw new Error(conversationNoLongerOpen);
								}
							}),
						async (command) => {
							await this.#session.completeResult(command);
						},
					);
					break;
				} catch (error) {
					if (
						error instanceof WorkspaceConflict && ++conflicts < MAX_CONFLICT_REPREPARATIONS &&
						!this.#stopped
					) continue;
					if (!this.#session.pending.includes(choice.operation)) {
						this.#pending = null;
						// A revision conflict proves non-admission, not loss of the
						// selected conversation. Keep the local choice visible while
						// reporting its failed save. Exact-target refusal clears it.
						if (!(error instanceof WorkspaceConflict) && this.#desired === choice) this.#desired = null;
						this.#changed();
					}
					throw error;
				}
			}
			this.#pending = null;
			if (this.#desired === choice) this.#desired = null;
			this.#changed();
		}
	}
	stop(): void {
		this.#stopped = true;
	}
	async close(): Promise<void> {
		this.stop();
		await this.#running?.catch(() => {
			// tolerant: the gesture owns its refusal; command receipts remain at the viewer until its close barrier.
		});
		this.#desired = this.#pending = null;
	}
}
