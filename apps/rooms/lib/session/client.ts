// Client contract for a durable Rooms application session capability.

import { Ref } from "@glowcap/runtime";
import { retainCleanupFailures } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { type BridgeForm, BridgeFormSchema } from "../bridge/form.ts";
import { MAX_FORM_JSON } from "../limits.ts";
import * as z from "zod/mini";
import type { RoomsSessionState } from "../rooms_state.ts";
import { type Attachment, type AttachmentSource, fetchBlob, sendWithAttachments } from "../attachment.ts";
import { type ArchiveRecord, archiveRecordRow, parseArchiveRecord } from "../archive/protocol.ts";
import { askOperatorPage, askOperatorRetire, askOperatorSnapshot } from "./operator.ts";
import { resolveRoomsSessionEffect, resumeRoomsSessionEffect } from "./effects.ts";
import { type HistoryChange, parseHistoryChange } from "./history.ts";
import { sessionRevision } from "./revision.ts";
import { mintRoomsSessionFacet, type RoomsSessionGrantOf } from "./facet.ts";

/** A live attenuated facet of this session, and the way to take it back. */
export type RoomsSessionGrant = RoomsSessionGrantOf<RoomsSessionClient>;
export {
	ROOMS_SESSION_ADOPT_WORKSPACE,
	ROOMS_SESSION_ARCHIVED_ATTACHMENT,
	ROOMS_SESSION_BRIDGE_FORM,
	ROOMS_SESSION_CHANGED,
	ROOMS_SESSION_COMMAND,
	ROOMS_SESSION_EVENT,
	ROOMS_SESSION_FACET,
	ROOMS_SESSION_FILES,
	ROOMS_SESSION_HISTORY,
	ROOMS_SESSION_HISTORY_CHANGED,
	ROOMS_SESSION_OPERATIONS_CHANGED,
	ROOMS_SESSION_OPERATIONS_SNAPSHOT,
	ROOMS_SESSION_OPERATOR_PAGE,
	ROOMS_SESSION_OPERATOR_RETIRE,
	ROOMS_SESSION_OPERATOR_SNAPSHOT,
	ROOMS_SESSION_REFILE,
	ROOMS_SESSION_REPLACE,
	ROOMS_SESSION_RESOLVE_EFFECT,
	ROOMS_SESSION_RESUME_EFFECT,
	ROOMS_SESSION_REVOKE,
	ROOMS_SESSION_SNAPSHOT,
	ROOMS_SESSION_TYPING,
	ROOMS_SESSION_WATCH,
} from "./verbs.ts";
import {
	ROOMS_SESSION_ADOPT_WORKSPACE,
	ROOMS_SESSION_ARCHIVED_ATTACHMENT,
	ROOMS_SESSION_BRIDGE_FORM,
	ROOMS_SESSION_CHANGED,
	ROOMS_SESSION_EVENT,
	ROOMS_SESSION_FILES,
	ROOMS_SESSION_HISTORY,
	ROOMS_SESSION_HISTORY_CHANGED,
	ROOMS_SESSION_OPERATIONS_CHANGED,
	ROOMS_SESSION_OPERATIONS_SNAPSHOT,
	ROOMS_SESSION_REFILE,
	ROOMS_SESSION_REPLACE,
	ROOMS_SESSION_SNAPSHOT,
	ROOMS_SESSION_TYPING,
	ROOMS_SESSION_WATCH,
} from "./verbs.ts";
import { RoomsSessionCommandClient } from "./client_commands.ts";
import {
	type OperatorCategory,
	type OperatorPage,
	type OperatorReferenceKind,
	type OperatorRetireBatch,
	type OperatorSnapshot,
} from "../operator.ts";
import {
	parseOperationsSnapshot,
	parseRoomsSessionSnapshot,
	type RoomsOperationsSnapshot,
	type RoomsSessionLineEvent,
	type RoomsSessionSnapshot,
} from "./messages.ts";
import { deliverRoomsSessionLine } from "./line.ts";
import { releaseUnclaimedCapabilityArguments } from "../argument_custody.ts";
import {
	issueRoomsSessionGrant,
	revokeRoomsSessionGrant,
	type RoomsSessionFacet,
	type RoomsSessionGrantView,
	setRoomsSessionGrantPolicy,
} from "./grants.ts";
import {
	dropRoomsSessionArchiveShare,
	listRoomsSessionIssuedArchiveShares,
	offerRoomsSessionDurableArchive,
	readRoomsSessionArchiveShare,
	revokeRoomsSessionArchiveShare,
	shareRoomsSessionArchive,
} from "./archive_share.ts";
export {
	ROOMS_SESSION_ARCHIVE_SHARE,
	ROOMS_SESSION_ARCHIVE_SHARE_DROP,
	ROOMS_SESSION_ARCHIVE_SHARE_READ,
} from "./archive_share.ts";
export {
	parseRoomsSessionSnapshot,
	type RoomsOperationsSnapshot,
	type RoomsSessionDirectoryView,
	type RoomsSessionIssue,
	type RoomsSessionLineEvent,
	type RoomsSessionPendingEffect,
	type RoomsSessionRoomView,
	type RoomsSessionSnapshot,
} from "./messages.ts";
export {
	accessOf,
	mayInteract,
	mayObserve,
	narrows,
	ROOMS_SESSION_ISSUE_GRANT,
	ROOMS_SESSION_REVOKE_GRANT,
	ROOMS_SESSION_SET_GRANT_POLICY,
	type RoomsSessionAccess,
	type RoomsSessionFacet,
	type RoomsSessionGrantView,
	RoomsSessionGrantViewSchema,
} from "./grants.ts";

