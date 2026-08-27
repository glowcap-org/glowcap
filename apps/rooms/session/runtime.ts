// Live directory connections and room memberships owned by a durable Rooms session.
import type { Runtime } from "@pancake/runtime";
import { type Message, Room } from "../lib/room_client.ts";
import { DurableRoomsArchive } from "./archive.ts";
import type { AttachmentSource } from "../lib/attachment.ts";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveCoordinates,
	type ArchiveRecord,
	type ErasableArchiveBackend,
} from "../lib/archive.ts";
import type { OperatorCategory, OperatorPage, OperatorRetireBatch, OperatorSnapshot } from "../lib/operator.ts";
import type { ArchiveLine } from "../lib/archive.ts";
import type { RoomsSessionState, WorkspaceConversation, WorkspaceDirectory } from "../lib/rooms_state.ts";
import type { RoomsSessionDirectoryView, RoomsSessionRoomView } from "../lib/rooms_session.ts";
import { type DurableOperationsSnapshot, DurableRoomsOperations } from "./operations.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import { refileSessionLine, sendSessionFiles } from "./file_mutation.ts";
import { DurableDirectLine } from "./direct_line.ts";
import { RoomsRuntimeIssues } from "./issues.ts";
import type { LiveDirectory } from "./live.ts";
import { ReconnectSchedule, roomsReconciliationNeedsRetry } from "./reconnect.ts";
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
import { makeRoomCallbacks, reconcileRooms, type RoomMessageReceiver } from "./room_reconcile.ts";
import { archiveShareFacet, DurableRoomsArchiveShares } from "./archive_shares.ts";
import { roomsDirectoryConnectionTopology } from "./topology.ts";
import {
	durableTypingTarget,
	realizeConversation as realizeLiveConversation,
	waitForLiveRealization,
} from "./realization.ts";
import { reconcileRoomStanding } from "./standing.ts";
import { connectDirectory } from "./directory_connection.ts";
import { projectDirectoryViews, projectRoomViews } from "./live_views.ts";
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

const RECONNECT_CONCURRENCY = 4;

export class DurableRoomsRuntime {
	readonly #runtime: Runtime;
	readonly #directories = new Map<string, LiveDirectory>();
	#tail: Promise<void> = Promise.resolve();
	readonly #operations: DurableRoomsOperations;
	readonly #viz: DurableRoomsViz;
	readonly #peering: DurableRoomsPeering;
	readonly #messages = new Set<RoomMessageReceiver>();
	readonly #issues = new RoomsRuntimeIssues();
	readonly #operationsInvalidated = new Set<(scope: string) => void>();
	readonly #invitations = new Set<DirectRealizationCallbacks["onInvitation"]>();
	readonly #archive: DurableRoomsArchive;
	readonly #archiveShares: DurableRoomsArchiveShares;
	readonly #emitDirect: DirectRealizationCallbacks["emit"];
	readonly #directCallbackSet: DirectRealizationCallbacks;
	#memberLocator: string | null = null;
	readonly #reconnect = new ReconnectSchedule<RoomsSessionState>();
	#roomViewNotifyTimer: ReturnType<typeof setTimeout> | null = null;
	#keepHistory = true;
	#closed = false;
	#closePromise: Promise<void> | null = null;

