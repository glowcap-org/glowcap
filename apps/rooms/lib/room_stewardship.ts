// Durable room and steward authorities held by one room client.

import { Ref, retainCleanupFailures } from "@pancake/runtime";
import type { Argument, Session } from "@pancake/runtime";
import { roomAuthorityIdentity } from "./authority_identity.ts";
import { ask } from "./ask.ts";
import { NOT_STEWARD, roomErrorOf } from "./errors.ts";
import { GOVERNS, KICK, LINK, STEWARD } from "./protocol.ts";
import { parseRoomsSturdyref, roomsSturdyrefForSession } from "./locator.ts";

const swissDecoder = new TextDecoder("utf-8", { fatal: true });

/** The durable authority one room membership has accumulated.
 *
 * This object owns the imported steward reference and the two sturdyref
 * strings that describe it. Keeping that lifecycle together prevents a room
 * reconnect, handover, or failed replacement from leaving `canKick` and the
 * copyable links describing different authority. */
export class RoomStewardship {
	readonly #session: Session;
	readonly #room: Ref;
	#steward: Ref | null = null;
	#roomLink: string | null = null;
	#stewardLink: string | null = null;

	constructor(session: Session, room: Ref) {
		this.#session = session;
		this.#room = room;
	}

	/** Mint or recover the room's durable sturdyref. */
	async link(): Promise<string> {
		const authority = await this.#roomAuthority();
		this.#roomLink = authority.link;
		return authority.link;
	}

	async #roomAuthority(): Promise<{ swiss: string; link: string }> {
		const link = await ask(this.#session, this.#room, LINK, [], "the room did not answer linking itself");
		if (typeof link !== "string" || link.length === 0) {
			throw new Error("link() did not return a sturdyref");
		}
		const swiss = swissDecoder.decode(parseRoomsSturdyref(link).swissnum);
		if (swiss === "") throw new Error("the room answered a sturdyref with no authority");
		return { swiss, link };
	}

	/** Try to mint this room's one steward. Only the exact typed refusal means
	 * this membership does not hold it; every operational failure propagates. */
	async claim(): Promise<boolean> {
		if (this.#steward !== null) return true;
		try {
			await this.#claimAuthority();
			return true;
		} catch (error) {
			if (roomErrorOf(error)?.code === NOT_STEWARD) return false;
			throw error;
		}
	}

	async #claimAuthority(): Promise<void> {
		const grant = await ask(this.#session, this.#room, STEWARD, [], "the room did not answer for its steward");
		if (
			!Array.isArray(grant) || typeof grant[0] !== "string" || grant[0] === "" ||
			typeof grant[1] !== "string" || grant[1] === "" ||
			typeof grant[2] !== "string" || grant[2] === ""
		) {
			throw new Error("the room did not answer with its steward authority");
		}
		const roomAuthority = swissDecoder.decode(parseRoomsSturdyref(grant[0]).swissnum);
		if (roomAuthority === "" || grant[1] !== await roomAuthorityIdentity(roomAuthority)) {
			throw new Error("the room answered a steward for a different room authority");
		}
		const roomLink = grant[0];
		const stewardLink = grant[2];
		const steward = await this.#session.enliven(roomsSturdyrefForSession(stewardLink, this.#session));
		this.#roomLink = roomLink;
		this.#stewardLink = stewardLink;
		this.#steward = steward;
	}

	async #moderatedRoomIdentity(candidate: Ref): Promise<Argument> {
		try {
			return await ask(
				this.#session,
				candidate,
				GOVERNS,
				[],
				"the moderator capability did not identify its room",
			);
		} catch (error) {
			const reason = error instanceof Error ? error.message : String(error);
			throw new Error(`could not validate that sturdyref as a room moderator capability: ${reason}`);
		}
	}

	/** Take a steward sturdyref for this exact room. Validation completes before
	 * replacing any authority already held, and every rejected candidate is
	 * released. */
	async take(stewardLink: string): Promise<void> {
		// A reconnect can race an explicit take of the same retained string. The
		// imported reference already passed the exact-room proof, so importing it
		// again would only add a retain that then has to be balanced correctly.
		if (this.#steward !== null && stewardLink === this.#stewardLink) return;
		const room = await this.#roomAuthority();
		const roomIdentity = await roomAuthorityIdentity(room.swiss);
		const candidate = await this.#session.enliven(roomsSturdyrefForSession(stewardLink, this.#session));
		try {
			const governs = await this.#moderatedRoomIdentity(candidate);
			if (typeof governs !== "string" || governs === "" || governs !== roomIdentity) {
				throw new Error("that moderator capability belongs to a different room");
			}
		} catch (error) {
			throw await retainCleanupFailures(error, [() => this.#session.release(candidate)]);
		}
		const previous = this.#steward;
		if (previous !== null) {
			try {
				this.#session.release(previous);
			} catch (error) {
				throw await retainCleanupFailures(error, [() => this.#session.release(candidate)]);
			}
		}
		this.#steward = candidate;
		this.#roomLink = room.link;
		this.#stewardLink = stewardLink;
	}

	get roomLink(): string | null {
		return this.#roomLink;
	}

	get stewardLink(): string | null {
		return this.#stewardLink;
	}

	get held(): boolean {
		return this.#steward !== null;
	}

	async kick(nick: string): Promise<void> {
		if (this.#steward === null) throw new Error("this room did not hand over its steward");
		await ask(this.#session, this.#steward, KICK, [nick], "the steward did not answer the kick");
	}

	/** Release the live import while retaining the copyable sturdyref strings. */
	release(): void {
		if (this.#steward === null) return;
		this.#session.release(this.#steward);
		this.#steward = null;
	}
}