export class RoomsSessionClient extends RoomsSessionCommandClient {
	snapshot(): Promise<RoomsSessionSnapshot> {
		return ask(this.session, this.capability, ROOMS_SESSION_SNAPSHOT, [], "the Rooms session did not answer")
			.then(parseRoomsSessionSnapshot);
	}

	/** Observe this durable session. A line callback takes ownership of every
	 * attachment occurrence it receives; null declines lines and releases their
	 * capabilities here. */
	async watch(
		changed: (snapshot: RoomsSessionSnapshot) => void,
		event: ((event: RoomsSessionLineEvent) => void) | null = null,
		operationsChanged: (scope: string) => void = () => {},
		historyChanged: (change: HistoryChange) => void = () => {},
	): Promise<RoomsSessionSnapshot> {
		const observer = this.session.spawn((verb, args) => {
			if (verb !== ROOMS_SESSION_EVENT) {
				releaseUnclaimedCapabilityArguments(
					this.session,
					args,
					"the Rooms session observer could not return an unexpected capability",
				);
			}
			if (verb === ROOMS_SESSION_CHANGED) {
				changed(parseRoomsSessionSnapshot(args));
				return null;
			}
			if (verb === ROOMS_SESSION_EVENT) {
				deliverRoomsSessionLine(this.session, args, event);
				return null;
			}
			if (verb === ROOMS_SESSION_HISTORY_CHANGED) {
				historyChanged(parseHistoryChange(args));
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
				this.session,
				this.capability,
				ROOMS_SESSION_WATCH,
				[observer],
				"the Rooms session did not answer watching",
			);
			this.session.release(observer);
			return parseRoomsSessionSnapshot(raw);
		} catch (error) {
			throw await retainCleanupFailures(error, [() => this.session.release(observer)]);
		}
	}

	replace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return ask(
			this.session,
			this.capability,
			ROOMS_SESSION_REPLACE,
			[operationId, BigInt(baseRevision), JSON.stringify(checkpoint)],
			"the Rooms session did not replace its checkpoint",
		).then((raw) => sessionRevision(raw, "checkpoint"));
	}

