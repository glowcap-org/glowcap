// In-process AttachedRoomsRemote for the tab that is hosting the session actor.
//
// This tab cannot dial its own sturdyref: a Host keeps one session per peer.
// Commands, snapshots, and grants go through the same typed actor the CapTP
// facet uses. File bytes stay on RuntimeAttachment readers, not a self-dial.

import { type Behavior, Ref, type Session } from "@pancake/runtime";
import { BLOB_CHUNK, MAX_ATTACHMENT_BYTES } from "../../../lib/limits.ts";
import type {
	RoomsOperationsSnapshot,
	RoomsSessionFacet,
	RoomsSessionGrantView,
	RoomsSessionLineEvent,
	RoomsSessionSnapshot,
} from "../../../lib/session/client.ts";
import { parseOperationsSnapshot, parseRoomsSessionSnapshot } from "../../../lib/session/messages.ts";
import type { Attachment, AttachmentSource } from "../../../lib/attachment.ts";
import {
	type ArchiveCoordinates,
	type ArchiveLine,
	type ArchiveRecord,
	MAX_ARCHIVE_RECORDS,
} from "../../../lib/archive/protocol.ts";
import { parseArchiveShareKind } from "../../../lib/archive/handover.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type {
	OperatorCategory,
	OperatorPage,
	OperatorReferenceKind,
	OperatorRetireBatch,
	OperatorSnapshot,
} from "../../../lib/operator.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import { roomsSturdyrefLocator } from "../../../lib/locator.ts";
import type { BoundDurableRoomsSession } from "../../../session/bind.ts";
import { dispatchRoomsSessionCommand } from "../../../session/command_dispatch.ts";
import { snapshotForFacet } from "../../../session/facet_view.ts";
import { ResultEffectCoordinator, resumeResultEffect } from "../../../session/result_effect.ts";
import { prepareConversationEffect } from "../../../session/conversation_admission.ts";
import type { DurableRoomsRuntime } from "../../../session/runtime.ts";
import type { DurableRoomsSessionState } from "../../../session/state.ts";
import type { RuntimeAttachment } from "../../../session/room_files.ts";
import type { Message } from "../../../lib/room/client.ts";
import type { AttachedRoomsRemote, RoomsSessionGrantPatch } from "./remote.ts";

const LOCAL_SESSION = {} as Session;

function commandRevision(result: ReturnType<Behavior>): Promise<number> {
	return Promise.resolve(result).then((value) => {
		if (typeof value === "bigint" && value >= 0n && value <= BigInt(Number.MAX_SAFE_INTEGER)) {
			return Number(value);
		}
		throw new Error("the Rooms session command did not answer a revision");
	});
}

