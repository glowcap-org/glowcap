// Client ownership of one passable room-manager sturdyref.

import { Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { GOVERNS, LINK, MANAGED_ROOM_IDENTITY } from "../protocol.ts";

export async function managedRoomIdentity(session: Session, room: Ref): Promise<string> {
	const identity = await ask(
		session,
		room,
		MANAGED_ROOM_IDENTITY,
		[],
		"the room did not identify its manager",
	);
	if (typeof identity !== "string" || identity === "") {
		throw new Error("the room answered no management identity");
	}
	return identity;
}

class RoomManagerMismatch extends Error {}

export class RoomManager {
	readonly #session: Session;
	readonly sturdyref: string;

	private constructor(session: Session, sturdyref: string) {
		this.#session = session;
		this.sturdyref = sturdyref;
	}

	/** Validate before retaining the string. The imported occurrences are only
	 * proof work. The sturdyref remains the durable authority. */
	static async take(session: Session, room: Ref, sturdyref: string): Promise<RoomManager> {
		const manager = await session.enliven(sturdyref);
		try {
			const governed = await ask(session, manager, GOVERNS, [], "the room manager did not identify its room");
			const identity = await managedRoomIdentity(session, room);
			if (typeof governed !== "string" || governed === "" || governed !== identity) {
				throw new RoomManagerMismatch("that room manager belongs to a different room");
			}
		} catch (error) {
			await retainCleanupFailures(error, [() => session.release(manager)]);
			throw error;
		}
		session.release(manager);
		return new RoomManager(session, sturdyref);
	}

	async roomLink(): Promise<string> {
		const answer = await this.#call(LINK, []);
		if (typeof answer !== "string" || answer === "") throw new Error("the room manager named no room link");
		return answer;
	}

	async #call(verb: string, args: string[]): Promise<unknown> {
		const manager = await this.#session.enliven(this.sturdyref);
		try {
			return await ask(this.#session, manager, verb, args, `the room manager did not answer ${verb}`);
		} finally {
			this.#session.release(manager);
		}
	}
}
