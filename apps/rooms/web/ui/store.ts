// What the page shows, and the verbs that change it.
//
// Everything the interface draws is a field here and everything that changes one
// is a verb here, so the interface stays a function of this and nothing keeps a
// second copy of the truth. The state itself, the page's chrome, conversations,
// lines, and directories live in `store/`. This file is who is in a room, where
// this reader stands, and what they have been offered.

import type { BridgeFacts, DirId, Invitation, RoomCarries, RoomConv } from "./types.ts";
import { NO_MEMBERS, NO_TYPERS, type PageProjection, type State } from "./store/core.ts";
import type { RoomMemberState } from "../../lib/room/presence.ts";
import { isSubjectEmpty, type Subject } from "../../lib/room/subject.ts";
import { getConv, put } from "./store/convs.ts";
import { patchDir } from "./store/dirs.ts";

// Reached through one name, as it always was: splitting where the code lives is
// not a change to what a caller may ask for.
export * from "./store/core.ts";
export * from "./store/chrome.ts";
export * from "./store/archive.ts";
export * from "./store/convs.ts";
export * from "./store/rooms.ts";
export * from "./store/items.ts";
export * from "./store/sent_lines.ts";
export * from "./store/dirs.ts";
export * from "./store/reaching.ts";
export * from "./store/trouble.ts";

// ── Room membership and typing ────────────────────────────────────────────

/** What a room says it is about. The empty subject takes it down, so the room
 * holds no subject afterward. */
export function setSubject(projection: PageProjection, key: string, subject: Subject): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	const next = isSubjectEmpty(subject) ? undefined : subject;
	if (subjectsEqual(conv.subject, next)) return;
	const { subject: _subject, ...base } = conv;
	put(projection, next === undefined ? base : { ...base, subject: next });
}

function subjectsEqual(a: Subject | undefined, b: Subject | undefined): boolean {
	return a?.description === b?.description && a?.link === b?.link;
}

/** What a room will carry in one line, in bytes. See `lineBytes`. */
export function setLineBytes(projection: PageProjection, key: string, lineBytes: number): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.lineBytes === lineBytes) return;
	put(projection, { ...conv, lineBytes });
}

/** Every field of a room's bridge facts, exhaustively. A field the comparison
 * below does not know is a bridge whose change never reaches the roster, so
 * listing them as a `Record` over the schema's own keys makes forgetting one a
 * build error. `SEAT_FIELD_SET` guards a seat the same way. */
const BRIDGE_FIELD_SET: Record<keyof BridgeFacts, true> = {
	prefix: true,
	badge: true,
	said: true,
	scope: true,
};
const BRIDGE_FIELDS = Object.keys(BRIDGE_FIELD_SET) as readonly (keyof BridgeFacts)[];

/** Whether two statements of a room's bridge say the same thing.
 *
 * Compared field by field rather than by reference, because the fact arrives on
 * a fresh object every time a room repeats it and an identity check would
 * rewrite the conversation on every welcome. Both a line stating the fact and a
 * snapshot carrying it ask this, so they cannot disagree about what changed. */
function bridgeFactsEqual(left: BridgeFacts | undefined, right: BridgeFacts | undefined): boolean {
	return BRIDGE_FIELDS.every((field) => left?.[field] === right?.[field]);
}

/** What the bridge behind a room calls its own, as a line stated it. See
 * `readBridge`. */
export function setBridgeFacts(projection: PageProjection, key: string, bridge: BridgeFacts): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	if (bridgeFactsEqual(conv.bridge, bridge)) return;
	put(projection, { ...conv, bridge });
}

/** Every field of what a room carries, exhaustively, for the same reason
 * `BRIDGE_FIELD_SET` lists a bridge's: a field the comparison does not know
 * is a change the composer never hears about. */
const CARRIES_FIELD_SET: Record<keyof RoomCarries, true> = {
	previews: true,
	typing: true,
};
const CARRIES_FIELDS = Object.keys(CARRIES_FIELD_SET) as readonly (keyof RoomCarries)[];

function carriesEqual(left: RoomCarries | undefined, right: RoomCarries | undefined): boolean {
	return (left === undefined) === (right === undefined) &&
		CARRIES_FIELDS.every((field) => left?.[field] === right?.[field]);
}

/** What a room keeps or relays of a message, as a line stated it. See
 * `readCarries`. */
export function setCarries(projection: PageProjection, key: string, carries: RoomCarries): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	if (carriesEqual(conv.carries, carries)) return;
	put(projection, { ...conv, carries });
}

/** Every field of a seat, exhaustively.
 *
 * The comparison below decides whether a roster re-renders, so a field it does
 * not know is a member whose row silently stops updating. Listing them as a
 * `Record` over the seat's own keys makes that a build error rather than a
 * stale badge: adding one to the schema and not here will not compile. */
type SeatField = keyof NonNullable<RoomMemberState["seat"]>;
const SEAT_FIELD_SET: Record<SeatField, true> = {
	network: true,
	state: true,
	nick: true,
	badge: true,
	said: true,
};
const SEAT_FIELDS = Object.keys(SEAT_FIELD_SET) as readonly SeatField[];

