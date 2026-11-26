// One production viewer over explicit managed use: the accepted snapshot, the
// observation that keeps it current, and directory registration. Rust owns
// memberships, persistent authority, retained effect execution and physical
// storage. The link to a session elsewhere is `SessionLink`'s.
import { invariant } from "../../../../lib/invariant.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedObservation,
	RoomsManagedObservationRequest,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ManagedAccess } from "./access.ts";
import { OWN_CONTROL } from "./held_control.ts";
import { type LinkClock, type ManagedLink, realClock } from "./link.ts";
import type { LinkPort, Stamp } from "./link_port.ts";
import { SessionLink } from "./session_link.ts";
import type { ManagedOperation } from "./operation.ts";
import { ManagedReads } from "./reads.ts";
import { ManagedEffects } from "./effects.ts";
import { Committed } from "./committed.ts";
import type { ReleaseEnd } from "./release.ts";
import { ManagedActions } from "./actions.ts";
import type { ActivityDelivery } from "./activity.ts";
import { ManagedActivityReading } from "./activity_reading.ts";
import { registerObservation } from "./observation_registration.ts";
import type { DialedLink } from "./relink.ts";
import { ManagedDrafts } from "./drafts.ts";
import { ManagedOpenings } from "./openings.ts";
import { ManagedNavigation } from "./navigation.ts";
import { ManagedTyping } from "./typing.ts";
import { ManagedSelection } from "./selection.ts";
import { indexAcceptedConversations } from "./conversation_lookup.ts";
import {
	type DirectoryIntent,
	type ObservationView,
	permitted,
	type UseView,
	type WorkspaceSnapshot,
} from "./model.ts";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { managedAccessText as text, savedControlSource } from "../../../../lib/text/managed_access.ts";
import { TrackedJobs } from "./tracked_jobs.ts";

// Registration is observed through the existing workspace subscription.
const DIRECTORY_REGISTRATION_WAIT_MS = 30_000;

/** What a press module holds of the session: reads that wait for the link
 * because nothing is sent yet, and `press`, the one way to send. A press has
 * no `Now` read, no `command`, and no completion of its own. What follows its
 * commit is `Committed`'s, handed to `press`'s completion. */
export type Door = Pick<
	ManagedRoomsSession,
	"current" | "readBeforeSending" | "candidateBeforeSending" | "request" | "press"
>;

/** What a press prepares its first send with, inside `press`. */
export interface Sending {
	command: ManagedRoomsSession["command"];
	perform: ManagedRoomsSession["perform"];
}

