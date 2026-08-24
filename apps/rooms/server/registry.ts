// Room-server state, admission, indexing, and reclamation.

import { durableIdentityAuthenticated, type Ref, type Session } from "@pancake/runtime";
import { ROOM_EXISTS, RoomError, TOO_MANY_PEERED_ROOMS, TOO_MANY_ROOMS } from "../lib/errors.ts";
import {
	MAX_PEERED_ROOMS,
	MAX_PEERED_ROOMS_PER_SOURCE,
	MAX_ROOMS_PER_CREATOR,
	PRIVATE_ROOM_KEY_BYTES,
} from "../lib/limits.ts";
import type { RoomLinks } from "./state.ts";
import { noteTrouble } from "./journal.ts";

/** One subscriber: the nickname it chose and the capability to call it back on,
 * plus the connection that capability lives on (a far ref is sent over the
 * connection that holds it). */
export interface Member {
	nick: string;
	inbox: Ref;
	session: Session;
	/** The room's own hold on the references it answered this member's recent
	 * posts with, oldest first.
	 *
	 * Spawning one leaves the room holding a retain, so a member talking all day
	 * would leave the room holding one per line said until the connection went.
	 * Past `HELD_LINE_REFS` the oldest is handed back.
	 *
	 * Handing one back does not take the line away from the member: a released
	 * local capability stops being the room's to hold, while the member's own
	 * import keeps it alive and callable. That is the point rather than a
	 * caveat — the authority is the reference they hold, and the room could not
	 * revoke it by tidying its own bookkeeping even if it wanted to. */
	lines: Ref[];
	/** Why this member has stepped away, empty while they are here.
	 *
	 * Theirs to state rather than the room's to decide, so nothing is handed
	 * over for it: the room knows which membership is calling and writes the
	 * standing of that one. It lives on the membership because it is about a
	 * person being in a room, not about the connection, so leaving and coming
	 * back arrives present. */
	away: string;
	/** The room's own hold on the topic capability this membership was answered
	 * with. Superseded by a fresh one on every subscribe, so it is handed back
	 * whenever the membership record goes, silently or not. */
	topic: Ref;
}

/** How many line references one room keeps a hold of per member. Its own
 * bookkeeping only; see `Member.lines`. */
export const HELD_LINE_REFS = 100;

/** A live room: its display name (the casing the opener chose), its roster, and
 * the connection that opened it. The room owns its members and its broadcast;
 * the directory owns the set of rooms. A room lives while it has members; an
 * `open`ed room with no members yet is reclaimed if its opener disconnects
 * before subscribing. */
export interface RoomState {
	/** Opaque identity for this exact public-room generation. */
	entryId: string;
	name: string;
	/** What `rooms` is keyed by, which is also what makes a room private.
	 *
	 * A public room's key is its name folded, so the name is how you enter it and
	 * two rooms cannot share one. A private room's key is an unguessable id and
	 * its name is only a label: nothing looks a private room up by name, so two
	 * of them may be called the same thing, and the only way to reach one is to
	 * hold a reference somebody handed you. That is the whole of the privacy —
	 * there is no member list to be on and no check to pass. */
	key: string;
	/** Whether this room is private. Read where a room would otherwise be shown
	 * to somebody who does not hold it: the live list, its deltas, and links. */
	private: boolean;
	members: Member[];
	creator: Session;
	/** The files posted here, oldest first, and the bytes they add up to. The
	 * room hosts media so a picture outlives the tab that posted it; that
	 * makes storage the room's to bound, which is what `dropOldestFiles`
	 * enforces against `MAX_ROOM_ATTACHMENT_BYTES`. */
	files: PostedFile[];
	fileBytes: number;
	/** Uploads begun here and not yet posted, by the connection driving each.
	 * Nobody has seen these bytes, so an abandoned upload is pure cost and
	 * leaves with its connection. */
	uploads: Map<Session, Set<PendingUpload>>;
	/** Names the next line this room makes. Unique for as long as the room
	 * lives, which is as long as anything can refer to one: the room keeps no
	 * history, so an id means something only to the members who were here. */
	nextLine: number;
	/** What this room says it is about, empty until somebody sets it.
	 *
	 * Held by the room rather than by whoever set it, because it outlives them:
	 * a topic set by a member who then leaves is still what the room is about,
	 * and everyone arriving afterwards is told it. */
	topic: string;
}