/** One attached room's complete live view, as a session snapshot states it.
 *
 * Every field is required, and that is the point rather than strictness for its
 * own sake. This shape is the whole of what an attached reader rebuilds a room
 * from after a reload, so a field that may be left out is a field a snapshot
 * can quietly stop carrying. That is how bridge facts went missing here, and
 * left a bridged room's foreign members drawn under bare row keys. Adding a
 * field breaks every caller until each one says what it means to send. */
export interface RoomViewUpdate {
	members: readonly [string, RoomMemberState][];
	subject: Subject | null;
	lineBytes: number | null;
	bridge: BridgeFacts | null;
	/** What the room stated it carries, or null while it has not said. */
	carries: RoomCarries | null;
	canSetSubject: boolean;
	/** Whether this membership holds the files facet: the `files` grant. */
	canPostFiles: boolean;
	canModerate: boolean;
}

/** Replace one attached room's complete live view from a session snapshot. */
export function setRoomView(projection: PageProjection, key: string, view: RoomViewUpdate): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	const grants = new Set([
		...(view.canSetSubject ? ["subject"] : []),
		...(view.canPostFiles ? ["files"] : []),
		...(view.canModerate ? ["steward"] : []),
	]);
	const nextSubject = view.subject == null || isSubjectEmpty(view.subject) ? undefined : view.subject;
	const nextLineBytes = view.lineBytes == null ? undefined : view.lineBytes;
	const nextBridge = view.bridge ?? undefined;
	const nextCarries = view.carries ?? undefined;
	const viewChanged = !setsEqual(conv.grants, grants) || !subjectsEqual(conv.subject, nextSubject) ||
		conv.lineBytes !== nextLineBytes || !bridgeFactsEqual(conv.bridge, nextBridge) ||
		!carriesEqual(conv.carries, nextCarries);
	const roster = new Map(view.members);
	const rosterChanged = !rosterEquals(membersOf(projection, key), roster);
	if (!viewChanged && !rosterChanged) return;
	const next: Partial<Pick<State, "convs" | "members">> = {};
	if (viewChanged) {
		const convs = new Map(projection.get().convs);
		// Each optional field is stripped before the spread puts it back, so a
		// view that stops carrying one clears it rather than leaving the previous
		// snapshot's value standing.
		const { subject: _subject, lineBytes: _lineBytes, bridge: _bridge, carries: _carries, ...base } = conv;
		convs.set(key, {
			...base,
			grants,
			...(nextSubject == null ? {} : { subject: nextSubject }),
			...(nextLineBytes == null ? {} : { lineBytes: nextLineBytes }),
			...(nextBridge == null ? {} : { bridge: nextBridge }),
			...(nextCarries == null ? {} : { carries: nextCarries }),
		});
		next.convs = convs;
	}
	if (rosterChanged) {
		const held = new Map(projection.get().members);
		if (roster.size === 0) held.delete(key);
		else held.set(key, roster);
		next.members = held;
	}
	projection.set(next);
}

function setsEqual(left: ReadonlySet<string>, right: ReadonlySet<string>): boolean {
	if (left.size !== right.size) return false;
	for (const value of right) if (!left.has(value)) return false;
	return true;
}

function rosterEquals(
	left: ReadonlyMap<string, RoomMemberState>,
	right: ReadonlyMap<string, RoomMemberState>,
): boolean {
	if (left.size !== right.size) return false;
	for (const [name, standing] of right) {
		const was = left.get(name);
		if (was == null || was.online !== standing.online || was.away !== standing.away) return false;
		if ((was.seat == null) !== (standing.seat == null)) return false;
		if (was.seat != null && standing.seat != null) {
			for (const field of SEAT_FIELDS) {
				if (was.seat[field] !== standing.seat[field]) return false;
			}
		}
	}
	return true;
}

/** Whose lines this window does not show.
 *
 * Kept in this window rather than told to the room, which is the right shape:
 * ignoring somebody is a decision about what you read, and a room that was told
 * would be a room that could be asked. Names are held folded, since a directory
 * grants them case-insensitively.
 *
 * Persisted, because an ignore that forgot itself on reload would have to be
 * made again every morning by exactly the person who least wants to think about
 * whoever it names. */
export function ignore(projection: PageProjection, name: string): void {
	const folded = name.toLowerCase();
	const state = projection.get();
	if (state.ignored.has(folded)) return;
	const ignored = new Set(state.ignored);
	ignored.add(folded);
	projection.set({ ignored });
}

export function unignore(projection: PageProjection, name: string): boolean {
	const folded = name.toLowerCase();
	const state = projection.get();
	if (!state.ignored.has(folded)) return false;
	const ignored = new Set(state.ignored);
	ignored.delete(folded);
	projection.set({ ignored });
	return true;
}

/** Remember what this conversation just submitted, including a command that
 * never became a chat line. Empty text is not a submission worth recalling, and a
 * conversation that has already left is not one: last sent dies with it. */
export function rememberLastSent(projection: PageProjection, key: string, text: string): void {
	if (text === "" || !projection.get().convs.has(key)) return;
	const lastSent = new Map(projection.get().lastSent);
	lastSent.set(key, text);
	projection.set({ lastSent });
}

