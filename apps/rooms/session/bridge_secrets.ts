// Secrets a reader answered a bridge form with, held for one durable runtime.
//
// A checkpoint keeps what the reader chose and never what they typed into a
// secret field. So a password lives here, in memory, from the moment a command
// stages it until every room in its scope has replayed it, a refused command
// takes it back, or the runtime closes.
//
// Scope is the bridge's word for how far one answer reaches, so this holds what
// the bridge said rather than deciding for itself: IRC shares an identity
// across a network, and a bridge that shares nothing names each room.
//
// Tokens exist because two commands can be in flight for one scope. Without
// one, an older command's refusal would discard the credentials a newer command
// had already staged, and the newer submission would replay with nothing.

import type { BridgeAnswers } from "../lib/bridge/form.ts";

export class RoomBridgeSecrets {
	readonly #held = new Map<string, { answers: BridgeAnswers; token: symbol }>();

	static key(directoryId: string, scope: string): string {
		// A separator no name can contain, so two scopes cannot be spelled into
		// one another's key.
		return `${directoryId}\u0000${scope.toLowerCase()}`;
	}

	/** Take what one submission answered in secret. Answering nothing takes back
	 * whatever was held, because a submission with no secrets is a reader saying
	 * this scope needs none. */
	stage(directoryId: string, scope: string, answers: BridgeAnswers): symbol | null {
		const key = RoomBridgeSecrets.key(directoryId, scope);
		if (Object.keys(answers).length === 0) {
			this.#held.delete(key);
			return null;
		}
		const token = Symbol("staged bridge secrets");
		this.#held.set(key, { answers, token });
		return token;
	}

	/** Give back exactly what one command staged, and nothing a later one did. */
	discard(directoryId: string, scope: string, token: symbol): void {
		const key = RoomBridgeSecrets.key(directoryId, scope);
		if (this.#held.get(key)?.token === token) this.#held.delete(key);
	}

	/** What this scope answered in secret, or null when nothing is held.
	 *
	 * Null and empty are different answers and a caller must keep them apart:
	 * nothing held means a reader has to be asked again, while an empty set means
	 * they answered and had no secrets to give. */
	answers(directoryId: string, scope: string): BridgeAnswers | null {
		return this.#held.get(RoomBridgeSecrets.key(directoryId, scope))?.answers ?? null;
	}

	clear(): void {
		this.#held.clear();
	}
}
