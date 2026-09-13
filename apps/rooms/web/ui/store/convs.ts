// Conversations this tab holds: rooms, direct lines, and the keys that name them.
//
// A room's identity is its directory and its name; a direct line's is the
// introduction that opened it. The page reaches these through `store.ts`.

import type { Conv, ConvBase, DirectoryConv, DirId, DirView, DmConv, DmLine, RoomConv, SessionConv } from "../types.ts";
import type { WorkspaceRoomBridgeIntent } from "../../../lib/rooms_state.ts";
import { openRoomPolicy, privateRoomPolicy, roomPoliciesEqual, type RoomPolicy, roomPreset } from "../room_policy.ts";
import type { RoomMembershipKind } from "../../../lib/room/membership.ts";
import type { PageProjection, State } from "./core.ts";
import { isSelf } from "./dirs.ts";
import { roomAuthorityToken as authorityToken } from "../application.ts";

// ── Conversations ─────────────────────────────────────────────────────────
/** A room's key is its directory and its name together, because a room name only
 * means anything inside the directory that granted it. Two clients naming one
 * room on one directory mean one room; the same name on another directory is
 * somewhere else entirely.
 *
 * A direct line's key is minted per introduction and never derived from a name,
 * which is why only rooms have a key function. It carries its directory in a
 * field instead, for the same reason: the nickname it reaches is that
 * directory's to grant.
 *
 * The two halves are joined by a NUL, and it is written as an escape and never
 * as a raw byte. A locator may hold any character a URI may and a room name may
 * hold a space, so a separator drawn from that alphabet lets one pair spell
 * another pair's key; the typing timers join their two halves the same way and
 * for the same reason. A raw NUL in the source would make the file binary, and
 * every text tool then skips it without saying so. */
export function roomKey(dir: DirId, name: string): string {
	return "room:" + dir + "\u0000" + name.toLowerCase();
}

export function publishedRoomKey(dir: DirId, publicationId: string): string {
	return "room-publication:" + dir + "\u0000" + publicationId;
}

/** One view per held directory. Recreated when shown; never a workspace row. */
function directoryKey(dir: DirId): string {
	return "directory:" + dir;
}

/** The conversation a leave or close should stand on next: a room or a
 * direct line, never a directory view. Those views are this tab's, not a
 * place a room was sitting in front of. */
export function nextStandingKey(convs: ReadonlyMap<string, Conv>): string | undefined {
	for (const conv of convs.values()) {
		if (conv.type !== "directory") return conv.key;
	}
	return undefined;
}

// Introductions this tab has opened are counted on the page projection. A
// direct conversation is keyed on the introduction rather than on the member's
// nick, which is the whole of the fix for a thread that used to change hands:
// the nick is a claim the room grants and reclaims, so keying a conversation
// on it meant that when the claim moved, the next message in a thread — same
// title, same history — was redeemed to whoever held the name now.

export function getConv(
	projection: PageProjection,
	key: string | null,
	s: Readonly<Pick<State, "convs">> = projection.get(),
): Conv | null {
	return key === null ? null : s.convs.get(key) ?? null;
}

/** The listed room this tab already holds for `dir` and `name`.
 *
 * A caller with a conversation key names that row. Without one, a name-key and a
 * publication-key are two spellings of the same listed room; preferring the
 * publication identity keeps a bridge from becoming a second join. Private rooms
 * are not found by label: two of them may share one, and only the key tells
 * them apart. */
export function existingRoom(
	projection: PageProjection,
	dir: DirId,
	name: string,
	at?: string,
): RoomConv | null {
	if (at != null) {
		const conv = getConv(projection, at);
		if (conv?.type === "room") return conv;
	}
	const want = name.toLowerCase();
	let found: RoomConv | null = null;
	for (const conv of projection.get().convs.values()) {
		if (conv.type !== "room" || conv.dir !== dir || conv.held || conv.id.toLowerCase() !== want) continue;
		if (found == null || conv.publicationId != null) found = conv;
	}
	return found;
}

/** The conversation whose durable id is `persistId`, or null. Session commands
 * and snapshots name conversations this way; this tab's map is keyed on `key`. */
export function convByPersistId(
	projection: PageProjection,
	persistId: string,
	s: Readonly<Pick<State, "convs">> = projection.get(),
): SessionConv | null {
	for (const conversation of s.convs.values()) {
		if (conversation.type !== "directory" && conversation.persistId === persistId) return conversation;
	}
	return null;
}

export function activeConv(projection: PageProjection): Conv | null {
	return getConv(projection, projection.get().activeKey);
}

