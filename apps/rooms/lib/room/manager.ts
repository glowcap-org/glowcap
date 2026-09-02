// Client custody for one passable room-manager sturdyref.

import { Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { GOVERNS, LINK, MANAGED_ROOM_IDENTITY } from "../protocol.ts";
import {
	GIVE_STEWARD,
	REVOKE_ROOM_LINK,
	REVOKE_STEWARD,
	SET_ROOM_POLICY,
	UNREGISTER_ROOM,
} from "../protocol_operator.ts";
import { roomAuthorityToken } from "./authority.ts";
import { isRoomEntry, isRoomSpeaking, isRoomVisibility, parseRoomPolicy, type RoomPolicy } from "./policy.ts";

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

export class RoomManagerMismatch extends Error {}

export class RoomManager {
	readonly #session: Session;
	readonly sturdyref: string;

	private constructor(session: Session, sturdyref: string) {
		this.#session = session;
		this.sturdyref = sturdyref;
	}

	/** Validate before retaining the string. The imported occurrences are only
	 * proof work; the sturdyref remains the durable authority. */
	static async take(session: Session, room: Ref, sturdyref: string): Promise<RoomManager> {
		const manager = await session.enliven(sturdyref);
		try {
			const governed = await ask(session, manager, GOVERNS, [], "the room manager did not identify its room");
			const identity = await managedRoomIdentity(session, room);
			if (typeof governed !== "string" || governed === "" || governed !== identity) {
				throw new RoomManagerMismatch("that room manager belongs to a different room");
			}
		} catch (error) {
			throw await retainCleanupFailures(error, [() => session.release(manager)]);
		}
		session.release(manager);
		return new RoomManager(session, sturdyref);
	}

	async giveModerator(): Promise<unknown> {
		return await this.#call(GIVE_STEWARD, []);
	}

	async roomLink(): Promise<string> {
		const answer = await this.#call(LINK, []);
		if (typeof answer !== "string" || answer === "") throw new Error("the room manager named no room link");
		return answer;
	}

	async revokeModerator(token: string): Promise<void> {
		await this.#call(REVOKE_STEWARD, [token]);
	}

	async revokeRoomLink(token: string): Promise<void> {
		await this.#call(REVOKE_ROOM_LINK, [token]);
	}

	async unregisterRoom(): Promise<{ policy: RoomPolicy; name: string }> {
		return this.#policyAnswer(
			await this.#call(UNREGISTER_ROOM, [roomAuthorityToken(this.sturdyref)]),
			"unregistration",
		);
	}

	async setPolicy(policy: RoomPolicy, name: string): Promise<{ policy: RoomPolicy; name: string }> {
		const answer = await this.#call(SET_ROOM_POLICY, [
			roomAuthorityToken(this.sturdyref),
			policy.visibility,
			policy.entry,
			policy.speaking,
			name,
		]);
		return this.#policyAnswer(answer, "policy change");
	}

	#policyAnswer(answer: unknown, operation: string): { policy: RoomPolicy; name: string } {
		if (
			!Array.isArray(answer) || answer.length !== 4 || typeof answer[0] !== "string" || answer[0] === "" ||
			!isRoomVisibility(answer[1]) || !isRoomEntry(answer[2]) || !isRoomSpeaking(answer[3])
		) throw new Error(`the room manager answered ${operation} with an invalid room policy`);
		const returned = parseRoomPolicy(answer.slice(1));
		if (returned === null) throw new Error("the room manager answered an unsupported room policy");
		return { name: answer[0], policy: returned };
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
