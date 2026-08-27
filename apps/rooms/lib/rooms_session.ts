// Client contract for a durable Rooms application session capability.

import { Ref, type Session } from "@pancake/runtime";
import { retainCleanupFailures } from "@pancake/runtime";
import { ask } from "./ask.ts";
import type { RoomsRoomJoinIntent, RoomsSessionState } from "./rooms_state.ts";
import { type Attachment, type AttachmentSource, fetchBlob, sendWithAttachments } from "./attachment.ts";
import { type ArchiveRecord, archiveRecordRow, parseArchiveRecord } from "./archive.ts";
import {
	type OperatorCategory,
	type OperatorPage,
	type OperatorRetireBatch,
	type OperatorSnapshot,
	parseOperatorPageAnswer,
	parseOperatorRetireAnswer,
	parseOperatorSnapshotJson,
} from "./operator.ts";
import {
	parseOperationsSnapshot,
	parseRoomsSessionSnapshot,
	type RoomsOperationsSnapshot,
	type RoomsSessionLineEvent,
	type RoomsSessionSnapshot,
} from "./rooms_session_messages.ts";
import { deliverRoomsSessionLine } from "./rooms_session_line.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";
import {
	issueRoomsSessionGrant,
	revokeRoomsSessionGrant,
	type RoomsSessionFacet,
	type RoomsSessionGrantView,
} from "./rooms_session_grants.ts";
import {
	dropRoomsSessionArchiveShare,
	readRoomsSessionArchiveShare,
	shareRoomsSessionArchive,
} from "./rooms_session_archive_share.ts";
export {
	ROOMS_SESSION_ARCHIVE_SHARE,
	ROOMS_SESSION_ARCHIVE_SHARE_DROP,
	ROOMS_SESSION_ARCHIVE_SHARE_READ,
} from "./rooms_session_archive_share.ts";
export {
	parseRoomsSessionSnapshot,
	type RoomsOperationsSnapshot,
	type RoomsSessionDirectoryView,
	type RoomsSessionIssue,
	type RoomsSessionLineEvent,
	type RoomsSessionPendingEffect,
	type RoomsSessionRoomView,
	type RoomsSessionSnapshot,
} from "./rooms_session_messages.ts";
export {
	ROOMS_SESSION_ISSUE_GRANT,
	ROOMS_SESSION_REVOKE_GRANT,
	type RoomsSessionFacet,
	type RoomsSessionGrantView,
} from "./rooms_session_grants.ts";

export const ROOMS_SESSION_SNAPSHOT = "snapshot";
export const ROOMS_SESSION_WATCH = "watch";
export const ROOMS_SESSION_REPLACE = "replaceCheckpoint";
export const ROOMS_SESSION_ADOPT_WORKSPACE = "adoptWorkspace";
export const ROOMS_SESSION_FACET = "facet";
export const ROOMS_SESSION_REVOKE = "revoke";
export const ROOMS_SESSION_COMMAND = "command";
export const ROOMS_SESSION_RESOLVE_EFFECT = "resolveEffect";
export const ROOMS_SESSION_RESUME_EFFECT = "resumeEffect";
export const ROOMS_SESSION_CHANGED = "changed";
export const ROOMS_SESSION_EVENT = "event";
export const ROOMS_SESSION_FILES = "sendFiles";
export const ROOMS_SESSION_REFILE = "refileLine";
export const ROOMS_SESSION_HISTORY = "readHistory";
export const ROOMS_SESSION_ARCHIVED_ATTACHMENT = "archivedAttachment";
export const ROOMS_SESSION_OPERATOR_SNAPSHOT = "operatorSnapshot";
export const ROOMS_SESSION_OPERATOR_PAGE = "operatorPage";
export const ROOMS_SESSION_OPERATOR_RETIRE = "operatorRetire";
export const ROOMS_SESSION_OPERATIONS_CHANGED = "operationsChanged";
export const ROOMS_SESSION_OPERATIONS_SNAPSHOT = "operationsSnapshot";
export const ROOMS_SESSION_TYPING = "typing";
export interface RoomsSessionGrant {
	readonly session: RoomsSessionClient;
	revoke(): Promise<void>;
}

function sessionRevision(raw: unknown, operation: string): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error(`the Rooms session answered an invalid ${operation} revision`);
	}
	return Number(raw);
}

export class RoomsSessionClient {
	readonly #session: Session;
	readonly #capability: Ref;

	constructor(session: Session, capability: Ref) {
		this.#session = session;
		this.#capability = capability;
	}

