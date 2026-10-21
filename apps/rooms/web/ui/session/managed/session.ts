// One production viewer over explicit managed use. Rust owns memberships,
// persistent authority, retained effect execution and physical storage.
import type {
	RoomsManagedActivityReader,
	RoomsManagedApplication,
	RoomsManagedObservation,
	RoomsManagedObservationRequest,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ManagedAccess, OWN_CONTROL } from "./access.ts";
import type { ManagedOperation } from "./operation.ts";
import { ManagedReads } from "./reads.ts";
import { ManagedEffects } from "./effects.ts";
import { ManagedActions } from "./actions.ts";
import { ActivityDelivery } from "./activity.ts";
import { ManagedDrafts } from "./drafts.ts";
import { ManagedOpenings } from "./openings.ts";
import { ManagedNavigation } from "./navigation.ts";
import { ManagedTyping } from "./typing.ts";
import { ManagedSelection } from "./selection.ts";
import type { ActivityPage, DirectoryIntent, ObservationView, UseView, WorkspaceSnapshot } from "./model.ts";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { managedAccessText as text, savedControlSource } from "../../../../lib/text/managed_access.ts";
import { READINESS_WAIT_MS, ReadinessNotices } from "./readiness.ts";
import type { ReadinessNotice } from "./readiness.ts";

export class ManagedRoomsSession {
	readonly application: RoomsManagedApplication;
	readonly workspace: RoomsManagedWorkspace;
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
	readonly #notices = new ReadinessNotices();
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
	readonly #report: (source: string, error: unknown) => void;

