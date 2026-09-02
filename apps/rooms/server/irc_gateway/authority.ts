// Source-owned durable entry and moderation authority for IRC bridge rooms.

import { type Behavior, currentSession, type Session } from "@glowcap/runtime";
import { roomAuthorityIdentity } from "../../lib/authority_identity.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";
import { NOT_STEWARD, ROOM_RETIRED, RoomError } from "../../lib/errors.ts";
import { GOVERNS, KICK } from "../../lib/protocol.ts";
import type { RoomAuthorityKind } from "../../lib/room/authority.ts";
import type { IrcBridgeAuthorityState, RoomServerOperationsState } from "../operations_state.ts";

export interface IrcBridgeAuthorityHost {
	publish(entropy: Uint8Array, behavior: Behavior): string;
	unpublish(swiss: string): boolean;
	advertisedLocation(session: Session): string;
}

interface ActiveBridgeAuthority {
	readonly publicationId: string;
	readonly roomName: string;
	readonly roomEntropy: string;
	roomSwiss: string;
	stewardSwiss: string | null;
	readonly kickRoomsMember: (nick: string) => boolean;
	/** Whether this name sits under a prefix the server granted a bridge, and so
	 * names somebody bridged from elsewhere rather than a Rooms membership. */
	readonly bridgedName: (nick: string) => boolean;
	readonly authorityChanged: (kind: RoomAuthorityKind, token: string) => void;
}

export interface IrcBridgeStewardship {
	readonly name: string;
	readonly label: string;
	readonly visibility: "listed";
	readonly generation: number;
	readonly issued: boolean;
	readonly steward: string | null;
}

function entropyBytes(hex: string): Uint8Array {
	const bytes = new Uint8Array(hex.length / 2);
	for (let at = 0; at < bytes.length; at += 1) bytes[at] = Number.parseInt(hex.slice(at * 2, at * 2 + 2), 16);
	return bytes;
}

/** One authority publisher for every current IRC bridge generation. Durable
 * state holds only deterministic publication entropy; live swiss names,
 * behavior, and member removal stay with the active bridge projection. */
export class IrcBridgeAuthorities {
	readonly #active = new Map<string, ActiveBridgeAuthority>();
	readonly #state: RoomServerOperationsState;
	readonly #host: IrcBridgeAuthorityHost;
	readonly #changed: () => void;
	#tail: Promise<void> = Promise.resolve();

	constructor(state: RoomServerOperationsState, host: IrcBridgeAuthorityHost, changed: () => void = () => {}) {
		this.#state = state;
		this.#host = host;
		this.#changed = changed;
	}

	activate(
		publicationId: string,
		roomName: string,
		roomBehavior: Behavior,
		kickRoomsMember: (nick: string) => boolean,
		bridgedName: (nick: string) => boolean,
		authorityChanged: (kind: RoomAuthorityKind, token: string) => void = () => {},
	): void {
		const authority = this.#authority(publicationId);
		if (this.#active.has(publicationId)) throw new Error("that IRC bridge authority is already active");
		const active: ActiveBridgeAuthority = {
			publicationId,
			roomName,
			roomEntropy: authority.roomEntropy,
			roomSwiss: "",
			stewardSwiss: null,
			kickRoomsMember,
			bridgedName,
			authorityChanged,
		};
		this.#active.set(publicationId, active);
		try {
			active.roomSwiss = this.#host.publish(entropyBytes(authority.roomEntropy), roomBehavior);
			if (authority.issued) active.stewardSwiss = this.#publishSteward(active, authority);
		} catch (error) {
			this.#active.delete(publicationId);
			if (active.roomSwiss !== "") this.#host.unpublish(active.roomSwiss);
			if (active.stewardSwiss != null) this.#host.unpublish(active.stewardSwiss);
			throw error;
		}
	}

	deactivate(publicationId: string): void {
		const active = this.#active.get(publicationId);
		if (active == null) return;
		this.#active.delete(publicationId);
		this.#host.unpublish(active.roomSwiss);
		if (active.stewardSwiss != null) this.#host.unpublish(active.stewardSwiss);
	}

	link(publicationId: string, session: Session): string {
		const active = this.#active.get(publicationId);
		const authority = this.#state.ircBridgeAuthority(publicationId);
		if (active == null || authority == null || authority.roomEntropy !== active.roomEntropy) {
			throw new RoomError(ROOM_RETIRED, "this IRC bridge publication was retired");
		}
		return this.#linkFor(session, active.roomSwiss);
	}

	stewardships(session: Session): IrcBridgeStewardship[] {
		const out: IrcBridgeStewardship[] = [];
		for (const bridge of this.#state.ircBridges()) {
			const active = this.#active.get(bridge.publicationId);
			const authority = this.#state.ircBridgeAuthority(bridge.publicationId);
			if (active == null || authority == null) continue;
			out.push(this.#row(active, authority, session));
		}
		return out;
	}

	stewardship(publicationId: string, session: Session): IrcBridgeStewardship | null {
		const active = this.#active.get(publicationId);
		const authority = this.#state.ircBridgeAuthority(publicationId);
		return active == null || authority == null ? null : this.#row(active, authority, session);
	}

	issueSteward(publicationId: string, session: Session): Promise<IrcBridgeStewardship> {
		let row: IrcBridgeStewardship | null = null;
		const run = this.#tail.then(async () => {
			const active = this.#active.get(publicationId);
			if (active == null) throw new RoomError(ROOM_RETIRED, "this IRC bridge publication was retired");
			const current = this.#state.ircBridgeAuthority(publicationId);
			if (current == null) throw new RoomError(ROOM_RETIRED, "this IRC bridge publication was retired");
			if (current.issued) {
				if (active.stewardSwiss == null) throw new Error("the active IRC bridge has no published moderator");
				row = this.#row(active, current, session);
				return;
			}
			const authority = await this.#state.issueIrcBridgeSteward(publicationId);
			const stillCurrent = this.#state.ircBridgeAuthority(publicationId);
			if (
				this.#active.get(publicationId) !== active || !stillCurrent?.issued ||
				stillCurrent.stewardEntropy !== authority.stewardEntropy
			) throw new RoomError(ROOM_RETIRED, "this IRC bridge publication retired during moderator issuance");
			try {
				active.stewardSwiss = this.#publishSteward(active, authority);
			} catch (publishError) {
				try {
					await this.#state.revokeIrcBridgeSteward(publicationId, authority.stewardEntropy);
				} catch (rollbackError) {
					this.#changed();
					throw new AggregateError(
						[publishError, rollbackError],
						"IRC bridge moderator publication failed and its durable issuance could not be rolled back",
					);
				}
				this.#changed();
				throw publishError;
			}
			this.#changed();
			row = this.#row(active, authority, session);
		});
		this.#tail = run.then(() => {}, () => {});
		return run.then(() => row!);
	}

