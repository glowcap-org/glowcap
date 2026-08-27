// The two lifetimes this page keeps apart, and the registry that holds them.
//
// A directory session dies whenever the room server restarts, and everything it
// was holding dies with it. What makes this tab reachable does not: a cold-dial
// line runs browser to browser through the relay, so a room respawning has
// nothing to do with it. Confusing the two is the mistake this module exists to
// make hard — state that belongs to a session lives in `Live` and goes when the
// object does, and state that outlives one lives beside the thing it does
// belong to, which is the inbox host rather than any connection to a directory.
//
// Everything here is the shape of that split and the one route from something
// on screen to the wire that carries it. No behavior, so nothing to reason
// about twice.

import type { Attachment } from "../../../lib/attachment.ts";
import type { DirectMessage, Directory, PostedLine, Room } from "../../../lib/room_client.ts";
import type { WebrtcSignalingServer } from "../../../lib/signaling.ts";
import type { Ref } from "@pancake/runtime";
import { type AttachmentView, type DirId, dirId } from "../types.ts";
import * as store from "../store.ts";

/** Everything that belongs to one directory session, and nothing that outlives
 * one.
 *
 * The page has two lifetimes and they are easy to confuse. A directory session
 * dies whenever the room server restarts, and everything it was holding dies
 * with it: the room it had us in, the direct lines redeemed over it, the name it
 * advertised. What is reachable *about us* does not — a cold-dial line is
 * browser-to-browser through the relay, so a room respawn must not disturb it —
 * and that state stays in module scope below.
 *
 * Both used to be module scope, and which was which lived in one place: a list
 * inside the disconnect handler, of everything to put back. A field added
 * without a line added there is a value that survives a reconnect it has no
 * business surviving, on the path hardest to exercise. Here the session is one
 * object, and ending it is dropping the object; what is left to do by hand is
 * only what has to be *released*, which is a shorter and more obvious list. */
export interface HeldFile {
	attachment: Omit<Attachment, "blob">;
	fetch: (onProgress?: (got: number) => void) => Promise<Uint8Array>;
	release: () => void;
}

export interface AttachmentProgress {
	/** Latest presentation state by conversation and file. File ids are unique,
	 * but retaining the conversation boundary lets one flush use the store's
	 * batch verb without rediscovering ownership. */
	pending: Map<string, Map<number, store.AttachmentFields>>;
	frame: number | null;
}

export interface Live {
	/** Which directory this session is. Every table below belongs to it, and a
	 * captured session can ask whether it is still the live one for its own
	 * directory without knowing anything about the others. */
	readonly id: DirId;
	readonly dir: Directory;
	/** Whether this is the directory that served the page. Its locator is
	 * rediscovered after a disconnect because routing hints may have changed,
	 * while `id` below keeps the directory's authority stable. */
	readonly home: boolean;
	/** The directory peer this session actually reaches. It need not be the
	 * server that served the page. */
	readonly locator: string;
	/** This tab's member-owned archive projected on the concrete session. The
	 * backend outlives a directory reconnect; this occurrence does not. */
	readonly archive: Ref;
	/** Every room this session has us in, by conversation key. None of them is
	 * necessarily the one on screen, and there is no "current" one: a room is
	 * addressed by the conversation being acted on.
	 *
	 * The table hangs off the session because a room reference is only good on
	 * the connection that fetched it. Dropping the session drops every room with
	 * it, and a reconnect re-enters them all against the new one. */
	rooms: Map<string, Room>;
	/** Rooms this exact directory connection opened and may therefore ask to
	 * issue stewardship for, by conversation key. This is connection state, not
	 * a role: reconnecting creates a new session and an empty set. */
	stewardClaimable: Set<string>;
	/** What each room on this connection was last told about where this reader
	 * stands, by conversation key.
	 *
	 * Beside `rooms` and for the same reason: a membership belongs to a
	 * connection, so a reconnect has told the new one nothing however much the
	 * old one heard. Held so that saying one word everywhere does not send it to
	 * rooms whose answer it does not change. */
	standingTold: Map<string, string>;
	/** Introduced direct lines, by conversation. One introduction each: the first
	 * send opens it, later sends reuse it, and a failed open is dropped so the
	 * next send retries. */
	directRoutes: Map<string, Promise<DirectMessage>>;
	/** Our own room lines painted and awaiting the room's echo. */
	echoes: { key: string; id: number; attachmentIds: number[]; text: string }[];
	/** Our own file-set changes awaiting the room's `refiled` echo, by the wire
	 * line each one changed. The value is the ordered file views this window
	 * already painted on the line, so when the echo comes back it holds each
	 * fresh blob under the view already on screen rather than replacing it — a
	 * kept file keeps its bytes and a new one keeps the local copy we uploaded,
	 * so a refile of our own line downloads nothing. */
	refiling: Map<number, readonly AttachmentView[]>;
	/** The reference the room answered with for each of our own lines, by the id
	 * this window knows that line by. Holding one is the authority to change or
	 * withdraw that line, so this map is exactly what this tab may still act on —
	 * and it dies with the session, because a reference cannot outlive the
	 * connection it came over. */
	posted: Map<number, PostedLine>;
	/** Attempts left to re-advertise a registration this session lost. */
	advertiseRetries: number;
	/** The nick this session advertised a locator for, so we register once per
	 * name rather than on every room switch. */
	advertised: string | null;
	/** Whether that registration has been acknowledged, which is when we may
	 * offer inboxes. */
	registered: boolean;
	/** Peers to offer an inbox to as soon as it is. */
	deferredOffers: Map<string, string>;
	/** Fires once this session has lasted long enough to count as stable. */
	stable: ReturnType<typeof setTimeout> | null;
	/** How long to wait before the next attempt on *this* directory, doubling per
	 * failure. One directory being unreachable says nothing about the others, so a
	 * dead one cannot drag a healthy one's cadence with it. */
	backoff: number;
	/** Pending WebRTC offer bring-ups filed through this directory session. */
	signaling: WebrtcSignalingServer | null;
	/** The blob capability behind each received file, by the file's id, with the
	 * fetch and release operations for the session it is reachable through.
	 * Capabilities live here rather than in the
	 * store for the same reason every other one does: the store holds what the
	 * page draws, and a reference is not something a page draws. */
	files: Map<number, HeldFile>;
	/** Object URLs this session minted, by the file that displays them.
	 * A retry replaces its URL; closing a conversation releases its files. */
	objectUrls: Map<number, string>;
	/** Network chunks coalesced to at most one immutable UI update per frame. */
	progress: AttachmentProgress;
	/** The files behind each of our own posts that has not been confirmed, by
	 * the message's id. Retrying a failed file message has to send the files again;
	 * without this it would re-post the caption alone and the room would show
	 * everyone a bare line while our own bubble still drew an attachment. */
	outgoing: Map<
		number,
		{
			key: string;
			attachmentIds: number[];
			files: File[];
			caption: string;
			/** Trips the bytes of this send, once they are going. Replaced on every
			 * attempt, so a retry after a stop is not stopped before it starts. */
			stop?: AbortController;
		}
	>;
}

