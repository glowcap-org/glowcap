// What the page shows, and the verbs that change it.
//
// Everything the interface draws is a field here and everything that changes one
// is a verb here, so the interface stays a function of this and nothing keeps a
// second copy of the truth. The state itself, the page's chrome, conversations,
// lines, and directories live in `store/`; this file is who is in a room, where
// this reader stands, and what they have been offered.

import type { DirId, Invitation, RoomConv } from "./types.ts";
import { get, set, type State } from "./store/core.ts";
import type { Presence } from "../../lib/room_presence.ts";
import { applyRoomPresence } from "../../lib/room_presence.ts";
import type { RoomMemberState } from "../../lib/room_presence.ts";
import { getConv, put } from "./store/convs.ts";
import { patchDir } from "./store/dirs.ts";

// Reached through one name, as it always was: splitting where the code lives is
// not a change to what a caller may ask for.
export * from "./store/core.ts";
export * from "./store/chrome.ts";
export * from "./store/archive.ts";
export * from "./store/convs.ts";
export * from "./store/items.ts";
export * from "./store/dirs.ts";
export * from "./store/reaching.ts";
export * from "./store/trouble.ts";

// ── Room membership and typing ────────────────────────────────────────────
export function applyPresence(key: string, event: Presence | null): void {
	const conv = getConv(key);
	if (!event || conv?.type !== "room") return;
	put({ ...conv, members: applyRoomPresence(conv.members, event) });
}

/** What a room says it is about.
 *
 * Cleared and never-set are different states and both are spellable: a room that
 * has had its topic taken down says so with an empty string, and a room that has
 * never had one says nothing. The bar draws neither, so the difference shows
 * only in whether a change is worth announcing — taking one down is news. */
export function setTopic(key: string, topic: string): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.topic === topic) return;
	put({ ...conv, topic });
}

/** What a room will carry in one line, in bytes. See `lineBytes`. */
export function setLineBytes(key: string, lineBytes: number): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.lineBytes === lineBytes) return;
	put({ ...conv, lineBytes });
}

/** Replace one attached room's complete live view from a session snapshot. */
export function setRoomView(
	key: string,
	members: readonly [string, RoomMemberState][],
	topic: string | null,
	lineBytes: number | null,
	canSetTopic = false,
	canModerate = false,
): void {
	const conv = getConv(key);
	if (conv?.type !== "room") return;
	const { topic: _topic, lineBytes: _lineBytes, ...base } = conv;
	put({
		...base,
		members: new Map(members),
		grants: new Set([
			...(canSetTopic ? ["topic"] : []),
			...(canModerate ? ["steward"] : []),
		]),
		...(topic == null ? {} : { topic }),
		...(lineBytes == null ? {} : { lineBytes }),
	});
}
/** Whose lines this window does not show.
 *
 * Kept in this window rather than told to the room, which is the honest shape:
 * ignoring somebody is a decision about what you read, and a room that was told
 * would be a room that could be asked. Names are held folded, since a directory
 * grants them case-insensitively.
 *
 * Persisted, because an ignore that forgot itself on reload would have to be
 * made again every morning by exactly the person who least wants to think about
 * whoever it names. */
export function ignore(name: string): void {
	const folded = name.toLowerCase();
	const state = get();
	if (state.ignored.has(folded)) return;
	const ignored = new Set(state.ignored);
	ignored.add(folded);
	set({ ignored });
}

export function unignore(name: string): boolean {
	const folded = name.toLowerCase();
	const state = get();
	if (!state.ignored.has(folded)) return false;
	const ignored = new Set(state.ignored);
	ignored.delete(folded);
	set({ ignored });
	return true;
}

/** Remember what this conversation just submitted, including a command that
 * never became a chat line. Empty text is not a submission worth recalling. */
export function rememberLastSent(key: string, text: string): void {
	if (text === "") return;
	const lastSent = new Map(get().lastSent);
	lastSent.set(key, text);
	set({ lastSent });
}

export function lastSentFor(key: string | null): string | undefined {
	return key === null ? undefined : get().lastSent.get(key);
}
// ── Where this reader stands, at three levels ──────────────────────────────
//
// One word — empty for here, otherwise why they stepped out — and three places
// it can be said, each falling through to the next:
//
//   the room       what they said in this room alone
//   the directory  what they said on this server, the way IRC means away
//   the reader     what they said everywhere, the answer with no qualifier
//
// A level holds null while it has nothing of its own to say, so setting the
// outermost one moves every room that has not been given a word of its own, and
// a room that has been keeps it. What each level is *for* is in its field's doc;
// this is where the three meet.
//
// The intention, not the standing: what a roster shows is the room's word about
// a member, and this is what makes that word survive a membership. A reconnect
// enters a room as somebody new, and nobody would say it again.

/** Where this reader stands in one room: the room's own word, or the
 * directory's, or theirs. */
type StandingState = Readonly<Pick<State, "standing" | "convs" | "dirs">>;

export function standingFor(key: string, s: StandingState = get()): string {
	const conv = getConv(key, s);
	if (conv?.type !== "room") return s.standing;
	return conv.standing ?? s.dirs.get(conv.dir)?.standing ?? s.standing;
}

/** Where this reader stands on one directory, for a room it has not spoken for
 * itself: the directory's own word, or theirs. */
export function standingOn(dir: DirId, s: StandingState = get()): string {
	return s.dirs.get(dir)?.standing ?? s.standing;
}

/** Say where this reader stands everywhere. */
export function setStanding(standing: string): void {
	if (get().standing !== standing) set({ standing });
}

/** Say where they stand on one directory, or `null` to follow their own. */
export function setDirStanding(dir: DirId, standing: string | null): void {
	if (get().dirs.get(dir)?.standing !== standing) patchDir(dir, { standing });
}

/** Say where they stand in one room, or `null` to follow its directory. */
export function setRoomStanding(key: string, standing: string | null): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.standing === standing) return;
	put({ ...conv, standing });
}

/** Record what this room handed this membership, once subscribing has answered.
 *
 * Replaced whole rather than added to, because a fresh subscribe is a fresh set
 * of references: a grant that stopped being answered has stopped being held. */
// ── Rooms somebody handed you ──────────────────────────────────────────────

/** Put an invitation in front of the reader. */
export function addInvite(invite: Invitation): void {
	set({ invites: [...get().invites, invite] });
}

/** Forget one, however it was answered. */
export function dropInvite(id: string): void {
	const invites = get().invites;
	if (!invites.some((invite) => invite.id === id)) return;
	set({ invites: invites.filter((invite) => invite.id !== id) });
}

export function setGrants(key: string, grants: ReadonlySet<string>): void {
	const conv = getConv(key);
	if (conv?.type !== "room") return;
	put({ ...conv, grants });
}

/** Record what the conversation's current history request learned. */
export function setEarlierHistory(key: string, earlierHistory: RoomConv["earlierHistory"]): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.earlierHistory === earlierHistory) return;
	put({ ...conv, earlierHistory });
}
export function clearMembers(key: string): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.members.size === 0) return;
	put({ ...conv, members: new Map() });
}

/** Whether this room has said `name` is one of its members. */
export function hasMember(key: string, name: string): boolean {
	const conv = getConv(key);
	return conv?.type === "room" && conv.members.has(name);
}

export function setTyper(key: string, who: string, typing: boolean): void {
	const conv = getConv(key);
	if (conv == null || conv.typers.has(who) === typing) return;
	const typers = new Set(conv.typers);
	if (typing) typers.add(who);
	else typers.delete(who);
	put({ ...conv, typers });
}
