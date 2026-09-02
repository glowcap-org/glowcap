// What an established Rooms session can do for this tab, split by the surface
// that asks: directory, conversation, room, workspace, and operations.

import { createContext, useContext } from "react";
import type { OperatorReferenceKind, OperatorResetScope } from "../../../lib/operator.ts";
import type { RoomsSessionFacet } from "../../../lib/session/client.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type { RoomAuthorityKind } from "../../../lib/room/authority.ts";
import type { RoomPolicy } from "../../../lib/room/policy.ts";
import type { DirId, DmConv, OperatorCategory, OpsCap, RoomDestination, ViewerDirection } from "../types.ts";

export interface RoomsDirectoryController {
	readonly directoryReady: Promise<void>;
	pickRoom(dir: DirId, name: string, key?: string): void;
	openManagedRoom(dir: DirId, label: string, policy: RoomPolicy): void;
	acceptInvite(id: string): Promise<void>;
	declineInvite(id: string): void;
	leaveRoom(key: string): void;
	leaveDirectory(dir: DirId): void;
	openConv(key: string): Promise<void>;
	closeDm(conv: DmConv): void;
	endConv(): void;
	releaseNick(dir: DirId): Promise<string>;
	selfLocator(): string | null;
	directoryLocator(): string | null;
	dirAddress(dir: DirId): string;
	directoryId(locator: string): DirId | null;
	join(destination: RoomDestination, nick: string, signal?: AbortSignal): Promise<string>;
	/** Reach a directory without entering a room in it, so a card can offer its
	 * listing before asking which room. An empty locator names this page's own.
	 * Answers the refusal, or the empty string when the directory is reached. */
	reachDirectory(locator: string, nick: string, signal?: AbortSignal): Promise<string>;
}

export interface RoomsConversationController {
	startDm(who: string): void;
	retry(key: string, id: number): void;
	stopSend(key: string, id: number): void;
	withdraw(key: string, id: number): void;
	mention(who: string): void;
	setDraft(text: string): void;
	recallLastSent(): string | null;
	send(): void;
	openFile(key: string, id: number): void;
	openViewer(key: string, id: number): void;
	stepViewer(direction: ViewerDirection): void;
	setTyping(on: boolean): void;
	setStanding(standing: string): void;
	setDirStanding(dir: DirId, standing: string | null): void;
	setRoomStanding(key: string, standing: string | null): void;
}

export interface RoomsRoomController {
	/** The declared bridge form for a room, or null when its bridge declares
	 * none. Asked when a reader opens the surface, because a form is declared
	 * for the state its bridge is in now. */
	bridgeForm(key: string): Promise<BridgeForm | null>;
	/** Submit one bridge form act for a room. The scope is the bridge's own
	 * word for how far the answers reach, the bridge judges the answers when
	 * they are replayed to it, and secrets never enter a checkpoint or the
	 * browser store. Resolves with "" once applied, or the refusal a reader
	 * can act on. */
	submitBridgeForm(
		key: string,
		scope: string,
		action: string,
		answers: Record<string, string>,
		secrets: Record<string, string>,
	): Promise<string>;
	/** Take or claim the room's moderator capability; resolves with the refusal,
	 * or "" once held. */
	stewardRoom(key: string, link?: string): Promise<string>;
	managerRoom(key: string, link: string): Promise<string>;
	dropRoomManager(key: string, token: string): Promise<string>;
	revokeManagedRoomAuthority(key: string, kind: "room" | "steward", token: string): Promise<string>;
	unregisterManagedRoom(key: string): Promise<string>;
	setManagedRoomPolicy(key: string, policy: RoomPolicy): Promise<string>;
	/** Stop retaining this session's moderator authority without revoking other holders. */
	dropRoomModerator(key: string, token: string): Promise<string>;
	createRoomLink(key: string): Promise<string>;
	/** Explicitly recover a room whose exact authority retired. A public room
	 * retries by name; a held room supplies a current exact link. */
	recoverRoom(key: string, link?: string): Promise<string>;
	/** Ask a member out; resolves with the refusal, or "" once asked. */
	askRoomMemberOut(key: string, name: string): Promise<string>;
}