	revokeSteward(publicationId: string): Promise<void> {
		const run = this.#tail.then(async () => {
			const active = this.#active.get(publicationId);
			if (active == null) throw new RoomError(ROOM_RETIRED, "this IRC bridge publication was retired");
			const current = this.#state.ircBridgeAuthority(publicationId);
			const oldSwiss = active.stewardSwiss;
			if (current == null || !current.issued || oldSwiss == null) {
				throw new RoomError(NOT_STEWARD, "this IRC bridge has no issued moderator capability");
			}
			await this.#state.revokeIrcBridgeSteward(publicationId, current.stewardEntropy);
			active.stewardSwiss = null;
			this.#host.unpublish(oldSwiss);
			active.authorityChanged("steward", oldSwiss);
			this.#changed();
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	hasSteward(publicationId: string): boolean {
		return this.#active.get(publicationId)?.stewardSwiss != null &&
			this.#state.ircBridgeAuthority(publicationId)?.issued === true;
	}

	#publishSteward(active: ActiveBridgeAuthority, authority: IrcBridgeAuthorityState): string {
		return this.#host.publish(entropyBytes(authority.stewardEntropy), this.#stewardBehavior(active, authority));
	}

	#stewardBehavior(active: ActiveBridgeAuthority, authority: IrcBridgeAuthorityState): Behavior {
		return (verb, args) => {
			const session = currentSession();
			if (session == null) throw new Error("an IRC bridge moderator call has no arriving session");
			const current = this.#state.ircBridgeAuthority(active.publicationId);
			if (
				this.#active.get(active.publicationId) !== active ||
				current?.stewardEntropy !== authority.stewardEntropy ||
				!current.issued
			) throw new RoomError(NOT_STEWARD, "this IRC bridge moderator capability was retired");
			if (verb === GOVERNS) {
				if (args.length !== 0) throw new Error("governs takes no arguments");
				return roomAuthorityIdentity(active.roomSwiss) as ReturnType<Behavior>;
			}
			if (verb === KICK) {
				if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
					throw new Error("kick takes one Rooms member name");
				}
				// A bridged name is not a Rooms membership, so this moderator has no
				// say over one. Asked of the namespace rather than of a literal: the
				// answer has to move when a second bridge takes a second prefix.
				if (active.bridgedName(args[0])) {
					throw new Error("this moderator governs Rooms memberships, not identities bridged from elsewhere");
				}
				if (!active.kickRoomsMember(args[0])) {
					throw new Error(`${args[0]} is not a Rooms member of this bridge`);
				}
				return null;
			}
			throw new Error(`an IRC bridge moderator has no method ${verb}`);
		};
	}

	#row(active: ActiveBridgeAuthority, authority: IrcBridgeAuthorityState, session: Session): IrcBridgeStewardship {
		const steward = authority.issued && active.stewardSwiss != null
			? this.#linkFor(session, active.stewardSwiss)
			: null;
		return {
			name: active.publicationId,
			label: active.roomName,
			visibility: "listed",
			generation: authority.generation,
			issued: steward != null,
			steward,
		};
	}

	#authority(publicationId: string): IrcBridgeAuthorityState {
		const authority = this.#state.ircBridgeAuthority(publicationId);
		if (authority == null) throw new Error("that IRC bridge has no durable authority state");
		return authority;
	}

	#linkFor(session: Session, swiss: string): string {
		return formatRoomsSturdyref(roomsLocator(this.#host.advertisedLocation(session)), swiss);
	}
}
