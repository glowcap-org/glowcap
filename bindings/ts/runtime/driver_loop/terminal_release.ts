import { GlowcapError, retainSecondaryFailure } from "../errors.ts";
import { deferFinalizerRetry, type FinalizerRetry } from "../finalizer_retry.ts";
import type { DriverCallOutcome } from "../internal/driver_failure.ts";
import { releaseConsumed } from "../lifecycle.ts";

type ReleaseAttempt = () => DriverCallOutcome;
type ReleaseCommit = () => void | Promise<void>;
type RetryScheduler = (retry: FinalizerRetry) => void;

/** The last owner of a loop release refused after the loop became terminal.
 * One safe boundary claims one attempt; another refusal requeues the same
 * identity, while a consumed result commits wrapper retirement exactly once. */
export class TerminalDriverRelease {
	readonly failure: GlowcapError;
	readonly #attempt: ReleaseAttempt;
	readonly #commit: ReleaseCommit;
	readonly #schedule: RetryScheduler;
	readonly #retry: FinalizerRetry;
	#finished = false;
	#refusalRetained = false;

	constructor(
		failure: GlowcapError,
		attempt: ReleaseAttempt,
		commit: ReleaseCommit,
		initialOutcome?: DriverCallOutcome,
		schedule: RetryScheduler = deferFinalizerRetry,
	) {
		this.failure = failure;
		this.#attempt = attempt;
		this.#commit = commit;
		this.#schedule = schedule;
		this.#retry = () => this.#run();
		if (initialOutcome == null) this.#run();
		else this.#accept(initialOutcome);
	}

	#run(): void {
		if (this.#finished) return;
		try {
			this.#accept(this.#attempt());
		} catch (refusal) {
			this.#retainRefusal(refusal);
			this.#schedule(this.#retry);
		}
	}

	#retainRefusal(refusal: unknown): void {
		if (this.#refusalRetained) return;
		this.#refusalRetained = true;
		retainSecondaryFailure(this.failure, refusal);
	}

	#accept(outcome: DriverCallOutcome): void {
		const consumed = releaseConsumed(outcome.code);
		if (!consumed) {
			if (outcome.error !== null) this.#retainRefusal(outcome.error);
			this.#schedule(this.#retry);
			return;
		}
		this.#finished = true;
		if (outcome.error !== null) retainSecondaryFailure(this.failure, outcome.error);
		let completion: void | Promise<void>;
		try {
			completion = this.#commit();
		} catch (cleanup) {
			retainSecondaryFailure(this.failure, cleanup);
			return;
		}
		if (completion != null) {
			void completion.catch((cleanup) => {
				retainSecondaryFailure(this.failure, cleanup);
			});
		}
	}
}
