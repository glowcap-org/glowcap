// Each opening owns its cancellation and late membership cleanup. Selection
// consumes the opening before it changes presentation or waits for a receipt.
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import type { ManagedRoomsSession } from "./session.ts";

export type AcquisitionTarget =
	| { readonly kind: "direct"; readonly peer: string }
	| { readonly kind: "room"; readonly directory: string; readonly name: string };

export class ConversationOpening {
	readonly #controller = new AbortController();
	#accepted = false;
	#release: (() => Promise<void>) | null = null;
	#cleanup: Promise<void> | null = null;
	#released = false;
	readonly #cancel: () => void;
	constructor(
		readonly session: ManagedRoomsSession,
		readonly consumed: () => void = () => {},
		readonly cancel?: AbortSignal,
	) {
		this.#cancel = () => this.abort();
		cancel?.addEventListener("abort", this.#cancel, { once: true });
		if (cancel?.aborted) this.abort();
	}
	get signal(): AbortSignal {
		return this.#controller.signal;
	}
	/** Called by the retained admission owner, including during recovery. A
	 * pre-existing conversation never transfers membership to this opening. */
	async acquired(id: string, departure: "leaveConversation" | "closeDirect" = "leaveConversation"): Promise<void> {
		if (this.#release == null) {
			const operation = crypto.randomUUID();
			this.#release = async () => {
				if (this.session.pending.includes(operation)) {
					await this.session.completeOperation(operation);
					return;
				}
				if (!(await this.session.refresh()).intent.conversations.some((row) => row.id === id)) return;
				await this.session.completeResult(await this.session.command(departure, [id], operation));
			};
		}
		if (this.signal.aborted && !this.#released) {
			// A failed cleanup retains its exact command. Recovery can continue
			// that command, but must never prepare a second departure.
			if (this.#cleanup != null) {
				try {
					await this.#cleanup;
				} catch {
					// tolerant: this call explicitly retries the same cleanup receipt.
					this.#cleanup = null;
				}
			}
			if (this.#released) return;
			await this.#discard();
		}
	}
	#discard(): Promise<void> | null {
		if (this.#release != null && this.#cleanup == null) {
			this.#cleanup = this.#release().then(() => {
				this.#released = true;
			});
			// The opening worker or retained acquisition observes this failure.
			// Install observation now because abort can precede their next await.
			void this.#cleanup.catch(() => {
				// tolerant: drain() and the retained acquisition disclose the failure.
			});
		}
		return this.#cleanup;
	}
	abort(): void {
		if (this.#accepted || this.signal.aborted) return;
		this.#controller.abort();
		this.cancel?.removeEventListener("abort", this.#cancel);
		this.consumed();
		this.#discard();
	}
	accept(): void {
		this.signal.throwIfAborted();
		this.#accepted = true;
		this.cancel?.removeEventListener("abort", this.#cancel);
		this.consumed();
	}
	failed(): void {
		// The form receives the refusal. Any uncertain admission retains this
		// opening, so a subsequent cancellation still owns late cleanup.
		this.consumed();
	}
	select(id: string): Promise<void> {
		this.accept();
		return this.session.navigation.select(id);
	}
	async drain(): Promise<void> {
		await this.#cleanup;
	}
}

export class ManagedOpenings {
	#current: { attempt: ConversationOpening; target: AcquisitionTarget | null } | null = null;
	readonly #workers = new Set<Promise<unknown>>();
	#stopped = false;
	constructor(
		readonly session: ManagedRoomsSession,
		readonly changed: () => void = () => {},
		readonly report: (error: unknown) => void = (error) => console.error(error),
	) {}
	get destination(): AcquisitionTarget | null {
		return this.#current?.target ?? null;
	}
	dismiss(): void {
		this.#current?.attempt.abort();
	}
	run<T>(
		work: (attempt: ConversationOpening) => Promise<T>,
		target: AcquisitionTarget | null = null,
		cancel?: AbortSignal,
	): Promise<T> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		if (cancel?.aborted) return Promise.reject(cancel.reason);
		if (this.#workers.size >= SESSION_CONTENT.limits.effects) {
			return Promise.reject(new Error("Finish pending conversation openings before starting another"));
		}
		this.dismiss();
		const attempt = new ConversationOpening(this.session, () => {
			if (this.#current?.attempt === attempt) this.#current = null;
			this.changed();
		}, cancel);
		this.#current = { attempt, target };
		this.changed();
		const task = (async () => {
			try {
				const value = await work(attempt);
				attempt.accept();
				return value;
			} catch (error) {
				attempt.failed();
				throw error;
			} finally {
				await attempt.drain();
			}
		})().finally(() => this.#workers.delete(task));
		this.#workers.add(task);
		return new Promise<T>((resolve, reject) => {
			const abort = () => reject(attempt.signal.reason);
			attempt.signal.addEventListener("abort", abort, { once: true });
			if (attempt.signal.aborted) abort();
			void task.then(resolve, (error: unknown) => {
				if (attempt.signal.aborted && !(error instanceof DOMException && error.name === "AbortError")) {
					this.report(error);
				}
				reject(error);
			}).finally(() => attempt.signal.removeEventListener("abort", abort));
		});
	}
	stop(): void {
		this.#stopped = true;
		this.dismiss();
	}
	async close(): Promise<void> {
		this.stop();
		await Promise.allSettled(this.#workers);
	}
}
