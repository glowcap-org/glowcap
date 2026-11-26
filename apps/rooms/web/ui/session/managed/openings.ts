// Each opening owns its cancellation and late membership cleanup. Selection
// consumes the opening before it changes presentation or waits for a receipt.
import { roomsErrorIn, SESSION_REQUEST_TIMED_OUT } from "../../../../lib/error_codes.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import type { ManagedRoomsSession } from "./session.ts";
import { LINK_WAIT_MS } from "./link.ts";
import { conversationById } from "./conversation_lookup.ts";

export type AcquisitionTarget =
	| { readonly kind: "direct"; readonly peer: string }
	| { readonly kind: "room"; readonly directory: string; readonly name: string };

/** How many times a dismissed opening's departure is tried, and the first
 * wait between tries, which doubles. */
export const LEAVE_ATTEMPTS = 6;
export const LEAVE_BACKOFF_MS = 1_000;

/** Leave what an opening committed. Nothing of the departure is sent until its
 * read of the session answers, so that read waits for the link as a first
 * send does, and the departure's own press finishes over the next link. */
async function departed(
	session: Pick<ManagedRoomsSession, "pending" | "completeOperation" | "readBeforeSending" | "press">,
	operation: string,
	id: string,
	departure: "leaveConversation" | "closeDirect",
): Promise<void> {
	if (session.pending.includes(operation)) {
		await session.completeOperation(operation);
		return;
	}
	if (conversationById(await session.readBeforeSending(), id) == null) return;
	await session.press(
		operation,
		({ command }) => command(departure, [id], operation),
		(command, after) => after.complete(command),
	);
}

/** Whether a refusal clears with time, so the departure is tried again. */
function clearsWithTime(error: unknown): boolean {
	return roomsErrorIn(error)?.code === SESSION_REQUEST_TIMED_OUT || LocalRefusal.is(error, "session-unread") ||
		LocalRefusal.is(error, "busy") ||
		LocalRefusal.is(error, "not-sent");
}

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
			this.#release = () => departed(this.session, operation, id, departure);
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
	/** Run the departure of a dismissed opening, and again after each cause that
	 * clears with time: a link that ended, a read or send the link was not live for,
	 * or a busy page. The waits double on the page's
	 * clock and stop after `LEAVE_ATTEMPTS`. Any other refusal ends it at once.
	 * Either end is a notice that the room is still joined. Every run is the
	 * same operation, so nothing departs twice. */
	async #leave(depart: () => Promise<void>): Promise<void> {
		const { environment } = this.session.effects;
		for (let attempt = 1;; attempt++) {
			try {
				await depart();
				return;
			} catch (error) {
				const lost = connectionLost(error);
				if (attempt >= LEAVE_ATTEMPTS || environment.stopped() || (!lost && !clearsWithTime(error))) {
					environment.report(managedText.leaveUnfinished, error);
					throw error;
				}
				if (lost && await this.session.link?.available(LINK_WAIT_MS)) continue;
				await new Promise<void>((resolve) =>
					environment.clock.after(LEAVE_BACKOFF_MS * 2 ** (attempt - 1), resolve)
				);
			}
		}
	}
	#discard(again = false): Promise<void> | null {
		if (this.#release != null && this.#cleanup == null) {
			this.#cleanup = (again ? this.#leave(this.#release) : this.#release()).then(() => {
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
		// A dismissal has no owner to run its cleanup again over the next link,
		// where an acquisition under way does.
		this.#discard(true);
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
		return this.session.navigation.selectAfterCommit(id);
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
		if (this.#stopped) return Promise.reject(new LocalRefusal("session-closed"));
		if (cancel?.aborted) return Promise.reject(cancel.reason);
		if (this.#workers.size >= SESSION_CONTENT.limits.effects) {
			return Promise.reject(new LocalRefusal("busy"));
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
