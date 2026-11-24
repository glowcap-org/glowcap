// One production viewer over explicit managed use. Rust owns memberships,
// persistent authority, retained effect execution and physical storage.
import { invariant } from "../../../../lib/invariant.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { ACTIVITY_CURSOR_STALE, roomsErrorIn } from "../../../../lib/error_codes.ts";
import type {
	RoomsManagedActivityReader,
	RoomsManagedApplication,
	RoomsManagedObservation,
	RoomsManagedObservationRequest,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ManagedAccess, OWN_CONTROL } from "./access.ts";
import { type LinkClock, ManagedLink, realClock, RECOVERY_WAIT_MS } from "./link.ts";
import type { ManagedOperation } from "./operation.ts";
import { ManagedReads } from "./reads.ts";
import { ManagedEffects } from "./effects.ts";
import { ManagedActions } from "./actions.ts";
import { ActivityDelivery } from "./activity.ts";
import { dialAgain, registerObservation, resumeLink, type Step } from "./relink.ts";
import { ManagedDrafts } from "./drafts.ts";
import { ManagedOpenings } from "./openings.ts";
import { ManagedNavigation } from "./navigation.ts";
import { ManagedTyping } from "./typing.ts";
import { ManagedSelection } from "./selection.ts";
import { indexAcceptedConversations } from "./conversation_lookup.ts";
import {
	type ActivityRead,
	type DirectoryIntent,
	type ObservationView,
	permitted,
	type UseView,
	type WorkspaceSnapshot,
} from "./model.ts";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { managedAccessText as text, savedControlSource } from "../../../../lib/text/managed_access.ts";

// Registration is observed through the existing workspace subscription.
const DIRECTORY_REGISTRATION_WAIT_MS = 30_000;

