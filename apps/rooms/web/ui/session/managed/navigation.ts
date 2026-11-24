// Visible selection changes immediately. One retained command and one latest
// scalar choice settle in order. An older acknowledgment cannot move the view.
import type { ManagedRoomsSession } from "./session.ts";
import { conversationById } from "./conversation_lookup.ts";
import { WorkspaceConflict } from "./operation.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";

// Selection exercises no authority. It refuses only when the chosen row is
// gone. The shared admission fence keeps that row's identity across conflicts,
// and supervisor churn never refuses it.
type Choice = { id: string; operation: string };
export class ManagedNavigation {
	readonly #session: ManagedRoomsSession;
	readonly #changed: () => void;
	readonly #report: (error: unknown) => void;
	#desired: Choice | null = null;
	#pending: Choice | null = null;
	#running: Promise<void> | null = null;
	#stopped = false;
	constructor(session: ManagedRoomsSession, changed = () => {}, report: (error: unknown) => void = () => {}) {
		this.#session = session;
		this.#changed = changed;
		this.#report = report;
	}
	get selected(): string | undefined {
		return this.choice?.id;
	}
	get choice(): Readonly<Choice> | undefined {
		return this.#desired ?? this.#pending ?? undefined;
	}
	select(id: string): Promise<void> {
		if (this.#stopped) return Promise.reject(new LocalRefusal("session-closed"));
		if (this.#session.current == null) return Promise.reject(new LocalRefusal("workspace-unavailable"));
		this.#desired = { id, operation: crypto.randomUUID() };
		this.#changed();
		return this.#running ??= this.#drain().finally(() => {
			this.#running = null;
		});
	}
	/** `select` for a press whose commit already answered. The link's end
	 * leaves the choice to the next link (`relink`) and is never the press's
	 * failure. A select refused for any other reason still is. */
	async selectAfterCommit(id: string): Promise<void> {
		try {
			await this.select(id);
		} catch (error) {
			if (!this.#session.linkEnded(error)) throw error;
		}
	}
	/** A new link sends the choice a lost one kept: a selection that never went
	 * out stays desired, so a press that ended with the link's loss still ends
	 * on the conversation it chose. */
	relink(): void {
		if (this.#stopped || this.#desired == null || this.#running != null || this.#pending != null) return;
		this.#running = this.#drain().catch((error: unknown) => this.#report(error)).finally(() => {
			this.#running = null;
		});
	}
	async #drain(): Promise<void> {
		while (!this.#stopped && (this.#pending != null || this.#desired != null)) {
			const choice = this.#pending ??= this.#desired!;
			try {
				await this.#session.execute(
					choice.operation,
					() =>
						this.#session.command("select", [choice.id], choice.operation, (snapshot) => {
							if (conversationById(snapshot, choice.id) == null) {
								throw new LocalRefusal("conversation-not-open");
							}
						}),
					async (command) => {
						await this.#session.completeResult(command);
					},
				);
			} catch (error) {
				if (!this.#session.pending.includes(choice.operation)) {
					this.#pending = null;
					// A revision conflict proves non-admission, not loss of the
					// selected conversation. Keep the local choice visible while
					// reporting its failed save. Exact-target refusal clears it. A choice
					// the link's loss kept from going out stays for the next link.
					const unsent = this.#session.linkEnded(error);
					if (!(error instanceof WorkspaceConflict) && !unsent && this.#desired === choice) {
						this.#desired = null;
					}
					this.#changed();
				}
				throw error;
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
