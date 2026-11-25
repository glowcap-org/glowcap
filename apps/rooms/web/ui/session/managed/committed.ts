// What a press may do to the session once its change is committed. The change
// went through, so nothing here ends the press as a refusal of the change. A
// lost link throws the raw loss, which the owner of the completion
// (`surviving`, or a held acquisition's `#shown`) answers by running the
// completion again over the next link.
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import type { ManagedOperation } from "./operation.ts";
import type { ManagedRoomsSession } from "./session.ts";

/** The reads a follow-up makes. None waits for the link. */
export type AfterReads = Pick<ManagedRoomsSession, "current" | "readNow" | "candidateNow" | "requestNow">;

type Owner = AfterReads & Pick<ManagedRoomsSession, "actions" | "completeResult">;

/** The connection loss a follow-up change ended with, or null when it ended
 * for another reason. A change held back for the link, or sent when the link
 * went, says so with a refusal whose cause is the loss. A refusal with no loss
 * behind it stays what it is: no loss is made up for the owner to wait on. */
function lostLink(error: unknown): unknown {
	if (connectionLost(error)) return error;
	const cause = error instanceof Error ? error.cause : undefined;
	return connectionLost(cause) ? cause : null;
}

/** The session after a press committed. Every completion that holds a
 * `Committed` is run again over the next link whenever a loss ends it, so each
 * completion is safe to run twice: it finds its own earlier work done and does
 * only what is left. The owner builds one `Committed` per press, so what the
 * press acquired outlives the link a rerun starts over. */
export class Committed {
	readonly #session: Owner;
	readonly #report: (source: string, error: unknown) => void;
	/** The results this press already acquired, by receipt. A completion run
	 * again finds its result in place and goes on to what is left. */
	readonly #acquired = new Map<string, unknown>();
	constructor(session: Owner, report: (source: string, error: unknown) => void) {
		this.#session = session;
		this.#report = report;
	}
	/** The accepted snapshot, which is read nowhere. */
	get current(): AfterReads["current"] {
		return this.#session.current;
	}
	/** Run `read`. A lost link throws, so the owner runs the completion again.
	 * Any other failure is a notice and the read answers `fallback`, which is
	 * allowed only where the press is true without the read: the next update
	 * redraws what the read would have shown. */
	async readOr<T>(fallback: T, read: (reads: AfterReads) => Promise<T>): Promise<T> {
		try {
			return await read(this.#session);
		} catch (error) {
			if (connectionLost(error) || LocalRefusal.is(error, "session-closed")) throw error;
			this.#report(managedText.changeUnread, error);
			return fallback;
		}
	}
	/** A second change after the commit. A link that ends it throws the raw
	 * loss, never a refusal that says nothing was sent or that the receipt was
	 * lost, because the first change went through. It may wait for the link up
	 * to `LINK_WAIT_MS` first, and the completion then runs again over the next
	 * link and reads what the session holds first. Any other failure is a
	 * notice: the first change went through, so the press does not end as a
	 * refusal and nothing invites a repeat. */
	async change(run: () => Promise<unknown>): Promise<void> {
		try {
			await run();
		} catch (error) {
			const lost = lostLink(error);
			if (lost != null) throw lost;
			if (LocalRefusal.is(error, "session-closed")) throw error;
			this.#report(managedText.followUpFailed, error);
		}
	}
	/** The standard completion of a change: acquire its result into the page
	 * and redraw. */
	async complete(command: ManagedOperation): Promise<unknown> {
		if (this.#acquired.has(command.id)) return this.#acquired.get(command.id);
		const result = await this.#session.completeResult(command);
		this.#acquired.set(command.id, result);
		return result;
	}
	/** `ManagedActions.replace`, as a second change. */
	replace(...args: Parameters<ManagedRoomsSession["actions"]["replace"]>): Promise<void> {
		return this.change(() => this.#session.actions.replace(...args));
	}
}