function localBlob(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

async function readAll(
	read: (offset: number, maxLen: number) => Promise<Uint8Array>,
	size: number,
	onProgress?: (got: number) => void,
): Promise<Uint8Array> {
	if (size > MAX_ATTACHMENT_BYTES) throw new Error(`attachment declares ${size} bytes, over the cap`);
	const out = new Uint8Array(size);
	let got = 0;
	while (got < size) {
		const chunk = await read(got, BLOB_CHUNK);
		if (!(chunk instanceof Uint8Array) || chunk.length === 0) {
			throw new Error(`blob ended at ${got} of ${size} bytes`);
		}
		if (got + chunk.length > size) throw new Error(`blob answered past its ${size} bytes`);
		out.set(chunk, got);
		got += chunk.length;
		onProgress?.(got);
	}
	return out;
}

async function materialize(files: readonly AttachmentSource[]): Promise<AttachmentSource[]> {
	const sources: AttachmentSource[] = [];
	for (const file of files) {
		if (file.bytes != null) {
			sources.push(file);
			continue;
		}
		const size = file.size ?? 0;
		const bytes = await readAll(
			(offset, maxLen) => {
				if (file.read == null) throw new Error("a file source has neither bytes nor a reader");
				return file.read(offset, maxLen);
			},
			size,
		);
		sources.push({ ...file, bytes });
	}
	return sources;
}

function fileMaterial(files: readonly AttachmentSource[]): unknown[] {
	return files.map((file) => ({
		name: file.name,
		mime: file.mime,
		size: file.bytes?.length ?? file.size ?? 0,
		width: file.width ?? 0,
		height: file.height ?? 0,
	}));
}

export class InProcessAttachedRemote implements AttachedRoomsRemote {
	readonly #bound: BoundDurableRoomsSession;
	readonly #live: DurableRoomsRuntime;
	readonly #state: DurableRoomsSessionState;
	readonly #effects = new ResultEffectCoordinator();
	readonly #blobs = new Map<Ref, RuntimeAttachment>();
	#source = crypto.randomUUID();
	#sequence = 0;
	#closed = false;
	#stops: Array<() => void> = [];

	constructor(bound: BoundDurableRoomsSession, live: DurableRoomsRuntime, state: DurableRoomsSessionState) {
		this.#bound = bound;
		this.#live = live;
		this.#state = state;
	}

	#assertOpen(): void {
		if (this.#closed) throw new Error("this hosted Rooms session is closed");
	}

	#owner() {
		return { state: this.#state, runtime: this.#live, grants: this.#bound.grants };
	}

	#context() {
		return {
			state: this.#state,
			runtime: this.#live,
			session: LOCAL_SESSION,
			resultEffects: this.#effects,
		};
	}

	#snapshot(): RoomsSessionSnapshot {
		return parseRoomsSessionSnapshot(snapshotForFacet("admin", LOCAL_SESSION, "", [], this.#owner()));
	}

	#line(
		conversationId: string,
		message: Message,
		editable: boolean,
		files: RuntimeAttachment[],
		history: ArchiveCoordinates | null,
	): RoomsSessionLineEvent {
		if (this.#sequence === Number.MAX_SAFE_INTEGER) {
			this.#source = crypto.randomUUID();
			this.#sequence = 0;
		}
		this.#sequence += 1;
		const attachments: Attachment[] = files.map((file) => {
			const blob = localBlob();
			this.#blobs.set(blob, file);
			return {
				name: file.name,
				mime: file.mime,
				size: file.size,
				width: file.width,
				height: file.height,
				blob,
			};
		});
		return {
			source: this.#source,
			sequence: this.#sequence,
			conversationId,
			from: message.from,
			text: message.text,
			at: Date.now(),
			lineId: message.lineId ?? null,
			change: message.change ?? null,
			editable,
			history,
			system: message.system,
			presence: message.presence,
			facts: message.facts,
			attachments,
		};
	}

	snapshot(): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		return Promise.resolve(this.#snapshot());
	}

	verifySibling(sturdyref: string): Promise<void> {
		this.#assertOpen();
		const here = roomsSturdyrefLocator(this.#bound.sturdyref);
		const there = roomsSturdyrefLocator(sturdyref);
		if (here.transport !== there.transport || here.designator !== there.designator) {
			return Promise.reject(new Error("that capability names a different session peer"));
		}
		if (sturdyref === this.#bound.sturdyref) return Promise.resolve();
		if (this.#bound.grants.list(LOCAL_SESSION).some((grant) => grant.sturdyref === sturdyref)) {
			return Promise.resolve();
		}
		return Promise.reject(new Error("that capability is not published by this session"));
	}

	watch(
		changed: (snapshot: RoomsSessionSnapshot) => void,
		event: (event: RoomsSessionLineEvent) => void,
		operationsChanged: (scope: string) => void,
	): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		const publish = () => {
			if (this.#closed) return;
			changed(this.#snapshot());
		};
		this.#stops.push(this.#state.onCheckpointChange(() => publish()));
		this.#stops.push(this.#live.onStatus(publish));
		this.#stops.push(this.#bound.grants.onChange(publish));
		this.#stops.push(this.#live.onOperationsInvalidated(operationsChanged));
		this.#stops.push(this.#live.onMessage((conversationId, message, editable, files, history) => {
			if (this.#closed) return;
			event(this.#line(conversationId, message, editable, files, history));
		}));
		return Promise.resolve(this.#snapshot());
	}

	command(operationId: string, baseRevision: number, name: string, args: string[]): Promise<number> {
		this.#assertOpen();
		return commandRevision(dispatchRoomsSessionCommand("admin", [
			operationId,
			BigInt(baseRevision),
			name,
			...args,
		], this.#context()));
	}

	publishPeeredRoom(operationId: string, baseRevision: number, intent: unknown): Promise<number> {
		return this.command(operationId, baseRevision, "publishPeeredRoom", [JSON.stringify(intent)]);
	}

	revokePeeredRoom(operationId: string, baseRevision: number, id: string): Promise<number> {
		return this.command(operationId, baseRevision, "revokePeeredRoom", [id]);
	}

	setTyping(conversationId: string, on: boolean): Promise<void> {
		this.#assertOpen();
		this.#live.roomActions.setTyping(conversationId, on);
		return Promise.resolve();
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

	replace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		this.#assertOpen();
		return this.#state.replace(operationId, baseRevision, checkpoint);
	}

	adoptWorkspace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		this.#assertOpen();
		return this.#state.adoptWorkspace(operationId, baseRevision, checkpoint);
	}

	async sendFiles(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		caption: string,
		files: AttachmentSource[],
	): Promise<number> {
		this.#assertOpen();
		const materialized = await materialize(files);
		const conversation = this.#state.snapshot().checkpoint.conversations.find((entry) =>
			entry.id === conversationId
		);
		if (conversation == null) throw new Error("that conversation is no longer part of this Rooms session");
		const operationMaterial = JSON.stringify([
			"sendFiles",
			conversationId,
			caption,
			...fileMaterial(materialized),
		]);
		const admission = await prepareConversationEffect(
			this.#state,
			this.#live,
			operationId,
			baseRevision,
			operationMaterial,
			conversation.kind,
			conversationId,
		);
		if (admission.kind === "committed") return admission.revision;
		await this.#live.sendFiles(conversationId, caption, materialized);
		return await this.#state.commitEffect(operationId, operationMaterial);
	}

	async refileLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		files: AttachmentSource[],
	): Promise<number> {
		this.#assertOpen();
		const materialized = await materialize(files);
		const conversation = this.#state.snapshot().checkpoint.conversations.find((entry) =>
			entry.id === conversationId
		);
		if (conversation == null) throw new Error("that conversation is no longer part of this Rooms session");
		const operationMaterial = JSON.stringify([
			"refileLine",
			conversationId,
			String(lineId),
			caption,
			...keep.map(String),
			...fileMaterial(materialized),
		]);
		const admission = await prepareConversationEffect(
			this.#state,
			this.#live,
			operationId,
			baseRevision,
			operationMaterial,
			conversation.kind,
			conversationId,
		);
		if (admission.kind === "committed") return admission.revision;
		await this.#live.refileLine(conversationId, lineId, caption, keep, materialized);
		return await this.#state.commitEffect(operationId, operationMaterial);
	}

	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		this.#assertOpen();
		return this.#live.readHistory(kind, directory, conversation);
	}

	roomBridgeForm(conversationId: string): Promise<BridgeForm | null> {
		this.#assertOpen();
		return this.#live.roomActions.bridgeForm(conversationId);
	}

	operatorSnapshot(
		scope: string,
		query?: string,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<OperatorSnapshot> {
		this.#assertOpen();
		return this.#live.operatorSnapshot(scope, query ?? "", referenceKind ?? null);
	}

	operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query?: string,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<OperatorPage> {
		this.#assertOpen();
		return this.#live.operatorPage(scope, category, cursor, query ?? "", referenceKind ?? null);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind?: OperatorReferenceKind | null,
	): Promise<OperatorRetireBatch> {
		this.#assertOpen();
		return this.#live.operatorRetireMatching(scope, category, query, limit, referenceKind ?? null);
	}

	async operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot> {
		this.#assertOpen();
		if (capability === "viz") {
			const snapshot = this.#live.vizSnapshot(scope);
			return parseOperationsSnapshot(
				capability,
				JSON.stringify({ url: snapshot.url, connected: snapshot.connected, refusal: snapshot.refusal }),
			);
		}
		if (capability === "peering") {
			return parseOperationsSnapshot(capability, JSON.stringify(this.#live.peeringSnapshot(scope)));
		}
		const snapshot = await this.#live.operationsSnapshot(scope, capability);
		return parseOperationsSnapshot(
			capability,
			JSON.stringify(snapshot.capability === "irc" ? snapshot.snapshot : snapshot.rows),
		);
	}

	shareArchiveHistory(kind: string, conversationId: string, peer?: string): Promise<void> {
		this.#assertOpen();
		return this.#live.shareArchiveHistory(parseArchiveShareKind(kind), conversationId, peer ?? "");
	}

	offerDurableArchive(kind: string, conversationId: string, peer?: string): Promise<void> {
		this.#assertOpen();
		return this.#live.offerDurableArchive(parseArchiveShareKind(kind), conversationId, peer ?? "");
	}

	async readArchiveShare(id: string): ReturnType<AttachedRoomsRemote["readArchiveShare"]> {
		this.#assertOpen();
		const records: ArchiveRecord[] = [];
		let after = 0;
		let view;
		while (records.length < MAX_ARCHIVE_RECORDS) {
			const page = await this.#live.readArchiveShare(id, after);
			view = page.view;
			records.push(...page.page.records.map((entry) => entry.record));
			if (!page.page.more) break;
			after = page.page.next;
		}
		if (view == null) throw new Error("that archive share is no longer offered");
		return { view, records };
	}

	dropArchiveShare(id: string): Promise<void> {
		this.#assertOpen();
		this.#live.dropArchiveShare(id);
		return Promise.resolve();
	}

	listIssuedArchiveShares(): ReturnType<AttachedRoomsRemote["listIssuedArchiveShares"]> {
		this.#assertOpen();
		return this.#live.listIssuedArchiveShares();
	}

	revokeIssuedArchiveShare(id: string): Promise<boolean> {
		this.#assertOpen();
		return this.#live.revokeIssuedArchiveShare(id);
	}

	fetchAttachment(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		this.#assertOpen();
		const held = this.#blobs.get(attachment.blob);
		if (held == null) throw new Error("that attachment is no longer held by this hosted session");
		return readAll((offset, maxLen) => held.read(offset, maxLen), attachment.size, onProgress);
	}

	async fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
	): Promise<Uint8Array> {
		this.#assertOpen();
		const held = await this.#live.readArchivedAttachment(record as ArchiveLine, index);
		if (held == null) throw new Error("that archive line retains no bytes for this file");
		try {
			return await readAll((offset, maxLen) => held.read(offset, maxLen), held.size, onProgress);
		} finally {
			held.release();
		}
	}

	releaseAttachment(attachment: Attachment): void {
		this.#blobs.delete(attachment.blob);
	}

	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void> {
		this.#assertOpen();
		return this.#state.resolveEffect(operationId, outcome);
	}

	resumeEffect(operationId: string): Promise<number> {
		this.#assertOpen();
		return resumeResultEffect(this.#state, this.#live, operationId);
	}

	issueGrant(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		history: boolean,
	): Promise<RoomsSessionGrantView> {
		this.#assertOpen();
		return this.#bound.grants.issue(id, rights, label, history, LOCAL_SESSION);
	}

	revokeGrant(id: string): Promise<void> {
		this.#assertOpen();
		return this.#bound.grants.revoke(id).then(() => {});
	}

	changeGrant(id: string, patch: RoomsSessionGrantPatch): Promise<RoomsSessionGrantView> {
		this.#assertOpen();
		return this.#bound.grants.setPolicy(id, patch, LOCAL_SESSION);
	}

	close(): Promise<void> {
		if (this.#closed) return Promise.resolve();
		this.#closed = true;
		for (const stop of this.#stops.splice(0)) stop();
		this.#blobs.clear();
		return Promise.resolve();
	}
}
