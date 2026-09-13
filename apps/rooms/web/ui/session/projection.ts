// Projection of one durable Rooms session into the presentation store.
//
// Checkpoint `direct` becomes presentation `dm`. Checkpoint conversation `id`
// becomes `persistId`; a room `name` or DM `peer` becomes presentation `id`.
// Topology lives in `topology.ts`, kept history in `history_hydration.ts`,
// and the per-snapshot shared state in `shared_state.ts`; this composes them
// and owns what a snapshot's issues mean.

import type { AttachedLineEvent as RoomsSessionLineEvent } from "./remote.ts";
import * as store from "../store.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { CapabilitySetEventSource } from "../ops/capability_set_events.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import { retainSessionState } from "../workspace_state.ts";
import { directoryLivePhase, dirId } from "../types.ts";
import { ArchiveTargetProjection } from "./archive_target_projection.ts";
import { AttachedLineProjection } from "./line_projection.ts";
import type { RoomsPageContext } from "../page.ts";
import type { RoomsSessionIssue, RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { RoomsSessionState, WorkspaceOperationCredential } from "../../../lib/rooms_state.ts";
import { sameOperations, sameTopology } from "./checkpoint_identity.ts";
import { projectAttachedHistoryRead } from "./history_reconciliation.ts";
import { HistoryHydration } from "./history_hydration.ts";
import { reconcileTopology, type SelectionRepair } from "./topology.ts";
import { projectSharedState } from "./shared_state.ts";
import { directoryListTruncated, memberListTruncated, sharedHistoryOffered } from "../../../lib/text/attached.ts";

export class AttachedSessionProjection {
	readonly #page: RoomsPageContext;
	readonly #files: AttachedSessionFiles | null;
	readonly #capabilityEvents: CapabilitySetEventSource | null;
	readonly #lines: AttachedLineProjection;
	readonly #archiveTarget = new ArchiveTargetProjection();
	readonly #history: HistoryHydration;
	#topology: RoomsSessionState | null = null;
	#operations: readonly WorkspaceOperationCredential[] | null = null;
	readonly #keys = new Map<string, string>();
	readonly #reportedIssues = new Map<string, string>();
	readonly #truncatedDirectories = new Set<string>();
	readonly #truncatedRooms = new Set<string>();
	#sessionDisconnected = false;
	#accessRevoked = false;
	#archiveUnavailable = false;
	#projectedActive: string | null | undefined;
	#pendingDraft: (conversationId: string) => string | undefined = () => undefined;
	#ignoredNickname: (conversationId: string) => string | undefined = () => undefined;
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
		const keyOf = (conversationId: string) => this.#keys.get(conversationId) ?? null;
		this.#lines = new AttachedLineProjection(keyOf, files, page);
		this.#history = new HistoryHydration(page, files, keyOf);
	}

	bind(controller: AttachedRoomsController): () => void {
		this.#pendingDraft = (conversationId) => controller.pendingDraft(conversationId);
		this.#ignoredNickname = (conversationId) => controller.ignoredNickname(conversationId);
		this.#driving = () => controller.driving();
		let checkpoint: RoomsSessionState | null = null;
		// Subscribe before the first read. An invalidation during a read retires
		// its token and queues one fresh pass after current reads have settled.
		const stopHistory = controller.observesHistory ? () => {} : controller.onHistoryInvalidated((change) => {
			if (checkpoint == null) return;
			for (const conversation of checkpoint.conversations) {
				if (
					change == null || (change.kind === conversation.kind &&
						change.directory === conversation.directory && change.conversation === conversation.id)
				) {
					this.#history.forget(conversation.id);
				}
			}
			this.#history.hydrate(controller, checkpoint);
		});
		const stopSnapshot = controller.onSnapshot((snapshot) => {
			checkpoint = snapshot.checkpoint;
			this.apply(snapshot);
			if (!controller.observesHistory) this.#history.hydrate(controller, snapshot.checkpoint);
		});
		const stopRead = controller.observesHistory
			? controller.onHistoryRead((result) => {
				const key = this.#keys.get(result.conversationId);
				if (key != null) projectAttachedHistoryRead(this.#page, key, result, this.#files);
			})
			: () => {};
		const stopLine = controller.onLine((event) => this.line(event));
		return () => {
			stopLine();
			stopRead();
			stopSnapshot();
			stopHistory();
			checkpoint = null;
			this.#history.reset();
			this.#pendingDraft = () => undefined;
			this.#ignoredNickname = () => undefined;
		};
	}

	apply(snapshot: RoomsSessionSnapshot): void {
		const session = snapshot.checkpoint;
		retainSessionState(this.#page, session);
		const operations = session.capabilities.operations;
		if (this.#operations != null && !sameOperations(operations, this.#operations)) {
			void this.#capabilityEvents?.note();
		}
		this.#operations = operations;
		let selectionRepair: SelectionRepair = { kind: "unchanged" };
		if (this.#topology == null || !sameTopology(session, this.#topology)) {
			this.#topology = session;
			selectionRepair = reconcileTopology({
				page: this.#page,
				keys: this.#keys,
				history: this.#history,
				ignoredNickname: (conversationId) => this.#ignoredNickname(conversationId),
			}, session);
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
			if (archiveIssue == null && (issue.subject === "archive" || issue.subject.startsWith("archive:"))) {
				archiveIssue = issue;
			}
			if (issue.subject.startsWith("event-gap:")) eventGaps.add(issue.subject.slice("event-gap:".length));
		}
		// Every runtime failure reaches the bounded diagnostics journal even when a
		// more specific control also explains it. Remember the current reason so a
		// stable snapshot does not manufacture repeated failures; clearing and later
		// recurring is a new event and is filed again.
		for (const issue of issues.values()) {
			if (this.#reportedIssues.get(issue.subject) === issue.reason) continue;
			this.#reportedIssues.set(issue.subject, issue.reason);
			store.noteTrouble(this.#page.projection, `shared session ${issue.subject}`, issue.reason);
		}
		for (const subject of this.#reportedIssues.keys()) {
			if (!issues.has(subject)) this.#reportedIssues.delete(subject);
		}
		this.#projectDirectoryViews(snapshot);
		this.#projectRoomViews(session, snapshot, issues);
		if (accessIssue != null && !this.#accessRevoked) {
			store.toast(this.#page.projection, "failure", accessIssue.reason);
		}
		this.#accessRevoked = accessIssue != null;
		if (archiveIssue != null && !this.#archiveUnavailable) {
			store.toast(this.#page.projection, "failure", archiveIssue.reason);
		}
		this.#archiveUnavailable = archiveIssue != null;
		if (sessionIssue != null) {
			this.#files?.markLost(sessionIssue.reason);
			for (const directory of session.directories) {
				store.dropHeldLines(this.#page.projection, dirId(directory.id));
			}
		}
		const recovered = this.#sessionDisconnected && sessionIssue == null;
		this.#sessionDisconnected = sessionIssue != null;
		if (recovered) this.#history.forgetAll();
		else for (const conversationId of eventGaps) this.#history.forget(conversationId);
		const connectedDirectories = new Set(snapshot.connectedDirectories);
		for (const directory of session.directories) {
			const issue = issues.get(`directory:${directory.id}`);
			if (issue != null) {
				this.#files?.markLost(issue.reason, directory.id);
				store.dropHeldLines(this.#page.projection, dirId(directory.id));
			}
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
		// Read the Rust claim projection once, only when there are pending effects.
		const driving = snapshot.pendingEffectDetails.length === 0 ? null : this.#driving();
		const selectionChanged = this.#projectedActive === undefined || this.#projectedActive !== session.active;
		this.#projectedActive = session.active;
		const offered = projectSharedState(this.#page, {
			session,
			keyOf: (conversationId) => this.#keys.get(conversationId),
			pendingDraft: (conversationId) => this.#pendingDraft(conversationId),
			// The ledger's leftovers, not everything in it. An operation this tab
			// is driving will settle, or fail where it was asked for, and until
			// then it is somebody's business already: the page carries the wait
			// on the control that started it. What reaches the store is what the
			// store says it holds: operations awaiting an explicit decision.
			// Sending a line is one of these operations, so without this the
			// notice appeared and left again on every message anybody sent.
			sessionEffects: snapshot.pendingEffectDetails.filter((effect) => !driving?.has(effect.id)),
			sessionAccess: snapshot.access,
			suspendedNote: snapshot.suspendedNote ?? "",
			sessionGrants: snapshot.grants,
			issues,
			archiveShares: snapshot.archiveShares,
			handedRooms: snapshot.handedRooms,
			selectionRepair,
			selectionChanged,
		});
		for (const share of offered) {
			store.deliver(
				this.#page.projection,
				share.conversationKey,
				store.sysItem(this.#page.projection, sharedHistoryOffered(share.from)),
			);
		}
		store.setArchiveTarget(
			this.#page.projection,
			this.#archiveTarget.update(session.capabilities.archivePeer, archiveIssue?.reason ?? ""),
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
					directoryListTruncated,
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
			const issue = issues.get(`room:${conversation.directory}:${conversation.id}`);
			store.setRoomMembership(
				this.#page.projection,
				key,
				view != null ? "joined" : issue != null || unnamed ? "unavailable" : "joining",
				issue?.reason ?? "",
			);
			store.setRoomView(this.#page.projection, key, {
				members: view?.members ?? [],
				topic: view?.topic ?? null,
				lineBytes: view?.lineBytes ?? null,
				bridge: view?.bridge ?? null,
				carries: view?.carries ?? null,
				canSetTopic: view?.canSetTopic ?? false,
				canPostFiles: view?.canPostFiles ?? false,
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
					memberListTruncated,
				);
			} else if (view?.membersMore !== true) this.#truncatedRooms.delete(conversation.id);
		}
		for (const room of this.#truncatedRooms) if (!wanted.has(room)) this.#truncatedRooms.delete(room);
	}

	line(event: RoomsSessionLineEvent): void {
		this.#lines.apply(event);
	}
}