/** The directory a reader means by "here": the one the open conversation is on,
 * or the first this tab holds while the join card is up. */
export function directoryHere(conv: Conv | null, dirs: ReadonlyMap<DirId, DirView>): DirView | null {
	if (conv != null) {
		const directory = dirs.get(conv.dir);
		if (directory != null) return directory;
	}
	for (const directory of dirs.values()) return directory;
	return null;
}

export function actingDir(
	projection: PageProjection,
	s: Readonly<Pick<State, "activeKey" | "convs" | "dirs">> = projection.get(),
): DirView | null {
	return directoryHere(s.activeKey === null ? null : s.convs.get(s.activeKey) ?? null, s.dirs);
}

/** Whether any directory has answered at all. The opening screen covers this
 * wait, not one directory's health. */
export function anyDirSettled(
	projection: PageProjection,
	s: Readonly<Pick<State, "dirs">> = projection.get(),
): boolean {
	for (const held of s.dirs.values()) {
		if (held.session !== "connecting") return true;
	}
	return false;
}

/** Replace the fields both kinds of conversation share, keeping the kind's own.
 *
 * The generic is what keeps a room's patch off a direct line, which is the whole
 * reason `Conv` is a union: spreading it directly loses the discriminant, and the
 * four call sites below each used to cast that enforcement away. */
export function patch<C extends Conv>(conv: C, fields: Partial<ConvBase>): C {
	return Object.assign({}, conv, fields);
}

/** Put a conversation into the map, replacing whatever was there.
 *
 * Whether a room is held is what its policy says, so it is settled here rather
 * than by whoever wrote the room. The two were set together when the room was
 * first seen and only the policy moved afterwards, which left every surface
 * reading `held` — the rail's mark, the topbar, the card, the log, the
 * composer's addressee — drawing the standing the room arrived with. Two
 * writers already move the policy and only one of them would have remembered;
 * every writer comes through here. */
export function put(projection: PageProjection, conv: Conv): void {
	const settled = conv.type === "room" && conv.held !== (roomPreset(conv.policy) === "private")
		? { ...conv, held: !conv.held }
		: conv;
	const convs = new Map(projection.get().convs);
	convs.set(settled.key, settled);
	projection.set({ convs });
}

interface RoomIdentity {
	key?: string;
	persistId?: string;
	publicationId?: string;
	held?: boolean;
	/** The room entry link, manager, and moderator this session holds for the
	 * room, as the Rust checkpoint carries them. These are bearer strings on
	 * the way in and tokens once stored (`RoomConv.linkToken` and siblings):
	 * the verb keeps the identity and lets the string go. */
	link?: string;
	manager?: string;
	steward?: string;
	reconnect?: "manual" | "requested";
	membership?: RoomConv["membership"];
	bridgeIntent?: WorkspaceRoomBridgeIntent | null;
	policy?: RoomPolicy;
	membershipKind?: RoomMembershipKind;
}

interface DirectIdentity {
	persistId?: string;
	peerRegistrationId: string;
}

/** Stable local archive identity for one exact directory registration. A
 * deliberate close removes the visible row, but reopening the same live member
 * must query the history it just kept. A new holder receives a new registration
 * id and therefore cannot inherit that record. */
function directPersistId(dir: DirId, peerRegistrationId: string): string {
	return `direct:${dir}:${peerRegistrationId}`;
}