	snapshot(): Promise<RoomsSessionSnapshot> {
		return ask(this.#session, this.#capability, ROOMS_SESSION_SNAPSHOT, [], "the Rooms session did not answer")
			.then(parseRoomsSessionSnapshot);
	}

	/** Observe this durable session. A line callback takes ownership of every
	 * attachment occurrence it receives; null declines lines and releases their
	 * capabilities here. */
	async watch(
		changed: (snapshot: RoomsSessionSnapshot) => void,
		event: ((event: RoomsSessionLineEvent) => void) | null = null,
		operationsChanged: (scope: string) => void = () => {},
	): Promise<RoomsSessionSnapshot> {
		const observer = this.#session.spawn((verb, args) => {
			if (verb !== ROOMS_SESSION_EVENT) {
				releaseUnclaimedCapabilityArguments(
					this.#session,
					args,
					"the Rooms session observer could not return an unexpected capability",
				);
			}
			if (verb === ROOMS_SESSION_CHANGED) {
				changed(parseRoomsSessionSnapshot(args));
				return null;
			}
			if (verb === ROOMS_SESSION_EVENT) {
				deliverRoomsSessionLine(this.#session, args, event);
				return null;
			}
			if (verb === ROOMS_SESSION_OPERATIONS_CHANGED) {
				if (args.length !== 1 || typeof args[0] !== "string") {
					throw new Error("the Rooms session sent an invalid operations invalidation");
				}
				operationsChanged(args[0]);
				return null;
			}
			throw new Error(`Rooms session observer has no method ${verb}`);
		});
		try {
			const raw = await ask(
				this.#session,
				this.#capability,
				ROOMS_SESSION_WATCH,
				[observer],
				"the Rooms session did not answer watching",
			);
			this.#session.release(observer);
			return parseRoomsSessionSnapshot(raw);
		} catch (error) {
			throw await retainCleanupFailures(error, [() => this.#session.release(observer)]);
		}
	}

	replace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_REPLACE,
			[operationId, BigInt(baseRevision), JSON.stringify(checkpoint)],
			"the Rooms session did not replace its checkpoint",
		).then((raw) => sessionRevision(raw, "checkpoint"));
	}

