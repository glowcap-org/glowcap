// Durable room and steward authorities held by one room client.

import { PublicationNotFound, Ref, retainCleanupFailures } from "@glowcap/runtime";
import { settleCapabilityCleanup } from "../capability_cleanup.ts";
import type { Argument, Session } from "@glowcap/runtime";
import { roomAuthorityIdentity } from "../authority_identity.ts";
import { ask } from "../ask.ts";
import { NOT_STEWARD, RoomsError, roomsErrorOf } from "../errors.ts";
import { GOVERNS, KICK, LINK } from "../protocol.ts";
import { parseRoomsSturdyref } from "../locator.ts";
import { type RoomAuthorityChange, roomAuthorityToken } from "./authority.ts";
import { RoomManager } from "./manager.ts";
import type { RoomPolicy } from "./policy.ts";

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
	#managerLink: string | null = null;
	#roomToken: string | null = null;
	#stewardToken: string | null = null;
	#managerToken: string | null = null;
	#stewardRetired = false;

	constructor(session: Session, room: Ref) {
		this.#session = session;
		this.#room = room;
	}

	/** Mint or recover the room's durable sturdyref. */
	async link(): Promise<string> {
		const authority = this.#managerLink == null
			? await this.#roomAuthority()
			: await this.#roomAuthorityFromManager(this.#managerLink);
		this.#roomLink = authority.link;
		this.#roomToken = authority.swiss;
		return authority.link;
	}

	async #roomAuthorityFromManager(managerLink: string): Promise<{ swiss: string; link: string }> {
		const manager = await RoomManager.take(this.#session, this.#room, managerLink);
		const link = await manager.roomLink();
		const swiss = swissDecoder.decode(parseRoomsSturdyref(link).swissnum);
		if (swiss === "") throw new Error("the room manager answered a link with no authority");
		return { swiss, link };
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
		if (this.#managerLink === null) return false;
		try {
			const manager = await RoomManager.take(this.#session, this.#room, this.#managerLink);
			await this.#acceptSteward(await manager.giveModerator());
			return true;
		} catch (error) {
			if (roomsErrorOf(error)?.code === NOT_STEWARD) return false;
			throw error;
		}
	}

	async #acceptSteward(grant: unknown): Promise<void> {
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
		const steward = await this.#session.enliven(stewardLink);
		this.#roomLink = roomLink;
		this.#stewardLink = stewardLink;
		this.#roomToken = roomAuthority;
		this.#stewardToken = roomAuthorityToken(stewardLink);
		this.#steward = steward;
		this.#stewardRetired = false;
	}

	async takeManager(managerLink: string): Promise<void> {
		await RoomManager.take(this.#session, this.#room, managerLink);
		this.#managerLink = managerLink;
		this.#managerToken = roomAuthorityToken(managerLink);
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
		let candidate: Ref;
		try {
			candidate = await this.#session.enliven(stewardLink);
		} catch (error) {
			if (error instanceof PublicationNotFound) {
				throw new RoomsError(NOT_STEWARD, "this moderator capability was retired");
			}
			throw error;
		}
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
		this.#stewardRetired = false;
		this.#roomLink = room.link;
		this.#stewardLink = stewardLink;
		this.#roomToken = room.swiss;
		this.#stewardToken = roomAuthorityToken(stewardLink);
	}

	get roomLink(): string | null {
		return this.#roomLink;
	}

	get stewardLink(): string | null {
		return this.#stewardLink;
	}

	get managerLink(): string | null {
		return this.#managerLink;
	}

	get held(): boolean {
		return this.#steward !== null;
	}

	/** Forget authority the server explicitly rotated. Reconnect retention is a
	 * different lifecycle and continues to use `release`, which keeps strings. */
	forget(change: RoomAuthorityChange): void {
		const matchesSteward = this.#stewardToken === change.token;
		const matchesRoom = this.#roomToken === change.token;
		const matchesManager = this.#managerToken === change.token;
		if ((change.kind === "steward" ? matchesSteward : matchesRoom) && this.#steward !== null) {
			const retired = this.#steward;
			this.#steward = null;
			settleCapabilityCleanup(
				"revoked room moderator capability release failed",
				() => this.#session.release(retired),
			);
		}
		if (change.kind === "steward" && matchesSteward) {
			this.#stewardLink = null;
			this.#stewardToken = null;
			this.#stewardRetired = true;
		}
		if (change.kind === "room" && matchesRoom) {
			this.#roomLink = null;
			this.#roomToken = null;
			this.#stewardLink = null;
			this.#stewardToken = null;
			this.#stewardRetired = true;
		}
		if (change.kind === "manager" && matchesManager) {
			this.#managerLink = null;
			this.#managerToken = null;
		}
	}

	/** Voluntarily drop this client's moderator occurrence without revoking
	 * copies held elsewhere or forgetting the room link itself. */
	drop(): void {
		if (this.#steward !== null) this.#session.release(this.#steward);
		this.#steward = null;
		this.#stewardLink = null;
		this.#stewardToken = null;
		this.#stewardRetired = false;
	}

	dropManager(): void {
		this.#managerLink = null;
		this.#managerToken = null;
	}

	async revokeManagedAuthority(kind: "room" | "steward", token: string): Promise<void> {
		if (this.#managerLink === null) throw new Error("this room does not retain its manager capability");
		const manager = await RoomManager.take(this.#session, this.#room, this.#managerLink);
		if (kind === "room") await manager.revokeRoomLink(token);
		else await manager.revokeModerator(token);
	}

	async unregisterRoom(): Promise<{ policy: RoomPolicy; name: string }> {
		if (this.#managerLink === null) throw new Error("this room does not retain its manager capability");
		const manager = await RoomManager.take(this.#session, this.#room, this.#managerLink);
		return await manager.unregisterRoom();
	}

	async setPolicy(policy: RoomPolicy, name: string): Promise<{ policy: RoomPolicy; name: string }> {
		if (this.#managerLink === null) throw new Error("this room does not retain its manager capability");
		const manager = await RoomManager.take(this.#session, this.#room, this.#managerLink);
		return await manager.setPolicy(policy, name);
	}

	async kick(nick: string): Promise<void> {
		if (this.#steward === null) {
			if (this.#stewardRetired) throw new RoomsError(NOT_STEWARD, "this moderator capability was retired");
			throw new Error("this room did not hand over its steward");
		}
		await ask(this.#session, this.#steward, KICK, [nick], "the steward did not answer the kick");
	}

	/** Release the live import while retaining the copyable sturdyref strings. */
	release(): void {
		if (this.#steward === null) return;
		this.#session.release(this.#steward);
		this.#steward = null;
	}
}
