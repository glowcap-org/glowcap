import { answerWithin } from "../../../../lib/answer_within.ts";
import { managedSessionText as text } from "../../../../lib/text/managed_session.ts";
import type { ActivityPage } from "./model.ts";

// A viewer gesture must finish even when its selected peer stays silent.
export const READINESS_WAIT_MS = 30_000;
export type ReadinessNotice = Pick<NonNullable<ActivityPage["event"]>, "target" | "notice">;

/** Retain early notices without treating cancellation as readiness. */
export class ReadinessNotices {
	readonly #waiters = new Set<{ matches(event: ReadinessNotice): boolean; done(error: Error | null): void }>();
	#closed = false;

	wait(matches: (event: ReadinessNotice) => boolean): { ready: Promise<void>; cancel(): void } {
		if (this.#closed) throw new Error("This workspace is closed");
		if (this.#waiters.size >= 32) throw new Error("Too many retained protocol readiness waits");
		let resolve!: (error: Error | null) => void;
		const outcome = new Promise<Error | null>((done) => resolve = done);
		const waiter = {
			matches,
			done: (error: Error | null) => {
				this.#waiters.delete(waiter);
				resolve(error);
			},
		};
		this.#waiters.add(waiter);
		const cancel = () => {
			if (this.#waiters.has(waiter)) waiter.done(new Error("The readiness wait was cancelled"));
		};
		let ready: Promise<void> | undefined;
		return {
			// Start the deadline when the introduction actually reports pending.
			// Until then the outcome is data, so closing an unused waiter cannot
			// create an unhandled rejection while the command is still in flight.
			get ready() {
				return ready ??= answerWithin(
					outcome,
					text.directReadinessTimeout,
					READINESS_WAIT_MS,
				).then((error) => {
					if (error != null) throw error;
				}).finally(cancel);
			},
			cancel,
		};
	}

	notify(event: ReadinessNotice): void {
		for (const waiter of this.#waiters) {
			if (waiter.matches(event)) waiter.done(null);
		}
	}

	close(): void {
		this.#closed = true;
		for (const waiter of this.#waiters) waiter.done(new Error("This workspace is closed"));
	}
}
