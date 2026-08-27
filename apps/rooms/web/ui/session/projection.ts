// Projection of one durable Rooms session into the existing presentation store.

import type { RoomsSessionIssue, RoomsSessionLineEvent, RoomsSessionSnapshot } from "../../../lib/rooms_session.ts";
import type {
	RoomsSessionState,
	WorkspaceConversation,
	WorkspaceOperationCredential,
} from "../../../lib/rooms_state.ts";
import { type ArchiveLine, sameArchiveCoordinates } from "../../../lib/archive.ts";
import * as store from "../store.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { noteCapabilitySetChanged } from "../ops/capability_set_events.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import { adoptAttachedSessionState } from "../workspace_state.ts";
import { archivedAttachmentViews } from "../archive_attachments.ts";
import { fetchesOnArrival } from "../media.ts";
import { type AttachmentView, type Conv, dirId, silencedFrom } from "../types.ts";
import { AttachedLineProjection } from "./line_projection.ts";

type SelectionRepair =
	| { readonly kind: "unchanged" }
	| { readonly kind: "replaced"; readonly key: string | null };

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

function sameConversationIdentity(existing: Conv, intended: WorkspaceConversation): boolean {
	if (existing.persistId !== intended.id || existing.dir !== dirId(intended.directory)) return false;
	if (intended.kind === "direct") {
		return existing.type === "dm" && existing.id === intended.peer &&
			existing.peerRegistrationId === intended.peerRegistrationId;
	}
	return existing.type === "room" && existing.id === intended.name && existing.held === intended.held &&
		(existing.publicationId ?? null) === (intended.publicationId ?? null);
}

export class AttachedSessionProjection {
	readonly #files: AttachedSessionFiles | null;
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

	constructor(files: AttachedSessionFiles | null = null) {
		this.#files = files;
		this.#lines = new AttachedLineProjection((conversationId) => this.#keys.get(conversationId) ?? null, files);
	}

