// Live directory connections and room memberships owned by a durable Rooms session.
import type { Runtime } from "@pancake/runtime";
import type { Message } from "../lib/room/client.ts";
import { DurableRoomsArchive } from "./archive.ts";
import type { AttachmentSource } from "../lib/attachment.ts";
import {
	type ArchiveCoordinates,
	type ArchiveLine,
	type ArchiveRecord,
	type ErasableArchiveBackend,
} from "../lib/archive/protocol.ts";
import type {
	OperatorCategory,
	OperatorPage,
	OperatorReferenceKind,
	OperatorRetireBatch,
	OperatorSnapshot,
} from "../lib/operator.ts";
import type { RoomsSessionState, WorkspaceDirectory } from "../lib/rooms_state.ts";
import type { RoomsSessionDirectoryView, RoomsSessionRoomView } from "../lib/session/client.ts";
import { type DurableOperationsSnapshot, DurableRoomsOperations } from "./operations.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import { refileSessionLine, sendSessionFiles } from "./file_mutation.ts";
import { RoomsRuntimeIssues } from "./issues.ts";
import type { LiveDirectory } from "./live.ts";
import { ReconciliationBlocked, ReconnectSchedule, roomsReconciliationNeedsRetry } from "./reconnect.ts";
import { DurableRoomsViz, type DurableVizSnapshot } from "./viz.ts";
import { type DurablePeeringPublication, DurableRoomsPeering } from "./peering.ts";
import {
	directEmitter,
	type DirectRealizationCallbacks,
	directTypingEmitter,
	notifyInvitations,
	receiveDirect,
	reconcileDirects,
	sendDirectFiles,
} from "./directory_directs.ts";
import { makeRoomCallbacks, reconcileRooms } from "./room_reconcile.ts";
import type { ConversationEventObserver } from "./conversation_events.ts";
import { archiveShareCallbacks, DurableRoomsArchiveShares, redeemArchiveShare } from "./archive_shares.ts";
import { realizeConversation as realizeLiveConversation } from "./realization.ts";
import { reconcileRoomStanding } from "./standing.ts";
import { connectDirectory } from "./directory_connection.ts";
import { projectDirectoryViews, projectRoomViews, roomBridgeScope } from "./live_views.ts";
import type { RoomsCheckpointImpact } from "./commands.ts";
import {
	editConversationLine,
	requireConversationRealization,
	sayInConversation,
	withdrawConversationLine,
} from "./conversation_effects.ts";
import {
	cleanupRuntime as cleanup,
	closeRuntimeDirectories,
	closeRuntimeDirectory,
	releaseRoomResources,
	RuntimeCleanupFailures,
} from "./runtime_cleanup.ts";
import type { RoomAuthorityRetirement, RuntimeStateReconciliation } from "./state_sync.ts";
import { acceptDirectConversation, RuntimeStateSync } from "./runtime_state_sync.ts";
import { DurableRoomActions } from "./runtime_room_actions.ts";
import {
	reconcileRuntimeDirectories,
	roomPublicationId,
	unresolvedRoomPublication,
} from "./runtime_directory_reconcile.ts";
import { RoomBridgeSecrets } from "./bridge_secrets.ts";
import { DurableHandedRooms } from "./handed_rooms.ts";