export class ManagedRoomsSession {
	readonly application: RoomsManagedApplication;
	/** The link to a session a process elsewhere runs, or null for a session
	 * this browser runs, which has no link to lose. */
	readonly link: ManagedLink | null;
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
	readonly #inFlight = new Set<Promise<unknown>>();
	readonly #listeners = new Set<() => void>();
	readonly #activityListeners = new Set<(delivery: ActivityDelivery) => void | Promise<void>>();
	readonly #waiters = new Set<() => void>();
	readonly #clock: LinkClock;
	/** A dial is under way and the old link has not yet been replaced. */
	#dialing = false;
	/** The move of what the page keeps onto the newest link. */
	#moving: Promise<void> = Promise.resolve();
	readonly #relinkListeners = new Set<() => void | Promise<void>>();
	/** Loops of replaced links, which end on their own once their calls fail. */
	readonly #replaced = new Set<Promise<void>>();
	#workspace: RoomsManagedWorkspace;
	/** Rises each time a new link replaces the handles of the last. */
	#generation = 0;
	#snapshot: WorkspaceSnapshot | null = null;
	#access: UseView = { status: "outOfScope" };
	#observation: RoomsManagedObservation | null = null;
	#observationRequest: RoomsManagedObservationRequest | null = null;
	#activity: RoomsManagedActivityReader | null = null;
	#observing: Promise<void> | null = null;
	#reading: Promise<void> | null = null;
	#closing: Promise<void> | null = null;
	#presentation: (() => Promise<void>) | null = null;
	#stopped = false;
	#change = 0;
	#observationFailure: unknown = null;
	#activityFailure: unknown = null;
	#retryObservation = 0;
	#retryingUpdates = false;
	#activityCursor = "";
	/** How far behind the journal this reader is, or null once every event it
	 * reads is news. It is behind at first, and after a failed read, a gap, or
	 * a stretch with no reader, and it then reads without waiting. `head` is
	 * where the journal ended when it began to catch up, or null until a read
	 * says where. Every event up to it had already happened. */
	#activityBehind: { readonly head: string | null } | null = { head: null };
	readonly #report: (source: string, error: unknown) => void;

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
		this.application = application;
		this.#workspace = workspace;
		this.#clock = clock;
		this.link = local ? null : new ManagedLink({
			dial: () => this.#relink(),
			probe: () => this.#probe(),
			changed: () => this.#changed(),
			report: (error) => report(text.link, error),
		}, clock);
		this.#custody = custody;
		this.management = new ManagedAccess(application, custody, (error) => report(text.management, error));
		this.effects = new ManagedEffects(this, {
			stopped: () => this.#stopped,
			observationFailure: () => this.#observationFailure,
			change: () => this.#change,
			changed: () => this.#changed(),
			linked: () => this.#linked(),
			relinked: () => this.link?.available(null) ?? Promise.resolve(false),
			generation: () => this.#generation,
			refused: () => this.link?.state.kind === "refused" ? this.link.cause : null,
			lost: (error, generation) => this.#lost(error, generation),
			wait: (change) => this.#wait(change),
			report,
		});
		this.actions = new ManagedActions(this);
		this.drafts = new ManagedDrafts(this);
		this.navigation = new ManagedNavigation(this, () => this.#changed());
		this.openings = new ManagedOpenings(
			this,
			() => this.#changed(),
			(error) => report("conversation opening", error),
		);
		this.typing = new ManagedTyping(this);
		this.selection = new ManagedSelection(application, custody, (task) => this.#track(task));
		this.#report = report;
	}
	/** Rises each time a new link replaces the handles of the last. */
	get linkGeneration(): number {
		return this.#generation;
	}
	get workspace(): RoomsManagedWorkspace {
		return this.#workspace;
	}
	get resources() {
		return {
			effects: this.effects.resources,
			acquisitions: this.actions.resources,
			workers: this.#inFlight.size,
			reads: this.reads.active,
			typing: this.typing.resources,
			listeners: this.#listeners.size + this.#activityListeners.size,
			waiters: this.#waiters.size,
			observation: this.#observation != null,
			activity: this.#activity != null,
		};
	}
	get current(): WorkspaceSnapshot | null {
		return this.#snapshot;
	}
	/** Whether nothing the person did is still on its way: no edit unsaved and no change in progress. */
	get idle(): boolean {
		return !this.drafts.unsaved && !this.effects.busy && !this.actions.busy;
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
		return this.#observationFailure ?? this.#activityFailure;
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
		invariant(this.#activityListeners.size === 0, "activity custody already has a presentation owner");
		this.#activityListeners.add(listener);
		this.#changed();
		return () => {
			this.#activityListeners.delete(listener);
			this.#changed();
		};
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
	#wait(change: number): Promise<void> {
		if (this.#stopped || change !== this.#change) return Promise.resolve();
		return new Promise<void>((resolve) => this.#waiters.add(resolve));
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
	async refresh(): Promise<WorkspaceSnapshot> {
		if (this.#stopped) throw new LocalRefusal("session-closed");
		const snapshot: WorkspaceSnapshot = await this.workspace.snapshot();
		if (this.#stopped) throw new LocalRefusal("session-closed");
		return this.#accept(snapshot);
	}
	/** Keep `snapshot` unless a newer revision is already accepted. Command
	 * preparation and presentation share the accepted revision, including when
	 * concurrent reads finish out of order. */
	#accept(snapshot: WorkspaceSnapshot): WorkspaceSnapshot {
		if (this.#snapshot == null || BigInt(snapshot.revision) >= BigInt(this.#snapshot.revision)) {
			indexAcceptedConversations(snapshot);
			this.#snapshot = snapshot;
			this.#changed();
		}
		return this.#snapshot;
	}
	// A staged edit must not mutate the accepted projection before commitment.
	// One bounded candidate copy belongs to the gesture, then Rust serializes
	// its retained request. Observation reads never pay this copy.
	async candidate(): Promise<WorkspaceSnapshot> {
		return structuredClone(await this.refresh());
	}
	/** Acquisition establishes custody. Registration establishes the chosen name.
	 * Wait on the existing observation owner, retaining the exact original choice. */
	async directoryRegistered(original: DirectoryIntent, signal?: AbortSignal): Promise<void> {
		let expired = false;
		const wake = () => this.#changed();
		const deadline = setTimeout(() => {
			expired = true;
			wake();
		}, DIRECTORY_REGISTRATION_WAIT_MS);
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
			clearTimeout(deadline);
			signal?.removeEventListener("abort", wake);
		}
	}
	initializeManagement(local: boolean, saved: readonly string[]): void {
		void this.#track((async () => {
			if (local) {
				try {
					const control = await this.application.management();
					try {
						(await this.management.hold(OWN_CONTROL, control)).saved = true;
					} catch (error) {
						control.free();
						throw error;
					}
				} catch (error) {
					this.#report(text.management, error);
				}
			}
			await this.management.restore(saved, (id, error) => this.#report(savedControlSource(id), error));
		})()).catch((error) => this.#report(text.management, error));
	}
	async start(): Promise<void> {
		invariant(this.#observation == null, "this workspace viewer is already running");
		// A registration a refused submit leaves is kept for close to retry.
		const observation = await registerObservation(
			this.workspace,
			(request) => this.#observationRequest = request,
		);
		this.#observation = observation;
		const first: ObservationView = await observation.poll();
		this.#access = first.source;
		if (this.permits("observeWorkspace")) await this.refresh();
		this.#observing = this.#observe(first.cursor, observation, this.#generation);
		this.#reading = this.#readActivity();
		if (this.permits("resolvePending")) await this.effects.restore();
	}
	async #observe(cursor: Uint8Array, observation: RoomsManagedObservation, generation: number): Promise<void> {
		let project = false;
		try {
			while (!this.#stopped && generation === this.#generation) {
				const retry = this.#retryObservation;
				try {
					if (!project) {
						const update: ObservationView = await observation.receive(cursor);
						if (this.#stopped || generation !== this.#generation) break;
						cursor = update.cursor;
						this.#access = update.source;
						project = true;
					}
					if (this.permits("observeWorkspace")) await this.refresh();
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
					if (this.#stopped || generation !== this.#generation) break;
					this.#observationFailure = error;
					this.#retryingUpdates = false;
					this.#lost(error);
					this.#report(text.observation, error);
					this.#changed();
					// Keep the same registration and accepted cursor. A failed
					// snapshot retries projection before waiting for another event.
					while (
						!this.#stopped && generation === this.#generation && retry === this.#retryObservation
					) await this.#wait(this.#change);
				}
			}
		} finally {
			// The registration of a replaced link retires with its session.
			if (observation !== this.#observation) observation.free();
		}
	}
	async #readActivity(): Promise<void> {
		while (!this.#stopped) {
			const change = this.#change;
			const generation = this.#generation;
			if (!this.permits("observeWorkspace") || this.#activityListeners.size === 0) {
				// Whatever happens while nothing reads has already happened to the
				// next reader.
				this.#activityBehind = { head: null };
				// Nothing reads activity now, so no failure of it is waiting on a retry.
				if (this.#activityFailure != null) {
					this.#activityFailure = null;
					this.#retryingUpdates = false;
					this.#changed();
				}
				await this.#wait(change);
				continue;
			}
			let offered: ActivityDelivery | undefined;
			try {
				let reader = this.#activity;
				if (reader == null) {
					const opened: RoomsManagedActivityReader = await this.workspace.activityReader();
					if (generation !== this.#generation) {
						opened.free();
						continue;
					}
					this.#activity = reader = opened;
				}
				const behind = this.#activityBehind;
				let delivery: ActivityRead<unknown>;
				let restarted = false;
				try {
					delivery = await reader.read(this.#activityCursor, behind == null);
				} catch (error) {
					if (roomsErrorIn(error)?.code !== ACTIVITY_CURSOR_STALE) throw error;
					// The session restarted since this cursor was kept. Start from the
					// beginning of what it holds, as a gap does.
					restarted = true;
					delivery = { cursor: "", gap: true, head: "" };
				}
				// A gap skips to what the journal still holds, which ends where the
				// journal ends now. A restart says nowhere yet.
				const head = restarted ? null : delivery.gap ? delivery.head : behind?.head ?? delivery.head;
				const empty = delivery.event == null && !delivery.gap && !delivery.unavailable;
				const caughtUp = !restarted && behind != null && (empty || this.#activityCursor === head);
				offered = new ActivityDelivery(delivery, behind != null && !caughtUp);
				if (generation !== this.#generation) {
					offered.close();
					continue;
				}
				const listener = this.#activityListeners.values().next().value;
				if (this.#stopped || listener == null) {
					offered.close();
					continue;
				}
				if (delivery.gap) await this.workspace.resynchronizeDiscovery();
				await listener(offered);
				this.#activityCursor = delivery.cursor;
				this.#activityBehind = (behind == null || caughtUp) && !delivery.gap ? null : { head };
				if (this.#activityFailure != null) {
					this.#activityFailure = null;
					this.#retryingUpdates = false;
					this.#changed();
				}
			} catch (error) {
				offered?.close();
				if (this.#stopped) break;
				if (generation !== this.#generation) continue;
				this.#activityFailure = error;
				this.#activityBehind = { head: null };
				this.#retryingUpdates = false;
				this.#lost(error);
				this.#report(text.activity, error);
				this.#changed();
				// A source observation or an explicit retry wakes this exact reader.
				// Refusal preserves both its custody and its last accepted cursor.
				await this.#wait(this.#change);
			} finally {
				offered?.close();
			}
		}
	}
	/** A read or a command whose connection is gone, and not one the session
	 * refused, says the link is gone. */
	#lost(error: unknown, generation = this.#generation): void {
		// Until the new link replaces it, a failure is the old link's, which a dial is already replacing.
		if (generation === this.#generation && !this.#dialing) this.link?.lost(error);
	}
	/** Whether the current link still answers. */
	async #probe(): Promise<void> {
		await this.#observation?.poll();
	}
	/** Whether a command may go out now. A page whose link is being replaced
	 * holds it until the new link is live, for as long as recovery may take. */
	#linked(): true | Promise<boolean> {
		const link = this.link;
		if (link == null || link.live) return true;
		return link.available(RECOVERY_WAIT_MS);
	}
	/** Hear that a new link replaced the last, once its handles are in place. */
	onRelink(listener: () => void | Promise<void>): () => void {
		this.#relinkListeners.add(listener);
		return () => this.#relinkListeners.delete(listener);
	}
	/** Dial the session again. The old handles change nothing until the new link
	 * has answered, so a dial that fails leaves the page as it was. The dial
	 * ends once the new handles are in place, which makes the link live, and the
	 * rest of the move follows as work of the link's own owners. */
	async #relink(): Promise<void> {
		this.#dialing = true;
		let dialed;
		try {
			dialed = await dialAgain(this.application, this.#workspace, () => this.#stopped);
		} catch (error) {
			this.#dialing = false;
			throw error;
		}
		const { workspace, observation, first, snapshot } = dialed;
		const stale = this.#workspace;
		const staleActivity = this.#activity;
		this.#generation++;
		this.#dialing = false;
		this.#workspace = workspace;
		this.#observation = observation;
		this.#activity = null;
		this.#access = first.source;
		this.#observationFailure = null;
		this.#activityFailure = null;
		this.#retryingUpdates = false;
		// The new reader catches up as a reload does, from the cursor it kept.
		this.#activityBehind = { head: null };
		staleActivity?.free();
		stale.free();
		// An access that may not observe shows no workspace, so the old one goes.
		if (snapshot != null) this.#accept(snapshot);
		else this.#snapshot = null;
		const previous = this.#observing;
		if (previous != null) {
			this.#replaced.add(previous);
			void previous.finally(() => this.#replaced.delete(previous));
		}
		this.#observing = this.#observe(first.cursor, observation, this.#generation);
		this.#changed();
		// One move runs at a time. A move for a link already replaced ends at its
		// next step, and the one after it moves what the newest link holds.
		const generation = this.#generation;
		const moved = this.#moving.then(() => this.#resumeAfterLink(generation));
		this.#moving = moved.catch(() => {
			// tolerant: each step reports its own failure.
		});
		void this.#track(moved);
	}
	/** Everything kept over the old link moves onto the new one. Each owner's
	 * failure is its own, shown where that owner shows it. A lost connection
	 * says the new link is gone too, and the move is not repeated: the next
	 * link starts it again. */
	async #resumeAfterLink(generation: number): Promise<void> {
		const current = () => !this.#stopped && generation === this.#generation;
		const step: Step = async (source, work) => {
			if (!current()) return;
			try {
				await work(current);
			} catch (error) {
				if (connectionLost(error)) this.#lost(error, generation);
				else this.#report(source, error);
			}
		};
		await resumeLink(
			this,
			step,
			(id, error) => this.#report(savedControlSource(id), error),
			this.#relinkListeners,
		);
	}
	#track<T>(task: Promise<T>): Promise<T> {
		const tracked = task.finally(() => this.#inFlight.delete(tracked));
		this.#inFlight.add(tracked);
		return tracked;
	}
	command(...args: Parameters<ManagedEffects["command"]>): Promise<ManagedOperation> {
		return this.effects.command(...args);
	}
	execute(...args: Parameters<ManagedEffects["execute"]>): Promise<void> {
		return this.effects.execute(...args);
	}
	/** Give up on one open change for good: a held acquisition is freed here,
	 * and a receipt is released at the workspace. */
	releaseOperation(id: string): Promise<void> {
		return this.actions.pending.includes(id) ? this.actions.release(id) : this.effects.releaseOperation(id);
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
		// A lost link's registration retires with its session.
		if (this.link?.live ?? true) await this.#observation?.cancel();
		await this.#presentation?.();
		this.#presentation = null;
		// Closing the application ends a dial in flight, which the link waits for.
		const linkClosed = this.link?.close();
		await this.application.close();
		await linkClosed;
		await this.actions.close();
		await this.reads.close();
		await this.drafts.close();
		await this.navigation.close();
		await this.openings.close();
		await this.typing.close();
		await Promise.allSettled([...this.#inFlight, this.#observing, this.#reading, ...this.#replaced]);
		this.#observation?.free();
		this.#observation = null;
		this.#activity?.free();
		this.#activity = null;
		await this.effects.close();
		await this.management.close();
		this.selection.close();
		this.workspace.free();
		this.#custody.free();
		this.application.free();
		this.#listeners.clear();
		this.#activityListeners.clear();
		this.#waiters.clear();
		this.#relinkListeners.clear();
	}
}
