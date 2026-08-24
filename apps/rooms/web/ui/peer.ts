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
import type { Reach } from "./intent.ts";
import type {
	AttachmentView,
	DirId,
	DmConv,
	OpsCap,
	RoomDestination,
	SettingsTab,
	ToastKind,
	ViewerDirection,
} from "./types.ts";

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
	/** Show a room, entering it if this tab is not in it. `key` names the
	 * conversation for a caller that has one — a row in the rail — because a
	 * private room's name is a label rather than an identity. */
	pickRoom(dir: DirId, name: string, key?: string): void;
	/** Make a room nobody can look up, and enter it. Its name is a label: two
	 * of them may share one, and no name gets anybody in — the reference this
	 * opens with, and whoever it is handed to, is the whole of who can reach
	 * it. */
	openPrivateRoom(dir: DirId, label: string): void;
	/** Take up a room somebody offered this tab, by redeeming its link. */
	acceptInvite(id: string): void;
	/** Let one go: the offer was a string, so this forgets it. */
	declineInvite(id: string): void;
	/** Leave one room, keeping every other room and direct line. Named by its
	 * conversation, because the rail can leave a room it is not showing and a room
	 * name alone cannot say which directory's room it means. */
	leaveRoom(key: string): void;
	/** Put the join card up as the answer to one act, to reach a room this tab
	 * is not in yet. What the card offers comes from the act and nothing else,
	 * so the caller says what the reader meant rather than filling fields; see
	 * `intent.ts`.
	 *
	 * It takes nothing away. Every room stays entered and every direct line
	 * stays open behind the card, which is only the conversation column standing
	 * empty for as long as it is up; picking anything in the rail comes straight
	 * back. */
	reachFor(act: Reach): void;
	/** Put the join card in front of the reader, filing no act.
	 *
	 * The card is already up and already answering something; this is somebody
	 * walking back to it — from a phone's list screen, or from the rail's own
	 * field — rather than asking to reach anywhere new. Filing an act here would
	 * supersede the one they are answering and take every answer they had typed
	 * under it with it. */
	showJoinCard(): void;
	/** Show what is known about one directory: its locator, how it is reaching
	 * us, the name it granted, and Leave. Settings can open the same card for
	 * the directory that served this page; every directory this tab holds uses
	 * that one surface. */
	aboutDirectory(dir: DirId | null): void;
	/** Show what is known about the conversation on screen: how this tab
	 * reaches it, where the session stands, and the rest a reader would open
	 * the title to check. The title and `/details` both open this. */
	aboutConversation(): void;
	/** Put that card away. */
	closeAboutConversation(): void;
	/** Open the card that holds the rest of a long refusal. */
	showError(detail: { title: string; text: string }): void;
	/** Put that card away. */
	closeError(): void;
	/** Stop holding a directory: its rooms are left, its direct lines closed, and
	 * the name it granted given back. Offered from the card that describes it,
	 * including the directory this page came from: leaving that one gives the
	 * session back, and the join card still knows the page's locator. */
	leaveDirectory(dir: DirId): void;
	openConv(key: string): void;
	closeDm(conv: DmConv): void;
	/** A page notice above every layer, including a modal. Several may be up;
	 * each leaves on its own. */
	toast(kind: ToastKind, text: string): void;
	// ── The header ────────────────────────────────────────────────────────
	showRoster(shown: boolean): void;
	/** End whatever is on screen: leave a room, close a direct line. */
	endConv(): void;
	toggleNotify(): Promise<string | null>;
	openSettings(): void;
	closeSettings(): void;
	/** Which Settings panel is selected, remembered on this device. */
	setSettingsTab(tab: SettingsTab): void;
	setTheme(theme: "light" | "dark"): void;
	/** Save one or both reload-scoped choices — the DM transport, the
	 * visualizer endpoint override — and reload so the peer opens with them.
	 * What a caller leaves out keeps its current value. */
	applySettings(next: { dm?: "webrtc" | "relay"; viz?: string }): void;
	/** Close Settings under the glossary modal without ending its settings session. */
	openHelp(): void;
	/** Put Settings back after Help. */
	closeHelp(): void;
	/** Bridge one IRC channel through the held gateway. Empty when it stood,
	 * otherwise the reason it did not. */
	joinIrc(
		choice: {
			network: string;
			channel: string;
			host: string;
			port: number;
			tls: boolean;
			nick: string;
			sasl?: { account: string; password: string };
		},
	): Promise<string>;
	/** Part a bridged channel; its room leaves the directory with it. */
	partIrc(network: string, channel: string): Promise<string>;
	/** Flip whether this device keeps direct-message history. Turning it off
	 * erases what was kept. */
	setKeepHistory(keep: boolean): void;
	/** Close Settings and stand the reader on the Operations page at /ops. */
	openOperations(): void;
	/** Close Settings under `cap`'s take modal: flipping an Capabilities toggle on
	 * asks to hold that capability, and the toggle lands on only when the take
	 * succeeds. */
	openOpsTake(cap: OpsCap, from?: "settings" | "ops"): void;
	/** Put Settings back after the take modal, taken or dismissed alike. */
	closeOpsTake(): void;
	/** Redeem the swiss number the server printed for `cap`, the way that
	 * capability is redeemed: the two session-fetched ones on the live
	 * directory session, the visualizer by presenting it to the timeline
	 * endpoint. Empty when this tab now holds it, otherwise the reason it
	 * would not take. `remember` keeps the swiss in this browser, keyed by
	 * where it was redeemed, so a reload takes it again unasked. */
	takeOpsCap(cap: OpsCap, pasted: string, remember?: boolean): Promise<string>;
	/** Let go of a held operations capability: its toggle falls off, its pane
	 * goes, and its swiss number is forgotten. */
	dropOpsCap(cap: OpsCap): void;
	/** Ask a held capability to say again what it holds. Nothing to ask, or
	 * not held, is silently nothing. */
	refreshOpsCap(cap: OpsCap): Promise<void>;
	/** Which operations pane is selected while more than one is held. */
	setOpsTab(tab: OpsCap): void;
	/** Bring a listener up on a transport the server's own list named, with
	 * values for whichever of the seat's declared knobs the reader filled in.
	 * Empty when it came up, otherwise the refusal for the pane to show. */
	listenerUp(transport: string, options?: Record<string, string | number>): Promise<string>;
	/** Take a listener down by the number the list gave it, the same way. */
	listenerDown(id: number): Promise<string>;
	/** Publish the room behind one conversation into this directory, durably,
	 * under `name`. The room must live on another directory this tab holds.
	 * Empty when the publication is live, otherwise the refusal for the pane
	 * to show. */
	publishPeeredRoom(key: string, name: string): Promise<string>;
	/** Revoke one publication this tab made, by the row id its publish minted.
	 * Revocation removes the room from discovery; references already handed
	 * out stay live. Empty when the row is gone, otherwise the refusal. */
	revokePeeredPublication(id: number): Promise<string>;
	/** This window's advertised direct-message locator, or null before the peer is up. */
	selfLocator(): string | null;
	/** The room directory this window currently reaches. */
	directoryLocator(): string | null;
	/** The dialable address for one directory this tab holds: the route it was
	 * reached at, routing hints and all, falling back to the bare authority.
	 * What every copy or share surface hands out; the bare id stays the key. */
	dirAddress(dir: DirId): string;
	/** The directory identity a piece of locator text names, or null when it is
	 * not an address. The hinted route and the bare authority are one answer
	 * here, which is what lets a surface holding either recognise a directory
	 * already in hand. */
	directoryId(locator: string): DirId | null;
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
	/** Begin changing a file line's files: its caption fills the composer and its
	 * current files show as removable chips, with room to add more. Sending
	 * refiles the line to exactly what is left. */
	changeFiles(id: number, caption: string, keeping: readonly AttachmentView[]): void;
	/** Drop one of the kept files from a file-line change, by its position. */
	dropKeptFile(index: number): void;
	/** Leave the line as it was posted and empty the composer. */
	cancelChange(): void;
	// ── Where this reader stands ──────────────────────────────────────────
	// Three levels, outermost first. Each takes the word itself, or null to hand
	// the answer back to the level outside it; the outermost has nowhere to hand
	// it, so it takes only the word.
	setStanding(standing: string): void;
	setDirStanding(dir: DirId, standing: string | null): void;
	setRoomStanding(key: string, standing: string | null): void;
	/** Put an @mention of `who` into the composer. */
	mention(who: string): void;
	setDraft(text: string): void;
	/** Fill an empty composer with the last line submitted here. Empty when
	 * there is nothing to recall, or the field is not empty. */
	recallLastSent(): string | null;
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
	/** The reader changing one of the card's answers by hand. It counts
	 * against the act they are answering, so going somewhere else drops it. */
	editJoin(patch: { room?: string; locator?: string; nick?: string; secret?: boolean }): void;
	/** Settles when the room has us, or with the reason it will not. Pass a
	 * signal to stop waiting: the form comes back, and a join that had not yet
	 * seated is dropped rather than finishing behind the card. */
	join(destination: RoomDestination, nick: string, signal?: AbortSignal): Promise<string>;
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
