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
import type { DmConv } from "./types.ts";

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
	pickRoom(name: string): void;
	leaveRoom(): void;
	openConv(key: string): void;
	closeDm(conv: DmConv): void;
	banner(text: string): void;
	// ── The header ────────────────────────────────────────────────────────
	showRoster(shown: boolean): void;
	/** End whatever is on screen: leave a room, close a direct line. */
	endConv(): void;
	toggleTheme(): void;
	toggleNotify(): void;
	// ── The conversation ──────────────────────────────────────────────────
	startDm(who: string): void;
	/** Re-send a line whose bubble is marked failed, in its own conversation. */
	retry(key: string, id: number): void;
	/** Put an @mention of `who` into the composer. */
	mention(who: string): void;
	setDraft(text: string): void;
	send(): void;
	setTyping(on: boolean): void;
	// ── The join card ─────────────────────────────────────────────────────
	setJoinDraft(patch: { draftRoom?: string; draftNick?: string }): void;
	/** Settles when the room has us, or with the reason it will not. */
	join(room: string, nick: string): Promise<string>;
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