function makeConv(projection: PageProjection, type: "room", dir: DirId, id: string, identity?: RoomIdentity): RoomConv;
function makeConv(projection: PageProjection, type: "dm", dir: DirId, id: string, identity: DirectIdentity): DmConv;
function makeConv(
	projection: PageProjection,
	type: "room" | "dm",
	dir: DirId,
	id: string,
	identity?: RoomIdentity | DirectIdentity,
): Conv {
	const roomIdentity = type === "room" ? identity as RoomIdentity | undefined : undefined;
	const directIdentity = type === "dm" ? identity as DirectIdentity : null;
	const key = type === "room"
		? roomIdentity?.key ??
			(roomIdentity?.publicationId == null ? roomKey(dir, id) : publishedRoomKey(dir, roomIdentity.publicationId))
		: "dm:" + projection.nextIntroduction();
	const base = {
		id,
		key,
		dir,
		persistId: identity?.persistId ??
			(type === "dm" ? directPersistId(dir, directIdentity!.peerRegistrationId) : crypto.randomUUID()),
	};
	// Build only the fields the kind owns, so the union stays honest: a room gets
	// its membership and a direct line gets its standing.
	const conv: Conv = type === "room"
		? {
			...base,
			type,
			membership: roomIdentity?.membership ?? "joining",
			membershipIssue: "",
			earlierHistory: "unasked",
			grants: new Set(),
			membershipKind: roomIdentity?.membershipKind ?? "participant",
			policy: roomIdentity?.policy ?? (roomIdentity?.held === true ? privateRoomPolicy() : openRoomPolicy()),
			standing: null,
			bridgeIssue: "",
			held: roomIdentity?.held === true,
			...(roomIdentity?.reconnect == null ? {} : { reconnect: roomIdentity.reconnect }),
			...(roomIdentity?.publicationId != null ? { publicationId: roomIdentity.publicationId } : {}),
			...(roomIdentity?.link == null ? {} : { linkToken: authorityToken(roomIdentity.link) }),
			...(roomIdentity?.manager == null ? {} : { managerToken: authorityToken(roomIdentity.manager) }),
			...(roomIdentity?.steward == null ? {} : { stewardToken: authorityToken(roomIdentity.steward) }),
			...(roomIdentity != null && Object.hasOwn(roomIdentity, "bridgeIntent")
				? { bridgeIntent: roomIdentity.bridgeIntent }
				: {}),
		}
		: {
			...base,
			type,
			peerRegistrationId: directIdentity!.peerRegistrationId,
			line: "introducing",
		};
	put(projection, conv);
	return conv;
}

/** The row a room identity already names in this tab, whichever key it wears.
 * A row's key is minted when the room is first seen and never changes, so a
 * publication id resolved later must find the row a link-era join filed under
 * its name. The checkpoint's persistId outranks everything; a publication id
 * then adopts the same-named row that claims no other publication. A row
 * claiming a different publication is a different room, never adopted. */
function adoptableRoomConv(
	projection: PageProjection,
	dir: DirId,
	name: string,
	identity: RoomIdentity | undefined,
): RoomConv | null {
	const rooms = [...projection.get().convs.values()].filter(
		(conv): conv is RoomConv => conv.type === "room" && conv.dir === dir,
	);
	if (identity?.persistId != null) {
		const byPersist = rooms.find((conv) => conv.persistId === identity.persistId);
		if (byPersist != null) return byPersist;
	}
	const lowered = name.toLowerCase();
	if (identity?.publicationId != null) {
		return rooms.find((conv) =>
			!conv.held && conv.id.toLowerCase() === lowered &&
			(conv.publicationId == null || conv.publicationId === identity.publicationId)
		) ?? null;
	}
	// A name-only identity adopts the one same-named public row whatever
	// publication it recorded, because the checkpoint keeps one public row per
	// name. Two candidates are a genuine collision left apart.
	const named = rooms.filter((conv) => !conv.held && conv.id.toLowerCase() === lowered);
	return named.length === 1 ? named[0] : null;
}

/** The key the room named by `identity` wears, or would wear if made now.
 * Callers that seat live state under a computed key resolve here first, so a
 * publication-bearing join lands on the row a link-era join already minted. */
export function resolveRoomKey(
	projection: PageProjection,
	dir: DirId,
	name: string,
	publicationId?: string,
): string {
	return adoptableRoomConv(projection, dir, name, { publicationId })?.key ??
		(publicationId == null ? roomKey(dir, name) : publishedRoomKey(dir, publicationId));
}

/** The conversation for a room, made if this tab has none.
 *
 * `key` is given for a room reached by a reference rather than by name: a
 * private room's label is not unique, so `heldRoomKey` mints its identity the
 * way an introduction mints a direct line's. */