export function makeRoomState(
	name: string,
	creator: Session,
	kept?: { private: boolean; key?: string },
): RoomState {
	const isPrivate = kept?.private === true;
	return {
		entryId: publicRoomId(),
		name,
		key: kept?.key ?? (isPrivate ? privateRoomKey() : roomKey(name)),
		private: isPrivate,
		members: [],
		creator,
		nextLine: 1,
		topic: "",
		files: [],
		fileBytes: 0,
		uploads: new Map(),
	};
}

/** One file the room holds. `bytes` is null once it has been dropped to stay
 * under a ceiling; the capability members hold stays valid and breaks
 * `blob-expired` on read, which a reader can tell from an empty file.
 *
 * `room` is here because eviction is server-wide: the oldest file anywhere is
 * the one that goes, and dropping it has to find the room whose byte count it
 * was part of. */
export interface PostedFile {
	room: RoomState;
	name: string;
	mime: string;
	size: number;
	width: number;
	height: number;
	bytes: Uint8Array | null;
	written: number;
	failure: string | null;
	waiters: Set<BlobWaiter>;
}

interface BlobWaiter {
	offset: number;
	maxLen: number;
	resolve: (chunk: Uint8Array) => void;
	reject: (reason: Error) => void;
}

/** One upload in flight: what was declared at `attach`, the bytes written so
 * far, and whether its `post` has spent it. */
export interface PendingUpload {
	size: number;
	file: PostedFile;
	posted: boolean;
	/** Whether this row is finished — posted-and-complete, or discarded. The
	 * explicit fact rather than the proxy `written === size`, which is born true
	 * at size 0: an empty file read as "spent" the instant it was staged, so it
	 * could not be discarded and rode the reader's next message. Set only by
	 * `finishUpload` and `dropUpload`. */
	spent: boolean;
	/** The capability `attach` answered with, so the room can give its own
	 * retain back when the upload is spent or abandoned. Null only between
	 * minting the row and spawning its object. */
	ref: Ref | null;
	/** Re-armed on every chunk. An upload holds a reservation against the size
	 * it declared, so one that goes quiet has to be reclaimed rather than
	 * waited on: see `UPLOAD_IDLE_MS`. */
	expires: ReturnType<typeof setTimeout> | null;
}

export const rooms = new Map<string, RoomState>();

export interface LocalRoomEntry {
	kind: "local";
	id: string;
	name: string;
	state: RoomState;
}

export interface ForeignRoomEntry {
	kind: "foreign";
	id: string;
	name: string;
	room: Ref;
	source: Session;
	origin: string;
	proof: "authenticated" | "session";
}

export interface ForeignRoomReservation {
	id: string;
	name: string;
	key: string;
	source: Session;
	origin: string;
	proof: "authenticated" | "session";
}

/** An IRC channel the gateway bridged into this directory: entered like any
 * room, drawn per session from the bridge's own machinery, and gone when the
 * operator parts it. `proof` says "bridge" so a list row states plainly that
 * presence here is the gateway's observation of another protocol. */
export interface BridgeRoomEntry {
	kind: "bridge";
	id: string;
	name: string;
	origin: string;
	proof: "bridge";
	bridge: { roomBehavior(session: Session): import("@pancake/runtime").Behavior };
}

export type PublicRoomEntry = LocalRoomEntry | ForeignRoomEntry | BridgeRoomEntry;

/** How many IRC channels one server bridges at most. */
export const MAX_BRIDGED_ROOMS = 16;
let bridgedRoomCount = 0;

/** File a bridged channel under the ordinary public namespace. */
export function registerBridgeRoom(
	name: string,
	origin: string,
	bridge: { roomBehavior(session: Session): import("@pancake/runtime").Behavior },
): BridgeRoomEntry {
	const key = roomKey(name);
	if (publicRoomKeyTaken(key)) throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
	if (bridgedRoomCount >= MAX_BRIDGED_ROOMS) {
		throw new RoomError(TOO_MANY_ROOMS, `this directory already bridges ${MAX_BRIDGED_ROOMS} channels`);
	}
	const entry: BridgeRoomEntry = { kind: "bridge", id: publicRoomId(), name, origin, proof: "bridge", bridge };
	publicRooms.set(key, entry);
	publicRoomsById.set(entry.id, entry);
	bridgedRoomCount += 1;
	return entry;
}

