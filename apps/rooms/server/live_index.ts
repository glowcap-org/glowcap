// One Rooms server's live room, publication, introduction, and signaling tables.
//
// CapTP sessions remain the runtime's authority for references. This index is
// the application-owned inventory those sessions share: constructing another
// server constructs another set of tables, and closing one cannot empty the
// other.

import { durableIdentityAuthenticated, type Ref, type Session } from "@glowcap/runtime";
import { ROOM_EXISTS, RoomError, TOO_MANY_PEERED_ROOMS, TOO_MANY_ROOMS } from "../lib/errors.ts";
import {
	MAX_PEERED_ROOMS,
	MAX_PEERED_ROOMS_PER_SOURCE,
	MAX_ROOMS_PER_CREATOR,
	newManagedRoomId,
} from "../lib/limits.ts";
import { OPEN_ROOM_POLICY, roomIsListed, type RoomPolicy } from "../lib/room/policy.ts";
import type { TroubleJournal } from "./journal.ts";
import { retireInvitation } from "./invitation.ts";
import type { OperatorRevision } from "./operator/revision.ts";
import {
	type BridgeRoomEntry,
	type ForeignRoomEntry,
	type ForeignRoomReservation,
	type Introduction,
	localRoomEntry,
	type PublicRoomEntry,
	type PublicRoomNameReservation,
	roomKey,
	type RoomState,
} from "./registry.ts";

/** How many IRC channels one server bridges at most. */
const MAX_BRIDGED_ROOMS = 16;

interface ForeignRoomSource {
	ids: Set<string>;
	origin: string;
	proof: "authenticated" | "session";
}

interface SignalExchange {
	originator: Session;
	reply: Ref;
	targetKey: string;
	expires: ReturnType<typeof setTimeout>;
}

/** Live rooms, public names, introductions, and signaling for one server. */
export class RoomLiveIndex {
	readonly rooms = new Map<string, RoomState>();
	readonly publicRooms = new Map<string, PublicRoomEntry>();
	readonly introductions = new Map<string, Introduction>();
	readonly introductionsById = new Map<string, Introduction>();
	readonly introductionsBySession = new Map<Session, Introduction>();
	readonly webrtcDesignators = new Map<string, string>();
	readonly signalExchanges = new Map<string, SignalExchange>();

	readonly #publicRoomsById = new Map<string, PublicRoomEntry>();
	readonly #foreignRoomReservationsById = new Map<string, ForeignRoomReservation>();
	readonly #foreignRoomReservationByKey = new Map<string, string>();
	readonly #localRoomReservationByKey = new Map<string, symbol>();
	readonly #foreignRoomsBySource = new Map<Session, ForeignRoomSource>();
	readonly #roomsPerOwnerSession = new Map<Session, number>();
	#bridgedRoomCount = 0;
	#foreignRoomCount = 0;
	#nextSignalExchange = 0;

	constructor(
		readonly operator: OperatorRevision,
		readonly journal: TroubleJournal,
	) {}

