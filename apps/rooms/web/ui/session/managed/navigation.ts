// Visible selection changes immediately. One retained command and one latest
// scalar choice settle in order; an older acknowledgment cannot move the view.
import type { ManagedRoomsSession } from "./session.ts";
import { WorkspaceConflict } from "./operation.ts";
import { conversationNoLongerOpen } from "../../../../lib/text/attached.ts";

// Selection exercises no authority. It refuses only when the chosen row is
// gone; the shared admission fence keeps that row's identity across conflicts,
// and supervisor churn never refuses it.
type Choice = { id: string; operation: string };
export class ManagedNavigation {
	readonly #session: ManagedRoomsSession;
	readonly #changed: () => void;
	#desired: Choice | null = null;
	#pending: Choice | null = null;
	#running: Promise<void> | null = null;
	#stopped = false;
	#opening: { peer: string | null } | null = null;
	readonly #acquiring = new Set<Promise<unknown>>();
	constructor(session: ManagedRoomsSession, changed = () => {}) {
		this.#session = session;
		this.#changed = changed;
	}
	get selected(): string | undefined {
		return this.#desired?.id ?? this.#pending?.id;
	}
	get destination(): string | null {
		return this.#opening?.peer ?? null;
	}
	openDirect(directory: string, peer: string): Promise<void> {
		return this.acquire(async (current) => {
			const id = await this.#session.actions.direct(directory, peer, false);
			if (current()) await this.select(id);
		}, peer);
	}
	/** Acquisition may finish after another gesture chose a view. Its exact
	 * receipt still settles, but only the current gesture can select its result. */
	acquire<T>(work: (current: () => boolean) => Promise<T>, peer: string | null = null): Promise<T> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		const choice = { peer };
		this.#opening = choice;
		this.#changed();
		const task = (async () => {
			try {
				return await work(() => !this.#stopped && this.#opening === choice);
			} finally {
				if (this.#opening === choice) this.#opening = null;
				this.#changed();
			}
		})().finally(() => this.#acquiring.delete(task));
		this.#acquiring.add(task);
		return task;
	}
	dismissAcquisition(): void {
		this.#opening = null;
		this.#changed();
	}
	select(id: string): Promise<void> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		if (this.#session.current == null) return Promise.reject(new Error("This workspace has no accepted selection"));
		this.#opening = null;
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
			while (conflicts < 4) {
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
					if (error instanceof WorkspaceConflict && ++conflicts < 4 && !this.#stopped) continue;
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
		await Promise.allSettled(this.#acquiring);
		await this.#running?.catch(() => {
			// tolerant: the gesture owns its refusal; command receipts remain at the viewer until its close barrier.
		});
		this.#desired = this.#pending = null;
	}
}