/** Drop a bridged channel from the namespace; the gateway owns the
 * connection this frees. */
export function forgetBridgeRoom(id: string): BridgeRoomEntry | null {
	const entry = publicRoomsById.get(id);
	if (entry === undefined || entry.kind !== "bridge") return null;
	publicRoomsById.delete(id);
	publicRooms.delete(roomKey(entry.name));
	bridgedRoomCount -= 1;
	return entry;
}

export function localRoomEntry(state: RoomState): LocalRoomEntry {
	return { kind: "local", id: state.entryId, name: state.name, state };
}

/** The one case-folded public namespace used by open, enter, list, and peering. */
export const publicRooms = new Map<string, PublicRoomEntry>();

const publicRoomsById = new Map<string, PublicRoomEntry>();
const foreignRoomReservationsById = new Map<string, ForeignRoomReservation>();
const foreignRoomReservationByKey = new Map<string, string>();
const foreignRoomIdsBySource = new Map<Session, Set<string>>();
let foreignRoomCount = 0;

function publicRoomId(): string {
	let id = crypto.randomUUID();
	while (publicRoomsById.has(id) || foreignRoomReservationsById.has(id)) id = crypto.randomUUID();
	return id;
}

function publicRoomKeyTaken(key: string): boolean {
	return publicRooms.has(key) || foreignRoomReservationByKey.has(key);
}

export function publicRoomNameTaken(name: string): boolean {
	return publicRoomKeyTaken(roomKey(name));
}

export function publicRoomById(id: string): PublicRoomEntry | null {
	return publicRoomsById.get(id) ?? null;
}

/** How many rooms each connection currently has open, so `open` can be bounded
 * per creator in O(1) rather than by scanning every room on the server. A row
 * lives exactly as long as one of the creator's rooms does. */
export const roomsPerCreator = new Map<Session, number>();

/** File a new room, and count it against its creator's ceiling. The one place
 * `rooms` gains a row is also the one that admits the memory: directory opens
 * and cold durable-link reconstruction cannot drift into different limits. */
export function registerRoom(state: RoomState): void {
	const held = roomsPerCreator.get(state.creator) ?? 0;
	if (held >= MAX_ROOMS_PER_CREATOR) {
		throw new RoomError(
			TOO_MANY_ROOMS,
			`this connection already has ${MAX_ROOMS_PER_CREATOR} rooms open`,
		);
	}
	if (!state.private && publicRoomKeyTaken(state.key)) {
		throw new RoomError(ROOM_EXISTS, `room "${state.name}" already exists`);
	}
	rooms.set(state.key, state);
	if (!state.private) {
		const entry = localRoomEntry(state);
		publicRooms.set(state.key, entry);
		publicRoomsById.set(entry.id, entry);
	}
	roomsPerCreator.set(state.creator, held + 1);
}

/** Drop a room and release its creator's count. The one place `rooms` loses a
 * row, so the count cannot drift from the map. */
export function forgetRoom(state: RoomState): void {
	if (rooms.get(state.key) !== state) return;
	rooms.delete(state.key);
	if (!state.private) {
		const entry = publicRooms.get(state.key);
		if (entry?.kind === "local" && entry.id === state.entryId) {
			publicRooms.delete(state.key);
			publicRoomsById.delete(entry.id);
		}
	}
	const rest = (roomsPerCreator.get(state.creator) ?? 1) - 1;
	if (rest > 0) roomsPerCreator.set(state.creator, rest);
	else roomsPerCreator.delete(state.creator);
}

function sessionOrigin(source: Session): Pick<ForeignRoomReservation, "origin" | "proof"> {
	const identity = source.partnerIdentity();
	if (durableIdentityAuthenticated(identity)) {
		return { origin: identity.designator, proof: "authenticated" };
	}
	return {
		origin: [...identity.sessionKey].map((byte) => byte.toString(16).padStart(2, "0")).join(""),
		proof: "session",
	};
}