	adoptWorkspace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_ADOPT_WORKSPACE,
			[operationId, BigInt(baseRevision), JSON.stringify(checkpoint)],
			"the Rooms session did not adopt the workspace",
		).then((raw) => sessionRevision(raw, "workspace-adoption"));
	}

	command(operationId: string, baseRevision: number, name: string, args: string[]): Promise<number> {
		return ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_COMMAND,
			[operationId, BigInt(baseRevision), name, ...args],
			"the Rooms session did not apply the command",
		).then((raw) => sessionRevision(raw, "command"));
	}

	setDraft(operationId: string, baseRevision: number, conversationId: string, text: string): Promise<number> {
		return this.command(operationId, baseRevision, "setDraft", [conversationId, text]);
	}

	select(operationId: string, baseRevision: number, conversationId: string | null): Promise<number> {
		return this.command(operationId, baseRevision, "select", conversationId == null ? [] : [conversationId]);
	}

	setStanding(operationId: string, baseRevision: number, standing: string): Promise<number> {
		return this.command(operationId, baseRevision, "setStanding", [standing]);
	}

	joinDirectory(
		operationId: string,
		baseRevision: number,
		directory: RoomsSessionState["directories"][number],
	): Promise<number> {
		return this.command(operationId, baseRevision, "joinDirectory", [JSON.stringify(directory)]);
	}

	leaveDirectory(operationId: string, baseRevision: number, directoryId: string): Promise<number> {
		return this.command(operationId, baseRevision, "leaveDirectory", [directoryId]);
	}

	joinRoom(
		operationId: string,
		baseRevision: number,
		intent: RoomsRoomJoinIntent,
	): Promise<number> {
		return this.command(operationId, baseRevision, "joinRoom", [JSON.stringify(intent)]);
	}

	openPrivateRoom(
		operationId: string,
		baseRevision: number,
		conversation: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
		recoveryKey: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "openPrivateRoom", [JSON.stringify(conversation), recoveryKey]);
	}

	startDirect(
		operationId: string,
		baseRevision: number,
		conversation: Extract<RoomsSessionState["conversations"][number], { kind: "direct" }>,
	): Promise<number> {
		return this.command(operationId, baseRevision, "startDirect", [JSON.stringify(conversation)]);
	}

	leaveConversation(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "leaveConversation", [conversationId]);
	}

	closeDirect(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "closeDirect", [conversationId]);
	}

	setDirectoryStanding(
		operationId: string,
		baseRevision: number,
		directoryId: string,
		standing: string | null,
	): Promise<number> {
		return this.command(
			operationId,
			baseRevision,
			"setDirectoryStanding",
			standing == null ? [directoryId] : [directoryId, standing],
		);
	}

	setRoomStanding(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		standing: string | null,
	): Promise<number> {
		return this.command(
			operationId,
			baseRevision,
			"setRoomStanding",
			standing == null ? [conversationId] : [conversationId, standing],
		);
	}

	setIgnoredNames(operationId: string, baseRevision: number, names: readonly string[]): Promise<number> {
		return this.command(operationId, baseRevision, "setIgnoredNames", [JSON.stringify(names)]);
	}

	chooseHistoryRetention(operationId: string, baseRevision: number, keep: boolean): Promise<number> {
		return this.command(operationId, baseRevision, "chooseHistoryRetention", [String(keep)]);
	}

	chooseConnection(
		operationId: string,
		baseRevision: number,
		dmMode: RoomsSessionState["dmMode"],
		vizOverride: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "chooseConnection", [dmMode, vizOverride]);
	}

	replaceOperationsCapabilities(
		operationId: string,
		baseRevision: number,
		credentials: RoomsSessionState["capabilities"]["operations"],
	): Promise<number> {
		return this.command(operationId, baseRevision, "replaceOperationsCapabilities", [JSON.stringify(credentials)]);
	}

	selectArchive(operationId: string, baseRevision: number, sturdyref: string | null): Promise<number> {
		return this.command(operationId, baseRevision, "selectArchive", sturdyref == null ? [] : [sturdyref]);
	}

	acceptInvitation(
		operationId: string,
		baseRevision: number,
		invitationId: string,
		conversationId: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "acceptInvitation", [invitationId, conversationId]);
	}

	dismissInvitation(operationId: string, baseRevision: number, invitationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "dismissInvitation", [invitationId]);
	}

	setRoomTopic(operationId: string, baseRevision: number, conversationId: string, text: string): Promise<number> {
		return this.command(operationId, baseRevision, "setRoomTopic", [conversationId, text]);
	}

	kickRoomMember(operationId: string, baseRevision: number, conversationId: string, nick: string): Promise<number> {
		return this.command(operationId, baseRevision, "kickRoomMember", [conversationId, nick]);
	}

	connectRoomIrc(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		nick: string,
		account: string,
		password: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "connectRoomIrc", [conversationId, nick, account, password]);
	}

	disconnectRoomIrc(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "disconnectRoomIrc", [conversationId]);
	}

	ensureRoomLink(operationId: string, baseRevision: number, conversationId: string): Promise<number> {
		return this.command(operationId, baseRevision, "ensureRoomLink", [conversationId]);
	}

	takeRoomModerator(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		stewardLink?: string,
	): Promise<number> {
		return this.command(
			operationId,
			baseRevision,
			"takeRoomModerator",
			stewardLink == null ? [conversationId] : [conversationId, stewardLink],
		);
	}

	offerRoom(
		operationId: string,
		baseRevision: number,
		roomConversationId: string,
		directConversationId: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "offerRoom", [roomConversationId, directConversationId]);
	}

	async setTyping(conversationId: string, on: boolean): Promise<void> {
		await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_TYPING,
			[conversationId, on],
			"the Rooms session did not send typing",
		);
	}

	say(operationId: string, baseRevision: number, conversationId: string, text: string): Promise<number> {
		return this.command(operationId, baseRevision, "say", [conversationId, text]);
	}

	editLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		text: string,
	): Promise<number> {
		return this.command(operationId, baseRevision, "editLine", [conversationId, String(lineId), text]);
	}

	withdrawLine(operationId: string, baseRevision: number, conversationId: string, lineId: number): Promise<number> {
		return this.command(operationId, baseRevision, "withdrawLine", [conversationId, String(lineId)]);
	}

	operator(
		operationId: string,
		baseRevision: number,
		scope: string,
		action: string,
		args: string[] = [],
	): Promise<number> {
		return this.command(operationId, baseRevision, "operator", [scope, action, ...args]);
	}

	async sendFiles(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		caption: string,
		files: AttachmentSource[],
	): Promise<number> {
		const raw = await sendWithAttachments(
			this.#session,
			this.#capability,
			ROOMS_SESSION_FILES,
			[operationId, BigInt(baseRevision), conversationId, caption],
			files,
		);
		return sessionRevision(raw, "file-send");
	}

	async refileLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		sources: AttachmentSource[],
	): Promise<number> {
		const raw = await sendWithAttachments(
			this.#session,
			this.#capability,
			ROOMS_SESSION_REFILE,
			[operationId, BigInt(baseRevision), conversationId, BigInt(lineId), caption, ...keep.map(BigInt)],
			sources,
		);
		return sessionRevision(raw, "file-refile");
	}

	async readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_HISTORY,
			[kind, directory, conversation],
			"the Rooms session did not answer archive history",
		);
		if (!Array.isArray(raw)) throw new Error("the Rooms session answered invalid archive history records");
		return raw.map(parseArchiveRecord);
	}

	async fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
	): Promise<Uint8Array> {
		const metadata = record.attachments[index];
		if (metadata?.blob == null) throw new Error("that archive line retains no bytes for this file");
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_ARCHIVED_ATTACHMENT,
			[archiveRecordRow(record), BigInt(index)],
			"the Rooms session did not answer archived attachment",
		);
		if (!(raw instanceof Ref)) throw new Error("the Rooms session answered without an archived file capability");
		try {
			return await fetchBlob(this.#session, { ...metadata, blob: raw }, onProgress);
		} finally {
			this.#session.release(raw);
		}
	}

	fetchAttachment(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return fetchBlob(this.#session, attachment, onProgress);
	}

	releaseAttachment(attachment: Attachment): void {
		this.#session.release(attachment.blob);
	}

	async operatorSnapshot(scope: string, query = ""): Promise<OperatorSnapshot> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_OPERATOR_SNAPSHOT,
			query === "" ? [scope] : [scope, query],
			"the Rooms session did not answer operator state",
		);
		if (typeof raw !== "string") throw new Error("the Rooms session answered invalid operator state");
		return parseOperatorSnapshotJson(raw);
	}

	async operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
	): Promise<OperatorRetireBatch> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_OPERATOR_RETIRE,
			[scope, category, query, BigInt(limit)],
			"the Rooms session did not answer the operator retire",
		);
		return parseOperatorRetireAnswer(raw);
	}

	async operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query = "",
	): Promise<OperatorPage> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_OPERATOR_PAGE,
			[scope, category, BigInt(cursor), query],
			"the Rooms session did not answer the operator page",
		);
		return parseOperatorPageAnswer(category, raw);
	}

	async operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_OPERATIONS_SNAPSHOT,
			[scope, capability],
			`the Rooms session did not answer ${capability} state`,
		);
		return parseOperationsSnapshot(capability, raw);
	}

	publishPeeredRoom(operationId: string, baseRevision: number, intent: unknown): Promise<number> {
		return this.command(operationId, baseRevision, "publishPeeredRoom", [JSON.stringify(intent)]);
	}

	revokePeeredRoom(operationId: string, baseRevision: number, id: string): Promise<number> {
		return this.command(operationId, baseRevision, "revokePeeredRoom", [id]);
	}

	async resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void> {
		await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_RESOLVE_EFFECT,
			[operationId, outcome],
			"the Rooms session did not resolve the external effect",
		);
	}

	async resumeEffect(operationId: string): Promise<number> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_RESUME_EFFECT,
			[operationId],
			"the Rooms session did not resume the external effect",
		);
		return sessionRevision(raw, "resumed-effect");
	}

	shareArchiveHistory(conversationId: string): Promise<void> {
		return shareRoomsSessionArchive(this.#session, this.#capability, conversationId);
	}

	async readArchiveShare(
		id: string,
	): Promise<{ view: import("./rooms_session_messages.ts").RoomsSessionArchiveShare; records: ArchiveRecord[] }> {
		return await readRoomsSessionArchiveShare(this.#session, this.#capability, id);
	}

	dropArchiveShare(id: string): Promise<void> {
		return dropRoomsSessionArchiveShare(this.#session, this.#capability, id);
	}

	async facet(rights: RoomsSessionFacet): Promise<RoomsSessionGrant> {
		const raw = await ask(
			this.#session,
			this.#capability,
			ROOMS_SESSION_FACET,
			[rights],
			"the Rooms session did not mint the requested facet",
		);
		if (!Array.isArray(raw) || raw.length !== 2 || !(raw[0] instanceof Ref) || !(raw[1] instanceof Ref)) {
			throw new Error("the Rooms session did not answer with a facet and revoker");
		}
		const facet = raw[0];
		const revoker = raw[1];
		return {
			session: new RoomsSessionClient(this.#session, facet),
			revoke: async () => {
				await ask(this.#session, revoker, ROOMS_SESSION_REVOKE, [], "the Rooms session facet was not revoked");
			},
		};
	}

	async issueGrant(id: string, rights: RoomsSessionFacet, label: string): Promise<RoomsSessionGrantView> {
		return await issueRoomsSessionGrant(this.#session, this.#capability, id, rights, label);
	}

	revokeGrant(id: string): Promise<void> {
		return revokeRoomsSessionGrant(this.#session, this.#capability, id);
	}
}