	#publicRoomId(): string {
		let id = crypto.randomUUID();
		while (this.#publicRoomsById.has(id) || this.#foreignRoomReservationsById.has(id)) {
			id = crypto.randomUUID();
		}
		return id;
	}

	#publicRoomKeyTaken(key: string): boolean {
		return this.publicRooms.has(key) || this.#foreignRoomReservationByKey.has(key) ||
			this.#localRoomReservationByKey.has(key);
	}

	makeRoomState(
		name: string,
		lifetimeOwner: Session,
		kept?: { policy: RoomPolicy; key?: string; topic?: string },
	): RoomState {
		const policy = kept?.policy ?? OPEN_ROOM_POLICY;
		return {
			entryId: this.#publicRoomId(),
			name,
			key: kept?.key ?? (policy.visibility === "secret" ? newManagedRoomId() : roomKey(name)),
			policy,
			members: [],
			invitations: new Set(),
			lifetimeOwner,
			nextLine: 1,
			topic: kept?.topic ?? "",
			files: [],
			fileBytes: 0,
			uploads: new Map(),
		};
	}

	publicRoomNameTaken(name: string): boolean {
		return this.#publicRoomKeyTaken(roomKey(name));
	}

	publicRoomById(id: string): PublicRoomEntry | null {
		return this.#publicRoomsById.get(id) ?? null;
	}

	registerBridgeRoom(
		name: string,
		origin: string,
		bridge: { roomBehavior(): import("@glowcap/runtime").Behavior },
		id = this.#publicRoomId(),
	): BridgeRoomEntry {
		const key = roomKey(name);
		if (this.#publicRoomKeyTaken(key)) throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
		if (
			id === "" || id.length > 128 || this.#publicRoomsById.has(id) || this.#foreignRoomReservationsById.has(id)
		) {
			throw new RoomError(ROOM_EXISTS, "that room publication identity is already live");
		}
		if (this.#bridgedRoomCount >= MAX_BRIDGED_ROOMS) {
			throw new RoomError(TOO_MANY_ROOMS, `this directory already bridges ${MAX_BRIDGED_ROOMS} channels`);
		}
		const entry: BridgeRoomEntry = { kind: "bridge", id, name, origin, proof: "bridge", bridge };
		this.publicRooms.set(key, entry);
		this.#publicRoomsById.set(entry.id, entry);
		this.#bridgedRoomCount += 1;
		this.operator.noteChange();
		return entry;
	}

	forgetBridgeRoom(id: string): BridgeRoomEntry | null {
		const entry = this.#publicRoomsById.get(id);
		if (entry === undefined || entry.kind !== "bridge") return null;
		this.#publicRoomsById.delete(id);
		this.publicRooms.delete(roomKey(entry.name));
		this.#bridgedRoomCount -= 1;
		this.operator.noteChange();
		return entry;
	}

	reservePublicRoomName(name: string, owner?: RoomState): PublicRoomNameReservation {
		const key = roomKey(name);
		const token = Symbol(name);
		const current = this.publicRooms.get(key);
		if (
			(current !== undefined && (current.kind !== "local" || current.state !== owner)) ||
			this.#foreignRoomReservationByKey.has(key) || this.#localRoomReservationByKey.has(key)
		) throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
		this.#localRoomReservationByKey.set(key, token);
		return { key, token };
	}

	releasePublicRoomName(reservation: PublicRoomNameReservation): void {
		if (this.#localRoomReservationByKey.get(reservation.key) === reservation.token) {
			this.#localRoomReservationByKey.delete(reservation.key);
		}
	}

	commitLocalRoomPolicy(
		state: RoomState,
		policy: RoomPolicy,
		name: string,
		reservation: PublicRoomNameReservation | null,
	): boolean {
		if (this.rooms.get(state.key) !== state) {
			if (reservation !== null) this.releasePublicRoomName(reservation);
			return false;
		}
		if (roomIsListed(policy) !== (reservation !== null)) {
			throw new Error("a listed room access change needs one public-name reservation");
		}
		if (reservation !== null && this.#localRoomReservationByKey.get(reservation.key) !== reservation.token) {
			throw new Error("that managed room lost its public-name reservation");
		}
		const wasListed = roomIsListed(state.policy);
		if (wasListed) {
			const oldKey = roomKey(state.name);
			const prior = this.publicRooms.get(oldKey);
			if (prior?.kind === "local" && prior.state === state) this.publicRooms.delete(oldKey);
		}
		state.name = name;
		state.policy = policy;
		if (reservation !== null) {
			this.#localRoomReservationByKey.delete(reservation.key);
			const entry = localRoomEntry(state);
			this.publicRooms.set(reservation.key, entry);
			this.#publicRoomsById.set(entry.id, entry);
		} else {
			this.#publicRoomsById.delete(state.entryId);
		}
		this.operator.noteChange();
		return true;
	}

	registerRoom(state: RoomState): void {
		const held = this.#roomsPerOwnerSession.get(state.lifetimeOwner) ?? 0;
		if (held >= MAX_ROOMS_PER_CREATOR) {
			throw new RoomError(
				TOO_MANY_ROOMS,
				`this connection already has ${MAX_ROOMS_PER_CREATOR} rooms open`,
			);
		}
		const listed = roomIsListed(state.policy);
		const publicKey = roomKey(state.name);
		if (listed && this.#publicRoomKeyTaken(publicKey)) {
			throw new RoomError(ROOM_EXISTS, `room "${state.name}" already exists`);
		}
		this.rooms.set(state.key, state);
		if (listed) {
			const entry = localRoomEntry(state);
			this.publicRooms.set(publicKey, entry);
			this.#publicRoomsById.set(entry.id, entry);
		}
		this.#roomsPerOwnerSession.set(state.lifetimeOwner, held + 1);
		this.operator.noteChange();
	}

	forgetRoom(state: RoomState): void {
		if (this.rooms.get(state.key) !== state) return;
		this.rooms.delete(state.key);
		for (const invitation of state.invitations) retireInvitation(this.journal, invitation);
		state.invitations.clear();
		if (roomIsListed(state.policy)) {
			const publicKey = roomKey(state.name);
			const entry = this.publicRooms.get(publicKey);
			if (entry?.kind === "local" && entry.id === state.entryId) {
				this.publicRooms.delete(publicKey);
				this.#publicRoomsById.delete(entry.id);
			}
		}
		const rest = (this.#roomsPerOwnerSession.get(state.lifetimeOwner) ?? 1) - 1;
		if (rest > 0) this.#roomsPerOwnerSession.set(state.lifetimeOwner, rest);
		else this.#roomsPerOwnerSession.delete(state.lifetimeOwner);
		this.operator.noteChange();
	}

	#sessionOrigin(source: Session): Pick<ForeignRoomReservation, "origin" | "proof"> {
		const identity = source.partnerIdentity();
		if (durableIdentityAuthenticated(identity)) {
			return { origin: identity.designator, proof: "authenticated" };
		}
		return {
			origin: [...identity.sessionKey].map((byte) => byte.toString(16).padStart(2, "0")).join(""),
			proof: "session",
		};
	}

	reserveForeignRoom(name: string, source: Session): ForeignRoomReservation {
		const key = roomKey(name);
		if (this.#publicRoomKeyTaken(key)) throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
		if (this.#foreignRoomCount >= MAX_PEERED_ROOMS) {
			throw new RoomError(TOO_MANY_PEERED_ROOMS, `this directory already holds ${MAX_PEERED_ROOMS} peered rooms`);
		}
		let owned = this.#foreignRoomsBySource.get(source);
		if (owned !== undefined && owned.ids.size >= MAX_PEERED_ROOMS_PER_SOURCE) {
			throw new RoomError(
				TOO_MANY_PEERED_ROOMS,
				`this source already holds ${MAX_PEERED_ROOMS_PER_SOURCE} peered rooms here`,
			);
		}
		const reservation: ForeignRoomReservation = {
			id: this.#publicRoomId(),
			name,
			key,
			source,
			...(owned ?? this.#sessionOrigin(source)),
		};
		if (owned === undefined) {
			owned = { ids: new Set(), origin: reservation.origin, proof: reservation.proof };
			this.#foreignRoomsBySource.set(source, owned);
		}
		owned.ids.add(reservation.id);
		this.#foreignRoomReservationsById.set(reservation.id, reservation);
		this.#foreignRoomReservationByKey.set(key, reservation.id);
		this.#foreignRoomCount += 1;
		this.operator.noteChange();
		return reservation;
	}

	commitForeignRoom(reservation: ForeignRoomReservation, room: Ref): ForeignRoomEntry {
		if (this.#foreignRoomReservationsById.get(reservation.id) !== reservation) {
			throw new Error("room publication was revoked before its capability became ready");
		}
		this.#foreignRoomReservationsById.delete(reservation.id);
		if (this.#foreignRoomReservationByKey.get(reservation.key) === reservation.id) {
			this.#foreignRoomReservationByKey.delete(reservation.key);
		}
		const entry: ForeignRoomEntry = {
			kind: "foreign",
			id: reservation.id,
			name: reservation.name,
			room,
			source: reservation.source,
			origin: reservation.origin,
			proof: reservation.proof,
		};
		this.#publicRoomsById.set(entry.id, entry);
		this.publicRooms.set(reservation.key, entry);
		this.operator.noteChange();
		return entry;
	}

	#releaseForeignRoomSlot(source: Session, id: string): void {
		this.#foreignRoomCount -= 1;
		const owned = this.#foreignRoomsBySource.get(source);
		owned?.ids.delete(id);
		if (owned?.ids.size === 0) this.#foreignRoomsBySource.delete(source);
	}

	cancelForeignRoom(reservation: ForeignRoomReservation): boolean {
		if (this.#foreignRoomReservationsById.get(reservation.id) !== reservation) return false;
		this.#foreignRoomReservationsById.delete(reservation.id);
		if (this.#foreignRoomReservationByKey.get(reservation.key) === reservation.id) {
			this.#foreignRoomReservationByKey.delete(reservation.key);
		}
		this.#releaseForeignRoomSlot(reservation.source, reservation.id);
		this.operator.noteChange();
		return true;
	}

	forgetForeignRoom(id: string): ForeignRoomEntry | null {
		const found = this.#publicRoomsById.get(id);
		if (found?.kind !== "foreign") return null;
		const entry = found;
		this.#publicRoomsById.delete(id);
		const key = roomKey(entry.name);
		if (this.publicRooms.get(key)?.id === id) this.publicRooms.delete(key);
		this.#releaseForeignRoomSlot(entry.source, id);
		this.journal.release(entry.source, entry.room, "peered room");
		this.operator.noteChange();
		return entry;
	}

	forgetForeignRoomsFrom(source: Session): ForeignRoomEntry[] {
		const ids = [...this.#foreignRoomsBySource.get(source)?.ids ?? []];
		const removed: ForeignRoomEntry[] = [];
		for (const id of ids) {
			const reservation = this.#foreignRoomReservationsById.get(id);
			if (reservation !== undefined) {
				this.cancelForeignRoom(reservation);
				continue;
			}
			const entry = this.forgetForeignRoom(id);
			if (entry !== null) removed.push(entry);
		}
		return removed;
	}

	mintSignalExchangeId(): string {
		return `x${this.#nextSignalExchange++}`;
	}
}
