// Client custody for one consumable room invitation and its retry receipt.

import { Ref, type Session } from "@pancake/runtime";
import { ask } from "../ask.ts";
import { CLAIM_INVITATION } from "../protocol.ts";

function receipt(): string {
	return [...crypto.getRandomValues(new Uint8Array(16))]
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
}

export class RoomInvitation {
	readonly #session: Session;
	readonly #invitation: Ref;
	readonly #receipt = receipt();

	constructor(session: Session, invitation: Ref) {
		this.#session = session;
		this.#invitation = invitation;
	}

	async claim(): Promise<Ref> {
		const entrance = await ask(
			this.#session,
			this.#invitation,
			CLAIM_INVITATION,
			[this.#receipt],
			"the room invitation did not answer its claim",
		);
		if (!(entrance instanceof Ref)) throw new Error("the room invitation answered without an entrance capability");
		return entrance;
	}

	release(): void {
		this.#session.release(this.#invitation);
	}

	get reference(): Ref {
		return this.#invitation;
	}
}