export function lastSentFor(projection: PageProjection, key: string | null): string | undefined {
	return key === null ? undefined : projection.get().lastSent.get(key);
}
// ── Where this reader stands, at three levels ──────────────────────────────
//
// One word (empty for here, otherwise why they stepped out) and three places
// it can be said, each falling through to the next:
//
//   the room       what they said in this room alone
//   the directory  what they said on this server, the way IRC means away
//   the reader     what they said everywhere, the answer with no qualifier
//
// A level holds null while it has nothing of its own to say, so setting the
// outermost one moves every room that has not been given a word of its own, and
// a room that has been keeps it. What each level is *for* is in its field's doc.
// This is where the three meet.
//
// The intention, not the standing: what a roster shows is the room's word about
// a member, and this is what makes that word survive a membership. A reconnect
// enters a room as somebody new, and nobody would say it again.

/** Where this reader stands in one room: the room's own word, or the
 * directory's, or theirs. */
type StandingState = Readonly<Pick<State, "standing" | "convs" | "dirs">>;

export function standingFor(projection: PageProjection, key: string, s: StandingState = projection.get()): string {
	const conv = getConv(projection, key, s);
	if (conv?.type !== "room") return s.standing;
	return conv.standing ?? s.dirs.get(conv.dir)?.standing ?? s.standing;
}

/** Where this reader stands on one directory, for a room it has not spoken for
 * itself: the directory's own word, or theirs. */
export function standingOn(projection: PageProjection, dir: DirId, s: StandingState = projection.get()): string {
	return s.dirs.get(dir)?.standing ?? s.standing;
}

/** Say where this reader stands everywhere. */
export function setStanding(projection: PageProjection, standing: string): void {
	if (projection.get().standing !== standing) projection.set({ standing });
}

/** Say where they stand on one directory, or `null` to follow their own. */
export function setDirStanding(projection: PageProjection, dir: DirId, standing: string | null): void {
	if (projection.get().dirs.get(dir)?.standing !== standing) patchDir(projection, dir, { standing });
}

/** Say where they stand in one room, or `null` to follow its directory. */
export function setRoomStanding(projection: PageProjection, key: string, standing: string | null): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.standing === standing) return;
	put(projection, { ...conv, standing });
}

/** Record what this room handed this membership, once subscribing has answered.
 *
 * Replaced whole rather than added to, because a fresh subscribe is a fresh set
 * of references: a grant that stopped being answered has stopped being held. */
// ── Rooms somebody handed you ──────────────────────────────────────────────

/** Put an invitation in front of the reader. */
export function addInvite(projection: PageProjection, invite: Invitation): void {
	projection.set({ invites: [...projection.get().invites, invite] });
}

/** Forget one, however it was answered. */
export function dropInvite(projection: PageProjection, id: string): void {
	const invites = projection.get().invites;
	if (!invites.some((invite) => invite.id === id)) return;
	projection.set({ invites: invites.filter((invite) => invite.id !== id) });
}

export function setGrants(projection: PageProjection, key: string, grants: ReadonlySet<string>): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	put(projection, { ...conv, grants });
}

/** Record what the conversation's current history request learned. */
export function setEarlierHistory(
	projection: PageProjection,
	key: string,
	earlierHistory: RoomConv["earlierHistory"],
): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.earlierHistory === earlierHistory) return;
	put(projection, { ...conv, earlierHistory });
}
export function clearMembers(projection: PageProjection, key: string): void {
	if (getConv(projection, key)?.type !== "room" || membersOf(projection, key).size === 0) return;
	replaceMembers(projection, key, NO_MEMBERS);
}

/** Whether this room has said `name` is one of its members. */
export function hasMember(projection: PageProjection, key: string, name: string): boolean {
	return getConv(projection, key)?.type === "room" && membersOf(projection, key).has(name);
}

export function membersOf(
	projection: PageProjection,
	key: string | null,
	s: Readonly<Pick<State, "members">> = projection.get(),
): ReadonlyMap<string, RoomMemberState> {
	return key == null ? NO_MEMBERS : s.members.get(key) ?? NO_MEMBERS;
}

function replaceMembers(projection: PageProjection, key: string, roster: ReadonlyMap<string, RoomMemberState>): void {
	const members = new Map(projection.get().members);
	if (roster.size === 0) members.delete(key);
	else members.set(key, roster);
	projection.set({ members });
}

export function typersOf(
	projection: PageProjection,
	key: string | null,
	s: Readonly<Pick<State, "typers">> = projection.get(),
): ReadonlySet<string> {
	return key == null ? NO_TYPERS : s.typers.get(key) ?? NO_TYPERS;
}

export function setTyper(projection: PageProjection, key: string, who: string, typing: boolean): void {
	if (getConv(projection, key) == null) return;
	const current = typersOf(projection, key);
	if (current.has(who) === typing) return;
	const names = new Set(current);
	if (typing) names.add(who);
	else names.delete(who);
	const typers = new Map(projection.get().typers);
	if (names.size === 0) typers.delete(key);
	else typers.set(key, names);
	projection.set({ typers });
}
