// The data layer, as the interface sees it.
//
// This file names the verbs and hands them out; it does not know what performs
// them. `main.tsx` binds the table to the data layer once, which is what keeps a
// component renderable without a CapTP peer behind it: a component asks for
// `send`, and what `send` does is somebody else's decision.
//
// It is a context rather than props for a specific reason, and the same reason
// says why the *state* is not one. The table is built once and never replaced,
// so reading it costs a consumer nothing: a context only re-renders what reads
// it when its value changes, and this value never does. State is the opposite —
// it changes on every keystroke — so it stays behind `useStore`, where a
// component subscribes to the store directly and the memo boundaries above it
// decide what redraws. Putting both in one context would make a keystroke
// re-render every consumer of either, which is exactly what those boundaries
// exist to prevent.

import { createContext, useContext } from "react";
import type { Banner, DirId, DmConv, RoomDestination, ViewerDirection } from "./types.ts";

/** What the interface may ask of the data layer. Nothing here says who answers,
 * which is what lets a component be drawn without a peer behind it. */
export interface Peer {
	/** Settles when the directory has answered with its first list of rooms.
	 * A resource rather than a verb, and here rather than threaded down as a prop
	 * for the same reason the verbs are: the one component that reads it is three
	 * levels down, and every level between was carrying it for nothing. */
	directoryReady: Promise<void>;
	// ── The rail ──────────────────────────────────────────────────────────
	showRail(shown: boolean): void;
	/** Show a room if this tab is in it, otherwise enter it. Named by directory
	 * and room together, because a room name only means something inside the
	 * directory that granted it. */
	pickRoom(dir: DirId, name: string): void;
	/** Leave one room, keeping every other room and direct line. Named by its
	 * conversation, because the rail can leave a room it is not showing and a room
	 * name alone cannot say which directory's room it means. */
	leaveRoom(key: string): void;
	/** Go to the join card to reach a room in a directory this tab does not hold
	 * yet, carrying `room` into it if the reader had started naming one.
	 *
	 * It takes nothing away. Every room stays entered and every direct line stays
	 * open behind the card, which is only the conversation column standing empty
	 * for as long as it is up; picking anything in the rail comes straight back. */
	/** Open the join card, aimed at a directory when one is named and at whatever
	 * gets typed when it is not. */
	addDirectory(room: string, locator?: string): void;
	/** Show what is known about one directory: its locator, how it is reaching
	 * us, and the name it granted.
	 *
	 * The page's own directory has a home already — Settings is about this
	 * directory and nothing else — so asking about that one opens Settings rather
	 * than a second surface saying the same things. Any other directory gets a
	 * card of its own, because Settings would then have to grow a notion of which
	 * directory it is describing, and that is a question Settings should never
	 * have to answer. */
	aboutDirectory(dir: DirId | null): void;
	/** Stop holding a directory: its rooms are left, its direct lines closed, and
	 * the name it granted given back. Offered from the card that describes it,
	 * and never for the directory this page came from — there is nothing to fall
	 * back to there. */
	leaveDirectory(dir: DirId): void;
	openConv(key: string): void;
	closeDm(conv: DmConv): void;
	banner(message: Banner): void;
	// ── The header ────────────────────────────────────────────────────────
	showRoster(shown: boolean): void;
	/** End whatever is on screen: leave a room, close a direct line. */
	endConv(): void;
	toggleNotify(): Promise<string | null>;
	openSettings(): void;
	closeSettings(): void;
	setTheme(theme: "light" | "dark"): void;
	applySettings(next: { dm: "webrtc" | "relay"; viz: string }): void;
	/** This window's advertised direct-message locator, or null before the peer is up. */
	selfLocator(): string | null;
	/** The room directory this window currently reaches. */
	directoryLocator(): string | null;
	// ── The conversation ──────────────────────────────────────────────────
	startDm(who: string): void;
	/** Re-send a line whose bubble is marked failed, in its own conversation. */
	retry(key: string, id: number): void;
	/** Stop a send whose files are still going. It cannot un-say the message —
	 * that is already posted — but it gives the rest of the transfer back and
	 * leaves the send retryable, which is what a reader who picked the wrong
	 * large file needs. */
	stopSend(key: string, id: number): void;
	/** Withdraw a line you posted, by the reference the room handed back when it
	 * took the line. */
	withdraw(key: string, id: number): void;
	/** Begin changing a line you posted: its words go into the composer, which
	 * remembers which line they belong to until it is sent or cancelled. */
	changeLine(id: number, text: string): void;
	/** Leave the line as it was posted and empty the composer. */
	cancelChange(): void;
	/** Put an @mention of `who` into the composer. */
	mention(who: string): void;
	setDraft(text: string): void;
	send(): void;
	/** Add files to the local composer; Send publishes them with its text. */
	addFiles(files: readonly File[]): void;
	removeFile(index: number): void;
	/** Fetch a posted file's bytes, so its line can show or download them.
	 * Images small enough to draw ask for themselves; this is what a reader
	 * presses for everything else. */
	openFile(key: string, id: number): void;
	/** Show one posted file full-screen, over the whole interface. */
	openViewer(key: string, id: number): void;
	/** Move through the pictures in the open file's conversation. */
	stepViewer(direction: ViewerDirection): void;
	closeViewer(): void;
	setTyping(on: boolean): void;
	// ── The join card ─────────────────────────────────────────────────────
	setJoinDraft(patch: { draftRoom?: string; draftLocator?: string; draftNick?: string }): void;
	/** Settles when the room has us, or with the reason it will not. */
	join(destination: RoomDestination, nick: string): Promise<string>;
}

// No default. A component reached outside the provider would otherwise call a
// verb that silently does nothing, which is the failure this table exists to
// make impossible.
const PeerContext = createContext<Peer | null>(null);

export const PeerProvider = PeerContext.Provider;

export function usePeer(): Peer {
	const peer = useContext(PeerContext);
	if (peer === null) {
		throw new Error(
			"rooms: a component asked the data layer for something outside the provider",
		);
	}
	return peer;
}
