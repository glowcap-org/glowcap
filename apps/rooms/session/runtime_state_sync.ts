// Instance-owned delivery of live authority facts to the durable state owner.

import type { RuntimeStateReconciliation } from "./state_sync.ts";
import type { LiveDirectory } from "./live.ts";

const RETRY_FLOOR_MS = 1_000;
const RETRY_CEILING_MS = 30_000;

function subject(change: RuntimeStateReconciliation): string {
	if (change.type === "room-authority") return `authority:${change.conversationId}`;
	if (change.type === "room-authority-acquired") return `authority-acquired:${change.conversationId}`;
	if (change.type === "room-publication") return `room-publication:${change.conversationId}`;
	if (change.type === "direct-accepted") return `direct-accepted:${change.conversationId}`;
	if (change.type === "room-reconnect") return `room-reconnect:${change.conversationId}`;
	return `directory-reached:${change.directoryId}`;
}

/** Serialize facts, retain a failed fact ahead of later ones, and retry with a
 * bounded delay. The first attempt still settles its caller promptly; the
 * queue keeps ownership until commit or close. */
export class RuntimeStateSync {
	readonly #reconcile: (change: RuntimeStateReconciliation) => Promise<void>;
	readonly #setIssue: (subject: string, error: unknown | null) => void;
	#tail: Promise<void> = Promise.resolve();
	#closed = false;
	#wake: (() => void) | null = null;
	#lastFailure: unknown | null = null;

	constructor(
		reconcile: (change: RuntimeStateReconciliation) => Promise<void>,
		setIssue: (subject: string, error: unknown | null) => void,
	) {
		this.#reconcile = reconcile;
		this.#setIssue = setIssue;
	}

	submit(change: RuntimeStateReconciliation): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("Rooms runtime state synchronization is closed"));
		const first = Promise.withResolvers<void>();
		const run = this.#tail.then(() => this.#deliver(change, first));
		this.#tail = run.then(() => {}, () => {});
		return first.promise;
	}

	async close(): Promise<void> {
		this.#closed = true;
		this.#wake?.();
		await this.#tail;
		if (this.#lastFailure != null) {
			throw new Error(
				`Rooms runtime closed with unsynchronized state: ${
					this.#lastFailure instanceof Error ? this.#lastFailure.message : this.#lastFailure
				}`,
				{ cause: this.#lastFailure },
			);
		}
	}

	async #deliver(
		change: RuntimeStateReconciliation,
		first: PromiseWithResolvers<void>,
	): Promise<void> {
		let delay = RETRY_FLOOR_MS;
		let firstAttempt = true;
		while (!this.#closed) {
			try {
				await this.#reconcile(change);
				this.#lastFailure = null;
				this.#setIssue(subject(change), null);
				if (firstAttempt) first.resolve();
				return;
			} catch (error) {
				this.#lastFailure = error;
				this.#setIssue(subject(change), error);
				if (firstAttempt) first.reject(error);
				firstAttempt = false;
				await this.#wait(delay);
				delay = Math.min(delay * 2, RETRY_CEILING_MS);
			}
		}
		if (firstAttempt) first.reject(new Error("Rooms runtime closed before state synchronization"));
	}

	#wait(delay: number): Promise<void> {
		return new Promise((resolve) => {
			const timer = setTimeout(() => {
				this.#wake = null;
				resolve();
			}, delay);
			this.#wake = () => {
				clearTimeout(timer);
				this.#wake = null;
				resolve();
			};
		});
	}
}

/** Admit one exact incoming registration through durable state, then wait for
 * that checkpoint to populate the live directory before its inbox is offered. */
export async function acceptDirectConversation(
	sync: RuntimeStateSync,
	held: LiveDirectory,
	peer: string,
	peerRegistrationId: string,
	settled: () => Promise<void>,
): Promise<string> {
	const existing = held.directConversationByRegistration.get(peerRegistrationId);
	if (existing != null) return existing;
	const conversationId = crypto.randomUUID();
	await sync.submit({
		type: "direct-accepted",
		conversationId,
		directoryId: held.id,
		peer,
		peerRegistrationId,
	});
	await settled();
	const accepted = held.directConversationByRegistration.get(peerRegistrationId);
	if (accepted == null) throw new Error("the accepted direct conversation did not reach its live directory");
	return accepted;
}
