import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
// One production viewer over explicit managed use. Rust owns memberships,
// persistent authority, retained effect execution and physical storage.
import type {
	RoomsManagedActivityReader,
	RoomsManagedApplication,
	RoomsManagedCommand,
	RoomsManagedObservation,
	RoomsManagedObservationRequest,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ManagedAccess, OWN_CONTROL } from "./access.ts";
import { ManagedOperation, ReceiptRetired, ResultExpired, WorkspaceConflict } from "./operation.ts";
import { discloseFailure, releaseEffect, restoreEffects, resumeEffect } from "./recovery.ts";
import { ManagedActions } from "./actions.ts";
import { completeResult } from "./completion.ts";
import { ActivityDelivery } from "./activity.ts";
import { ManagedDrafts } from "./drafts.ts";
import { ManagedNavigation } from "./navigation.ts";
import { ManagedTyping } from "./typing.ts";
import { ManagedSelection } from "./selection.ts";
import type { ActivityPage, DirectoryIntent, ObservationView, UseView, WorkspaceSnapshot } from "./model.ts";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { managedAccessText as text, savedControlSource } from "../../../../lib/text/managed_access.ts";
import { admitCommand } from "./admission.ts";
import { READINESS_WAIT_MS, ReadinessNotices } from "./readiness.ts";
import type { ReadinessNotice } from "./readiness.ts";

