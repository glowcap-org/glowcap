// Room-server types and small helpers: membership records, publication entry
// shapes, and the name/session folding those records share.
//
// Live tables live on `RoomLiveIndex`. This file names the rows, not the
// inventory that holds them.

import { type Ref, type Session } from "@glowcap/runtime";
import type { RoomPolicy } from "../lib/room/policy.ts";
import type { RoomMembershipKind } from "../lib/room/membership.ts";

/** One live invitation, and the membership whose say-so it carries.
 *
 * `session` is the minter rather than the claimant: an invitation is authority
 * somebody chose to hand out, and the room keeps that edge so it can take the
 * authority back when the choosing stops. */
export interface RoomInvitation {
	session: Session;
	ref: Ref | null;
	active: boolean;
}

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
	lines: Array<{ ref: Ref; session: Session }>;
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
	topic: Ref | null;
	/** The room's own hold on this live seat. */
	seat: Ref | null;
	kind: RoomMembershipKind;
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
	/** Stable runtime identity. Managed rooms use an opaque id independent of
	 * the public namespace; unmanaged public rooms use their folded name. */
	key: string;
	/** Discovery and admission are one explicit policy. */
	policy: RoomPolicy;
	members: Member[];
	/** Live invitations minted into this room, each holding the membership
	 * session that minted it so a departure can retire exactly its own. */
	invitations: Set<RoomInvitation>;
	lifetimeOwner: Session;
	/** The files posted here, oldest first, and the bytes they add up to. The
	 * room hosts media so a picture outlives the tab that posted it; that
	 * makes storage the room's to bound, which is what `dropOldestFiles`
	 * enforces against `MAX_ROOM_ATTACHMENT_BYTES`. */
	files: PostedFile[];
	fileBytes: number;
	/** Uploads begun here and not yet posted, by the connection driving each.
	 * Nobody has seen these bytes, so an abandoned upload is pure cost and
	 * leaves with its connection. */
	uploads: Map<Member, Set<PendingUpload>>;
	/** Names the next line this live room generation makes. Current members use
	 * it to match edit and withdrawal notifications. Retained history uses a
	 * process-local mutation token instead: this counter deliberately restarts
	 * with a new room generation. */
	nextLine: number;
	/** What this room says it is about, empty until somebody sets it.
	 *
	 * Held by the room rather than by whoever set it, because it outlives them:
	 * a topic set by a member who then leaves is still what the room is about,
	 * and everyone arriving afterwards is told it. */
	topic: string;
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
	/** The participant membership that admitted this upload. */
	member: Member;
	/** The session on which the room spawned and retained the upload object. */
	session: Session;
	/** Re-armed on every chunk. An upload holds a reservation against the size
	 * it declared, so one that goes quiet has to be reclaimed rather than
	 * waited on: see `UPLOAD_IDLE_MS`. */
	expires: ReturnType<typeof setTimeout> | null;
}

export function roomDurableIdentity(state: RoomState): string {
	return state.key;
}

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
	bridge: { roomBehavior(): import("@glowcap/runtime").Behavior };
}

export type PublicRoomEntry = LocalRoomEntry | ForeignRoomEntry | BridgeRoomEntry;

export function localRoomEntry(state: RoomState): LocalRoomEntry {
	return { kind: "local", id: state.entryId, name: state.name, state };
}

export interface PublicRoomNameReservation {
	readonly key: string;
	readonly token: symbol;
}

/** One introducible member.
 *
 * `inboxes` is what `introduce` hands out: the capability this member offered for
 * each peer, keyed by that peer's registration ID, so a later holder of the
 * same nick cannot inherit it. `inbox` is the member's register inbox, where the directory asks for
 * an inbox it needs and tells a waiting caller one has arrived.
 *
 * The registered locator is not what a redeem dials. A member's own hello already
 * claims where it is reachable, and that claim is what the gifter relays when it
 * introduces this member, so the locator here is the member's advertised address
 * for the directory's own use: refusing a registration it cannot tie to the
 * caller, and routing `webrtc` signaling by designator. */
export interface Introduction {
	nick: string;
	/** Opaque identity of this exact live nickname registration. */
	registrationId: string;
	inbox: Ref;
	inboxes: Map<string, Ref>;
	/** Last reciprocal-route request notice per registered peer inside the
	 * bounded coalescing window. Expired rows are removed on later admission. */
	directRequests: Map<string, number>;
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

/** Printable identity for connection-scoped origin evidence. */
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
