import { createContext, useContext } from "react";
import type { OperatorResetScope } from "../../../lib/operator.ts";
import type { RoomsSessionFacet } from "../../../lib/rooms_session.ts";
import type { DirId, DmConv, OperatorCategory, OpsCap, RoomDestination, ViewerDirection } from "../types.ts";

export interface RoomsDirectoryController {
	readonly directoryReady: Promise<void>;
	pickRoom(dir: DirId, name: string, key?: string): void;
	openPrivateRoom(dir: DirId, label: string): void;
	acceptInvite(id: string): Promise<void>;
	declineInvite(id: string): void;
	leaveRoom(key: string): void;
	leaveDirectory(dir: DirId): void;
	openConv(key: string): void;
	closeDm(conv: DmConv): void;
	endConv(): void;
	releaseNick(dir: DirId): Promise<string>;
	selfLocator(): string | null;
	directoryLocator(): string | null;
	dirAddress(dir: DirId): string;
	directoryId(locator: string): DirId | null;
	join(destination: RoomDestination, nick: string, signal?: AbortSignal): Promise<string>;
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
	connectIrcIdentity(key: string, nick: string, account: string, password: string): Promise<string>;
	disconnectIrcIdentity(key: string): Promise<string>;
	/** Take or claim the room's moderator capability; resolves with the refusal,
	 * or "" once held. */
	stewardRoom(key: string, link?: string): Promise<string>;
	createRoomLink(key: string): Promise<string>;
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
	useDeviceArchive(): Promise<void>;
	shareArchiveHistory(key: string): Promise<string>;
	readArchiveShare(id: string): Promise<string>;
	dropArchiveShare(id: string): void;
}

export interface RoomsOperationsController {
	joinIrc(choice: {
		network: string;
		channel: string;
		host: string;
		port: number;
		tls: boolean;
		nick: string;
		sasl?: { account: string; password: string };
	}): Promise<string>;
	partIrc(network: string, channel: string): Promise<string>;
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
	revokeNick(nick: string, sessionId: string): Promise<string>;
	disconnectSession(id: string): Promise<string>;
	removeOperatorRoom(id: string): Promise<string>;
	releaseOperatorReference(id: string): Promise<string>;
	clearOperatorTrouble(): Promise<string>;
	resumeSessionEffect(id: string): Promise<string>;
	resolveSessionEffect(id: string, outcome: "committed" | "abandoned"): Promise<string>;
	issueSessionGrant(id: string, rights: RoomsSessionFacet, label: string): Promise<string>;
	revokeSessionGrant(id: string): Promise<string>;
	resetOperatorScope(scope: OperatorResetScope): Promise<string>;
	loadMoreOperator(category: OperatorCategory): Promise<string>;
	/** Read every inventory again through one search, empty for all of them. */
	searchOperator(query: string): Promise<string>;
	/** Retire one bounded batch of the rows matching a search, answering how
	 * many went and how many still match, or a refusal. */
	retireMatchingOperator(
		category: OperatorCategory,
		query: string,
		limit: number,
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