export class DurableRoomsRuntime {
	readonly #runtime: Runtime;
	readonly #directories = new Map<string, LiveDirectory>();
	#tail: Promise<void> = Promise.resolve();
	readonly #operations: DurableRoomsOperations;
	readonly roomActions: DurableRoomActions;
	readonly #viz: DurableRoomsViz;
	readonly #peering: DurableRoomsPeering;
	readonly #messages = new Set<ConversationEventObserver>();
	readonly #issues = new RoomsRuntimeIssues();
	readonly #operationsInvalidated = new Set<(scope: string) => void>();
	readonly #invitations = new Set<DirectRealizationCallbacks["onInvitation"]>();
	readonly bridgeSecrets = new RoomBridgeSecrets();
	readonly #archive: DurableRoomsArchive;
	readonly #archiveShares: DurableRoomsArchiveShares;
	readonly handedRooms: DurableHandedRooms;
	readonly #stateSync: RuntimeStateSync;
	readonly #emitDirect: DirectRealizationCallbacks["emit"];
	readonly #directCallbackSet: DirectRealizationCallbacks;
	#memberLocator: string | null = null;
	readonly #reconnect = new ReconnectSchedule<RoomsSessionState>();
	#roomViewNotifyTimer: ReturnType<typeof setTimeout> | null = null;
	#keepHistory = true;
	#realizationGeneration = 0;
	#closed = false;
	#closePromise: Promise<void> | null = null;
	readonly #ownsRuntime: boolean;