/** Reserve one bounded publication generation before handoff resolution. */
export function reserveForeignRoom(name: string, source: Session): ForeignRoomReservation {
	const key = roomKey(name);
	if (publicRoomKeyTaken(key)) throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
	if (foreignRoomCount >= MAX_PEERED_ROOMS) {
		throw new RoomError(TOO_MANY_PEERED_ROOMS, `this directory already holds ${MAX_PEERED_ROOMS} peered rooms`);
	}
	let owned = foreignRoomIdsBySource.get(source);
	if (owned !== undefined && owned.size >= MAX_PEERED_ROOMS_PER_SOURCE) {
		throw new RoomError(
			TOO_MANY_PEERED_ROOMS,
			`this source already holds ${MAX_PEERED_ROOMS_PER_SOURCE} peered rooms here`,
		);
	}
	const reservation: ForeignRoomReservation = {
		id: publicRoomId(),
		name,
		key,
		source,
		...sessionOrigin(source),
	};
	if (owned === undefined) {
		owned = new Set();
		foreignRoomIdsBySource.set(source, owned);
	}
	owned.add(reservation.id);
	foreignRoomReservationsById.set(reservation.id, reservation);
	foreignRoomReservationByKey.set(key, reservation.id);
	foreignRoomCount += 1;
	return reservation;
}