export class ManagedRoomsSession {
	readonly application: RoomsManagedApplication;
	readonly management: ManagedAccess;
	readonly actions: ManagedActions;
	readonly effects: ManagedEffects;
	readonly reads = new ManagedReads();
	readonly drafts: ManagedDrafts;
	readonly navigation: ManagedNavigation;
	readonly openings: ManagedOpenings;
	readonly typing: ManagedTyping;
	readonly selection: ManagedSelection;
	readonly #custody: RoomsManagedWorkspace;
	readonly #inFlight = new TrackedJobs();
	readonly #listeners = new Set<() => void>();
	readonly #waiters = new Set<() => void>();
	/** Observation loops of replaced links, which end on their own once their
	 * calls fail. */
	readonly #replaced = new TrackedJobs();
	#workspace: RoomsManagedWorkspace;
	readonly #link: SessionLink;
	readonly #port: LinkPort;
	#snapshot: WorkspaceSnapshot | null = null;
	#access: UseView = { status: "outOfScope" };
	#observation: RoomsManagedObservation | null = null;
	#observationRequest: RoomsManagedObservationRequest | null = null;
	#observing: Promise<void> | null = null;
	#closing: Promise<void> | null = null;
	#presentation: (() => Promise<void>) | null = null;
	#stopped = false;
	#change = 0;
	#observationFailure: unknown = null;
	#retryObservation = 0;
	#retryingUpdates = false;
	readonly #activity: ManagedActivityReading;
	readonly #report: (source: string, error: unknown) => void;
	/** What a press does once its change is committed. */
	readonly committed: Committed = new Committed(this, (source, error) => this.#report(source, error));
	readonly #clock: LinkClock;

	constructor(
		application: RoomsManagedApplication,
		workspace: RoomsManagedWorkspace,
		custody: RoomsManagedWorkspace,
		report: (source: string, error: unknown) => void,
		/** Whether this browser runs the session, dialing every directory
		 * itself, or is attached to one a process elsewhere runs. */
		readonly local = true,
		clock: LinkClock = realClock,
	) {
		this.#clock = clock;
		this.application = application;
		this.#workspace = workspace;
		this.#link = new SessionLink(
			application,
			{
				workspace: () => this.#workspace,
				observation: () => this.#observation,
				stopped: () => this.#stopped,
				changed: () => this.#changed(),
				install: (dialed, live) => this.#install(dialed, live),
				report,
				track: (job) => void this.#inFlight.track(job),
			},
			this,
			local,
			clock,
		);
		this.#port = this.#link.port;
		this.#custody = custody;
		this.management = new ManagedAccess(
			application,
			custody,
			(error) => report(text.management, error),
			() => this.#link.link?.probeIfSeen(),
		);
		this.effects = new ManagedEffects(this, {
			...this.#port,
			clock,
			stopped: () => this.#stopped,
			observationFailure: () => this.#observationFailure,
			change: () => this.#change,
			changed: () => this.#changed(),
			wait: (change, signal) => this.#wait(change, signal),
			report,
		});
		this.actions = new ManagedActions(this, this.#port);
		this.drafts = new ManagedDrafts(this);
		this.navigation = new ManagedNavigation(
			this,
			() => this.#changed(),
			(error) => report("conversation selection", error),
		);
		this.openings = new ManagedOpenings(
			this,
			() => this.#changed(),
			(error) => report("conversation opening", error),
		);
		this.typing = new ManagedTyping(this, this.#port);
		this.selection = new ManagedSelection(application, custody, (task) => this.#inFlight.track(task));
		this.#report = report;
		this.#activity = new ManagedActivityReading({
			current: () => this.#port.current(),
			isCurrent: (stamp) => this.#port.isCurrent(stamp),
			overStamped: (stamp, call) => this.#port.overStamped(stamp, call),
			permits: (permission) => this.permits(permission),
			stopped: () => this.#stopped,
			change: () => this.#change,
			wait: (change) => this.#wait(change),
			changed: () => this.#changed(),
			answered: () => this.#retryingUpdates = false,
			failed: (source, error) => this.#failed(source, error),
		});
	}
	/** Forwards `SessionLink.link`. */
	get link(): ManagedLink | null {
		return this.#link.link;
	}
	/** Read before sending. If the link stays away, the press ends with
	 * `session-unread`. A committed change uses the reads on `Committed`. */
	async request<T>(call: (workspace: RoomsManagedWorkspace) => Promise<T>): Promise<T> {
		await this.#port.ready("session-unread");
		return await this.#port.over((link) => call(link.workspace));
	}
	/** `request` for work under way whose owner handles a lost connection: it
	 * never waits for the link, so a follow-up to a sent change is never
	 * refused as if nothing was sent. */
	requestNow<T>(call: (workspace: RoomsManagedWorkspace) => Promise<T>): Promise<T> {
		return this.#port.over((link) => call(link.workspace));
	}
	/** Forwards `SessionLink.tells`. */
	linkTells(error: unknown): boolean {
		return this.#link.tells(error);
	}
	/** Forwards `SessionLink.ended`. */
	linkEnded(error: unknown): boolean {
		return this.#link.ended(error);
	}
	get resources() {
		return {
			effects: this.effects.resources,
			acquisitions: this.actions.resources,
			workers: this.#inFlight.size,
			reads: this.reads.active,
			typing: this.typing.resources,
			listeners: this.#listeners.size + this.#activity.listeners,
			waiters: this.#waiters.size,
			observation: this.#observation != null,
			activity: this.#activity.open,
		};
	}
	get current(): WorkspaceSnapshot | null {
		return this.#snapshot;
	}
	/** Whether a reload would drop what the person did: an edit with no write
	 * the session holds, or a change still being prepared. Everything the
	 * session holds a record of is adopted again by the reloaded page. */
	get reloadLoses(): boolean {
		return this.drafts.reloadLoses || this.effects.preparing;
	}
	get access(): UseView {
		return this.#access;
	}
	get pending(): readonly string[] {
		return this.effects.pending;
	}
	get recoverable(): readonly string[] {
		return this.effects.recoverable;
	}
	/** Why the workspace's updates stopped arriving, or null while they flow.
	 * Activity retries on the next change; `retryUpdates` retries both streams. */
	get updatesFailure(): unknown {
		return this.#observationFailure ?? this.#activity.failure;
	}
	/** A retry was asked and no stream has answered it yet. */
	get updatesRetrying(): boolean {
		return this.#retryingUpdates;
	}
	get pendingOperations(): Iterable<ManagedOperation> {
		return this.effects.pendingOperations;
	}
	permits(permission: RoomsPermission): boolean {
		return permitted(this.#access, permission);
	}
	subscribe = (listener: () => void): () => void => {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	};
	onActivity(listener: (delivery: ActivityDelivery) => void | Promise<void>): () => void {
		return this.#activity.listen(listener);
	}
	#changed(): void {
		this.#change++;
		for (const wake of this.#waiters) wake();
		this.#waiters.clear();
		for (const listener of this.#listeners) {
			try {
				listener();
			} catch (error) {
				this.#report(text.presentation, error);
			}
		}
	}
	/** Resolve at the next change, or when `signal` aborts, which leaves no
	 * waiter behind. */
	#wait(change: number, signal?: AbortSignal): Promise<void> {
		if (this.#stopped || change !== this.#change || signal?.aborted) return Promise.resolve();
		return new Promise<void>((resolve) => {
			this.#waiters.add(resolve);
			signal?.addEventListener("abort", () => {
				this.#waiters.delete(resolve);
				resolve();
			}, { once: true });
		});
	}
	acquisitionChanged(): void {
		this.#changed();
	}
	/** Wake both update streams now rather than at the next change. */
	retryUpdates(): void {
		if (this.updatesFailure == null || this.#retryingUpdates) return;
		this.#retryingUpdates = true;
		this.#retryObservation++;
		this.#changed();
	}
	bindPresentation(stop: () => Promise<void>): void {
		if (this.#presentation != null || this.#stopped) {
			invariant(false, "this viewer already has a presentation owner");
		}
		this.#presentation = stop;
	}
	/** Read the session for a press that has sent nothing yet. A read while
	 * the link is being replaced waits for the new one as `request` does, and
	 * ends with the link's refusal when none comes in time. Never after this
	 * press has sent: use `AfterCommit`. */
	async readBeforeSending(): Promise<WorkspaceSnapshot> {
		if (this.#stopped) throw new LocalRefusal("session-closed");
		await this.#port.ready("session-unread");
		return await this.readNow();
	}
	/** Read the session over the link it has now, for work under way whose
	 * owner handles a lost connection. A read while the link is being replaced
	 * fails at once, so a follow-up to a sent change never waits and then ends
	 * as if nothing was sent. */
	async readNow(): Promise<WorkspaceSnapshot> {
		if (this.#stopped) throw new LocalRefusal("session-closed");
		const snapshot: WorkspaceSnapshot = await this.#port.over((link) => link.workspace.snapshot());
		if (this.#stopped) throw new LocalRefusal("session-closed");
		return this.#accept(snapshot);
	}
	/** Keep `snapshot` unless a newer revision is already accepted. Command
	 * preparation and presentation share the accepted revision, including when
	 * concurrent reads finish out of order. */
	#accept(snapshot: WorkspaceSnapshot): WorkspaceSnapshot {
		const newer = this.#newer(snapshot);
		if (newer != null) return newer;
		this.#take(snapshot);
		return snapshot;
	}
	/** The accepted snapshot when it is newer than `snapshot`, or null once
	 * `snapshot` is indexed for lookup to be taken. Everything in accepting a
	 * snapshot that can throw runs here. */
	#newer(snapshot: WorkspaceSnapshot): WorkspaceSnapshot | null {
		const accepted = this.#snapshot;
		if (accepted != null && BigInt(snapshot.revision) < BigInt(accepted.revision)) return accepted;
		indexAcceptedConversations(snapshot);
		return null;
	}
	#take(snapshot: WorkspaceSnapshot): void {
		this.drafts.followRoomLinks(this.#snapshot, snapshot);
		this.#snapshot = snapshot;
		this.#changed();
	}
	// A staged edit must not mutate the accepted projection before commitment.
	// One bounded candidate copy belongs to the gesture, then Rust serializes
	// its retained request. Observation reads never pay this copy.
	/** `readBeforeSending`, as a copy the press may edit. */
	async candidateBeforeSending(): Promise<WorkspaceSnapshot> {
		return structuredClone(await this.readBeforeSending());
	}
	/** `readNow`, as a copy the work under way may edit. */
	async candidateNow(): Promise<WorkspaceSnapshot> {
		return structuredClone(await this.readNow());
	}
	/** Acquisition establishes custody. Registration establishes the chosen name.
	 * Wait on the existing observation owner, retaining the exact original choice. */
	async directoryRegistered(original: DirectoryIntent, signal?: AbortSignal): Promise<void> {
		let expired = false;
		const wake = () => this.#changed();
		const cancelDeadline = this.#clock.after(DIRECTORY_REGISTRATION_WAIT_MS, () => {
			expired = true;
			wake();
		});
		signal?.addEventListener("abort", wake, { once: true });
		try {
			while (!this.#stopped && !signal?.aborted) {
				const change = this.#change;
				const row = this.#snapshot?.intent.directories.find((row) => row.id === original.id);
				if (
					row == null || row.access !== original.access || row.source !== original.source ||
					row.nick !== original.nick || row.nickAllocation !== original.nickAllocation
				) throw new LocalRefusal("registration-changed");
				if (row.name != null && row.assignedNick != null) return;
				if (this.#observationFailure != null) throw this.#observationFailure;
				if (expired) throw new LocalRefusal("registration-unfinished");
				await this.#wait(change);
			}
			if (this.#stopped) throw new LocalRefusal("session-closed");
		} finally {
			cancelDeadline();
			signal?.removeEventListener("abort", wake);
		}
	}
	initializeManagement(local: boolean, saved: readonly string[]): void {
		void this.#inFlight.track((async () => {
			if (local) {
				try {
					const control = await this.application.management();
					try {
						await this.management.hold(OWN_CONTROL, control, { kind: "saved" });
					} catch (error) {
						control.free();
						throw error;
					}
				} catch (error) {
					this.#report(text.management, error);
				}
			}
			await this.management.restore(saved, {
				current: () => true,
				report: (id, error) => this.#report(savedControlSource(id), error),
				probe: () => this.link?.probeIfSeen(),
			});
		})()).catch((error) => this.#report(text.management, error));
	}
	/** Observe the workspace, read it, and adopt what other tabs left. A page
	 * attached to a session elsewhere opens even when its link is lost on the
	 * way: the dial that loss starts observes and reads over the new link, and
	 * adoption waits for it. */
	async start(): Promise<void> {
		invariant(this.#observation == null, "this workspace viewer is already running");
		let observation: RoomsManagedObservation | null = null;
		let observed = false;
		try {
			// A registration a refused submit leaves is kept for close to retry.
			observation = await this.#port.over((link) =>
				registerObservation(link.workspace, (request) => this.#observationRequest = request)
			);
			this.#observation = observation;
			const polled = observation;
			const first: ObservationView = await this.#port.over(() => polled.poll());
			this.#access = first.source;
			if (this.permits("observeWorkspace")) await this.readNow();
			this.#observing = this.#observe(first.cursor, polled, this.#port.current());
			observed = true;
		} catch (error) {
			if (!this.linkTells(error)) throw error;
			// A registration the loss cut off retired with its link.
			this.#observationRequest?.free();
			this.#observationRequest = null;
			// No loop observes what this registered, and the new link holds its own.
			if (observation != null && !observed) {
				if (this.#observation === observation) this.#observation = null;
				observation.free();
			}
		}
		this.#activity.start();
		await this.effects.restore();
	}
	async #observe(cursor: Uint8Array, observation: RoomsManagedObservation, stamp: Stamp): Promise<void> {
		let project = false;
		try {
			while (!this.#stopped && this.#port.isCurrent(stamp)) {
				const retry = this.#retryObservation;
				try {
					if (!project) {
						// A read parked on the live link probes it when the session stays quiet.
						const update: ObservationView = await this.#port.overStamped(
							stamp,
							() => observation.receive(cursor),
						)
							.finally(this.link?.quiet());
						if (this.#stopped || !this.#port.isCurrent(stamp)) break;
						cursor = update.cursor;
						this.#access = update.source;
						project = true;
					}
					if (this.permits("observeWorkspace")) await this.readNow();
					else {
						this.#snapshot = null;
						this.#changed();
					}
					project = false;
					this.#observationFailure = null;
					this.#retryingUpdates = false;
					this.#changed();
				} catch (error) {
					// A replaced link's failures belong to the link, not to its successor.
					if (this.#stopped || !this.#port.isCurrent(stamp)) break;
					this.#observationFailed(error);
					// Keep the same registration and accepted cursor. A failed
					// snapshot retries projection before waiting for another event.
					while (
						!this.#stopped && this.#port.isCurrent(stamp) && retry === this.#retryObservation
					) await this.#wait(this.#change);
				}
			}
		} finally {
			// The registration of a replaced link retires with its session.
			if (observation !== this.#observation) observation.free();
		}
	}
	/** A call failed, and the port charged a lost connection under it to its
	 * link. That loss is the link's to tell, in its one notice. Any other
	 * failure is reported under `source`, and the caller shows it: returns
	 * which. */
	#failed(source: string, error: unknown): boolean {
		if (this.linkTells(error)) return false;
		this.#report(source, error);
		return true;
	}
	/** The observation failed in its own loop. The failure stands until the
	 * next answer or a retry. */
	#observationFailed(error: unknown): void {
		if (this.#failed(text.observation, error)) this.#observationFailure = error;
		this.#retryingUpdates = false;
		this.#changed();
	}
	/** Forwards `SessionLink.onRelink`. */
	onRelink(listener: () => void): () => void {
		return this.#link.onRelink(listener);
	}
	/** Put the new link's handles in place and make it live, in one turn. Its
	 * snapshot is admitted first, the one step that can refuse it, so a refusal
	 * leaves every old handle in place. */
	#install({ workspace, observation, first, snapshot }: DialedLink, live: () => void): void {
		const admitted = snapshot != null && this.#newer(snapshot) == null;
		const stale = this.#workspace;
		this.#workspace = workspace;
		this.#observation = observation;
		this.#access = first.source;
		this.#observationFailure = null;
		this.#retryingUpdates = false;
		// Every call over the new handles starts after this, stamped with the new link.
		live();
		this.#activity.relink();
		// A call still waiting on the old handles holds its own clone, so this
		// frees nothing under it: the old connection's close fails it as a lost
		// connection, charged to the old link.
		stale.free();
		// An access that may not observe shows no workspace, so the old one goes.
		if (snapshot == null) this.#snapshot = null;
		else if (admitted) this.#take(snapshot);
		const previous = this.#observing;
		if (previous != null) {
			void this.#replaced.track(previous);
		}
		this.#observing = this.#observe(first.cursor, observation, this.#port.current());
		this.#changed();
	}
	command(...args: Parameters<ManagedEffects["command"]>): Promise<ManagedOperation> {
		return this.effects.command(...args);
	}
	execute<T>(
		operation: string,
		prepare: () => Promise<ManagedOperation>,
		then: (command: ManagedOperation, after: Committed) => Promise<T>,
		signal?: AbortSignal,
	): Promise<T> {
		return this.effects.execute<T>(operation, prepare, then, signal);
	}
	/** Send one change and finish what follows its commit, over the next link
	 * when a loss ends it. `prepare` makes the first send, and `then` runs once
	 * the change committed, and again over each new link a loss ends it on. */
	press<T>(
		operation: string,
		prepare: (sending: Sending) => Promise<ManagedOperation>,
		then: (command: ManagedOperation, after: Committed) => Promise<T>,
		signal?: AbortSignal,
	): Promise<T> {
		return this.effects.execute<T>(
			operation,
			() => prepare({ command: (...a) => this.command(...a), perform: (...a) => this.perform(...a) }),
			then,
			signal,
		);
	}
	/** Give up on one open change for good, and say how it ended: a held
	 * acquisition is freed here, which releases it, and a receipt is released
	 * at the workspace, which answers `kept` when its result was adopted. */
	releaseOperation(id: string): Promise<ReleaseEnd> {
		return this.actions.pending.includes(id)
			? this.actions.release(id).then(() => "released")
			: this.effects.releaseOperation(id);
	}
	completeOperation(id: string): Promise<boolean> {
		return this.effects.completeOperation(id);
	}
	completeResult(operation: ManagedOperation): Promise<unknown> {
		return this.effects.completeResult(operation);
	}
	perform(...args: Parameters<ManagedEffects["perform"]>): Promise<ManagedOperation> {
		return this.effects.perform(...args);
	}
	finish(operation: ManagedOperation): void {
		this.effects.finish(operation);
	}
	resume(id: string): Promise<ManagedOperation> {
		return this.effects.resume(id);
	}
	selectWorkspace(uri: string | null): Promise<void> {
		return this.selection.select(uri);
	}
	close(): Promise<void> {
		return this.#closing ??= this.#close().catch((error) => {
			this.#closing = null;
			throw error;
		});
	}
	async #close(): Promise<void> {
		this.#stopped = true;
		// The link stops first, so no dial starts while the page closes. Closing
		// the application below ends a dial in flight, which the link waits for.
		const linked = this.link?.live ?? true;
		const linkClosed = this.link?.close();
		this.management.stop();
		this.actions.stop();
		this.reads.stop();
		this.drafts.stop();
		this.navigation.stop();
		this.openings.stop();
		this.typing.stop();
		this.selection.stop();
		this.#changed();
		// Keep the observation handle if cancellation refuses. A retry uses the
		// original registration and cannot create a second watcher.
		if (this.#observationRequest != null) {
			this.#observation = await this.#observationRequest.submit();
			this.#observationRequest.free();
			this.#observationRequest = null;
		}
		if (this.link == null) await this.#observation?.cancel();
		else if (linked) {
			await this.#observation?.cancel().catch(() => {
				// best-effort: a registration the session is not told to cancel
				// retires with the session's link, which closes below.
			});
		}
		await this.#presentation?.();
		this.#presentation = null;
		await this.application.close();
		await linkClosed;
		await this.actions.close();
		await this.reads.close();
		await this.drafts.close();
		await this.navigation.close();
		await this.openings.close();
		await this.typing.close();
		await Promise.allSettled([
			this.#inFlight.settled(),
			this.#observing,
			this.#activity.running,
			this.#replaced.settled(),
		]);
		this.#observation?.free();
		this.#observation = null;
		this.#activity.free();
		await this.effects.close();
		await this.management.close();
		this.selection.close();
		this.#workspace.free();
		this.#custody.free();
		this.application.free();
		this.#listeners.clear();
		this.#waiters.clear();
		this.#link.clear();
	}
}