	constructor(
		runtime: Runtime,
		archiveSource: string,
		reconcileState: (change: RuntimeStateReconciliation) => Promise<void>,
		archiveBackend?: ErasableArchiveBackend,
		options?: { readonly ownsRuntime?: boolean },
	) {
		this.#runtime = runtime;
		this.#ownsRuntime = options?.ownsRuntime ?? true;
		this.#stateSync = new RuntimeStateSync(
			reconcileState,
			(subject, error) => this.#setIssue(subject, error),
		);
		this.#operations = new DurableRoomsOperations(
			(subject, error) => this.#setIssue(subject, error),
			(scope) => {
				for (const invalidated of this.#operationsInvalidated) invalidated(scope);
			},
		);
		this.roomActions = new DurableRoomActions(
			this.#directories,
			(directoryId, identity) => this.#operations.issueRoomManager(directoryId, identity),
		);
		this.#viz = new DurableRoomsViz(
			(subject, error) => this.#setIssue(subject, error),
			(scope) => {
				for (const invalidated of this.#operationsInvalidated) invalidated(scope);
			},
		);
		this.#peering = new DurableRoomsPeering(
			(subject, error) => this.#setIssue(subject, error),
			(scope) => this.#operationsInvalidated.forEach((invalidated) => invalidated(scope)),
		);
		this.#archive = new DurableRoomsArchive(
			runtime,
			archiveSource,
			(error) => this.#setIssue("archive", error),
			archiveBackend,
		);
		this.#archiveShares = new DurableRoomsArchiveShares(
			this.#archive,
			() => this.#notifyStatus(),
			redeemArchiveShare(runtime),
		);
		this.handedRooms = new DurableHandedRooms(() => this.#notifyStatus());
		this.#emitDirect = directEmitter(this.#archive, this.#messages, () => this.#keepHistory);
		this.#directCallbackSet = {
			setIssue: (subject, error) => this.#setIssue(subject, error),
			subjects: () => this.#issues.subjects(),
			receive: (held, conversationId, peer, text, attachments, session) =>
				receiveDirect(held, conversationId, peer, text, attachments, session, this.#emitDirect),
			emit: this.#emitDirect,
			onInvitation: (directory, label, link, from, locator, nick) =>
				notifyInvitations(this.#invitations, directory, label, link, from, locator, nick),
			handRoom: (held, owner, label, room, from) => this.handedRooms.receive(held.id, owner, label, room, from),
			cleanup,
			typing: directTypingEmitter(this.#messages),
			...archiveShareCallbacks(this.#archiveShares),
			acceptDirect: (held, peer, peerRegistrationId) =>
				acceptDirectConversation(this.#stateSync, held, peer, peerRegistrationId, () => this.settled()),
			routeChanged: () => this.#notifyStatus(),
		};
	}

	setMemberLocator(locator: string): void {
		if (this.#memberLocator != null && this.#memberLocator !== locator) {
			throw new Error("the durable Rooms session listener locator cannot change while running");
		}
		this.#memberLocator = locator;
	}

	reconcile(checkpoint: RoomsSessionState, impact: RoomsCheckpointImpact = "realization"): Promise<void> {
		if (this.#closed) return this.#closePromise ?? Promise.resolve();
		const eraseHistory = this.#keepHistory && !checkpoint.keepHistory;
		const historyClear = eraseHistory ? this.#archive.clearLocal() : null;
		this.#keepHistory = checkpoint.keepHistory;
		const realizationChanged = impact === "realization";
		const standingChanged = realizationChanged || impact === "standing";
		const changed = realizationChanged || standingChanged;
		if (realizationChanged) {
			this.#realizationGeneration += 1;
			for (const held of this.#directories.values()) {
				held.roomRealization.expectEvents(held.id, checkpoint.conversations);
			}
		}
		this.#reconnect.update(checkpoint, changed);
		if (!changed && historyClear == null) return this.#tail;
		return this.#enqueueReconcile(checkpoint, {
			realization: realizationChanged,
			standing: standingChanged,
			historyClear,
			generation: this.#realizationGeneration,
		});
	}

	/** Wait for every checkpoint reconciliation already admitted by the state
	 * observer. This does not wait for scheduled reconnect retries; one completed
	 * attempt plus its issue state is the result an administration command can
	 * report. */
	settled(): Promise<void> {
		return this.#tail;
	}

	#enqueueReconcile(
		checkpoint: RoomsSessionState,
		work: { realization: boolean; standing: boolean; historyClear: Promise<void> | null; generation: number } = {
			realization: true,
			standing: true,
			historyClear: null,
			generation: this.#realizationGeneration,
		},
	): Promise<void> {
		const run = this.#tail.then(() => this.#reconcile(checkpoint, work));
		this.#tail = run.then(
			() => {
				this.#setIssue("runtime", null);
				this.#reconnect.settled(
					roomsReconciliationNeedsRetry(
						this.#reconnect.current,
						this.#directories,
						this.#issues.retryableSubjects(),
						this.#closed,
					),
					(current) => this.#enqueueReconcile(current),
				);
			},
			(error) => {
				this.#setIssue("runtime", error);
				this.#reconnect.schedule((current) => this.#enqueueReconcile(current));
			},
		);
		return run;
	}

	onMessage(
		receive: (
			conversationId: string,
			message: Message,
			editable: boolean,
			files: RuntimeAttachment[],
			history: ArchiveCoordinates | null,
		) => void,
	): () => void {
		this.#messages.add(receive);
		return () => this.#messages.delete(receive);
	}

	onStatus(changed: () => void): () => void {
		return this.#issues.onChange(changed);
	}

	onOperationsInvalidated(invalidated: (scope: string) => void): () => void {
		this.#operationsInvalidated.add(invalidated);
		return () => this.#operationsInvalidated.delete(invalidated);
	}

	onInvitation(
		received: (
			directory: string,
			label: string,
			link: string,
			from: string,
			locator: string,
			nick: string,
		) => Promise<void> | void,
	): () => void {
		this.#invitations.add(received);
		return () => this.#invitations.delete(received);
	}

	issues(): { subject: string; reason: string }[] {
		return this.#issues.list();
	}

	connectedDirectories(): string[] {
		return [...this.#directories.keys()];
	}

	memberLocator(): string | null {
		return this.#memberLocator;
	}

	directoryViews(): RoomsSessionDirectoryView[] {
		return projectDirectoryViews(this.#directories);
	}

	roomPublicationId(directoryId: string, roomName: string): string | null {
		return roomPublicationId(this.#directories, directoryId, roomName);
	}

	roomViews(): RoomsSessionRoomView[] {
		return projectRoomViews(this.#directories);
	}

	roomBridgeScope(conversationId: string): string | null {
		return roomBridgeScope(this.#directories, conversationId);
	}

	#notifyStatus(): void {
		this.#issues.notify();
	}

	#synchronizeRoomAuthority(retired: RoomAuthorityRetirement): Promise<void> {
		return this.#synchronizeState({ type: "room-authority", ...retired });
	}

	#synchronizeState(change: RuntimeStateReconciliation): Promise<void> {
		return this.#stateSync.submit(change);
	}

	/** Room facts are live presentation state, not checkpoint state. Coalesce a
	 * burst of roster/topic notifications into one snapshot turn so attached
	 * views see the applied reducer without making one fan-out per line. */
	#scheduleRoomViewNotify(): void {
		if (this.#roomViewNotifyTimer != null) return;
		this.#roomViewNotifyTimer = setTimeout(() => {
			this.#roomViewNotifyTimer = null;
			if (!this.#closed) this.#notifyStatus();
		}, 0);
	}

	#setIssue(subject: string, error: unknown | null): boolean {
		return this.#issues.set(subject, error, !(error instanceof ReconciliationBlocked));
	}

	requireConversation(kind: "room" | "direct", conversationId: string): void {
		requireConversationRealization(this.#directories, kind, conversationId);
	}

	/** Realize one explicit user target without making intended direct state dial
	 * on restore. Network waiting happens outside the checkpoint serializer. */
	async realizeConversation(kind: "room" | "direct", conversationId: string): Promise<void> {
		await realizeLiveConversation(
			this.#directories,
			this.#tail,
			this.#directCallbackSet,
			kind,
			conversationId,
		);
	}

	async say(kind: "room" | "direct", conversationId: string, text: string): Promise<void> {
		await sayInConversation(this.#directories, this.#emitDirect, kind, conversationId, text);
	}

	async editLine(conversationId: string, lineId: number, text: string): Promise<void> {
		await editConversationLine(this.#directories, this.#emitDirect, conversationId, lineId, text);
	}

	async withdrawLine(conversationId: string, lineId: number): Promise<void> {
		await withdrawConversationLine(this.#directories, this.#emitDirect, conversationId, lineId);
	}

	async unregisterManagedRoom(conversationId: string): Promise<void> {
		await this.roomActions.unregister(conversationId);
	}

	operatorEffect(scope: string, action: string, args: string[]): () => Promise<void> {
		return this.#operations.operatorEffect(scope, action, args);
	}

	operationsSnapshot(
		scope: string,
		capability: DurableOperationsSnapshot["capability"],
	): Promise<DurableOperationsSnapshot> {
		return this.#operations.snapshot(scope, capability);
	}

	vizSnapshot(scope: string): DurableVizSnapshot {
		return this.#viz.snapshot(scope);
	}

	peeringSnapshot(scope: string): DurablePeeringPublication[] {
		return this.#peering.snapshot(
			(this.#reconnect.current?.peering ?? []).filter((intent) => intent.destination === scope),
		);
	}

	operationsEffect(scope: string, capability: string, action: string, args: string[]): () => Promise<void> {
		return this.#operations.operationEffect(scope, capability, action, args);
	}

	operatorSnapshot(
		scope: string,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorSnapshot> {
		return this.#operations.operatorSnapshot(scope, query, referenceKind);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorRetireBatch> {
		return this.#operations.operatorRetireMatching(scope, category, query, limit, referenceKind);
	}

	operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorPage> {
		return this.#operations.operatorPage(scope, category, cursor, query, referenceKind);
	}

	async sendFiles(conversationId: string, caption: string, files: AttachmentSource[]): Promise<void> {
		return await sendSessionFiles(
			this.#directories,
			(held, id, text, sources) => sendDirectFiles(held, id, text, sources, this.#emitDirect),
			conversationId,
			caption,
			files,
		);
	}

	async refileLine(
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		files: AttachmentSource[],
	): Promise<void> {
		return await refileSessionLine(
			this.#directories,
			this.#emitDirect,
			conversationId,
			lineId,
			caption,
			keep,
			files,
		);
	}

	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		return this.#archive.read(kind, directory, conversation);
	}

	readArchivedAttachment(record: ArchiveLine, index: number) {
		return this.#archive.attachment(record, index);
	}

	prepareArchive(sturdyref: string): Promise<void> {
		return this.#archive.prepare(sturdyref);
	}

	archiveShares(): import("./archive_shares.ts").DurableArchiveShareView[] {
		return this.#archiveShares.list();
	}

	shareArchiveHistory(
		kind: import("../lib/archive/handover.ts").ArchiveShareKind,
		conversationId: string,
		peer = "",
	): Promise<void> {
		const checkpoint = this.#reconnect.current;
		if (checkpoint == null) throw new Error("this Rooms session has no workspace yet");
		return this.#archiveShares.offer(
			this.#directories,
			checkpoint.conversations,
			kind,
			conversationId,
			peer,
			(directId) => this.realizeConversation("direct", directId),
		);
	}

	offerDurableArchive(
		kind: import("../lib/archive/handover.ts").ArchiveShareKind,
		conversationId: string,
		peer = "",
	): Promise<void> {
		const checkpoint = this.#reconnect.current;
		if (checkpoint == null) throw new Error("this Rooms session has no workspace yet");
		return this.#archiveShares.offerDurable(
			this.#directories,
			checkpoint.conversations,
			kind,
			conversationId,
			peer,
			(directId) => this.realizeConversation("direct", directId),
		);
	}

	listIssuedArchiveShares(): Promise<import("../lib/archive/facet.ts").ArchiveDurableShareView[]> {
		return this.#archive.listShares();
	}

	revokeIssuedArchiveShare(id: string): Promise<boolean> {
		return this.#archive.revokeShare(id);
	}

	readArchiveShare(
		id: string,
		after: number,
	): Promise<{
		view: import("./archive_shares.ts").DurableArchiveShareView;
		page: import("../lib/archive/protocol.ts").ArchivePage;
	}> {
		return this.#archiveShares.read(id, after);
	}

	dropArchiveShare(id: string): void {
		this.#archiveShares.drop(id);
	}

	close(): Promise<void> {
		return this.#closePromise ??= this.#close();
	}

	async #close(): Promise<void> {
		this.#closed = true;
		this.bridgeSecrets.clear();
		this.#reconnect.close();
		if (this.#roomViewNotifyTimer != null) clearTimeout(this.#roomViewNotifyTimer);
		this.#roomViewNotifyTimer = null;
		const cleanup = new RuntimeCleanupFailures(false);
		await cleanup.attempt("checkpoint work would not settle", () => this.#tail);
		await cleanup.attempt("state synchronization would not settle", () => this.#stateSync.close());
		await cleanup.attempt("visualizer would not close", () => this.#viz.close());
		// Publication leases must leave while their destination sessions can still
		// accept local release. The remaining owners close even if one release fails.
		await cleanup.attempt("peering would not close", () => this.#peering.close());
		await cleanup.attempt("handed rooms would not close", () => this.handedRooms.close());
		await cleanup.attempt(
			"directories would not close",
			() => closeRuntimeDirectories(this.#directories, this.#operations, this.#archiveShares),
		);
		await cleanup.attempt("archive shares would not close", () => this.#archiveShares.close());
		await cleanup.attempt("archive would not close", () => this.#archive.close());
		const closeNetwork = () => this.#ownsRuntime ? this.#runtime.close() : Promise.resolve();
		await cleanup.attempt("network runtime would not close", closeNetwork);
		cleanup.finish();
	}

	#directoryClosed(held: LiveDirectory): void {
		if (this.#directories.get(held.id) !== held) return;
		this.#directories.delete(held.id);
		this.#operations.releaseFor(held.id);
		this.handedRooms.releaseDirectory(held.id);
		this.#setIssue(`directory-view:${held.id}`, null);
		this.#notifyStatus();
		this.#setIssue(`directory:${held.id}`, "the directory connection closed");
		void cleanup(
			(async () => {
				await this.#peering.releaseFor(held.id);
				await closeRuntimeDirectory(held, this.#archiveShares);
			})(),
			"a disconnected directory would not close",
		).finally(() => this.#reconnect.schedule((current) => this.#enqueueReconcile(current)));
	}

	async #reconcile(
		checkpoint: RoomsSessionState,
		work: { realization: boolean; standing: boolean; historyClear: Promise<void> | null; generation: number },
	): Promise<void> {
		if (work.historyClear != null) await work.historyClear;
		else await this.#archive.settleLocalErase();
		if (work.realization) await this.#reconcileRealization(checkpoint, work.generation);
		if (work.generation !== this.#realizationGeneration) return;
		if (work.standing) {
			await reconcileRoomStanding(
				checkpoint,
				this.#directories,
				(subject, error) => this.#setIssue(subject, error),
				this.#issues.subjects(),
			);
		}
	}

	async #reconcileRealization(checkpoint: RoomsSessionState, generation: number): Promise<void> {
		const current = () => generation === this.#realizationGeneration;
		if (
			!await reconcileRuntimeDirectories({
				wanted: checkpoint.directories,
				live: this.#directories,
				current,
				release: async (id) => {
					await this.#peering.releaseFor(id);
					this.#operations.releaseFor(id);
				},
				connect: (saved) => this.#connect(saved),
				close: (held) => closeRuntimeDirectory(held, this.#archiveShares),
				changed: () => this.#notifyStatus(),
				setIssue: (subject, error) => this.#setIssue(subject, error),
			})
		) return;
		for (const saved of checkpoint.directories) {
			if (generation !== this.#realizationGeneration) return;
			const held = this.#directories.get(saved.id);
			if (held != null) {
				const publication = unresolvedRoomPublication(checkpoint.conversations, held);
				if (publication != null) {
					await this.#synchronizeState(publication);
					return;
				}
				await reconcileRooms(
					held.roomRealization,
					held,
					checkpoint.conversations,
					makeRoomCallbacks({
						held,
						archive: this.#archive,
						keepHistory: () => this.#keepHistory,
						receivers: this.#messages,
						release: releaseRoomResources,
						retry: () => this.#reconnect.schedule((current) => this.#enqueueReconcile(current)),
						notifyView: () => this.#scheduleRoomViewNotify(),
						setIssue: (subject, error) => this.#setIssue(subject, error),
						cleanup,
						reconcileAuthority: (retired) => this.#synchronizeRoomAuthority(retired),
						reconcileAcquisition: (acquired) => this.#synchronizeState(acquired),
						reconcileReconnect: (result) => this.#synchronizeState(result),
						current,
						bridgeSecrets: (directoryId, scope) => this.bridgeSecrets.answers(directoryId, scope),
					}),
				);
				if (generation !== this.#realizationGeneration) return;
				await reconcileDirects(held, checkpoint.conversations, this.#directCallbackSet);
			}
		}
		await this.#operations.reconcile(checkpoint, this.#directories);
		if (!current()) return;
		await this.#peering.reconcile(checkpoint, this.#directories);
		if (!current()) return;
		this.#viz.reconcile(checkpoint);
		await this.#archive.reconcile(checkpoint.capabilities.archivePeer);
	}
	async #connect(saved: WorkspaceDirectory): Promise<LiveDirectory> {
		if (this.#memberLocator == null) throw new Error("the durable Rooms session listener is not ready");
		return await connectDirectory({
			runtime: this.#runtime,
			saved,
			memberLocator: this.#memberLocator,
			directCallbacks: this.#directCallbackSet,
			releaseRoom: releaseRoomResources,
			onClosed: (live) => this.#directoryClosed(live),
			notifyView: () => this.#scheduleRoomViewNotify(),
			roomPublicationsChanged: () => {
				const checkpoint = this.#reconnect.current;
				if (checkpoint != null) void this.#enqueueReconcile(checkpoint);
			},
			setIssue: (subject, error) => this.#setIssue(subject, error),
			cleanup,
			reconcileState: (change) => this.#synchronizeState(change),
		});
	}
}