/** Attach the resolved room capability to an exact live reservation. */
export function commitForeignRoom(reservation: ForeignRoomReservation, room: Ref): ForeignRoomEntry {
	if (foreignRoomReservationsById.get(reservation.id) !== reservation) {
		throw new Error("room publication was revoked before its capability became ready");
	}
	foreignRoomReservationsById.delete(reservation.id);
	if (foreignRoomReservationByKey.get(reservation.key) === reservation.id) {
		foreignRoomReservationByKey.delete(reservation.key);
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
	publicRoomsById.set(entry.id, entry);
	publicRooms.set(reservation.key, entry);
	return entry;
}

function releaseForeignRoomSlot(source: Session, id: string): void {
	foreignRoomCount -= 1;
	const owned = foreignRoomIdsBySource.get(source);
	owned?.delete(id);
	if (owned?.size === 0) foreignRoomIdsBySource.delete(source);
}

export function cancelForeignRoom(reservation: ForeignRoomReservation): boolean {
	if (foreignRoomReservationsById.get(reservation.id) !== reservation) return false;
	foreignRoomReservationsById.delete(reservation.id);
	if (foreignRoomReservationByKey.get(reservation.key) === reservation.id) {
		foreignRoomReservationByKey.delete(reservation.key);
	}
	releaseForeignRoomSlot(reservation.source, reservation.id);
	return true;
}

/** Remove one exact generation. A stale lease cannot remove its replacement. */
export function forgetForeignRoom(id: string): ForeignRoomEntry | null {
	const found = publicRoomsById.get(id);
	if (found?.kind !== "foreign") return null;
	const entry = found;
	publicRoomsById.delete(id);
	const key = roomKey(entry.name);
	if (publicRooms.get(key)?.id === id) publicRooms.delete(key);
	releaseForeignRoomSlot(entry.source, id);
	handBack(entry.source, entry.room, "peered room");
	return entry;
}

export function forgetForeignRoomsFrom(source: Session): ForeignRoomEntry[] {
	const ids = [...foreignRoomIdsBySource.get(source) ?? []];
	const removed: ForeignRoomEntry[] = [];
	for (const id of ids) {
		const reservation = foreignRoomReservationsById.get(id);
		if (reservation !== undefined) {
			cancelForeignRoom(reservation);
			continue;
		}
		const entry = forgetForeignRoom(id);
		if (entry !== null) removed.push(entry);
	}
	return removed;
}

/** One introducible member.
 *
 * `inboxes` is what `introduce` hands out: the capability this member offered for
 * each peer, keyed by that peer's nick, so a caller only ever gets the one minted
 * for them. `inbox` is the member's register inbox, where the directory asks for
 * an inbox it needs and tells a waiting caller one has arrived.
 *
 * The registered locator is not what a redeem dials. A member's own hello already
 * claims where it is reachable, and that claim is what the gifter relays when it
 * introduces this member, so the locator here is the member's advertised address
 * for the directory's own use: refusing a registration it cannot tie to the
 * caller, and routing `webrtc` signaling by designator. */
export interface Introduction {
	nick: string;
	inbox: Ref;
	inboxes: Map<string, Ref>;
	registrar: Session;
	/** The member's one WebRTC signaling inbox (`offerSignaling`), or null.
	 * The directory routes offers and candidates for the member's `webrtc`
	 * designator here; released with the introduction. */
	signaling: Ref | null;
	/** Vouchers minted by this registration's name capability and not yet
	 * redeemed, as hex. Single-use, bounded by `MAX_NAME_VOUCHERS`, and gone
	 * with the introduction — a voucher's life is the registration's. */
	vouchers: Set<string>;
}

/** Introducible members, by nick. */
export const introductions = new Map<string, Introduction>();

/** Members reachable at a `webrtc` locator, by that locator's designator. A
 * `signalOffer` names the designator (that is all a `webrtc` locator carries),
 * so this is the index that finds whose signaling inbox carries the exchange.
 * A row lives exactly as long as its registration. */
export const webrtcDesignators = new Map<string, string>();

/** One in-flight WebRTC signaling exchange: who started it (and the reply
 * capability their answer and candidates ride back on), and which member
 * answers it. Transient scratch for one channel bring-up, capped by
 * `MAX_SIGNAL_EXCHANGES` with oldest-first eviction. */
interface SignalExchange {
	originator: Session;
	reply: Ref;
	targetKey: string;
	expires: ReturnType<typeof setTimeout>;
}

export const signalExchanges = new Map<string, SignalExchange>();

let nextSignalExchange = 0;

/** Name the next signaling exchange. Minted here, beside the table it keys, so
 * the counter and the rows it names cannot come apart. */
export function mintSignalExchangeId(): string {
	return `x${nextSignalExchange++}`;
}

/** Give one offered inbox back to the member that offered it, so it can drop the
 * export. A release on a connection already gone throws and is ignored: its
 * imports went with it. Every site that stops holding an inbox comes through
 * here. */
/** Give one capability back on the session it lives on. The room does this for
 * everything it holds and no longer needs — an offered inbox, a signaling
 * reply, a posted file's blob — so the object retires when its last holder
 * lets go rather than being pinned by a retain nobody is using. */
export function handBack(session: Session, ref: Ref, what = "retained capability"): void {
	try {
		session.release(ref);
	} catch (error) {
		// Cleanup cannot replace the operation that made this reference unwanted,
		// but a refusal is still an exact process-owned diagnostic. Session release
		// is already wire-free after teardown, so a refusal here is never evidence
		// that teardown harmlessly reclaimed it.
		noteTrouble(`could not release ${what}`, error);
	}
}

/** The key a public room lives under. Room names are unique ignoring case, like
 * nicknames: the directory grants one room per name and frees it when the room
 * empties.
 *
 * Prefixed because `rooms` holds two kinds of key and a bare fold would let one
 * kind spell the other: a private room's key is `~` and sixteen bytes of hex,
 * and without the `#` here a reader could open a public room named exactly that
 * and be handed somebody's private one by name. Two namespaces in one table
 * have to be told apart by construction rather than by hoping the shapes never
 * meet. */
export function roomKey(name: string): string {
	return "#" + name.toLowerCase();
}

/** The key a private room lives under: unguessable, so the table a public room
 * is entered from cannot be searched for one.
 *
 * Sixteen bytes from the platform's own source. It is the same shape of secret
 * as a swissnum and is never shown to anybody: a member reaches a private room
 * through the reference they were handed, never through this. */
function privateRoomKey(): string {
	return "~" + hex(crypto.getRandomValues(new Uint8Array(PRIVATE_ROOM_KEY_BYTES)));
}

export function hex(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function nickKey(nick: string): string {
	return nick.toLowerCase();
}

export function findBySession(state: RoomState, session: Session): Member | null {
	return state.members.find((m) => m.session === session) ?? null;
}

export function claimedByAnother(
	state: RoomState,
	session: Session,
	nick: string,
): boolean {
	const key = nickKey(nick);
	return state.members.some((m) => m.session !== session && nickKey(m.nick) === key);
}

/** The durable-name registry this server was started with, or null when it
 * keeps no state and so mints no sturdyrefs.
 *
 * Held here rather than threaded through every room because a room is asked
 * for its own link by whoever holds it, and a room is reached from three
 * places: the directory's `open` and `enter`, and a link being redeemed. */
let roomLinks: RoomLinks | null = null;

/** Name the durable-room registry this server was started with, once.
 *
 * A room is asked for its own link by whoever holds it, and a room is reached
 * from three places, so the registry lives beside the tables rather than being
 * threaded through every one of them. */
export function useRoomLinks(links: RoomLinks | null): void {
	roomLinks = links;
}

/** The durable-name registry, or null when this server keeps no state and so
 * mints no sturdyrefs. */
export function heldRoomLinks(): RoomLinks | null {
	return roomLinks;
}