	constructor(
		application: RoomsManagedApplication,
		workspace: RoomsManagedWorkspace,
		custody: RoomsManagedWorkspace,
		report: (source: string, error: unknown) => void,
	) {
		this.application = application;
		this.workspace = workspace;
		this.#custody = custody;
		this.management = new ManagedAccess(application, custody, (error) => report(text.management, error));
		this.effects = new ManagedEffects(this, {
			stopped: () => this.#stopped,
			observationFailure: () => this.#observationFailure,
			change: () => this.#change,
			changed: () => this.#changed(),
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
	get resources() {
		return {
			effects: this.effects.resources,
			acquisitions: this.actions.resources,
			workers: this.#inFlight.size,
			reads: this.reads.active,
			listeners: this.#listeners.size + this.#activityListeners.size,
			waiters: this.#waiters.size,
			observation: this.#observation != null,
			activity: this.#activity != null,
		};
	}
	get current(): WorkspaceSnapshot | null {
		return this.#snapshot;
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
	/** A retry was asked and no stream has answered it yet.  status-allow: pending state or quoted runtime label */
	get updatesRetrying(): boolean {
		return this.#retryingUpdates;
	}
	get pendingOperations(): Iterable<ManagedOperation> {
		return this.effects.pendingOperations;
	}
	permits(permission: RoomsPermission): boolean {
		return this.#access.status === "active" && this.#access.effective?.permissions.includes(permission) === true;
	}
	subscribe = (listener: () => void): () => void => {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	};
	onActivity(listener: (delivery: ActivityDelivery) => void | Promise<void>): () => void {
		if (this.#activityListeners.size !== 0) throw new Error("Activity custody already has a presentation owner");
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
			throw new Error("This viewer already has a presentation owner");
		}
		this.#presentation = stop;
	}
	waitNotice(
		matches: (event: ReadinessNotice) => boolean,
	): { ready: Promise<void>; cancel(): void } {
		return this.#notices.wait(matches);
	}
	async refresh(): Promise<WorkspaceSnapshot> {
		if (this.#stopped) throw new Error("This workspace is closed");
		const snapshot: WorkspaceSnapshot = await this.workspace.snapshot();
		if (this.#stopped) throw new Error("This workspace is closed");
		if (this.#snapshot == null || BigInt(snapshot.revision) >= BigInt(this.#snapshot.revision)) {
			this.#snapshot = snapshot;
			this.#changed();
		}
		// Command preparation and presentation share the accepted revision,
		// including when concurrent reads finish out of order.
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
		}, READINESS_WAIT_MS);
		signal?.addEventListener("abort", wake, { once: true });
		try {
			while (!this.#stopped && !signal?.aborted) {
				const change = this.#change;
				const row = this.#snapshot?.intent.directories.find((row) => row.id === original.id);
				if (
					row == null || row.access !== original.access || row.source !== original.source ||
					row.nick !== original.nick || row.nickAllocation !== original.nickAllocation
				) throw new Error("The original directory or nickname choice changed");
				if (row.name != null && row.assignedNick != null) return;
				if (this.#observationFailure != null) throw this.#observationFailure;
				if (expired) throw new Error("Directory registration did not complete. Review its original operation.");
				await this.#wait(change);
			}
			if (this.#stopped) throw new Error("This workspace is closed");
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
		if (this.#observation != null) throw new Error("This workspace viewer is already running");
		const registering: RoomsManagedObservationRequest = await this.workspace.prepareObservation();
		this.#observationRequest = registering;
		const observation = await registering.submit();
		this.#observation = observation;
		registering.free();
		this.#observationRequest = null;
		const first: ObservationView = await observation.poll();
		this.#access = first.source;
		if (this.permits("observeWorkspace")) await this.refresh();
		this.#observing = this.#observe(first.cursor);
		this.#reading = this.#readActivity();
		if (this.permits("resolvePending")) await this.effects.restore();
	}
	async #observe(cursor: Uint8Array): Promise<void> {
		// Only start() launches this loop, with the observation already bound.
		// A null here names a lifecycle state, not an expected branch.
		const observation = this.#observation;
		if (observation == null) throw new Error("the workspace observation runs only while the viewer is started");
		let project = false;
		while (!this.#stopped) {
			const retry = this.#retryObservation;
			try {
				if (!project) {
					const update: ObservationView = await observation.receive(cursor);
					if (this.#stopped) break;
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
				if (this.#stopped) break;
				this.#observationFailure = error;
				this.#retryingUpdates = false;
				this.#report(text.observation, error);
				this.#changed();
				// Keep the same registration and accepted cursor. A failed
				// snapshot retries projection before waiting for another event.
				while (!this.#stopped && retry === this.#retryObservation) await this.#wait(this.#change);
			}
		}
	}
	async #readActivity(): Promise<void> {
		while (!this.#stopped) {
			const change = this.#change;
			if (!this.permits("observeWorkspace") || this.#activityListeners.size === 0) {
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
				const reader: RoomsManagedActivityReader = this.#activity ?? await this.workspace.activityReader();
				this.#activity = reader;
				const delivery: ActivityPage<unknown> = await reader.read(this.#activityCursor, true);
				offered = new ActivityDelivery(delivery);
				const listener = this.#activityListeners.values().next().value;
				if (this.#stopped || listener == null) {
					offered.close();
					continue;
				}
				if (delivery.gap) await this.workspace.resynchronizeDiscovery();
				if (offered.event != null) {
					this.#notices.notify(offered.event);
				}
				await listener(offered);
				this.#activityCursor = delivery.cursor;
				if (this.#activityFailure != null) {
					this.#activityFailure = null;
					this.#retryingUpdates = false;
					this.#changed();
				}
			} catch (error) {
				offered?.close();
				if (this.#stopped) break;
				this.#activityFailure = error;
				this.#retryingUpdates = false;
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
	releaseOperation(id: string): Promise<void> {
		return this.effects.releaseOperation(id);
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
		this.#notices.close();
		this.#changed();
		// Keep the observation handle if cancellation refuses. A retry uses the
		// original registration and cannot create a second watcher.
		if (this.#observationRequest != null) {
			this.#observation = await this.#observationRequest.submit();
			this.#observationRequest.free();
			this.#observationRequest = null;
		}
		await this.#observation?.cancel();
		await this.#presentation?.();
		this.#presentation = null;
		await this.application.close();
		await this.actions.close();
		await this.reads.close();
		await this.drafts.close();
		await this.navigation.close();
		await this.openings.close();
		await this.typing.close();
		await Promise.allSettled([...this.#inFlight, this.#observing, this.#reading]);
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
	}
}