	bind(controller: AttachedRoomsController): () => void {
		this.#pendingDraft = (conversationId) => controller.pendingDraft(conversationId);
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
		adoptAttachedSessionState(session);
		const operations = session.capabilities.operations;
		if (this.#operations != null && !sameOperations(operations, this.#operations)) void noteCapabilitySetChanged();
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
		let eventGap = false;
		for (const issue of snapshot.issues) {
			if (!issues.has(issue.subject)) issues.set(issue.subject, issue);
			if (sessionIssue == null && (issue.subject === "session" || issue.subject === "session-access")) {
				sessionIssue = issue;
			}
			if (accessIssue == null && issue.subject === "session-access") accessIssue = issue;
			if (archiveIssue == null && issue.subject === "archive") archiveIssue = issue;
			if (issue.subject === "event-gap") eventGap = true;
		}
		this.#projectDirectoryViews(snapshot);
		this.#projectRoomViews(session, snapshot, issues);
		if (accessIssue != null && !this.#accessRevoked) store.toast("failure", accessIssue.reason);
		this.#accessRevoked = accessIssue != null;
		if (sessionIssue != null) this.#files?.markLost(sessionIssue.reason);
		const recovered = this.#sessionDisconnected && sessionIssue == null;
		this.#sessionDisconnected = sessionIssue != null;
		if (recovered || eventGap) this.#historyLoads.clear();
		const connectedDirectories = new Set(snapshot.connectedDirectories);
		for (const directory of session.directories) {
			const issue = issues.get(`directory:${directory.id}`);
			if (issue != null) this.#files?.markLost(issue.reason, directory.id);
			const connected = connectedDirectories.has(directory.id);
			store.patchDir(
				dirId(directory.id),
				sessionIssue != null
					? { nick: "", session: "disconnected", statusText: sessionIssue.reason }
					: issue != null
					? { nick: "", session: "disconnected", statusText: issue.reason }
					: connected
					? { nick: directory.nick, session: "connected", statusText: "" }
					: { nick: "", session: "reconnecting", statusText: "" },
			);
		}
		this.#projectSharedState(
			session,
			snapshot.pendingEffectDetails,
			snapshot.access,
			snapshot.grants,
			archiveIssue,
			issues,
			snapshot.archiveShares,
			selectionRepair,
		);
	}

	#projectDirectoryViews(snapshot: RoomsSessionSnapshot): void {
		const views = new Map<string, RoomsSessionSnapshot["directoryViews"][number]>();
		for (const view of snapshot.directoryViews) views.set(view.directoryId, view);
		for (const directory of snapshot.checkpoint.directories) {
			const view = views.get(directory.id);
			store.resetDirectoryDiscovery(dirId(directory.id), view?.rooms ?? [], view?.peers ?? []);
			if (view?.truncated === true && !this.#truncatedDirectories.has(directory.id)) {
				this.#truncatedDirectories.add(directory.id);
				store.noteTrouble(
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
			store.setRoomMembership(key, view != null ? "joined" : issue || unnamed ? "unavailable" : "joining");
			store.setRoomView(
				key,
				view?.members ?? [],
				view?.topic ?? null,
				view?.lineBytes ?? null,
				view?.canSetTopic ?? false,
				view?.canModerate ?? false,
			);
			if (view?.membersMore === true && !this.#truncatedRooms.has(conversation.id)) {
				this.#truncatedRooms.add(conversation.id);
				store.noteTrouble(
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
		const selected = store.activeConv();
		let selectedReplaced = false;
		const wantedConversations = new Set(session.conversations.map((entry) => entry.id));
		for (const id of this.#historyLoads.keys()) if (!wantedConversations.has(id)) this.#historyLoads.delete(id);
		for (const conversation of store.get().convs.values()) {
			if (!wantedConversations.has(conversation.persistId)) {
				if (conversation.key === selected?.key) selectedReplaced = true;
				store.forgetConv(conversation.key);
			}
		}
		const wantedDirectories = new Set(session.directories.map((entry) => dirId(entry.id)));
		for (const directory of store.get().dirs.keys()) {
			if (!wantedDirectories.has(directory)) store.forgetDir(directory);
		}
		for (const directory of session.directories) {
			const id = dirId(directory.id);
			store.openDir(id, directory.locator);
			store.patchDir(id, {
				requestedNick: directory.nick,
				nick: "",
				standing: directory.standing,
				reached: true,
				session: "reconnecting",
			});
			if (directory.home) store.setHomeDir(id);
		}
		this.#keys.clear();
		const existingConversations = new Map<string, Conv>();
		for (const conversation of store.get().convs.values()) {
			existingConversations.set(conversation.persistId, conversation);
		}
		for (const conversation of session.conversations) {
			const existing = existingConversations.get(conversation.id);
			let restored: Conv | undefined = existing ?? undefined;
			if (existing != null && !sameConversationIdentity(existing, conversation)) {
				if (existing.key === selected?.key) selectedReplaced = true;
				store.forgetConv(existing.key);
				this.#historyLoads.delete(conversation.id);
				restored = undefined;
			}
			if (restored == null) restored = this.#restoreConversation(conversation) ?? undefined;
			if (restored != null) this.#keys.set(conversation.id, restored.key);
		}
		return selectedReplaced
			? { kind: "replaced", key: selected == null ? null : this.#keys.get(selected.persistId) ?? null }
			: { kind: "unchanged" };
	}

	async #hydrate(controller: AttachedRoomsController, session: RoomsSessionState): Promise<void> {
		for (const conversation of session.conversations) {
			if (this.#historyLoads.has(conversation.id)) continue;
			const key = this.#keys.get(conversation.id);
			if (key == null) continue;
			const token = Symbol(conversation.id);
			this.#historyLoads.set(conversation.id, token);
			const room = store.getConv(key);
			const awaitingHistory = room?.type === "room" && room.earlierHistory === "unasked";
			if (awaitingHistory) store.setEarlierHistory(key, "loading");
			try {
				const records = await controller.readHistory(
					conversation.kind,
					conversation.directory,
					conversation.id,
				);
				if (this.#historyLoads.get(conversation.id) !== token || this.#keys.get(conversation.id) !== key) {
					continue;
				}
				const existing = (store.get().convs.get(key)?.history ?? [])
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
					store.prependHistory(key, lines, "Earlier messages kept by the shared Rooms session archive");
					for (const line of lines) {
						for (const attachment of line.attachments) {
							if (
								typeof (attachment as { id?: unknown }).id === "number" && attachment.lost !== true &&
								fetchesOnArrival(attachment, silencedFrom(line.from, line.mine, store.get().ignored))
							) this.#files?.open(key, (attachment as AttachmentView).id);
						}
					}
				}
				if (awaitingHistory) {
					store.setEarlierHistory(key, lines.length === 0 ? "empty" : "shown");
				}
			} catch (error) {
				if (this.#historyLoads.get(conversation.id) !== token) continue;
				this.#historyLoads.delete(conversation.id);
				if (awaitingHistory) store.setEarlierHistory(key, "unavailable");
				store.noteTrouble("shared session archive", error instanceof Error ? error.message : String(error));
			}
		}
	}

	#restoreConversation(conversation: WorkspaceConversation) {
		const directory = dirId(conversation.directory);
		if (conversation.kind === "direct") {
			return store.restoreDm(
				directory,
				conversation.peer,
				conversation.peerRegistrationId,
				conversation.id,
				conversation.closed,
			);
		}
		return store.ensureRoom(directory, conversation.name, {
			persistId: conversation.id,
			key: conversation.held ? `held:${conversation.id}` : undefined,
			held: conversation.held,
			link: conversation.link,
			steward: conversation.steward,
			publicationId: conversation.publicationId,
			irc: conversation.irc,
		});
	}

	#projectSharedState(
		session: RoomsSessionState,
		sessionEffects: RoomsSessionSnapshot["pendingEffectDetails"],
		sessionAccess: RoomsSessionSnapshot["access"],
		sessionGrants: RoomsSessionSnapshot["grants"],
		archiveIssue: { reason: string } | null,
		issues: ReadonlyMap<string, RoomsSessionIssue>,
		archiveShares: RoomsSessionSnapshot["archiveShares"],
		selectionRepair: SelectionRepair,
	): void {
		const current = store.get();
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
				const { irc: _irc, link: _link, steward: _steward, ...withoutIntent } = conversation;
				const ircIssue = issues.get(`room-irc:${intended.directory}:${intended.id}`)?.reason ?? "";
				convs.set(
					key,
					{
						...withoutIntent,
						standing: intended.standing,
						ircIssue,
						stewardClaimable: intended.steward == null ? conversation.stewardClaimable : false,
						...(intended.link == null ? {} : { link: intended.link }),
						...(intended.steward == null ? {} : { steward: intended.steward }),
						...(Object.hasOwn(intended, "irc") ? { irc: intended.irc } : {}),
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
		store.set({
			dirs,
			convs,
			drafts,
			invites: session.invitations.map((invitation) => ({
				id: invitation.id,
				dir: dirId(invitation.directory),
				locator: invitation.locator,
				nick: invitation.nick,
				way: "link" as const,
				label: invitation.label,
				from: invitation.from,
				link: invitation.link,
			})),
			activeKey: selectionChanged
				? session.active == null ? null : this.#keys.get(session.active) ?? null
				: selectionRepair.kind === "replaced"
				? selectionRepair.key
				: current.activeKey,
			standing: session.standing,
			ignored: new Set(session.ignored),
			keepHistory: session.keepHistory,
			remembered: { ...session.join },
			sessionEffects,
			sessionAccess,
			sessionGrants,
			archiveShares: archiveShares.flatMap((share) => {
				const conversationKey = this.#keys.get(share.conversationId);
				return conversationKey == null ? [] : [{
					id: share.id,
					conversationKey,
					from: share.from,
					status: share.status,
					error: share.error,
				}];
			}),
		});
		const archivePeer = session.capabilities.archivePeer;
		store.setArchiveTarget(
			archivePeer == null ? { kind: "device" } : {
				kind: "peer",
				status: archiveIssue == null ? "connected" : "unavailable",
				label: "Shared session archive peer",
				remembered: true,
				error: archiveIssue?.reason ?? "",
			},
		);
	}
}
