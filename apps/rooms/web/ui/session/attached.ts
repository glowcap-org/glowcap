// Revisioned browser controller for an attached durable Rooms session.

import type {
	RoomsOperationsSnapshot,
	RoomsSessionFacet,
	RoomsSessionGrantView,
	RoomsSessionLineEvent,
	RoomsSessionSnapshot,
} from "../../../lib/session/client.ts";
import type { RoomsRoomJoinIntent, RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { RoomPolicy } from "../../../lib/room/policy.ts";
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
import type { AttachedRoomsRemote, RoomsSessionGrantPatch } from "./remote.ts";
import { AttachedSessionFeed } from "./attached_feed.ts";
import { type OperationSeat, runEffectCommand, runResultCommand } from "./attached_effects.ts";

export class AttachedRoomsController {
	readonly #remote: AttachedRoomsRemote;
	readonly #closeRemote: () => Promise<void>;
	readonly #feed: AttachedSessionFeed;
	#tail: Promise<void> = Promise.resolve();
	readonly #resultOperationIds = new Map<string, { args: string; id: string }>();
	/** The durable operations this tab is driving right now.
	 *
	 * An operation sitting in the session's pending ledger is not by itself
	 * something a reader has to decide about. While this tab is awaiting one it
	 * will settle, or it will fail at the control that started it, and either
	 * way somebody is already looking after it. What is left when those are
	 * taken out is the ledger's leftovers: an operation from a session that went
	 * away mid-flight, which nothing is driving and which will sit there until a
	 * person says what becomes of it. That is what the page calls a session
	 * effect, and what it asks about. */
	readonly #driving = new Set<string>();
	readonly #pendingDrafts = new Map<string, { token: symbol; text: string }>();
	#closed = false;

	constructor(remote: AttachedRoomsRemote, closeRemote: () => Promise<void> = () => Promise.resolve()) {
		this.#remote = remote;
		this.#closeRemote = closeRemote;
		this.#feed = new AttachedSessionFeed(remote);
	}

	get current(): RoomsSessionSnapshot | null {
		return this.#feed.current;
	}

	start(): Promise<RoomsSessionSnapshot> {
		if (this.#closed) throw new Error("this attached Rooms controller is closed");
		return this.#feed.start();
	}

	/** Whether a second capability for this session's peer answers, asked over
	 * the connection this controller already holds. */
	verifySibling(sturdyref: string): Promise<void> {
		if (this.#closed) throw new Error("this attached Rooms controller is closed");
		return this.#remote.verifySibling(sturdyref);
	}

	onSnapshot(listener: (snapshot: RoomsSessionSnapshot) => void): () => void {
		return this.#feed.onSnapshot(listener);
	}

	onLine(listener: (event: RoomsSessionLineEvent) => void): () => void {
		return this.#feed.onLine(listener);
	}

	onOperationsInvalidated(listener: (scope: string) => void): () => void {
		return this.#feed.onOperationsInvalidated(listener);
	}

	/** Read the runtime facts that accompany the latest durable checkpoint.
	 * Capability custody uses this after the server has reconciled the change,
	 * so success and refusal come from state rather than a browser delay. */
	refreshSnapshot(): Promise<RoomsSessionSnapshot> {
		return this.#serialize(() => this.#feed.refresh());
	}

	#command(name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(() => this.#pureCommand(operationId, name, args));
	}

	say(conversationId: string, text: string): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("say", [conversationId, text]);
	}

	editLine(conversationId: string, lineId: number, text: string): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const base = this.#feed.requireSnapshot().revision;
			const revision = await this.#remote.editLine(operationId, base, conversationId, lineId, text);
			return await this.#feed.settleRevision(revision);
		});
	}

	withdrawLine(conversationId: string, lineId: number): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const base = this.#feed.requireSnapshot().revision;
			const revision = await this.#remote.withdrawLine(operationId, base, conversationId, lineId);
			return await this.#feed.settleRevision(revision);
		});
	}

	operator(scope: string, action: string, args: string[] = []): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const base = this.#feed.requireSnapshot().revision;
			const revision = await this.#remote.command(operationId, base, "operator", [scope, action, ...args]);
			return await this.#feed.settleRevision(revision);
		});
	}

	operations(scope: string, capability: string, action: string, args: string[] = []): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const base = this.#feed.requireSnapshot().revision;
			const revision = await this.#remote.command(operationId, base, "operations", [
				scope,
				capability,
				action,
				...args,
			]);
			return await this.#feed.settleRevision(revision);
		});
	}

	sendFiles(conversationId: string, caption: string, files: AttachmentSource[]): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const base = this.#feed.requireSnapshot().revision;
			const revision = await this.#remote.sendFiles(operationId, base, conversationId, caption, files);
			return await this.#feed.settleRevision(revision);
		});
	}

	refileLine(
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		files: AttachmentSource[],
	): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const base = this.#feed.requireSnapshot().revision;
			const revision = await this.#remote.refileLine(
				operationId,
				base,
				conversationId,
				lineId,
				caption,
				keep,
				files,
			);
			return await this.#feed.settleRevision(revision);
		});
	}

	setDraft(conversationId: string, text: string): Promise<RoomsSessionSnapshot> {
		if (this.#pendingDrafts.get(conversationId)?.text !== text) this.stageDraft(conversationId, text);
		const token = this.#pendingDrafts.get(conversationId)?.token;
		if (token == null) throw new Error("the attached draft was not staged");
		const operationId = crypto.randomUUID();
		return this.#serialize(() => this.#pureCommand(operationId, "setDraft", [conversationId, text])).finally(() => {
			if (this.#pendingDrafts.get(conversationId)?.token === token) this.#pendingDrafts.delete(conversationId);
		});
	}

	/** Make a view-local draft authoritative during its debounce window. The
	 * later `setDraft` command persists this exact staged value. */
	stageDraft(conversationId: string, text: string): void {
		this.#pendingDrafts.set(conversationId, { token: Symbol(conversationId), text });
	}

	retireDraft(conversationId: string): void {
		this.#pendingDrafts.delete(conversationId);
	}

	pendingDraft(conversationId: string): string | undefined {
		return this.#pendingDrafts.get(conversationId)?.text;
	}

	select(conversationId: string | null): Promise<RoomsSessionSnapshot> {
		return this.#command("select", conversationId == null ? [] : [conversationId]);
	}

	setStanding(standing: string): Promise<RoomsSessionSnapshot> {
		return this.#command("setStanding", [standing]);
	}

	setDirectoryNick(directoryId: string, nick: string): Promise<RoomsSessionSnapshot> {
		return this.#command("setDirectoryNick", [directoryId, nick]);
	}

	setDirectoryStanding(directoryId: string, standing: string | null): Promise<RoomsSessionSnapshot> {
		return this.#command("setDirectoryStanding", standing == null ? [directoryId] : [directoryId, standing]);
	}

	setRoomStanding(conversationId: string, standing: string | null): Promise<RoomsSessionSnapshot> {
		return this.#command("setRoomStanding", standing == null ? [conversationId] : [conversationId, standing]);
	}

	setIgnoredNames(names: readonly string[]): Promise<RoomsSessionSnapshot> {
		return this.#command("setIgnoredNames", [JSON.stringify(names)]);
	}

	chooseHistoryRetention(keep: boolean): Promise<RoomsSessionSnapshot> {
		return this.#command("chooseHistoryRetention", [String(keep)]);
	}

	chooseConnection(dmMode: RoomsSessionState["dmMode"], vizOverride: string): Promise<RoomsSessionSnapshot> {
		return this.#command("chooseConnection", [dmMode, vizOverride]);
	}

	selectArchive(sturdyref: string | null): Promise<RoomsSessionSnapshot> {
		return this.#command("selectArchive", sturdyref == null ? [] : [sturdyref]);
	}

	replaceCheckpoint(checkpoint: RoomsSessionState): Promise<RoomsSessionSnapshot> {
		return this.#writeCheckpoint("replace", checkpoint);
	}

	adoptWorkspace(checkpoint: RoomsSessionState): Promise<RoomsSessionSnapshot> {
		return this.#writeCheckpoint("adoptWorkspace", checkpoint);
	}

	#writeCheckpoint(
		operation: "replace" | "adoptWorkspace",
		checkpoint: RoomsSessionState,
	): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const revision = await this.#remote[operation](
				operationId,
				this.#feed.requireSnapshot().revision,
				checkpoint,
			);
			return await this.#feed.settleRevision(revision);
		});
	}

	joinDirectory(directory: RoomsSessionState["directories"][number]): Promise<RoomsSessionSnapshot> {
		return this.#command("joinDirectory", [JSON.stringify(directory)]);
	}

	leaveDirectory(directoryId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("leaveDirectory", [directoryId]);
	}

	joinRoom(
		room: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
		directory?: Pick<RoomsRoomJoinIntent, "locator" | "nick">,
	): Promise<RoomsSessionSnapshot> {
		const currentDirectory = this.#feed.current?.checkpoint.directories.find((entry) =>
			entry.id === room.directory
		);
		const target = directory ?? currentDirectory;
		if (target == null) return Promise.reject(new Error("joinRoom names no directory route in this session"));
		return this.#command("joinRoom", [JSON.stringify({
			locator: target.locator,
			nick: target.nick,
			conversation: room,
		})]);
	}

	openManagedRoom(
		room: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
		recoveryKey: string,
		policy: RoomPolicy,
	): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const revision = await this.#remote.command(
				operationId,
				this.#feed.requireSnapshot().revision,
				"openManagedRoom",
				[
					JSON.stringify(room),
					recoveryKey,
					policy.visibility,
					policy.entry,
					policy.speaking,
				],
			);
			return await this.#feed.settleRevision(revision);
		});
	}

	acceptInvitation(invitationId: string, conversationId = crypto.randomUUID()): Promise<RoomsSessionSnapshot> {
		return this.#command("acceptInvitation", [invitationId, conversationId]);
	}

	dismissInvitation(invitationId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("dismissInvitation", [invitationId]);
	}

	setRoomTopic(conversationId: string, text: string): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("setRoomTopic", [conversationId, text]);
	}

	kickRoomMember(conversationId: string, nick: string): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("kickRoomMember", [conversationId, nick]);
	}

	/** Submit one bridge form act for the durable session to replay to its
	 * live room. The scope is the bridge's own word for how far the answers
	 * reach, and the secrets ride the command without entering the checkpoint. */
	submitRoomBridgeForm(
		conversationId: string,
		scope: string,
		action: string,
		answers: Record<string, string>,
		secrets: Record<string, string>,
	): Promise<RoomsSessionSnapshot> {
		return this.#command("submitRoomBridgeForm", [
			conversationId,
			scope,
			action,
			JSON.stringify(answers),
			JSON.stringify(secrets),
		]);
	}

	ensureRoomLink(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#resultCommand("ensureRoomLink", [conversationId]);
	}

	takeRoomModerator(conversationId: string, sturdyref?: string): Promise<RoomsSessionSnapshot> {
		return this.#resultCommand(
			"takeRoomModerator",
			sturdyref == null ? [conversationId] : [conversationId, sturdyref],
		);
	}

	takeRoomManager(conversationId: string, sturdyref: string): Promise<RoomsSessionSnapshot> {
		return this.#resultCommand("takeRoomManager", [conversationId, sturdyref]);
	}

	recoverRoomManager(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#resultCommand("recoverRoomManager", [conversationId]);
	}

	dropRoomManager(conversationId: string, token: string): Promise<RoomsSessionSnapshot> {
		return this.#command("dropRoomManager", [conversationId, token]);
	}

	revokeManagedRoomAuthority(
		conversationId: string,
		kind: "room" | "steward",
		token: string,
	): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("revokeManagedRoomAuthority", [conversationId, kind, token]);
	}

	unregisterManagedRoom(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("unregisterManagedRoom", [conversationId]);
	}

	setManagedRoomPolicy(conversationId: string, policy: RoomPolicy): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("setManagedRoomPolicy", [
			conversationId,
			policy.visibility,
			policy.entry,
			policy.speaking,
		]);
	}

	dropRoomModerator(conversationId: string, token: string): Promise<RoomsSessionSnapshot> {
		return this.#command("dropRoomModerator", [conversationId, token]);
	}

	offerRoom(roomConversationId: string, directConversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#effectCommand("offerRoom", [roomConversationId, directConversationId]);
	}

	setTyping(conversationId: string, on: boolean): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return this.#remote.setTyping(conversationId, on);
	}

	startDirect(
		direct: Extract<RoomsSessionState["conversations"][number], { kind: "direct" }>,
	): Promise<RoomsSessionSnapshot> {
		return this.#command("startDirect", [JSON.stringify(direct)]);
	}

	openDirect(
		direct: Extract<RoomsSessionState["conversations"][number], { kind: "direct" }>,
	): Promise<RoomsSessionSnapshot> {
		return this.#command("openDirect", [JSON.stringify(direct)]);
	}

	leaveConversation(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("leaveConversation", [conversationId]);
	}

	replaceOperationsCapabilities(
		credentials: RoomsSessionState["capabilities"]["operations"],
	): Promise<RoomsSessionSnapshot> {
		return this.#command("replaceOperationsCapabilities", [JSON.stringify(credentials)]);
	}

	roomBridgeForm(conversationId: string): Promise<BridgeForm | null> {
		return this.#remote.roomBridgeForm(conversationId);
	}

	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		return this.#remote.readHistory(kind, directory, conversation);
	}

	operatorSnapshot(
		scope: string,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorSnapshot> {
		return this.#remote.operatorSnapshot(scope, query, referenceKind);
	}

	operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorPage> {
		return this.#remote.operatorPage(scope, category, cursor, query, referenceKind);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorRetireBatch> {
		return this.#remote.operatorRetireMatching(scope, category, query, limit, referenceKind);
	}

	operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot> {
		return this.#remote.operationsSnapshot(scope, capability);
	}

	async shareArchiveHistory(kind: string, conversationId: string, peer = ""): Promise<RoomsSessionSnapshot> {
		await this.#remote.shareArchiveHistory(kind, conversationId, peer);
		return await this.#feed.refresh();
	}

	async offerDurableArchive(kind: string, conversationId: string, peer = ""): Promise<RoomsSessionSnapshot> {
		await this.#remote.offerDurableArchive(kind, conversationId, peer);
		return await this.#feed.refresh();
	}

	async readArchiveShare(id: string): ReturnType<AttachedRoomsRemote["readArchiveShare"]> {
		const result = await this.#remote.readArchiveShare(id);
		await this.#feed.refresh();
		return result;
	}

	async dropArchiveShare(id: string): Promise<RoomsSessionSnapshot> {
		await this.#remote.dropArchiveShare(id);
		return await this.#feed.refresh();
	}

	listIssuedArchiveShares(): ReturnType<AttachedRoomsRemote["listIssuedArchiveShares"]> {
		return this.#remote.listIssuedArchiveShares();
	}

	async revokeIssuedArchiveShare(id: string): Promise<RoomsSessionSnapshot> {
		await this.#remote.revokeIssuedArchiveShare(id);
		return await this.#feed.refresh();
	}

	publishPeeredRoom(intent: unknown): Promise<RoomsSessionSnapshot> {
		return this.#command("publishPeeredRoom", [JSON.stringify(intent)]);
	}

	revokePeeredRoom(id: string): Promise<RoomsSessionSnapshot> {
		return this.#command("revokePeeredRoom", [id]);
	}

	fetchAttachment(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return this.#remote.fetchAttachment(attachment, onProgress);
	}

	fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
	): Promise<Uint8Array> {
		return this.#remote.fetchArchivedAttachment(record, index, onProgress);
	}

	releaseAttachment(attachment: Attachment): void {
		this.#remote.releaseAttachment(attachment);
	}

	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<RoomsSessionSnapshot> {
		return this.#serialize(async () => {
			await this.#remote.resolveEffect(operationId, outcome);
			return await this.#feed.refresh();
		});
	}

	resumeEffect(operationId: string): Promise<RoomsSessionSnapshot> {
		return this.#serialize(async () => {
			const revision = await this.#remote.resumeEffect(operationId);
			return await this.#feed.settleRevision(revision);
		});
	}

	issueGrant(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		history: boolean,
	): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const grant = await this.#remote.issueGrant(id, rights, label, history);
			await this.#feed.refresh();
			return grant;
		});
	}

	revokeGrant(id: string): Promise<void> {
		return this.#serialize(async () => {
			await this.#remote.revokeGrant(id);
			await this.#feed.refresh();
		});
	}

	/** Change what an issued link carries. The feed is read again after, because
	 * the inventory this is administered from is part of what changed. */
	changeGrant(id: string, patch: RoomsSessionGrantPatch): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const grant = await this.#remote.changeGrant(id, patch);
			await this.#feed.refresh();
			return grant;
		});
	}

	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		await this.#tail;
		this.#feed.close();
		this.#pendingDrafts.clear();
		this.#resultOperationIds.clear();
		await this.#closeRemote();
	}

	#serialize<T>(work: () => Promise<T>): Promise<T> {
		const run = this.#tail.then(() => {
			if (this.#closed) throw new Error("this attached Rooms controller is closed");
			return work();
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async #pureCommand(operationId: string, name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		for (let attempt = 0; attempt < 2; attempt += 1) {
			const base = this.#feed.requireSnapshot().revision;
			try {
				const revision = await this.#remote.command(operationId, base, name, args);
				return await this.#feed.settleRevision(revision);
			} catch (error) {
				if (attempt !== 0 || !(error instanceof Error) || !error.message.includes("session revision changed")) {
					throw error;
				}
				await this.#feed.refresh();
			}
		}
		throw new Error("the Rooms session command did not settle");
	}

	/** Which operations this tab is currently answering for. */
	driving(): ReadonlySet<string> {
		return this.#driving;
	}

	/** What issuing an operation needs from this session. */
	get #seat(): OperationSeat {
		return { remote: this.#remote, feed: this.#feed, driving: this.#driving };
	}

	#effectCommand(name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		return this.#serialize(() => runEffectCommand(this.#seat, name, args));
	}

	#resultCommand(name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		return this.#serialize(() => runResultCommand(this.#seat, this.#resultOperationIds, name, args));
	}
}