export interface RoomsWorkspaceController {
	applySettings(next: { dm?: "webrtc" | "relay"; viz?: string }): Promise<boolean>;
	exportRoomsState(includeCapabilities?: boolean): string;
	importRoomsState(raw: string): Promise<string>;
	clearRoomsState(): Promise<string>;
	setKeepHistory(keep: boolean): Promise<void>;
	takeArchivePeer(sturdyref: string, remember?: boolean): Promise<string>;
	retryArchivePeer(): Promise<string>;
	useOwnedArchive(): Promise<void>;
	shareArchiveHistory(key: string, peer?: string, records?: "line" | "standing"): Promise<string>;
	offerDurableArchive(key: string, peer?: string, records?: "line" | "standing"): Promise<string>;
	readArchiveShare(id: string): Promise<string>;
	dropArchiveShare(id: string): void;
	listIssuedArchiveShares(): Promise<readonly import("../../../lib/archive/facet.ts").ArchiveDurableShareView[]>;
	revokeIssuedArchiveShare(id: string): Promise<string>;
}

export interface RoomsOperationsController {
	watchOpsBundle(changed: () => void | Promise<void>): () => void;
	/** Open a bridge-gateway connection from the answers a reader filled into
	 * the gateway's own connection form. */
	openBridgeConnection(answers: Record<string, string>): Promise<string>;
	closeBridgeConnection(connectionId: string): Promise<string>;
	/** Add a lease under a connection from the gateway's lease-form answers. */
	addBridgeLease(connectionId: string, answers: Record<string, string>): Promise<string>;
	removeBridgeLease(connectionId: string, leaseId: string): Promise<string>;
	readOpsBundle(): Promise<string>;
	replaceOpsBundle(pasted: string): Promise<{
		bundle: string;
		failures: readonly { capability: OpsCap | null; reason: string }[];
	}>;
	refreshOpsCap(cap: OpsCap): Promise<void>;
	listenerUp(transport: string, options?: Record<string, string | number>): Promise<string>;
	listenerDown(id: number): Promise<string>;
	giveRoomStewardship(name: string): Promise<string>;
	revokeRoomStewardship(name: string): Promise<string>;
	revokeRoomLink(name: string): Promise<string>;
	/** Retire one exact room-link or moderator generation for every holder. */
	revokeRoomAuthority(kind: RoomAuthorityKind, token: string): Promise<string>;
	recoverRoomManager(key: string): Promise<string>;
	revokeNick(nick: string, sessionId: string): Promise<string>;
	disconnectSession(id: string): Promise<string>;
	removeOperatorRoom(id: string): Promise<string>;
	releaseOperatorReference(id: string): Promise<string>;
	clearOperatorTrouble(): Promise<string>;
	resumeSessionEffect(id: string): Promise<string>;
	resolveSessionEffect(id: string, outcome: "committed" | "abandoned"): Promise<string>;
	issueSessionGrant(id: string, rights: RoomsSessionFacet, label: string, history: boolean): Promise<string>;
	revokeSessionGrant(id: string): Promise<string>;
	/** Change what an already-issued link carries: its access, whether it may
	 * read earlier messages, and whether it is paused. Fields left out keep the
	 * answer they had. The link itself never changes. */
	changeSessionGrant(
		id: string,
		patch: { rights?: RoomsSessionFacet; history?: boolean; suspended?: boolean; note?: string },
	): Promise<string>;
	resetOperatorScope(scope: OperatorResetScope): Promise<string>;
	loadMoreOperator(category: OperatorCategory): Promise<string>;
	/** Read every inventory again through one search, empty for all of them. */
	searchOperator(query: string, referenceKind?: OperatorReferenceKind | null): Promise<string>;
	/** Retire one bounded batch of the rows matching a search, answering how
	 * many went and how many still match, or a refusal. */
	retireMatchingOperator(
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<{ retired: number; remaining: number; refused: string } | string>;
	publishPeeredRoom(key: string, name: string): Promise<string>;
	revokePeeredPublication(id: string | number): Promise<string>;
}

/** UI-facing commands owned by the established local or attached session. */
export interface RoomsSessionController
	extends
		RoomsDirectoryController,
		RoomsConversationController,
		RoomsRoomController,
		RoomsWorkspaceController,
		RoomsOperationsController {}

const RoomsSessionContext = createContext<RoomsSessionController | null>(null);

export const RoomsSessionProvider = RoomsSessionContext.Provider;

export function useRoomsSession(): RoomsSessionController {
	const controller = useContext(RoomsSessionContext);
	if (controller == null) {
		throw new Error("rooms: session behavior was requested before a session was established");
	}
	return controller;
}
