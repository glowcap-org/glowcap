// Projection of one durable Rooms session into the existing presentation store.
//
// Checkpoint `direct` becomes presentation `dm`. Checkpoint conversation `id`
// becomes `persistId`; a room `name` or DM `peer` becomes presentation `id`.

import * as store from "../store.ts";
import { type ArchiveLine, sameArchiveCoordinates } from "../../../lib/archive/protocol.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { CapabilitySetEventSource } from "../ops/capability_set_events.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import { adoptAttachedSessionState } from "../workspace_state.ts";
import { archivedAttachmentViews } from "../archive_attachments.ts";
import { fetchesOnArrival } from "../media.ts";
import {
	type AttachmentView,
	type Conv,
	directoryLivePhase,
	dirId,
	isSessionConv,
	type SessionConv,
	silencedFrom,
} from "../types.ts";
import { AttachedLineProjection } from "./line_projection.ts";
import type { RoomsPageContext } from "../page.ts";
import type { RoomsSessionIssue, RoomsSessionLineEvent, RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type {
	RoomsSessionState,
	WorkspaceConversation,
	WorkspaceOperationCredential,
} from "../../../lib/rooms_state.ts";
type SelectionRepair =
	| { readonly kind: "unchanged" }
	| { readonly kind: "replaced"; readonly key: string | null };

const HISTORY_RECONCILE_CONCURRENCY = 4;

function sameOperations(
	left: readonly WorkspaceOperationCredential[],
	right: readonly WorkspaceOperationCredential[],
): boolean {
	return left.length === right.length && left.every((operation, index) => {
		const other = right[index];
		return other != null && operation.capability === other.capability && operation.scope === other.scope &&
			operation.swiss === other.swiss;
	});
}

function sameConversationTopology(left: WorkspaceConversation, right: WorkspaceConversation): boolean {
	if (left.kind !== right.kind || left.id !== right.id || left.directory !== right.directory) return false;
	if (left.kind === "direct" && right.kind === "direct") {
		return left.peer === right.peer && left.peerRegistrationId === right.peerRegistrationId;
	}
	if (left.kind !== "room" || right.kind !== "room") return false;
	return left.name === right.name && left.held === right.held &&
		(left.reconnect ?? null) === (right.reconnect ?? null) &&
		(left.publicationId ?? null) === (right.publicationId ?? null);
}

function sameTopology(left: RoomsSessionState, right: RoomsSessionState): boolean {
	return left.directories.length === right.directories.length &&
		left.directories.every((directory, index) => {
			const other = right.directories[index];
			return other != null && directory.id === other.id && directory.locator === other.locator &&
				directory.home === other.home && directory.nick === other.nick;
		}) &&
		left.conversations.length === right.conversations.length &&
		left.conversations.every((conversation, index) => {
			const other = right.conversations[index];
			return other != null && sameConversationTopology(conversation, other);
		});
}

function sameConversationIdentity(existing: SessionConv, intended: WorkspaceConversation): boolean {
	if (existing.persistId !== intended.id || existing.dir !== dirId(intended.directory)) return false;
	if (intended.kind === "direct") {
		return existing.type === "dm" && existing.id === intended.peer &&
			existing.peerRegistrationId === intended.peerRegistrationId;
	}
	return existing.type === "room" && existing.id === intended.name && existing.held === intended.held &&
		(existing.publicationId ?? null) === (intended.publicationId ?? null);
}

export class AttachedSessionProjection {
	readonly #page: RoomsPageContext;
	readonly #files: AttachedSessionFiles | null;
	readonly #capabilityEvents: CapabilitySetEventSource | null;
	readonly #lines: AttachedLineProjection;
	#topology: RoomsSessionState | null = null;
	#operations: readonly WorkspaceOperationCredential[] | null = null;
	readonly #keys = new Map<string, string>();
	readonly #historyLoads = new Map<string, symbol>();
	readonly #truncatedDirectories = new Set<string>();
	readonly #truncatedRooms = new Set<string>();
	#sessionDisconnected = false;
	#accessRevoked = false;
	#projectedActive: string | null | undefined;
	#pendingDraft: (conversationId: string) => string | undefined = () => undefined;
	/** Which of the session's pending operations this tab is answering for.
	 *
	 * Empty until a controller is bound, which is the safe way round: with
	 * nothing known to be driven, every pending operation is reported, and the
	 * page asks about operations it might have settled itself. The other way
	 * round it would stay silent about ones nobody is driving at all. */
	#driving: () => ReadonlySet<string> = () => new Set();

	constructor(
		page: RoomsPageContext,
		files: AttachedSessionFiles | null = null,
		capabilityEvents: CapabilitySetEventSource | null = null,
	) {
		this.#page = page;
		this.#files = files;
		this.#capabilityEvents = capabilityEvents;
		this.#lines = new AttachedLineProjection(
			(conversationId) => this.#keys.get(conversationId) ?? null,
			files,
			page,
		);
	}

	bind(controller: AttachedRoomsController): () => void {
		this.#pendingDraft = (conversationId) => controller.pendingDraft(conversationId);
		this.#driving = () => controller.driving();
		const stopSnapshot = controller.onSnapshot((snapshot) => {
			this.apply(snapshot);
			void this.#hydrate(controller, snapshot.checkpoint);
		});
		const stopLine = controller.onLine((event) => this.line(event));
		return () => {
			stopLine();
			stopSnapshot();
			this.#pendingDraft = () => undefined;
		};
	}

	apply(snapshot: RoomsSessionSnapshot): void {
		const session = snapshot.checkpoint;
		adoptAttachedSessionState(this.#page, session);
		const operations = session.capabilities.operations;
		if (this.#operations != null && !sameOperations(operations, this.#operations)) {
			void this.#capabilityEvents?.note();
		}
		this.#operations = operations;
		let selectionRepair: SelectionRepair = { kind: "unchanged" };
		if (this.#topology == null || !sameTopology(session, this.#topology)) {
			this.#topology = session;
			selectionRepair = this.#reconcileTopology(session);
		}
		const issues = new Map<string, RoomsSessionIssue>();
		let sessionIssue: RoomsSessionIssue | null = null;
		let accessIssue: RoomsSessionIssue | null = null;
		let archiveIssue: RoomsSessionIssue | null = null;
		const eventGaps = new Set<string>();
		for (const issue of snapshot.issues) {
			if (!issues.has(issue.subject)) issues.set(issue.subject, issue);
			if (sessionIssue == null && (issue.subject === "session" || issue.subject === "session-access")) {
				sessionIssue = issue;
			}
			if (accessIssue == null && issue.subject === "session-access") accessIssue = issue;
			if (archiveIssue == null && issue.subject === "archive") archiveIssue = issue;
			if (issue.subject.startsWith("event-gap:")) eventGaps.add(issue.subject.slice("event-gap:".length));
		}
		this.#projectDirectoryViews(snapshot);
		this.#projectRoomViews(session, snapshot, issues);
		if (accessIssue != null && !this.#accessRevoked) {
			store.toast(this.#page.projection, "failure", accessIssue.reason);
		}
		this.#accessRevoked = accessIssue != null;
		if (sessionIssue != null) this.#files?.markLost(sessionIssue.reason);
		const recovered = this.#sessionDisconnected && sessionIssue == null;
		this.#sessionDisconnected = sessionIssue != null;
		if (recovered) this.#historyLoads.clear();
		else for (const conversationId of eventGaps) this.#historyLoads.delete(conversationId);
		const connectedDirectories = new Set(snapshot.connectedDirectories);
		for (const directory of session.directories) {
			const issue = issues.get(`directory:${directory.id}`);
			if (issue != null) this.#files?.markLost(issue.reason, directory.id);
			const id = dirId(directory.id);
			const alreadyReached = this.#page.projection.get().dirs.get(id)?.reached === true;
			const live = directoryLivePhase(
				alreadyReached || (directory.reached ?? false),
				connectedDirectories.has(directory.id),
				sessionIssue?.reason ?? issue?.reason,
			);
			store.patchDir(this.#page.projection, id, {
				nick: live.session === "connected" ? directory.nick : "",
				session: live.session,
				statusText: live.statusText,
				...(live.session === "connected" ? { reached: true } : {}),
			});
		}
		this.#projectSharedState(
			session,
			// The ledger's leftovers, not everything in it. An operation this tab
			// is driving will settle, or fail where it was asked for, and until
			// then it is somebody's business already — the page carries the wait
			// on the control that started it. What reaches the store is what the
			// store says it holds: operations awaiting an explicit decision.
			// Sending a line is one of these operations, so without this the
			// notice appeared and left again on every message anybody sent.
			snapshot.pendingEffectDetails.filter((effect) => !this.#driving().has(effect.id)),
			snapshot.access,
			snapshot.suspendedNote ?? "",
			snapshot.grants,
			archiveIssue,
			issues,
			snapshot.archiveShares,
			snapshot.handedRooms,
			selectionRepair,
		);
	}

	#projectDirectoryViews(snapshot: RoomsSessionSnapshot): void {
		const views = new Map<string, RoomsSessionSnapshot["directoryViews"][number]>();
		for (const view of snapshot.directoryViews) views.set(view.directoryId, view);
		for (const directory of snapshot.checkpoint.directories) {
			const view = views.get(directory.id);
			store.resetDirectoryDiscovery(
				this.#page.projection,
				dirId(directory.id),
				view?.rooms ?? [],
				view?.peers ?? [],
			);
			if (view?.truncated === true && !this.#truncatedDirectories.has(directory.id)) {
				this.#truncatedDirectories.add(directory.id);
				store.noteTrouble(
					this.#page.projection,
					`shared directory ${directory.id}`,
					"Its live room and peer list reached the shared snapshot limit.",
				);
			} else if (view?.truncated !== true) this.#truncatedDirectories.delete(directory.id);
		}
		const wanted = new Set(snapshot.checkpoint.directories.map((directory) => directory.id));
		for (const directory of this.#truncatedDirectories) {
			if (!wanted.has(directory)) this.#truncatedDirectories.delete(directory);
		}
	}

	#projectRoomViews(
		session: RoomsSessionState,
		snapshot: RoomsSessionSnapshot,
		issues: ReadonlyMap<string, RoomsSessionIssue>,
	): void {
		const byConversation = new Map<string, RoomsSessionSnapshot["roomViews"][number]>();
		for (const view of snapshot.roomViews) byConversation.set(view.conversationId, view);
		const unnamedDirectories = new Set<string>();
		for (const directory of session.directories) if (directory.nick === "") unnamedDirectories.add(directory.id);
		const wanted = new Set<string>();
		for (const conversation of session.conversations) {
			if (conversation.kind !== "room") continue;
			wanted.add(conversation.id);
			const key = this.#keys.get(conversation.id);
			if (key == null) continue;
			const view = byConversation.get(conversation.id);
			const unnamed = unnamedDirectories.has(conversation.directory);
			const issue = issues.has(`room:${conversation.directory}:${conversation.id}`);
			store.setRoomMembership(
				this.#page.projection,
				key,
				view != null ? "joined" : issue || unnamed ? "unavailable" : "joining",
			);
			store.setRoomView(this.#page.projection, key, {
				members: view?.members ?? [],
				topic: view?.topic ?? null,
				lineBytes: view?.lineBytes ?? null,
				bridge: view?.bridge ?? null,
				canSetTopic: view?.canSetTopic ?? false,
				canModerate: view?.canModerate ?? false,
			});
			if (view != null) {
				store.setRoomPolicy(this.#page.projection, key, view.policy);
				store.setRoomMembershipKind(this.#page.projection, key, view.membershipKind);
			}
			if (view?.membersMore === true && !this.#truncatedRooms.has(conversation.id)) {
				this.#truncatedRooms.add(conversation.id);
				store.noteTrouble(
					this.#page.projection,
					`shared room ${conversation.id}`,
					"Its member list reached the shared snapshot limit.",
				);
			} else if (view?.membersMore !== true) this.#truncatedRooms.delete(conversation.id);
		}
		for (const room of this.#truncatedRooms) if (!wanted.has(room)) this.#truncatedRooms.delete(room);
	}

	line(event: RoomsSessionLineEvent): void {
		this.#lines.apply(event);
	}

	#reconcileTopology(session: RoomsSessionState): SelectionRepair {
		const selected = store.activeConv(this.#page.projection);
		let selectedReplaced = false;
		const wantedConversations = new Set(session.conversations.map((entry) => entry.id));
		const wantedDirectories = new Set(session.directories.map((entry) => dirId(entry.id)));
		for (const id of this.#historyLoads.keys()) if (!wantedConversations.has(id)) this.#historyLoads.delete(id);
		// A directory view is this tab's, not a checkpoint row. Forgetting every
		// persistId the session does not name would delete it on the next join.
		for (const conversation of this.#page.projection.get().convs.values()) {
			if (!isSessionConv(conversation)) {
				if (!wantedDirectories.has(conversation.dir)) {
					if (conversation.key === selected?.key) selectedReplaced = true;
					store.forgetConv(this.#page.projection, conversation.key);
				}
				continue;
			}
			if (!wantedConversations.has(conversation.persistId)) {
				if (conversation.key === selected?.key) selectedReplaced = true;
				store.forgetConv(this.#page.projection, conversation.key);
			}
		}
		for (const directory of this.#page.projection.get().dirs.keys()) {
			if (!wantedDirectories.has(directory)) store.forgetDir(this.#page.projection, directory);
		}
		for (const directory of session.directories) {
			const id = dirId(directory.id);
			store.openDir(this.#page.projection, id, directory.locator);
			const reached = directory.reached ?? false;
			store.patchDir(this.#page.projection, id, {
				requestedNick: directory.nick,
				nick: "",
				standing: directory.standing,
				reached,
				session: directoryLivePhase(reached, false, undefined).session,
			});
			if (directory.home) store.setHomeDir(this.#page.projection, id);
		}
		this.#keys.clear();
		const existingConversations = new Map<string, SessionConv>();
		for (const conversation of this.#page.projection.get().convs.values()) {
			if (isSessionConv(conversation)) existingConversations.set(conversation.persistId, conversation);
		}
		for (const conversation of session.conversations) {
			const existing = existingConversations.get(conversation.id);
			let restored: Conv | undefined = existing ?? undefined;
			if (existing != null && !sameConversationIdentity(existing, conversation)) {
				if (existing.key === selected?.key) selectedReplaced = true;
				store.forgetConv(this.#page.projection, existing.key);
				this.#historyLoads.delete(conversation.id);
				restored = undefined;
			}
			if (restored == null) restored = this.#restoreConversation(conversation) ?? undefined;
			if (restored != null) this.#keys.set(conversation.id, restored.key);
		}
		return selectedReplaced
			? {
				kind: "replaced",
				key: selected == null || !isSessionConv(selected) ? null : this.#keys.get(selected.persistId) ?? null,
			}
			: { kind: "unchanged" };
	}

	async #hydrate(controller: AttachedRoomsController, session: RoomsSessionState): Promise<void> {
		const pending = session.conversations.filter((conversation) =>
			!this.#historyLoads.has(conversation.id) && this.#keys.has(conversation.id)
		);
		let next = 0;
		const worker = async () => {
			while (next < pending.length) await this.#hydrateConversation(controller, pending[next++]);
		};
		await Promise.all(Array.from({ length: Math.min(HISTORY_RECONCILE_CONCURRENCY, pending.length) }, worker));
	}

	async #hydrateConversation(
		controller: AttachedRoomsController,
		conversation: WorkspaceConversation,
	): Promise<void> {
		const key = this.#keys.get(conversation.id);
		if (key == null || this.#historyLoads.has(conversation.id)) return;
		const token = Symbol(conversation.id);
		this.#historyLoads.set(conversation.id, token);
		const room = store.getConv(this.#page.projection, key);
		const awaitingHistory = room?.type === "room" && room.earlierHistory === "unasked";
		if (awaitingHistory) store.setEarlierHistory(this.#page.projection, key, "loading");
		try {
			const records = await controller.readHistory(
				conversation.kind,
				conversation.directory,
				conversation.id,
			);
			if (this.#historyLoads.get(conversation.id) !== token || this.#keys.get(conversation.id) !== key) {
				return;
			}
			const existing = store.historyOf(this.#page.projection, key)
				.filter((item) => item.kind === "chat" && item.history != null)
				.map((item) => item.kind === "chat" ? item.history : undefined);
			const seen = (record: ArchiveLine) =>
				existing.some((coordinate) => sameArchiveCoordinates(coordinate, record));
			const files = this.#files;
			const lines = records.filter((record): record is ArchiveLine =>
				record.kind === "line" && record.state !== "withdrawn"
			)
				.filter((record) => !seen(record))
				.sort((left, right) => left.at - right.at)
				.map((record) => ({
					from: record.from,
					text: record.text,
					mine: record.mine,
					at: record.at,
					history: { source: record.source, generation: record.generation, id: record.id },
					attachments: files == null
						? archivedAttachmentViews(record.attachments)
						: record.attachments.map((_attachment, index) => files.holdArchived(record, index)),
				}));
			if (lines.length > 0) {
				store.prependHistory(
					this.#page.projection,
					key,
					lines,
					"Earlier messages kept by the shared Rooms session archive",
				);
				for (const line of lines) {
					for (const attachment of line.attachments) {
						if (
							typeof (attachment as { id?: unknown }).id === "number" && attachment.lost !== true &&
							fetchesOnArrival(
								attachment,
								silencedFrom(line.from, line.mine, this.#page.projection.get().ignored),
							)
						) this.#files?.open(key, (attachment as AttachmentView).id);
					}
				}
			}
			if (awaitingHistory) {
				store.setEarlierHistory(this.#page.projection, key, lines.length === 0 ? "empty" : "shown");
			}
		} catch (error) {
			if (this.#historyLoads.get(conversation.id) !== token) return;
			this.#historyLoads.delete(conversation.id);
			if (awaitingHistory) store.setEarlierHistory(this.#page.projection, key, "unavailable");
			store.noteTrouble(
				this.#page.projection,
				"shared session archive",
				error instanceof Error ? error.message : String(error),
			);
		}
	}

	#restoreConversation(conversation: WorkspaceConversation) {
		const directory = dirId(conversation.directory);
		if (conversation.kind === "direct") {
			return store.restoreDm(
				this.#page.projection,
				directory,
				conversation.peer,
				conversation.peerRegistrationId,
				conversation.id,
				conversation.closed,
			);
		}
		return store.ensureRoom(this.#page.projection, directory, conversation.name, {
			persistId: conversation.id,
			key: conversation.held ? `held:${conversation.id}` : undefined,
			held: conversation.held,
			reconnect: conversation.reconnect,
			link: conversation.link,
			manager: conversation.manager,
			steward: conversation.steward,
			publicationId: conversation.publicationId,
			bridgeIntent: conversation.bridgeIntent,
		});
	}

	#projectSharedState(
		session: RoomsSessionState,
		sessionEffects: RoomsSessionSnapshot["pendingEffectDetails"],
		sessionAccess: RoomsSessionSnapshot["access"],
		suspendedNote: string,
		sessionGrants: RoomsSessionSnapshot["grants"],
		archiveIssue: { reason: string } | null,
		issues: ReadonlyMap<string, RoomsSessionIssue>,
		archiveShares: RoomsSessionSnapshot["archiveShares"],
		handedRooms: RoomsSessionSnapshot["handedRooms"],
		selectionRepair: SelectionRepair,
	): void {
		const current = this.#page.projection.get();
		const selectionChanged = this.#projectedActive === undefined || this.#projectedActive !== session.active;
		this.#projectedActive = session.active;
		const dirs = new Map(current.dirs);
		const convs = new Map(current.convs);
		const drafts = new Map<string, store.Draft>();
		for (const intended of session.directories) {
			const key = dirId(intended.id);
			const directory = dirs.get(key);
			if (directory != null && directory.standing !== intended.standing) {
				dirs.set(key, { ...directory, standing: intended.standing });
			}
		}
		for (const intended of session.conversations) {
			const key = this.#keys.get(intended.id);
			if (key == null) continue;
			const conversation = convs.get(key);
			if (conversation == null) continue;
			const localDraft = current.drafts.get(key);
			const text = this.#pendingDraft(intended.id) ?? intended.draft;
			if (text !== "" || localDraft != null) {
				drafts.set(key, { ...(localDraft ?? { files: [] }), text });
			}
			if (conversation.type === "room" && intended.kind === "room") {
				const {
					bridgeIntent: _bridgeIntent,
					link: _link,
					manager: _manager,
					reconnect: _reconnect,
					steward: _steward,
					...withoutIntent
				} = conversation;
				const bridgeIssue = issues.get(`room-bridge:${intended.directory}:${intended.id}`)?.reason ?? "";
				convs.set(
					key,
					{
						...withoutIntent,
						standing: intended.standing,
						bridgeIssue,
						...(intended.reconnect == null ? {} : { reconnect: intended.reconnect }),
						...(intended.link == null ? {} : { link: intended.link }),
						...(intended.manager == null ? {} : { manager: intended.manager }),
						...(intended.steward == null ? {} : { steward: intended.steward }),
						...(Object.hasOwn(intended, "bridgeIntent") ? { bridgeIntent: intended.bridgeIntent } : {}),
					},
				);
			} else if (conversation.type === "dm" && intended.kind === "direct") {
				const directIssue = issues.has(`direct:${intended.directory}:${intended.id}`);
				convs.set(key, {
					...conversation,
					line: intended.closed ? "closed" : directIssue ? "introducing" : conversation.line,
				});
			}
		}
		const directoryView = current.activeKey == null ? null : current.convs.get(current.activeKey);
		const sessionActiveKey = session.active == null ? null : this.#keys.get(session.active) ?? null;
		this.#page.projection.set({
			dirs,
			convs,
			drafts,
			invites: [
				...session.invitations.map((invitation) => ({
					id: invitation.id,
					dir: dirId(invitation.directory),
					locator: invitation.locator,
					nick: invitation.nick,
					way: "link" as const,
					label: invitation.label,
					from: invitation.from,
					link: invitation.link,
				})),
				...handedRooms.map((invitation) => ({
					id: invitation.id,
					dir: dirId(invitation.directory),
					way: "handed" as const,
					label: invitation.label,
					from: invitation.from,
					link: "",
				})),
			],
			activeKey: directoryView != null && !isSessionConv(directoryView)
				? current.activeKey
				: selectionChanged
				? sessionActiveKey
				: selectionRepair.kind === "replaced"
				? selectionRepair.key
				: current.activeKey,
			standing: session.standing,
			ignored: new Set(session.ignored),
			keepHistory: session.keepHistory,
			remembered: { ...session.join },
			sessionEffects,
			sessionAccess,
			sessionSuspendedNote: suspendedNote,
			sessionGrants,
			archiveShares: archiveShares.flatMap((share) => {
				const conversationKey = this.#keys.get(share.conversationId);
				return conversationKey == null ? [] : [{
					id: share.id,
					conversationKey,
					from: share.from,
					status: share.status,
					error: share.error,
					kind: share.kind,
					scopeConversation: share.scopeConversation,
					custody: share.custody,
					sturdyref: share.sturdyref,
				}];
			}),
		});
		const archivePeer = session.capabilities.archivePeer;
		store.setArchiveTarget(
			this.#page.projection,
			archivePeer == null ? { kind: "owned", owner: "session" } : {
				owner: "session",
				kind: "peer",
				status: archiveIssue == null ? "connected" : "unavailable",
				label: "Shared session archive peer",
				remembered: true,
				error: archiveIssue?.reason ?? "",
			},
		);
	}
}
