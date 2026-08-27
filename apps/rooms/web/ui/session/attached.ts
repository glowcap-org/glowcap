// Revisioned browser controller for an attached durable Rooms session.

import type {
	RoomsOperationsSnapshot,
	RoomsSessionClient,
	RoomsSessionFacet,
	RoomsSessionGrantView,
	RoomsSessionLineEvent,
	RoomsSessionSnapshot,
} from "../../../lib/rooms_session.ts";
import type { RoomsRoomJoinIntent, RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { Attachment, AttachmentSource } from "../../../lib/attachment.ts";
import type { ArchiveRecord } from "../../../lib/archive.ts";
import type { OperatorCategory, OperatorPage, OperatorRetireBatch, OperatorSnapshot } from "../../../lib/operator.ts";
import type { AttachedRoomsRemote } from "./remote.ts";
import { AttachedSessionFeed } from "./attached_feed.ts";

export class AttachedRoomsController {
	readonly #remote: AttachedRoomsRemote;
	readonly #closeRemote: () => Promise<void>;
	readonly #feed: AttachedSessionFeed;
	#tail: Promise<void> = Promise.resolve();
	readonly #resultOperationIds = new Map<string, { args: string; id: string }>();
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

	openPrivateRoom(
		room: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
		recoveryKey: string,
	): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const revision = await this.#remote.command(
				operationId,
				this.#feed.requireSnapshot().revision,
				"openPrivateRoom",
				[
					JSON.stringify(room),
					recoveryKey,
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

	connectRoomIrc(
		conversationId: string,
		nick: string,
		account: string,
		password: string,
	): Promise<RoomsSessionSnapshot> {
		return this.#command("connectRoomIrc", [conversationId, nick, account, password]);
	}

	disconnectRoomIrc(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("disconnectRoomIrc", [conversationId]);
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

	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		return this.#remote.readHistory(kind, directory, conversation);
	}

	operatorSnapshot(scope: string, query = ""): Promise<OperatorSnapshot> {
		return this.#remote.operatorSnapshot(scope, query);
	}

	operatorPage(scope: string, category: OperatorCategory, cursor: number, query = ""): Promise<OperatorPage> {
		return this.#remote.operatorPage(scope, category, cursor, query);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
	): Promise<OperatorRetireBatch> {
		return this.#remote.operatorRetireMatching(scope, category, query, limit);
	}

	operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot> {
		return this.#remote.operationsSnapshot(scope, capability);
	}

	async shareArchiveHistory(conversationId: string): Promise<RoomsSessionSnapshot> {
		await this.#remote.shareArchiveHistory(conversationId);
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

	issueGrant(id: string, rights: RoomsSessionFacet, label: string): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const grant = await this.#remote.issueGrant(id, rights, label);
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

	#effectCommand(name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		const operationId = crypto.randomUUID();
		return this.#serialize(async () => {
			const revision = await this.#remote.command(operationId, this.#feed.requireSnapshot().revision, name, args);
			return await this.#feed.settleRevision(revision);
		});
	}

	/** Result-bearing room authority acts retain their operation identity after
	 * an answer is lost. The key is one action per conversation, so a corrected
	 * moderator link replaces the prior intent while retries of the same intent
	 * reach the session's durable result row. */
	#resultCommand(name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		const key = `${name}\u0000${args[0] ?? ""}`;
		const material = JSON.stringify(args);
		const prior = this.#resultOperationIds.get(key);
		const operationId = prior?.args === material ? prior.id : crypto.randomUUID();
		this.#resultOperationIds.set(key, { args: material, id: operationId });
		return this.#serialize(async () => {
			const revision = await this.#remote.command(operationId, this.#feed.requireSnapshot().revision, name, args);
			const snapshot = await this.#feed.settleRevision(revision);
			if (this.#resultOperationIds.get(key)?.id === operationId) this.#resultOperationIds.delete(key);
			return snapshot;
		});
	}
}

export function attachedRoomsController(
	client: RoomsSessionClient,
	close: () => Promise<void>,
): AttachedRoomsController {
	return new AttachedRoomsController(client, close);
}
