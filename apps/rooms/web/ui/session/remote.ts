// Transport-independent contract consumed by an attached Rooms controller.

import type {
	RoomsOperationsSnapshot,
	RoomsSessionClient,
	RoomsSessionFacet,
	RoomsSessionGrantView,
	RoomsSessionLineEvent,
	RoomsSessionSnapshot,
} from "../../../lib/rooms_session.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { Attachment, AttachmentSource } from "../../../lib/attachment.ts";
import type { ArchiveRecord } from "../../../lib/archive.ts";
import type { OperatorCategory, OperatorPage, OperatorRetireBatch, OperatorSnapshot } from "../../../lib/operator.ts";

export interface AttachedRoomsRemote {
	snapshot(): Promise<RoomsSessionSnapshot>;
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
	operatorSnapshot(scope: string, query?: string): Promise<OperatorSnapshot>;
	operatorPage(scope: string, category: OperatorCategory, cursor: number, query?: string): Promise<OperatorPage>;
	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
	): Promise<OperatorRetireBatch>;
	operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot>;
	shareArchiveHistory(conversationId: string): Promise<void>;
	readArchiveShare(id: string): ReturnType<RoomsSessionClient["readArchiveShare"]>;
	dropArchiveShare(id: string): Promise<void>;
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
	issueGrant(id: string, rights: RoomsSessionFacet, label: string): Promise<RoomsSessionGrantView>;
	revokeGrant(id: string): Promise<void>;
}
