// What an established Rooms session can do for this tab, split by the surface
// that asks: directory, conversation, room, workspace, and operations.

import { createContext, useContext } from "react";
import type { OperatorReferenceKind, OperatorResetScope } from "../../../lib/operator.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type { RoomAuthorityKind } from "../../../lib/room/authority.ts";
import type { RoomPolicy } from "../room_policy.ts";
import type { DirId, DmConv, OperatorCategory, OpsCap, RoomDestination, ViewerDirection } from "../types.ts";
import type { RoomsError, RoomsErrorCode } from "../../../lib/error_codes.ts";

export type JoinOutcome =
	| { readonly ok: true }
	| {
		readonly ok: false;
		readonly code: RoomsErrorCode | null;
		readonly text: string;
		readonly failure?: RoomsError;
	};

export type JoinNicknameIntent =
	| { readonly kind: "exact"; readonly name: string }
	| { readonly kind: "automatic"; readonly base: string };

export interface RoomsDirectoryController {
	readonly directoryReady: Promise<void>;
	// Each verb below settles when its work does and never rejects; its
	// failure has already been told. A control awaits one to show it busy.
	pickRoom(dir: DirId, name: string, key?: string): Promise<void>;
	openManagedRoom(dir: DirId, label: string, policy: RoomPolicy): Promise<void>;
	acceptInvite(id: string): Promise<void>;
	declineInvite(id: string): Promise<void>;
	leaveRoom(key: string): Promise<void>;
	leaveDirectory(dir: DirId): Promise<void>;
	openConv(key: string): Promise<void>;
	closeDm(conv: DmConv): Promise<void>;
	endConv(): Promise<void>;
	releaseNick(dir: DirId): Promise<string>;
	selfLocator(): string | null;
	directoryLocator(): string | null;
	dirAddress(dir: DirId): string;
	directoryId(locator: string): DirId | null;
	/** The room's final answer to a join. Expected protocol failures retain their
	 * code so the field that can repair one receives it. Unknown failures still
	 * carry reader-facing text through the same boundary. */
	join(destination: RoomDestination, nick: JoinNicknameIntent, signal?: AbortSignal): Promise<JoinOutcome>;
	/** Reach a directory without entering a room in it, so a card can offer its
	 * listing before asking which room. An empty locator names this page's own.
	 * Answers the refusal, or the empty string when the directory is reached. */
	reachDirectory(locator: string, nick: JoinNicknameIntent, signal?: AbortSignal): Promise<string>;
}

export interface RoomsConversationController {
	/** Settles when the conversation opens. Its failure has already been told. */
	startDm(who: string): Promise<void>;
	/** Reconnect to the exact peer registration. An empty string is success. */
	recoverDm(key: string): Promise<string>;
	retry(key: string, id: number): void;
	withdraw(key: string, id: number): void;
	mention(who: string): void;
	setDraft(text: string): void;
	recallLastSent(): string | null;
	send(): void;
	openFile(key: string, id: number): void;
	openViewer(key: string, id: number): void;
	stepViewer(direction: ViewerDirection): void;
	setTyping(on: boolean): void;
	setStanding(standing: string): Promise<void>;
	setDirStanding(dir: DirId, standing: string | null): Promise<void>;
	setRoomStanding(key: string, standing: string | null): Promise<void>;
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
	/** Take or claim the room's moderator capability. Resolves with the refusal,
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
	 * retries by name. A held room supplies a current exact link. */
	recoverRoom(key: string, link?: string): Promise<string>;
	/** Ask a member out. Resolves with the refusal, or "" once asked. */
	askRoomMemberOut(key: string, name: string): Promise<string>;
}

export interface RoomsWorkspaceController {
	applySettings(next: { dm?: "webrtc" | "relay" }): Promise<boolean>;
	exportRoomsState(includeCapabilities?: boolean): Promise<string>;
	importRoomsState(raw: string): Promise<string>;
	clearRoomsState(): Promise<string>;
	setKeepHistory(keep: boolean): Promise<void>;
	takeArchivePeer(sturdyref: string): Promise<string>;
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
