// Transport-independent contract consumed by an attached Rooms controller.

import type { HistoryChange } from "../../../lib/session/history.ts";
import type {
	RoomsOperationsSnapshot,
	RoomsSessionClient,
	RoomsSessionFacet,
	RoomsSessionGrantView,
	RoomsSessionLineEvent,
	RoomsSessionSnapshot,
} from "../../../lib/session/client.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { Attachment, AttachmentSource } from "../../../lib/attachment.ts";
import type { ArchiveRecord } from "../../../lib/archive/protocol.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type {
	OperatorCategory,
	OperatorPage,
	OperatorReferenceKind,
	OperatorRetireBatch,
	OperatorSnapshot,
} from "../../../lib/operator.ts";

/** What may be changed about an issued link. Anything left out keeps the answer
 * it had. */
export interface RoomsSessionGrantPatch {
	readonly rights?: RoomsSessionFacet;
	readonly history?: boolean;
	readonly suspended?: boolean;
	readonly note?: string;
}

export type AttachedFile = Attachment | import("../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsBrowserFile;
export type AttachedFileData =
	| Uint8Array
	| import("../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsBrowserFileView;
export type AttachedLineEvent = Omit<RoomsSessionLineEvent, "attachments"> & { attachments: AttachedFile[] };

export type AttachedHistoryRead =
	| { conversationId: string; phase: "loading" }
	| { conversationId: string; phase: "ready"; records: ArchiveRecord[]; local: boolean; peer: boolean }
	| { conversationId: string; phase: "failed"; error: string };

export interface AttachedOperationsRead {
	capability: "listeners" | "diagnostics" | "irc" | "operator" | "peering" | "trace";
	snapshot: OperatorSnapshot | RoomsOperationsSnapshot | null;
	search: string;
	referenceKind: OperatorReferenceKind | null;
	error: string | null;
}

export interface AttachedRoomsRemote {
	eraseBrowserArchive(): Promise<void>;
	acceptInvitation(invitation: string): Promise<RoomsSessionSnapshot>;
	takeRoomLink(link: string, label: string): Promise<boolean>;
	chooseDirect(
		directory: string,
		who: string,
		select: boolean,
	): Promise<import("../../../lib/rooms_state.ts").WorkspaceDirectConversation>;
	reachDirectory(locator: string, nick: string, defaultDirectory: string, signal?: AbortSignal): Promise<void>;
	joinDestination(
		destination: string,
		nick: string,
		defaultDirectory: string,
		signal?: AbortSignal,
	): Promise<RoomsSessionSnapshot>;
	chooseRoom(directory: string, name: string, policy?: string): Promise<RoomsSessionSnapshot>;
	readonly operationsView: {
		retire(
			category: OperatorCategory,
			query: string,
			limit: number,
			referenceKind: OperatorReferenceKind | null,
		): Promise<OperatorRetireBatch>;
		run(capability: string, action: string, args: string[]): Promise<RoomsSessionSnapshot>;
		loadPage(category: OperatorCategory): Promise<void>;
		listen(listener: ((result: AttachedOperationsRead) => void) | undefined): void;
		refresh(
			capability: AttachedOperationsRead["capability"],
			search?: string,
			referenceKind?: OperatorReferenceKind | null,
		): Promise<void>;
	};
	encodeWorkspace(choices: string): string;
	selectWorkspace(
		persistence: import("../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsWorkspacePersistence,
		link: string,
		home: string,
	): Promise<{ workspace: string | null; cleanup: string | null }>;
	readonly drafts: {
		stage(conversation: string, text: string): void;
		pending(conversation: string): string | undefined;
		retire(conversation: string): void;
		clearSent(conversation: string): Promise<RoomsSessionSnapshot>;
		cancelSave(conversation: string): void;
		save(conversation: string, text: string, delayed: boolean): Promise<RoomsSessionSnapshot>;
	};
	runCommand(name: string, args: string[]): Promise<RoomsSessionSnapshot>;
	readonly writes: {
		files(
			conversation: string,
			caption: string,
			previewUrls: readonly string[],
			files: AttachmentSource[],
		): Promise<RoomsSessionSnapshot>;
		refile(
			conversation: string,
			line: number,
			caption: string,
			keep: readonly number[],
			files: AttachmentSource[],
		): Promise<RoomsSessionSnapshot>;
		checkpoint(value: RoomsSessionState, adopt: boolean): Promise<RoomsSessionSnapshot>;
	};
	listenHistory(listener: ((result: AttachedHistoryRead) => void) | undefined): void;
	listenLines(listener: ((event: AttachedLineEvent) => void) | undefined): void;
	settleRevision(revision: number): Promise<RoomsSessionSnapshot>;
	driving(): readonly string[];
	snapshot(): Promise<RoomsSessionSnapshot>;
	/** Ask this session whether a second capability for the same peer answers,
	 * over the connection already open to it. A Host keeps one session per
	 * peer, so this is the only way to try that capability without first
	 * giving up the one in hand. Rejects with what the peer or the enliven
	 * said; the reference is released either way. */
	verifySibling(sturdyref: string): Promise<void>;
	watch(
		changed: (snapshot: RoomsSessionSnapshot) => void,
		operationsChanged: (scope: string) => void,
		historyChanged: (change: HistoryChange) => void,
	): Promise<RoomsSessionSnapshot>;
	command(operationId: string, baseRevision: number, name: string, args: string[]): Promise<number>;
	setTyping(conversationId: string, on: boolean): Promise<void>;
	lastEditableLine(conversationId: string): number | undefined;
	ignoredNickname(conversationId: string): string | undefined;
	inviteToRoom(conversationId: string, who: string): Promise<void>;
	roomLinkFor(conversationId: string, name?: string): Promise<{ name: string; held: boolean; link: string }>;
	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]>;
	roomBridgeForm(conversationId: string): Promise<BridgeForm | null>;
	operatorSnapshot(
		scope: string,
		query?: string,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<OperatorSnapshot>;
	operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query?: string,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<OperatorPage>;
	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<OperatorRetireBatch>;
	operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot>;
	shareArchiveHistory(kind: string, conversationId: string, peer?: string): Promise<void>;
	offerDurableArchive(kind: string, conversationId: string, peer?: string): Promise<void>;
	readArchiveShare(id: string): ReturnType<RoomsSessionClient["readArchiveShare"]>;
	dropArchiveShare(id: string): Promise<void>;
	listIssuedArchiveShares(): ReturnType<RoomsSessionClient["listIssuedArchiveShares"]>;
	revokeIssuedArchiveShare(id: string): Promise<boolean>;
	publishPeeredRoom(operationId: string, baseRevision: number, intent: unknown): Promise<number>;
	revokePeeredRoom(operationId: string, baseRevision: number, id: string): Promise<number>;
	fetchAttachment(
		attachment: AttachedFile,
		onProgress?: (got: number) => void,
		signal?: AbortSignal,
	): Promise<AttachedFileData>;
	fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
		signal?: AbortSignal,
	): Promise<AttachedFileData>;
	releaseAttachment(attachment: AttachedFile): void;
	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void>;
	resumeEffect(operationId: string): Promise<number>;
	issueGrant(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		history: boolean,
	): Promise<RoomsSessionGrantView>;
	revokeGrant(id: string): Promise<void>;
	/** Change what an issued link carries, leaving the link itself alone. */
	changeGrant(id: string, patch: RoomsSessionGrantPatch): Promise<RoomsSessionGrantView>;
}