	constructor(runtime: Runtime, archiveSource: string, archiveBackend?: ErasableArchiveBackend) {
		this.#runtime = runtime;
		this.#operations = new DurableRoomsOperations(
			(subject, error) => this.#setIssue(subject, error),
			(scope) => {
				for (const invalidated of this.#operationsInvalidated) invalidated(scope);
			},
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
		this.#archiveShares = new DurableRoomsArchiveShares(this.#archive, () => this.#notifyStatus());
		this.#emitDirect = directEmitter(this.#archive, this.#messages, () => this.#keepHistory);
		this.#directCallbackSet = {
			setIssue: (subject, error) => this.#setIssue(subject, error),
			subjects: () => this.#issues.subjects(),
			receive: (held, conversationId, peer, text, attachments, session) =>
				receiveDirect(held, conversationId, peer, text, attachments, session, this.#emitDirect),
			emit: this.#emitDirect,
			onInvitation: (directory, label, link, from, locator, nick) =>
				notifyInvitations(this.#invitations, directory, label, link, from, locator, nick),
			cleanup,
			typing: directTypingEmitter(this.#messages),
			archiveShare: (held, owner, directory, conversation, archive, from, fromRegistrationId) =>
				this.#archiveShares.receive(held, owner, directory, conversation, archive, from, fromRegistrationId),
			closeConversation: (held, conversationId) =>
				this.#archiveShares.releaseConversation(held.id, conversationId),
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
		this.#reconnect.update(checkpoint, changed);
		if (!changed && historyClear == null) return this.#tail;
		return this.#enqueueReconcile(checkpoint, {
			realization: realizationChanged,
			standing: standingChanged,
			historyClear,
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
		work: { realization: boolean; standing: boolean; historyClear: Promise<void> | null } = {
			realization: true,
			standing: true,
			historyClear: null,
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
						this.#issues.subjects(),
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

	roomViews(): RoomsSessionRoomView[] {
		return projectRoomViews(this.#directories);
	}

	#notifyStatus(): void {
		this.#issues.notify();
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
		return this.#issues.set(subject, error);
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

	operatorSnapshot(scope: string, query = ""): Promise<OperatorSnapshot> {
		return this.#operations.operatorSnapshot(scope, query);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
	): Promise<OperatorRetireBatch> {
		return this.#operations.operatorRetireMatching(scope, category, query, limit);
	}

	operatorPage(scope: string, category: OperatorCategory, cursor: number, query = ""): Promise<OperatorPage> {
		return this.#operations.operatorPage(scope, category, cursor, query);
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

	async openPrivateRoom(directoryId: string, recoveryKey: string): Promise<string> {
		const held = this.#directories.get(directoryId);
		if (held == null) throw new Error("that directory is not connected in this Rooms session");
		return await held.directory.openPrivateLink(recoveryKey);
	}

	#room(conversationId: string): Room {
		for (const directory of this.#directories.values()) {
			const room = directory.roomRealization.rooms.get(conversationId)?.room;
			if (room != null) return room;
		}
		throw new Error("that room is not connected in this Rooms session");
	}

	async ensureRoomLink(conversationId: string): Promise<string> {
		return await this.#room(conversationId).link();
	}

	async takeRoomModerator(conversationId: string, stewardLink: string | null): Promise<string> {
		const room = this.#room(conversationId);
		if (stewardLink == null) {
			if (!(await room.claimSteward())) throw new Error("this room did not offer its moderator capability");
		} else await room.takeSteward(stewardLink);
		const roomLink = room.roomLink;
		const heldSteward = room.stewardLink;
		if (roomLink == null || heldSteward == null) {
			throw new Error("the room retained incomplete moderator authority");
		}
		return JSON.stringify({ roomLink, stewardLink: heldSteward });
	}

	async setRoomTopic(conversationId: string, text: string): Promise<void> {
		await this.#room(conversationId).setTopic(text);
	}

	async kickRoomMember(conversationId: string, nick: string): Promise<void> {
		await this.#room(conversationId).kick(nick);
	}

	async offerRoom(
		roomConversationId: string,
		directConversationId: string,
		label: string,
		link: string,
	): Promise<void> {
		const find = (): { direct: DurableDirectLine } | null => {
			for (const directory of this.#directories.values()) {
				if (!directory.roomRealization.rooms.has(roomConversationId)) continue;
				const direct = directory.directs.get(directConversationId);
				if (direct != null) return { direct };
			}
			return null;
		};
		let held = find();
		if (held == null) {
			held = await waitForLiveRealization(find, this.#tail);
		}
		if (held == null) throw new Error("the room and direct conversation are not realized in this Rooms session");
		await held.direct.line.offerRoom(label, link);
	}

	setTyping(conversationId: string, on: boolean): void {
		const target = durableTypingTarget(this.#directories, conversationId);
		if (target == null) return;
		if ("room" in target) void target.room.setTyping(on);
		else void target.direct.line.typing(on);
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

	async shareArchiveHistory(conversationId: string): Promise<void> {
		for (const held of this.#directories.values()) {
			const direct = held.directs.get(conversationId);
			if (direct == null) continue;
			const scope = {
				...ALL_ARCHIVE_RECORDS,
				kind: "line" as const,
				conversationKind: "direct" as const,
				directory: held.id,
				conversation: conversationId,
			};
			const facet = direct.line.spawn(archiveShareFacet(this.#archive, scope));
			try {
				await direct.line.handArchive(held.id, conversationId, facet);
			} finally {
				direct.line.releaseCapability(facet);
			}
			return;
		}
		throw new Error("that direct conversation is not connected in this Rooms session");
	}

	readArchiveShare(
		id: string,
		after: number,
	): Promise<{
		view: import("./archive_shares.ts").DurableArchiveShareView;
		page: import("../lib/archive.ts").ArchivePage;
	}> {
		return this.#archiveShares.read(id, after);
	}

	dropArchiveShare(id: string): void {
		this.#archiveShares.drop(id);
	}

	close(): Promise<void> {
		if (this.#closePromise != null) return this.#closePromise;
		this.#closePromise = this.#close();
		return this.#closePromise;
	}

	async #close(): Promise<void> {
		this.#closed = true;
		this.#reconnect.close();
		if (this.#roomViewNotifyTimer != null) clearTimeout(this.#roomViewNotifyTimer);
		this.#roomViewNotifyTimer = null;
		const cleanup = new RuntimeCleanupFailures(false);
		await cleanup.attempt("checkpoint work would not settle", () => this.#tail);
		await cleanup.attempt("visualizer would not close", () => this.#viz.close());
		// Publication leases must leave while their destination sessions can still
		// accept local release. The remaining owners close even if one release fails.
		await cleanup.attempt("peering would not close", () => this.#peering.close());
		await cleanup.attempt(
			"directories would not close",
			() => closeRuntimeDirectories(this.#directories, this.#operations, this.#archiveShares),
		);
		await cleanup.attempt("archive shares would not close", () => this.#archiveShares.close());
		await cleanup.attempt("archive would not close", () => this.#archive.close());
		await cleanup.attempt("network runtime would not close", () => this.#runtime.close());
		cleanup.finish();
	}

	#directoryClosed(held: LiveDirectory): void {
		if (this.#directories.get(held.id) !== held) return;
		this.#directories.delete(held.id);
		this.#operations.releaseFor(held.id);
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
		work: { realization: boolean; standing: boolean; historyClear: Promise<void> | null },
	): Promise<void> {
		if (work.historyClear != null) await work.historyClear;
		else await this.#archive.settleLocalErase();
		if (work.realization) await this.#reconcileRealization(checkpoint);
		if (work.standing) {
			await reconcileRoomStanding(
				checkpoint,
				this.#directories,
				(subject, error) => this.#setIssue(subject, error),
				this.#issues.subjects(),
			);
		}
	}

	async #reconcileRealization(checkpoint: RoomsSessionState): Promise<void> {
		const wanted = new Map(checkpoint.directories.map((directory) => [directory.id, directory]));
		const reconnect: WorkspaceDirectory[] = [];
		for (const [id, held] of this.#directories) {
			const saved = wanted.get(id);
			if (
				saved != null &&
				held.topology === roomsDirectoryConnectionTopology(saved)
			) continue;
			await this.#peering.releaseFor(id);
			this.#operations.releaseFor(id);
			this.#directories.delete(id);
			this.#notifyStatus();
			await closeRuntimeDirectory(held, this.#archiveShares);
			if (saved == null) {
				this.#setIssue(`directory:${id}`, null);
				this.#setIssue(`directory-view:${id}`, null);
			}
		}
		for (const saved of checkpoint.directories) {
			if (!this.#directories.has(saved.id)) reconnect.push(saved);
		}
		let next = 0;
		const worker = async () => {
			while (next < reconnect.length) {
				const saved = reconnect[next];
				next += 1;
				try {
					const connected = await this.#connect(saved, checkpoint.conversations);
					this.#directories.set(saved.id, connected);
					this.#notifyStatus();
					this.#setIssue(`directory:${saved.id}`, null);
				} catch (error) {
					if (this.#setIssue(`directory:${saved.id}`, error)) {
						console.error(
							`rooms session: could not restore ${saved.locator}: ${
								error instanceof Error ? error.message : error
							}`,
						);
					}
				}
			}
		};
		await Promise.all(Array.from({ length: Math.min(RECONNECT_CONCURRENCY, reconnect.length) }, worker));
		for (const saved of checkpoint.directories) {
			const held = this.#directories.get(saved.id);
			if (held != null) {
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
					}),
				);
				await reconcileDirects(held, checkpoint.conversations, this.#directCallbackSet);
			}
		}
		await this.#operations.reconcile(checkpoint, this.#directories);
		await this.#peering.reconcile(checkpoint, this.#directories);
		this.#viz.reconcile(checkpoint);
		await this.#archive.reconcile(checkpoint.capabilities.archivePeer);
	}
	async #connect(saved: WorkspaceDirectory, conversations: readonly WorkspaceConversation[]): Promise<LiveDirectory> {
		if (this.#memberLocator == null) throw new Error("the durable Rooms session listener is not ready");
		return await connectDirectory({
			runtime: this.#runtime,
			saved,
			conversations,
			memberLocator: this.#memberLocator,
			archive: this.#archive,
			keepHistory: () => this.#keepHistory,
			messages: this.#messages,
			directCallbacks: this.#directCallbackSet,
			releaseRoom: releaseRoomResources,
			onClosed: (live) => this.#directoryClosed(live),
			retry: () => this.#reconnect.schedule((current) => this.#enqueueReconcile(current)),
			notifyView: () => this.#scheduleRoomViewNotify(),
			setIssue: (subject, error) => this.#setIssue(subject, error),
			cleanup,
		});
	}
}
