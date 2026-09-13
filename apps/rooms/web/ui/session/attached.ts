import type { AttachedFile as Attachment } from "./remote.ts";
import type { AttachedLineEvent as RoomsSessionLineEvent } from "./remote.ts";
// Revisioned browser controller for an attached durable Rooms session.

import type { HistoryChange } from "../../../lib/session/history.ts";
import type { RoomsSessionFacet, RoomsSessionGrantView, RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { RoomsRoomJoinIntent, RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { RoomPolicy } from "../room_policy.ts";
import type { AttachmentSource } from "../../../lib/attachment.ts";
import type { ArchiveRecord } from "../../../lib/archive/protocol.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import type { OperatorCategory, OperatorReferenceKind, OperatorRetireBatch } from "../../../lib/operator.ts";
import type { AttachedFileData, AttachedHistoryRead, AttachedRoomsRemote, RoomsSessionGrantPatch } from "./remote.ts";
import { sessionPreferences } from "./preferences.ts";
import { AttachedSessionFeed } from "./attached_feed.ts";
import { waitForRoomAdmission } from "./join_admission.ts";

export class AttachedRoomsController {
	readonly #remote: AttachedRoomsRemote;
	readonly #closeRemote: () => Promise<void>;
	readonly #feed: AttachedSessionFeed;
	#closed = false;

	constructor(remote: AttachedRoomsRemote, closeRemote: () => Promise<void> = () => Promise.resolve()) {
		this.#remote = remote;
		this.#closeRemote = closeRemote;
		this.#feed = new AttachedSessionFeed(remote);
	}

	encodeWorkspace(choices: string): string {
		if (this.#closed) throw new Error("This Rooms controller is closed");
		return this.#remote.encodeWorkspace(choices);
	}

	eraseBrowserArchive(): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("This Rooms controller cannot erase browser data"));
		return this.#remote.eraseBrowserArchive();
	}

	selectWorkspace(
		persistence: import("../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsWorkspacePersistence,
		link: string,
		home: string,
	): Promise<{ workspace: string | null; cleanup: string | null }> {
		if (this.#closed) return Promise.reject(new Error("This Rooms controller cannot change the workspace"));
		return this.#remote.selectWorkspace(persistence, link, home);
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

	get observesHistory(): boolean {
		return this.#remote.listenHistory != null;
	}
	onHistoryRead(listener: (result: AttachedHistoryRead) => void): () => void {
		if (this.#closed) throw new Error("this attached Rooms controller is closed");
		this.#remote.listenHistory(listener);
		return () => {
			if (!this.#closed) this.#remote.listenHistory(undefined);
		};
	}

	onSnapshot(listener: (snapshot: RoomsSessionSnapshot) => void): () => void {
		return this.#feed.onSnapshot(listener);
	}

	onLine(listener: (event: RoomsSessionLineEvent) => void): () => void {
		return this.#feed.onLine(listener);
	}

	onHistoryInvalidated(listener: (change: HistoryChange) => void): () => void {
		return this.#feed.onHistoryInvalidated(listener);
	}

	onOperationsRead(listener: (result: import("./remote.ts").AttachedOperationsRead) => void): () => void {
		if (this.#closed) throw new Error("this attached Rooms controller is closed");
		this.#remote.operationsView.listen(listener);
		return () => {
			if (!this.#closed) this.#remote.operationsView.listen(undefined);
		};
	}
	loadOperatorPage(category: OperatorCategory): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return this.#remote.operationsView.loadPage(category);
	}
	refreshOperations(
		capability: import("./remote.ts").AttachedOperationsRead["capability"],
		search?: string,
		kind?: OperatorReferenceKind | null,
	): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return this.#remote.operationsView.refresh(capability, search, kind);
	}

	/** Read the runtime facts that accompany the latest durable checkpoint.
	 * Capability custody uses this after the server has reconciled the change,
	 * so success and refusal come from state rather than a browser delay. */
	refreshSnapshot(): Promise<RoomsSessionSnapshot> {
		return this.#serialize(() => this.#feed.refresh());
	}

	#command(name: string, args: string[]): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return this.#remote.runCommand(name, args);
	}

	say(conversationId: string, text: string, previewUrls: readonly string[] = []): Promise<RoomsSessionSnapshot> {
		return this.#command("say", [conversationId, text, JSON.stringify(previewUrls)]);
	}

	editLine(conversationId: string, lineId: number, text: string): Promise<RoomsSessionSnapshot> {
		return this.#command("editLine", [conversationId, String(lineId), text]);
	}
	lastEditableLine(conversationId: string): number | undefined {
		if (this.#closed) return undefined;
		return this.#remote.lastEditableLine(conversationId);
	}
	ignoredNickname(conversationId: string): string | undefined {
		if (this.#closed) return undefined;
		return this.#remote.ignoredNickname(conversationId);
	}
	inviteToRoom(conversationId: string, who: string): Promise<void> {
		return this.#serialize(() => this.#remote.inviteToRoom(conversationId, who));
	}
	roomLinkFor(conversationId: string, name?: string): Promise<{ name: string; held: boolean; link: string }> {
		return this.#serialize(() => this.#remote.roomLinkFor(conversationId, name));
	}

	withdrawLine(conversationId: string, lineId: number): Promise<RoomsSessionSnapshot> {
		return this.#command("withdrawLine", [conversationId, String(lineId)]);
	}

	operator(scope: string, action: string, args: string[] = []): Promise<RoomsSessionSnapshot> {
		return this.#command("operator", [scope, action, ...args]);
	}

	operations(scope: string, capability: string, action: string, args: string[] = []): Promise<RoomsSessionSnapshot> {
		return this.#command("operations", [scope, capability, action, ...args]);
	}

	sendFiles(
		conversationId: string,
		caption: string,
		previewUrls: readonly string[],
		files: AttachmentSource[],
	): Promise<RoomsSessionSnapshot> {
		return this.#serialize(() => this.#remote.writes.files(conversationId, caption, previewUrls, files));
	}

	refileLine(
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		files: AttachmentSource[],
	): Promise<RoomsSessionSnapshot> {
		return this.#serialize(() => this.#remote.writes.refile(conversationId, lineId, caption, keep, files));
	}

	setDraft(conversationId: string, text: string): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return this.#remote.drafts.save(conversationId, text, false);
	}

	get closed(): boolean {
		return this.#closed;
	}

	/** Make a view-local draft authoritative during its debounce window. The
	 * later `setDraft` command persists this exact staged value. */
	stageDraft(conversationId: string, text: string): void {
		if (this.#closed) throw new Error("this attached Rooms controller is closed");
		this.#remote.drafts.stage(conversationId, text);
	}

	retireDraft(conversationId: string): void {
		if (this.#closed) return;
		this.#remote.drafts.retire(conversationId);
	}

	pendingDraft(conversationId: string): string | undefined {
		if (this.#closed) return undefined;
		return this.#remote.drafts.pending(conversationId);
	}

	clearSentDraft(conversationId: string): Promise<RoomsSessionSnapshot | void> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return this.#remote.drafts.clearSent(conversationId);
	}

	cancelDraftSave(conversationId: string): void {
		if (!this.#closed) this.#remote.drafts.cancelSave(conversationId);
	}
	scheduleDraft(conversationId: string, text: string): Promise<RoomsSessionSnapshot> {
		if (this.#closed) {
			return Promise.reject(new Error("Rooms draft scheduler is unavailable"));
		}
		return this.#remote.drafts.save(conversationId, text, true);
	}

	select(conversationId: string | null): Promise<RoomsSessionSnapshot> {
		return this.#command("select", conversationId == null ? [] : [conversationId]);
	}

	readonly preferences = sessionPreferences((name, args) => this.#command(name, args));

	chooseHistoryRetention(keep: boolean): Promise<RoomsSessionSnapshot> {
		return this.#command("chooseHistoryRetention", [String(keep)]);
	}

	chooseConnection(dmMode: RoomsSessionState["dmMode"], traceOverride: string): Promise<RoomsSessionSnapshot> {
		return this.#command("chooseConnection", [dmMode, traceOverride]);
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
		return this.#serialize(() => this.#remote.writes.checkpoint(checkpoint, operation === "adoptWorkspace"));
	}

	chooseDirect(
		directory: string,
		who: string,
		select: boolean,
	): Promise<import("../../../lib/rooms_state.ts").WorkspaceDirectConversation> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.chooseDirect(directory, who, select);
	}

	reachDirectory(
		locator: string,
		nick: import("../controller/session.ts").JoinNicknameIntent,
		defaultDirectory: string,
		signal?: AbortSignal,
	): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.reachDirectory(locator, JSON.stringify(nick), defaultDirectory, signal);
	}

	joinDestination(
		destination: import("../types.ts").RoomDestination,
		nick: import("../controller/session.ts").JoinNicknameIntent,
		defaultDirectory: string,
		signal?: AbortSignal,
	): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		const submitted = this.#remote.joinDestination(
			JSON.stringify(destination),
			JSON.stringify(nick),
			defaultDirectory,
			signal,
		);
		return submitted.then((snapshot) => waitForRoomAdmission(this, snapshot, signal));
	}

	takeRoomLink(link: string, label: string): Promise<boolean> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.takeRoomLink(link, label);
	}

	chooseRoom(directory: string, name: string, policy?: RoomPolicy): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.chooseRoom(directory, name, policy == null ? undefined : JSON.stringify(policy));
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
		return this.#command("openManagedRoom", [
			JSON.stringify(room),
			recoveryKey,
			policy.visibility,
			policy.entry,
			policy.speaking,
		]);
	}

	acceptInvitation(invitationId: string): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.acceptInvitation(invitationId);
	}

	dismissInvitation(invitationId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("dismissInvitation", [invitationId]);
	}

	setRoomTopic(conversationId: string, text: string): Promise<RoomsSessionSnapshot> {
		return this.#command("setRoomTopic", [conversationId, text]);
	}

	kickRoomMember(conversationId: string, nick: string): Promise<RoomsSessionSnapshot> {
		return this.#command("kickRoomMember", [conversationId, nick]);
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
		return this.#command("ensureRoomLink", [conversationId]);
	}

	takeRoomModerator(conversationId: string, sturdyref?: string): Promise<RoomsSessionSnapshot> {
		return this.#command(
			"takeRoomModerator",
			sturdyref == null ? [conversationId] : [conversationId, sturdyref],
		);
	}

	takeRoomManager(conversationId: string, sturdyref: string): Promise<RoomsSessionSnapshot> {
		return this.#command("takeRoomManager", [conversationId, sturdyref]);
	}

	recoverRoomManager(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("recoverRoomManager", [conversationId]);
	}

	dropRoomManager(conversationId: string, token: string): Promise<RoomsSessionSnapshot> {
		return this.#command("dropRoomManager", [conversationId, token]);
	}

	revokeManagedRoomAuthority(
		conversationId: string,
		kind: "room" | "steward",
		token: string,
	): Promise<RoomsSessionSnapshot> {
		return this.#command("revokeManagedRoomAuthority", [conversationId, kind, token]);
	}

	unregisterManagedRoom(conversationId: string): Promise<RoomsSessionSnapshot> {
		return this.#command("unregisterManagedRoom", [conversationId]);
	}

	setManagedRoomPolicy(conversationId: string, policy: RoomPolicy): Promise<RoomsSessionSnapshot> {
		return this.#command("setManagedRoomPolicy", [
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
		return this.#command("offerRoom", [roomConversationId, directConversationId]);
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

	replaceOperationsBundle(raw: string, advertisedTrace: string, context: string): Promise<RoomsSessionSnapshot> {
		return this.#command("replaceOperationsBundle", [raw, advertisedTrace, context]);
	}

	roomBridgeForm(conversationId: string): Promise<BridgeForm | null> {
		return this.#remote.roomBridgeForm(conversationId);
	}

	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		return this.#remote.readHistory(kind, directory, conversation);
	}

	runOperation(capability: string, action: string, args: string[] = []): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.operationsView.run(capability, action, args);
	}

	retireOperatorMatches(
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorRetireBatch> {
		if (this.#closed) return Promise.reject(new Error("This session is closed"));
		return this.#remote.operationsView.retire(category, query, limit, referenceKind);
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

	fetchAttachment(
		attachment: Attachment,
		onProgress?: (got: number) => void,
		signal?: AbortSignal,
	): Promise<AttachedFileData> {
		return this.#remote.fetchAttachment(attachment, onProgress, signal);
	}

	fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
		signal?: AbortSignal,
	): Promise<AttachedFileData> {
		return this.#remote.fetchArchivedAttachment(record, index, onProgress, signal);
	}

	releaseAttachment(attachment: Attachment): void {
		this.#remote.releaseAttachment(attachment);
	}

	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<RoomsSessionSnapshot> {
		return this.#serialize(async () => {
			await this.#remote.resolveEffect(operationId, outcome);
			return this.#feed.requireSnapshot();
		});
	}

	resumeEffect(operationId: string): Promise<RoomsSessionSnapshot> {
		return this.#serialize(async () => {
			await this.#remote.resumeEffect(operationId);
			return this.#feed.requireSnapshot();
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
			return grant;
		});
	}

	revokeGrant(id: string): Promise<void> {
		return this.#serialize(async () => {
			await this.#remote.revokeGrant(id);
		});
	}

	/** Change what an issued link carries. The feed is read again after, because
	 * the inventory this is administered from is part of what changed. */
	changeGrant(id: string, patch: RoomsSessionGrantPatch): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const grant = await this.#remote.changeGrant(id, patch);
			return grant;
		});
	}

	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		this.#feed.close();
		await this.#closeRemote();
	}

	#serialize<T>(work: () => Promise<T>): Promise<T> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms controller is closed"));
		return work();
	}

	/** Which operations this tab is currently answering for. */
	driving(): ReadonlySet<string> {
		return new Set(this.#closed ? [] : this.#remote.driving());
	}
}