export function ensureRoom(projection: PageProjection, dir: DirId, name: string, identity?: RoomIdentity): RoomConv {
	const key = identity?.key ??
		(identity?.publicationId === undefined ? roomKey(dir, name) : publishedRoomKey(dir, identity.publicationId));
	const existing = getConv(projection, key) ??
		(identity?.key == null ? adoptableRoomConv(projection, dir, name, identity) : null);
	if (existing && existing.type === "room") {
		const linkToken = identity?.link == null ? undefined : authorityToken(identity.link);
		const managerToken = identity?.manager == null ? undefined : authorityToken(identity.manager);
		const stewardToken = identity?.steward == null ? undefined : authorityToken(identity.steward);
		const linkChanged = identity?.link !== undefined && existing.linkToken !== linkToken;
		const stewardChanged = stewardToken != null && existing.stewardToken !== stewardToken;
		const managerChanged = managerToken != null && existing.managerToken !== managerToken;
		const reconnectChanged = identity?.reconnect !== undefined && existing.reconnect !== identity.reconnect;
		const membershipKindChanged = identity?.membershipKind != null &&
			existing.membershipKind !== identity.membershipKind;
		const policyChanged = identity?.policy != null && !roomPoliciesEqual(existing.policy, identity.policy);
		const publicationChanged = identity?.publicationId != null &&
			existing.publicationId !== identity.publicationId;
		const intentSpecified = identity != null && Object.hasOwn(identity, "bridgeIntent");
		const intentChanged = intentSpecified &&
			JSON.stringify(existing.bridgeIntent) !== JSON.stringify(identity?.bridgeIntent);
		if (
			linkChanged || managerChanged || stewardChanged || reconnectChanged || membershipKindChanged ||
			policyChanged || publicationChanged ||
			intentChanged
		) {
			// Authorities are only ever added or replaced here; dropping one is a
			// retirement with a verb of its own in `rooms.ts`.
			const next = {
				...existing,
				...(linkToken == null ? {} : { linkToken }),
				...(managerToken == null ? {} : { managerToken }),
				...(stewardToken == null ? {} : { stewardToken }),
				...(identity?.reconnect === undefined ? {} : { reconnect: identity.reconnect }),
				...(identity?.membershipKind == null ? {} : { membershipKind: identity.membershipKind }),
				...(identity?.policy == null ? {} : { policy: identity.policy }),
				...(identity?.publicationId == null ? {} : { publicationId: identity.publicationId }),
				...(intentSpecified ? { bridgeIntent: identity?.bridgeIntent } : {}),
			};
			put(projection, next);
			return next;
		}
		return existing;
	}
	return makeConv(projection, "room", dir, name, identity);
}

/** The conversation for a held directory, made if this tab has none.
 *
 * It is this tab's view of the directory, not a room and not a checkpoint row.
 * Showing it again reuses the same key; leaving the directory forgets it. */
export function ensureDirectory(projection: PageProjection, dir: DirId): DirectoryConv {
	const key = directoryKey(dir);
	const existing = getConv(projection, key);
	if (existing?.type === "directory") return existing;
	const conv: DirectoryConv = { type: "directory", id: dir, key, dir };
	put(projection, conv);
	return conv;
}

/** Every room this tab is in, in the order it entered them, across every
 * directory or on one of them.
 *
 * A `Map` preserves insertion order, so this needs no timestamp on a
 * conversation to answer "the room I joined first." A reconnect replays that
 * room, and the foot names it when there is only one. */
export function joinedRooms(projection: PageProjection, dir?: DirId): RoomConv[] {
	return [...projection.get().convs.values()].filter((conv): conv is RoomConv =>
		conv.type === "room" && (dir === undefined || conv.dir === dir)
	);
}

/** The directories this tab holds with nothing open on them.
 *
 * Holding one is a live session and a name registered on it, so a directory with
 * no rooms and no direct lines is not nothing: it is a connection the reader is
 * paying for and a name somebody else cannot take, with no row anywhere saying
 * so. That state is easy to reach — leave the last room on a server — and used
 * to be invisible, which also made every *other* row wear a directory caption to
 * tell it apart from rooms on a directory that was not on screen at all.
 *
 * Never this page's own. It has no rooms before the first join either, and a row
 * saying so at the moment the join card is asking for one is noise. */
export function emptyDirs(
	s: Readonly<Pick<State, "convs" | "dirs" | "homeDir">>,
): DirView[] {
	const busy = new Set<DirId>();
	for (const conv of s.convs.values()) {
		if (conv.type === "directory") continue;
		busy.add(conv.dir);
	}
	return [...s.dirs.values()].filter((dir) => dir.id !== s.homeDir && !busy.has(dir.id));
}

/** Every conversation of either kind that the named directory's teardown has
 * to account for. */
export function convsOn(projection: PageProjection, dir: DirId): Conv[] {
	return [...projection.get().convs.values()].filter((conv) => conv.dir === dir);
}

/** The open conversation with `peer`, if there is one.
 *
 * A conversation whose member has gone is not open. The room frees a nick when
 * its holder leaves and will grant it to the next person who asks, and this side
 * has no way to tell one holder from the next — so a fresh introduction opens a
 * fresh conversation rather than continuing one that would now reach someone
 * else. Two conversations may therefore carry the same name, which is honest:
 * they are with two different people. */
export function liveDmWith(
	projection: PageProjection,
	dir: DirId,
	peer: string,
	peerRegistrationId: string,
): DmConv | null {
	const want = peer.toLowerCase();
	for (const conv of projection.get().convs.values()) {
		if (
			conv.type === "dm" && conv.dir === dir && conv.line !== "closed" &&
			conv.id.toLowerCase() === want && conv.peerRegistrationId === peerRegistrationId
		) {
			return conv;
		}
	}
	return null;
}
/** The conversation with `peer`, made if this tab has none — or `null` when
 * `peer` is this tab. A line to yourself is not a conversation, so the mint
 * refuses rather than leaving every caller to remember. */