	adoptWorkspace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return ask(
			this.session,
			this.capability,
			ROOMS_SESSION_ADOPT_WORKSPACE,
			[operationId, BigInt(baseRevision), JSON.stringify(checkpoint)],
			"the Rooms session did not adopt the workspace",
		).then((raw) => sessionRevision(raw, "workspace-adoption"));
	}

	async setTyping(conversationId: string, on: boolean): Promise<void> {
		await ask(
			this.session,
			this.capability,
			ROOMS_SESSION_TYPING,
			[conversationId, on],
			"the Rooms session did not send typing",
		);
	}

	async sendFiles(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		caption: string,
		files: AttachmentSource[],
	): Promise<number> {
		const raw = await sendWithAttachments(
			this.session,
			this.capability,
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
			this.session,
			this.capability,
			ROOMS_SESSION_REFILE,
			[operationId, BigInt(baseRevision), conversationId, BigInt(lineId), caption, ...keep.map(BigInt)],
			sources,
		);
		return sessionRevision(raw, "file-refile");
	}

	/** The declared bridge form for one of this session's rooms, or null when
	 * its bridge declares none. The session relays the ask to its live room,
	 * so the answer is for the state the bridge is in now. */
	async roomBridgeForm(conversationId: string): Promise<BridgeForm | null> {
		const said = await ask(
			this.session,
			this.capability,
			ROOMS_SESSION_BRIDGE_FORM,
			[conversationId],
			"the Rooms session did not answer the bridge form",
		);
		if (said == null || said === "") return null;
		if (typeof said !== "string" || said.length > MAX_FORM_JSON) {
			throw new Error("the Rooms session answered an invalid bridge form");
		}
		let decoded: unknown;
		try {
			decoded = JSON.parse(said);
		} catch {
			throw new Error("the Rooms session answered a bridge form that is not JSON");
		}
		const parsed = z.safeParse(BridgeFormSchema, decoded);
		if (!parsed.success) throw new Error("the Rooms session answered an invalid bridge form");
		return parsed.data;
	}

	async readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		const raw = await ask(
			this.session,
			this.capability,
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
			this.session,
			this.capability,
			ROOMS_SESSION_ARCHIVED_ATTACHMENT,
			[archiveRecordRow(record), BigInt(index)],
			"the Rooms session did not answer archived attachment",
		);
		if (!(raw instanceof Ref)) throw new Error("the Rooms session answered without an archived file capability");
		try {
			return await fetchBlob(this.session, { ...metadata, blob: raw }, onProgress);
		} finally {
			this.session.release(raw);
		}
	}

	fetchAttachment(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return fetchBlob(this.session, attachment, onProgress);
	}

	releaseAttachment(attachment: Attachment): void {
		this.session.release(attachment.blob);
	}

	operatorSnapshot(
		scope: string,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorSnapshot> {
		return askOperatorSnapshot(this.session, this.capability, scope, query, referenceKind);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorRetireBatch> {
		return askOperatorRetire(this.session, this.capability, scope, category, query, limit, referenceKind);
	}

	operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorPage> {
		return askOperatorPage(this.session, this.capability, scope, category, cursor, query, referenceKind);
	}

	async operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot> {
		const raw = await ask(
			this.session,
			this.capability,
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

	/** An external operation the session is waiting on is settled or picked up
	 * again through the Rust session state owner. */
	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void> {
		return resolveRoomsSessionEffect(this.session, this.capability, operationId, outcome);
	}

	resumeEffect(operationId: string): Promise<number> {
		return resumeRoomsSessionEffect(this.session, this.capability, operationId);
	}

	shareArchiveHistory(kind: string, conversationId: string, peer = ""): Promise<void> {
		return shareRoomsSessionArchive(this.session, this.capability, kind, conversationId, peer);
	}

	offerDurableArchive(kind: string, conversationId: string, peer = ""): Promise<void> {
		return offerRoomsSessionDurableArchive(this.session, this.capability, kind, conversationId, peer);
	}

	async readArchiveShare(
		id: string,
	): Promise<{ view: import("./messages.ts").RoomsSessionArchiveShare; records: ArchiveRecord[] }> {
		return await readRoomsSessionArchiveShare(this.session, this.capability, id);
	}

	dropArchiveShare(id: string): Promise<void> {
		return dropRoomsSessionArchiveShare(this.session, this.capability, id);
	}

	revokeIssuedArchiveShare(id: string): Promise<boolean> {
		return revokeRoomsSessionArchiveShare(this.session, this.capability, id);
	}

	listIssuedArchiveShares(): Promise<import("../archive/facet.ts").ArchiveDurableShareView[]> {
		return listRoomsSessionIssuedArchiveShares(this.session, this.capability);
	}

	/** Mint a live attenuated facet of this session, and the way to take it
	 * back. Unlike a durable grant it lasts only as long as the connection. */
	facet(rights: RoomsSessionFacet): Promise<RoomsSessionGrant> {
		return mintRoomsSessionFacet(
			this.session,
			this.capability,
			rights,
			(facet) => new RoomsSessionClient(this.session, facet),
		);
	}

	issueGrant(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		history: boolean,
	): Promise<RoomsSessionGrantView> {
		return issueRoomsSessionGrant(this.session, this.capability, id, rights, label, history);
	}

	revokeGrant(id: string): Promise<void> {
		return revokeRoomsSessionGrant(this.session, this.capability, id);
	}

	/** Change what an already-issued link carries. Its sturdyref does not move,
	 * which is the point: the moment you want to narrow a link is the moment
	 * somebody is holding it. Anything left out keeps the answer it had. */
	setGrantPolicy(
		id: string,
		patch: {
			rights?: RoomsSessionFacet | null;
			history?: boolean | null;
			suspended?: boolean | null;
			note?: string | null;
		},
	): Promise<RoomsSessionGrantView> {
		return setRoomsSessionGrantPolicy(this.session, this.capability, id, patch);
	}

	setGrantAccess(id: string, rights: RoomsSessionFacet): Promise<RoomsSessionGrantView> {
		return this.setGrantPolicy(id, { rights });
	}

	setGrantHistory(id: string, history: boolean): Promise<RoomsSessionGrantView> {
		return this.setGrantPolicy(id, { history });
	}

	/** Hold a link at no access without giving up the access it was issued with,
	 * and say why. Lifting it restores what was intended, so nobody has to
	 * remember. Revoking is still the permanent answer. */
	suspendGrant(id: string, note = ""): Promise<RoomsSessionGrantView> {
		return this.setGrantPolicy(id, { suspended: true, note });
	}

	resumeGrant(id: string): Promise<RoomsSessionGrantView> {
		return this.setGrantPolicy(id, { suspended: false });
	}
}