export class ManagedRoomsSession {
	readonly application: RoomsManagedApplication;
	readonly workspace: RoomsManagedWorkspace;
	readonly management: ManagedAccess;
	readonly actions: ManagedActions;
	readonly drafts: ManagedDrafts;
	readonly navigation: ManagedNavigation;
	readonly typing: ManagedTyping;
	readonly selection: ManagedSelection;
	readonly #custody: RoomsManagedWorkspace;
	readonly #pending = new Map<string, ManagedOperation>();
	readonly #preparing = new Set<string>();
	#commandTail: Promise<void> = Promise.resolve();
	readonly #inFlight = new Set<Promise<unknown>>();
	readonly #recovering = new Map<string, Promise<ManagedOperation>>();
	readonly #listeners = new Set<() => void>();
	readonly #activityListeners = new Set<(delivery: ActivityDelivery) => void | Promise<void>>();
	readonly #completions = new Map<string, (operation: ManagedOperation) => Promise<void>>();
	readonly #completing = new Map<string, Promise<boolean>>();
	readonly #resultCompletions = new Map<ManagedOperation, Promise<unknown>>();
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
		this.actions = new ManagedActions(this);
		this.drafts = new ManagedDrafts(this);
		this.navigation = new ManagedNavigation(this, () => this.#changed());
		this.typing = new ManagedTyping(this);
		this.selection = new ManagedSelection(application, custody, (task) => this.#track(task));
		this.#report = report;
	}
	get current(): WorkspaceSnapshot | null {
		return this.#snapshot;
	}
	get access(): UseView {
		return this.#access;
	}
	get pending(): readonly string[] {
		return [...this.#pending.keys()];
	}
	get recoverable(): readonly string[] {
		return [...this.#pending].filter(([id, operation]) =>
			!this.#preparing.has(id) && !this.#recovering.has(id) &&
			!this.#completing.has(id) && !this.#resultCompletions.has(operation)
		).map(([id]) => id);
	}
	#reserved(): number {
		let count = this.#pending.size;
		for (const id of this.#preparing) if (!this.#pending.has(id)) count++;
		return count;
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
		return this.#pending.values();
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
		return snapshot;
	}
	// A staged edit must not mutate the accepted projection before commitment.
	// One bounded candidate copy belongs to the gesture, then Rust serializes
	// its retained request. Observation reads never pay this copy.
	async candidate(): Promise<WorkspaceSnapshot> {
		return structuredClone(await this.refresh());
	}
	/** Acquisition establishes custody; registration establishes the chosen name.
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
		this.#observation = await registering.submit();
		registering.free();
		this.#observationRequest = null;
		const first: ObservationView = await this.#observation!.poll();
		this.#access = first.source;
		if (this.permits("observeWorkspace")) await this.refresh();
		this.#observing = this.#observe(first.cursor);
		this.#reading = this.#readActivity();
		if (this.permits("resolvePending")) await this.#restoreEffects();
	}
	async #restoreEffects(): Promise<void> {
		await restoreEffects({
			workspace: this.workspace,
			retain: (operation) => this.#pending.set(operation.id, operation),
			finish: (operation) => this.finish(operation),
			complete: (operation) => this.completeResult(operation),
			report: (error) => this.#report(managedText.resultRecovery, error),
		});
		this.#changed();
	}
	async #observe(cursor: Uint8Array): Promise<void> {
		let project = false;
		while (!this.#stopped) {
			const retry = this.#retryObservation;
			try {
				if (!project) {
					const update: ObservationView = await this.#observation!.receive(cursor);
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
				const delivery: ActivityPage = await reader.read(this.#activityCursor, true);
				offered = new ActivityDelivery(delivery);
				const listener = this.#activityListeners.values().next().value;
				if (this.#stopped || listener == null) {
					offered.close();
					continue;
				}
				if (delivery.gap) await this.workspace.resynchronizeDiscovery();
				if (delivery.event != null) {
					this.#notices.notify(delivery.event);
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
	command(
		name: string,
		args: string[] = [],
		operation: string = crypto.randomUUID(),
		validate?: (snapshot: WorkspaceSnapshot) => void,
	): Promise<ManagedOperation> {
		return admitCommand(this, name, args, operation, validate);
	}
	// A gesture registers its completion before preparation. Lost admission or
	// acquisition acknowledgments retain that exact gesture; recovery completes
	// its original result rather than preparing another upstream operation.
	async execute(
		operation: string,
		prepare: () => Promise<ManagedOperation>,
		complete: (operation: ManagedOperation) => Promise<void>,
	): Promise<void> {
		if (this.#completions.has(operation)) {
			throw new Error("Recover the original gesture before submitting it again");
		}
		this.#completions.set(operation, complete);
		const task = this.#track((async () => {
			await complete(await prepare());
			return true;
		})());
		this.#completing.set(operation, task);
		try {
			await task;
			this.#completions.delete(operation);
		} catch (error) {
			if (!this.#pending.has(operation)) this.#completions.delete(operation);
			throw error;
		} finally {
			this.#completing.delete(operation);
			this.#changed();
		}
	}
	/** Give up on a retained operation for good; see `releaseEffect`. */
	releaseOperation(id: string): Promise<void> {
		if (
			this.#preparing.has(id) || this.#recovering.has(id) || this.#completing.has(id) ||
			this.#pending.get(id)?.acquiring ||
			(this.#pending.has(id) && !this.recoverable.includes(id))
		) return Promise.reject(new Error("Recover the original operation and acquisition before releasing it"));
		return this.#track(releaseEffect(this.workspace, id, this.#pending.get(id), (held) => this.finish(held)));
	}
	completeOperation(id: string): Promise<boolean> {
		const existing = this.#completing.get(id);
		if (existing != null) return existing;
		const pending = this.#pending.get(id);
		const result = pending == null ? null : this.#resultCompletions.get(pending);
		if (result != null) return result.then(() => true);
		const task = this.#track(
			(async () => {
				let operation: ManagedOperation;
				try {
					operation = await this.resume(id);
				} catch (error) {
					if (error instanceof ReceiptRetired) return true;
					throw error;
				}
				const complete = this.#completions.get(id);
				try {
					if (complete == null) await this.completeResult(operation);
					else await complete(operation);
				} catch (error) {
					if (!(error instanceof ResultExpired)) throw error;
					// Committed, with nothing left to acquire: settle and journal the loss.
					if (this.#pending.get(id) === operation) this.finish(operation);
					this.#report(managedText.resultRecovery, error);
				}
				return true;
			})().finally(() => {
				this.#completing.delete(id);
				this.#changed();
			}),
		);
		this.#completing.set(id, task);
		return task;
	}
	completeResult(operation: ManagedOperation): Promise<unknown> {
		const existing = this.#resultCompletions.get(operation);
		if (existing != null) return existing;
		const task = this.#track(
			completeResult(this, operation).then((result) => {
				this.finish(operation);
				return result;
			}).finally(() => {
				this.#resultCompletions.delete(operation);
				this.#changed();
			}),
		);
		this.#resultCompletions.set(operation, task);
		return task;
	}
	perform(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		return this.#track(this.#perform(operation, prepare));
	}
	async #perform(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		if (this.#stopped) throw new Error("This workspace is closed");
		if (this.#pending.has(operation) || this.#preparing.has(operation)) {
			throw new Error("Recover the retained request before submitting another command");
		}
		if (this.#reserved() >= SESSION_CONTENT.limits.effects) {
			throw new Error("Recover pending operations before preparing another command");
		}
		this.#preparing.add(operation);
		// This viewer's writes share one revision authority, so admissions take
		// turns that end at admission. Each receipt then settles on its own, and a
		// slow upstream effect holds back no later gesture.
		const previous = this.#commandTail;
		let release!: () => void;
		this.#commandTail = new Promise<void>((resolve) => release = resolve);
		let admitted: ManagedOperation;
		try {
			await previous;
			if (this.#stopped) throw new Error("This workspace is closed");
			admitted = await this.#admit(operation, prepare);
		} finally {
			this.#preparing.delete(operation);
			this.#changed();
			release();
		}
		return await this.#settle(admitted);
	}
	async #admit(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		const request = await prepare();
		if (this.#stopped) {
			request.free();
			throw new Error("This workspace is closed");
		}
		const pending = new ManagedOperation(operation, request);
		this.#pending.set(operation, pending);
		this.#changed();
		const admitted = await request.submit();
		if (admitted === "conflict") {
			this.#pending.delete(operation);
			request.free();
			this.#changed();
			await this.refresh();
			throw new WorkspaceConflict();
		}
		return pending;
	}
	async #settle(operation: ManagedOperation): Promise<ManagedOperation> {
		while (!this.#stopped) {
			const change = this.#change;
			const status = await operation.request.status();
			if (status === "committed") {
				await this.refresh();
				return operation;
			}
			if (status !== "pending") {
				if (status === "unsent") {
					this.finish(operation);
					throw new Error("The upstream operation was not sent.");
				}
				// Failed observations disclose their reason through the exact
				// original receipt, with current authority checked again.
				if (status === "unknown") {
					await discloseFailure(operation.request, () => this.finish(operation));
				}
				throw new Error(`The retained operation is ${status}. Recover its original receipt.`);
			}
			if (this.#observationFailure != null) throw this.#observationFailure;
			if (change !== this.#change) continue;
			operation.observe(() => this.#changed());
			await this.#wait(change);
			if (this.#stopped) throw new Error("The viewer closed while its original operation remained pending");
		}
		throw new Error("The viewer closed while its original operation remained pending");
	}
	finish(operation: ManagedOperation): void {
		if (this.#pending.get(operation.id) !== operation) throw new Error("This operation belongs to another viewer");
		operation.finish();
		this.#pending.delete(operation.id);
		this.#completions.delete(operation.id);
		this.#changed();
	}
	resume(operation: string): Promise<ManagedOperation> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		const existing = this.#recovering.get(operation);
		if (existing != null) return existing;
		if (this.#preparing.has(operation)) return Promise.reject(new Error("This operation is still preparing"));
		const fresh = !this.#pending.has(operation);
		if (fresh && this.#reserved() >= SESSION_CONTENT.limits.effects) {
			return Promise.reject(new Error("Recover pending operations before restoring another receipt"));
		}
		if (fresh) this.#preparing.add(operation);
		const task = this.#track(
			this.#resume(operation).finally(() => {
				this.#recovering.delete(operation);
				if (fresh) this.#preparing.delete(operation);
				this.#changed();
			}),
		);
		this.#recovering.set(operation, task);
		return task;
	}
	async #resume(operation: string): Promise<ManagedOperation> {
		const request = this.#pending.get(operation);
		if (request?.acquiring) {
			await request.retryAcquisition();
			await this.refresh();
			return request;
		}
		const recovered = await this.workspace.recoverEffect(operation);
		if (recovered == null) {
			// Exact absence: another viewer adopted and retired this receipt, the
			// same rule startup restoration applies. A retained wrapper has nothing
			// left to recover, so it is released rather than left to fail again.
			if (request != null) {
				this.finish(request);
				throw new ReceiptRetired();
			}
			throw new Error("The original receipt is no longer recoverable; it cannot be resent");
		}
		let retained = false;
		try {
			const status = await resumeEffect(recovered, () => {
				if (request != null) this.finish(request);
			});
			if (this.#stopped) throw new Error("This workspace is closed");
			if (request != null) return await this.#settle(request);
			if (status !== "committed") throw new Error(`The original receipt is ${status}.`);
			const pending = new ManagedOperation(operation, recovered);
			this.#pending.set(operation, pending);
			retained = true;
			this.#changed();
			return pending;
		} finally {
			if (!retained) recovered.free();
		}
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
		this.drafts.stop();
		this.navigation.stop();
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
		await this.drafts.close();
		await this.navigation.close();
		await this.typing.close();
		await Promise.allSettled([...this.#inFlight, this.#observing, this.#reading]);
		this.#observation?.free();
		this.#observation = null;
		this.#activity?.free();
		this.#activity = null;
		await Promise.all([...this.#pending.values()].map((request) => request.close()));
		this.#pending.clear();
		this.#completions.clear();
		await this.management.close();
		this.selection.close();
		this.workspace.free();
		this.#custody.free();
		this.application.free();
	}
}
