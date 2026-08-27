// One bounded attempt to establish a durable direct conversation's route.

import { DIRECT_CONVERSATION_ROUTE_TIMEOUT_MS } from "../lib/limits.ts";

/** Shared by every command waiting on the same direct conversation. The
 * attempt may first dial normally and then wait for a reciprocal route, but it
 * has one completion and one cleanup lifetime either way. */
export class DirectConversationRouteAttempt {
	readonly topology: string;
	readonly promise: Promise<void>;
	readonly #resolvePromise: () => void;
	readonly #rejectPromise: (error: unknown) => void;
	#timer: ReturnType<typeof setTimeout> | null = null;
	#work: Promise<void> = Promise.resolve();
	#phase: "dialing" | "reciprocal" | "settled" = "dialing";
	#tracked = false;

	constructor(topology: string) {
		this.topology = topology;
		const pending = Promise.withResolvers<void>();
		this.promise = pending.promise;
		this.#resolvePromise = pending.resolve;
		this.#rejectPromise = pending.reject;
	}

	get settled(): boolean {
		return this.#phase === "settled";
	}

	trackOpening(work: Promise<void>): void {
		if (this.#tracked) throw new Error("a direct conversation route attempt already owns its opening work");
		this.#tracked = true;
		this.#work = work;
	}

	reciprocalRequested(normalFailure: unknown): void {
		if (this.settled || this.#phase === "reciprocal") return;
		this.#phase = "reciprocal";
		this.#timer = setTimeout(() => {
			this.failed(
				new Error("the peer did not establish the requested reciprocal direct route", {
					cause: normalFailure,
				}),
			);
		}, DIRECT_CONVERSATION_ROUTE_TIMEOUT_MS);
	}

	established(): void {
		if (!this.#finish()) return;
		this.#resolvePromise();
	}

	failed(error: unknown): void {
		if (!this.#finish()) return;
		this.#rejectPromise(error);
	}

	conversationChanged(): void {
		this.failed(new Error("that direct conversation changed while its route was opening"));
	}

	async directoryClosed(): Promise<void> {
		this.failed(new Error("the directory connection ended while a direct route was opening"));
		await this.#work;
	}

	#finish(): boolean {
		if (this.settled) return false;
		this.#phase = "settled";
		if (this.#timer != null) clearTimeout(this.#timer);
		this.#timer = null;
		return true;
	}
}