export function ensureDm(
	projection: PageProjection,
	dir: DirId,
	peer: string,
	peerRegistrationId: string,
): DmConv | null {
	if (isSelf(projection, dir, peer)) return null;
	return liveDmWith(projection, dir, peer, peerRegistrationId) ??
		makeConv(projection, "dm", dir, peer, { peerRegistrationId });
}

/** Rebuild one direct-conversation record without claiming its old live
 * introduction survived. A fresh send requires the same registration ID;
 * a later holder of the displayed nickname receives a new conversation. */
export function restoreDm(
	projection: PageProjection,
	dir: DirId,
	peer: string,
	peerRegistrationId: string,
	persistId: string,
	closed: boolean,
): DmConv | null {
	if (isSelf(projection, dir, peer)) return null;
	const conv = makeConv(projection, "dm", dir, peer, { persistId, peerRegistrationId });
	if (!closed) return conv;
	const closedConv = { ...conv, line: "closed" as const };
	put(projection, closedConv);
	return closedConv;
}

/** Close every open conversation with `peer` — the member has left, so the name
 * is back in the room's hands. Returns the keys closed, for the caller to drop
 * whatever it was holding for them. */
export function closeDmsWith(
	projection: PageProjection,
	dir: DirId,
	peer: string,
	peerRegistrationId: string,
): string[] {
	const closed: string[] = [];
	const convs = new Map(projection.get().convs);
	for (const conv of convs.values()) {
		if (
			conv.type === "dm" && conv.dir === dir && conv.line !== "closed" &&
			conv.id.toLowerCase() === peer.toLowerCase() && conv.peerRegistrationId === peerRegistrationId
		) {
			convs.set(conv.key, { ...conv, line: "closed" });
			closed.push(conv.key);
		}
	}
	if (closed.length > 0) projection.set({ convs });
	return closed;
}

/** Drop a conversation. If it was the one on screen, nothing is on screen now:
 * the caller chooses where to go next, but it cannot leave `activeKey` naming a
 * conversation that no longer exists.
 *
 * Its lines go the way every other line goes, through the release seam, and
 * they go before the row does: the seam finds the session by asking this store
 * which directory the conversation was on, so a conversation deleted first is
 * one whose lines can no longer be given back. Both callers used to hand their
 * history over themselves, immediately before calling this. That worked and
 * was one caller away from not working, which is the same shape as any
 * invariant kept by everybody remembering rather than by the seam that owns
 * it. */
export function forgetConv(projection: PageProjection, key: string): void {
	const state = projection.get();
	projection.letLinesGo(key, state.histories.get(key) ?? []);
	const convs = new Map(state.convs);
	convs.delete(key);
	// The draft goes with it. What was half-written to a room is addressed to
	// that room, so it cannot outlive it — and its attachments are open file
	// handles this tab would otherwise hold for a conversation that is gone.
	const drafts = new Map(state.drafts);
	drafts.delete(key);
	const lastSent = new Map(state.lastSent);
	lastSent.delete(key);
	const typers = new Map(state.typers);
	typers.delete(key);
	const members = new Map(state.members);
	members.delete(key);
	const histories = new Map(state.histories);
	histories.delete(key);
	const unreads = new Map(state.unreads);
	unreads.delete(key);
	const gone = { convs, drafts, lastSent, typers, members, histories, unreads };
	if (state.activeKey === key) {
		projection.set({ ...gone, activeKey: null, aboutConv: false, aboutConvLeave: false });
	} else projection.set(gone);
}

/** Mark every direct conversation as no longer live after their shared
 * directory session drops. */
export function unreadyDms(projection: PageProjection): void {
	const convs = new Map(projection.get().convs);
	let changed = false;
	for (const conv of convs.values()) {
		if (conv.type === "dm" && conv.line === "live") {
			convs.set(conv.key, { ...conv, line: "introducing" });
			changed = true;
		}
	}
	if (changed) projection.set({ convs });
}

/** Move a direct line between introducing and live. A closed one stays closed:
 * the room has the nick back, so nothing arriving under it belongs to this
 * conversation. */
export function setDmLine(projection: PageProjection, key: string, line: Exclude<DmLine, "closed">): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "dm" || conv.line === "closed" || conv.line === line) return;
	put(projection, { ...conv, line });
}
