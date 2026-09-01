// Transport-independent contract consumed by an attached Rooms controller.

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

export interface AttachedRoomsRemote {
	snapshot(): Promise<RoomsSessionSnapshot>;
	/** Ask this session whether a second capability for the same peer answers,
	 * over the connection already open to it. A Host keeps one session per
	 * peer, so this is the only way to try that capability without first
	 * giving up the one in hand. Rejects with what the peer or the enliven
	 * said; the reference is released either way. */
	verifySibling(sturdyref: string): Promise<void>;
	watch(
		changed: (snapshot: RoomsSessionSnapshot) => void,
		event: (event: RoomsSessionLineEvent) => void,
		operationsChanged: (scope: string) => void,
	): Promise<RoomsSessionSnapshot>;
	command(operationId: string, baseRevision: number, name: string, args: string[]): Promise<number>;
	setTyping(conversationId: string, on: boolean): Promise<void>;
	editLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		text: string,
	): Promise<number>;
	withdrawLine(operationId: string, baseRevision: number, conversationId: string, lineId: number): Promise<number>;
	replace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number>;
	adoptWorkspace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number>;
	sendFiles(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		caption: string,
		files: AttachmentSource[],
	): Promise<number>;
	refileLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		files: AttachmentSource[],
	): Promise<number>;
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
	fetchAttachment(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array>;
	fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
	): Promise<Uint8Array>;
	releaseAttachment(attachment: Attachment): void;
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