/** Every directory this tab holds, by the authority its locator names.
 *
 * A directory is not a place you switch to. Holding one means a live session, a
 * nickname registered on it, and everything reachable through that nickname, so
 * opening a second takes nothing away from the first — the same rule rooms
 * follow, one level up.
 *
 * Insertion order is the order they were opened, which is the order the rail
 * lists them and the order a reconnect works through them. */
export const dirs = new Map<DirId, Live>();

/** The freshest route known for each directory authority. A live session owns
 * its route, but Settings and reconnect still need it after that session has
 * been retired. */
export const directoryLocators = new Map<DirId, string>();

/** The address to hand somebody for `dir`: the route this tab actually used,
 * routing hints and all, because a shared locator is for somebody else to dial
 * and the hints are part of what makes it dialable. The bare authority is the
 * fallback only when no route was ever recorded. Every surface that puts a
 * directory's address in front of a reader — the card's copy field, a room
 * link, the directory listing — answers with this, while the store stays keyed
 * by the bare authority so one directory stays one directory across address
 * changes. */
export function dirAddress(dir: DirId): string {
	return directoryLocators.get(dir) ?? (dir as string);
}

/** The session for one directory, or null when this tab does not hold it. */
export function dirSession(dir: DirId): Live | null {
	return dirs.get(dir) ?? null;
}

/** The session a conversation belongs to. Every conversation names its
 * directory, so this is the one route from anything on screen to the wire that
 * carries it. */
export function convSession(key: string | null): Live | null {
	const conv = store.getConv(key);
	return conv === null ? null : dirSession(conv.dir);
}

/** The directory whose answer speaks for the page right now, as a name to send
 * to rather than the whole record: the store owns the choice, and this is the
 * projection the wire side wants.
 *
 * A tab may hold several, and almost everything belongs to exactly one of them,
 * so this is only for the few questions asked before a conversation has been
 * picked: the join card's, and a command typed with nothing open. Empty while
 * this tab holds none, because the callers here are already in a session and
 * have somewhere to put the answer. */
export function actingDir(): DirId {
	return store.actingDir()?.id ?? dirId("");
}

/** Whether `session` is still the live one for its own directory. A session a
 * reconnect replaced, or whose directory has been left, is not — and the test
 * says so without asking what any other directory is doing. */
export function isCurrent(session: Live): boolean {
	return dirs.get(session.id) === session;
}

export function isConnected(): boolean {
	return anyLive() !== null;
}

/** Any directory this tab holds, for the questions that are about the tab
 * rather than about one of them. */
export function anyLive(): Live | null {
	for (const session of dirs.values()) return session;
	return null;
}
