// Own retained gesture coordination from preparation through result acquisition.
import type { RoomsManagedCommand, RoomsManagedWorkspace } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import {
	ManagedOperation,
	readResult,
	ReceiptRetired,
	ResultExpired,
	TerminalObservationError,
	UnsentEffectError,
	WorkspaceConflict,
} from "./operation.ts";
import { discloseFailure, releaseEffect, restoreEffects, resumeEffect } from "./recovery.ts";
import { admitCommand } from "./admission.ts";
import { completeResult } from "./completion.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";

import { gesturesConflict, gestureScope } from "./gestures.ts";
import { OperationLifecycle } from "./lifecycle.ts";
import { CancellationRecovery } from "./cancellation.ts";

export interface GestureContinuation {
	signal?: AbortSignal;
	settled(): Promise<void>;
}

interface EffectRecord {
	lifecycle: OperationLifecycle;
	operation?: ManagedOperation;
	preparing?: boolean;
	recovering?: Promise<ManagedOperation>;
	completing?: Promise<boolean>;
	result?: Promise<unknown>;
	intent?: { name: string; args: string[]; scope: string | null };
	command?: Promise<ManagedOperation>;
	completion?: (operation: ManagedOperation) => Promise<void>;
	adopted?: boolean;
	continuation?: GestureContinuation;
	cancellation?: CancellationRecovery;
}

interface Environment {
	stopped(): boolean;
	observationFailure(): unknown;
	change(): number;
	changed(): void;
	wait(change: number): Promise<void>;
	report(source: string, error: unknown): void;
}

export class ManagedEffects {
	readonly #records = new Map<string, EffectRecord>();
	#commandTail: Promise<void> = Promise.resolve();
	readonly #inFlight = new Set<Promise<unknown>>();
	#record(id: string): EffectRecord {
		let record = this.#records.get(id);
		if (record == null) {
			if (this.#records.size >= SESSION_CONTENT.limits.effects) {
				throw new Error("Recover pending operations before preparing another command");
			}
			record = { lifecycle: new OperationLifecycle(id, () => this.environment.changed()) };
			this.#records.set(id, record);
		}
		return record;
	}
	constructor(readonly session: ManagedRoomsSession, readonly environment: Environment) {}
	get workspace(): RoomsManagedWorkspace {
		return this.session.workspace;
	}
	refresh(): Promise<WorkspaceSnapshot> {
		return this.session.refresh();
	}
	get standingVersion(): string {
		return [...this.#records].filter(([, record]) =>
			["setStanding", "setDirectoryStanding", "setRoomStanding", "setEffectiveStanding"].includes(
				record.intent?.name ?? "",
			)
		).map(([id]) => id).join(",");
	}
	standing(name: string, target: string | null, accepted: string | null): string | null {
		for (const record of this.#records.values()) {
			const intent = record.intent;
			if (
				intent?.name === "setEffectiveStanding" &&
				intent.scope === gestureScope(name, target == null ? [] : [target])
			) {
				return intent.args[1] ?? null;
			}
			if (intent?.name === name && (target == null || intent.args[0] === target)) {
				return intent.args[target == null ? 0 : 1] ?? null;
			}
		}
		return accepted;
	}
	get diagnostics() {
		return [...this.#records.values()].map((record) => record.lifecycle.inspect());
	}
	get resources() {
		return { effects: this.#records.size, workers: this.#inFlight.size };
	}
	get pendingOperations(): Iterable<ManagedOperation> {
		return [...this.#records.values()].flatMap((record) => record.operation == null ? [] : [record.operation]);
	}
	get pending(): readonly string[] {
		return [...this.#records].filter(([, record]) => record.operation != null || record.adopted).map(([id]) => id);
	}
	get recoverable(): readonly string[] {
		return [...this.#records].filter(([, record]) =>
			(record.operation != null || record.adopted) && record.lifecycle.needsDecision &&
			!record.cancellation?.pending
		)
			.map(([id]) => id);
	}
	get cancelledConversations(): readonly string[] {
		// Creation names a new conversation with its operation ID. Direct
		// reconnection can reuse saved data and must not retire its presentation.
		return [...this.#records].filter(([, record]) =>
			record.intent?.name === "openManagedRoom" && record.continuation?.signal?.aborted
		).map(([id]) => id);
	}
	async restore(): Promise<void> {
		await restoreEffects({
			workspace: this.workspace,
			retain: (operation) => {
				const record = this.#record(operation.id);
				record.operation = operation;
			},
			orphan: (operation) => this.#records.get(operation.id)?.lifecycle.orphan(),
			finish: (operation) => this.finish(operation),
			complete: (operation) => this.completeResult(operation),
			report: (error) => this.environment.report(managedText.resultRecovery, error),
		});
		this.environment.changed();
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
		signal?: AbortSignal,
	): Promise<ManagedOperation> {
		const own = this.#records.get(operation);
		if (own?.command != null) {
			if (own.intent?.name !== name || JSON.stringify(own.intent.args) !== JSON.stringify(args)) {
				return Promise.reject(new Error("The submitted gesture has different contents"));
			}
			return own.command;
		}
		try {
			this.reserve(operation, name, args);
		} catch (error) {
			return Promise.reject(error);
		}
		const record = this.#records.get(operation)!;
		const task = record.command = admitCommand(this.session, name, args, operation, validate, signal).finally(
			() => {
				record.command = undefined;
				if (record.operation == null && record.completion == null) this.#records.delete(operation);
				this.environment.changed();
			},
		);
		this.environment.changed();
		return task;
	}
	/** Reserve conflict ownership before non-command preparation, such as reading
	 * picked files. It follows the same command policy until the receipt retires. */
	reserve(operation: string, name: string, args: string[]): void {
		let scope = gestureScope(name, args);
		if (name === "setEffectiveStanding") {
			const room = this.session.current?.intent.conversations.find((row) => row.id === args[0]);
			const directory = this.session.current?.intent.directories.find((row) => row.id === room?.directory);
			scope = room?.kind === "room" && room.standing != null
				? gestureScope("setRoomStanding", [room.id])
				: directory?.standing != null
				? gestureScope("setDirectoryStanding", [directory.id])
				: gestureScope("setStanding", []);
		}
		for (const [id, record] of this.#records) {
			if (
				id !== operation && record.intent != null && gesturesConflict(
					record.intent,
					{ name, args, scope },
					(id) => this.session.current?.intent.conversations.find((row) => row.id === id)?.directory,
				)
			) {
				throw new Error("An operation on this target is still pending. Finish or recover it first.");
			}
		}
		const record = this.#record(operation);
		record.intent = { name, args: [...args], scope };
	}

	// A gesture registers its completion before preparation. Lost admission or
	// acquisition acknowledgments retain that exact gesture; recovery completes
	// its original result rather than preparing another upstream operation.
	async execute(
		operation: string,
		prepare: () => Promise<ManagedOperation>,
		complete: (operation: ManagedOperation) => Promise<void>,
		continuation?: GestureContinuation,
	): Promise<void> {
		if (this.#records.get(operation)?.completion != null) {
			throw new Error("Recover the original gesture before submitting it again");
		}
		const record = this.#record(operation);
		record.completion = complete;
		record.continuation = continuation;
		record.cancellation = new CancellationRecovery(
			continuation?.signal,
			() =>
				!this.environment.stopped() && record.completing == null && this.#records.get(operation) === record &&
				(record.operation != null || record.adopted === true),
			() => this.completeOperation(operation),
			() => this.environment.changed(),
		);
		const task = this.#track(record.lifecycle.own("preparing", async () => {
			await complete(await prepare());
			record.adopted = true;
			await continuation?.settled();
			return true;
		}));
		record.completing = task;
		try {
			await task;
			record.completion = undefined;
			if (record.operation == null) this.#forget(operation);
		} catch (error) {
			if (record.operation == null && !record.adopted) this.#forget(operation);
			record.completing = undefined;
			const recovery = record.cancellation?.idle();
			if (recovery != null) {
				await recovery;
				continuation?.signal?.throwIfAborted();
			}
			throw error;
		} finally {
			record.completing = undefined;
			this.environment.changed();
		}
	}
	/** Give up on a retained operation for good. See `releaseEffect`. */
	releaseOperation(id: string): Promise<void> {
		const record = this.#records.get(id);
		if (record?.adopted) {
			return Promise.reject(new Error("Complete cancellation cleanup before releasing this gesture"));
		}
		if (record != null && (!record.lifecycle.needsDecision || record.operation?.acquiring)) {
			return Promise.reject(new Error("Recover the original operation and acquisition before releasing it"));
		}
		return this.#track(
			releaseEffect(this.workspace, id, record?.operation, (held) => this.finish(held)).then(() => {
				this.#forget(id);
				this.environment.changed();
			}),
		);
	}
	completeOperation(id: string): Promise<boolean> {
		const record = this.#record(id);
		const existing = record.completing;
		if (existing != null) return existing;
		const result = record.result;
		if (result != null) return result.then(() => true);
		const task = this.#track(
			record.lifecycle.own("completing", async () => {
				let operation: ManagedOperation;
				if (record.adopted) {
					await record.continuation?.settled();
					this.#forget(id);
					return true;
				}
				try {
					operation = await this.resume(id);
				} catch (error) {
					if (error instanceof ReceiptRetired) {
						record.adopted = true;
						await record.continuation?.settled();
						this.#forget(id);
						return true;
					}
					throw error;
				}
				const complete = record.completion;
				try {
					if (complete == null) await this.completeResult(operation);
					else await complete(operation);
					record.adopted = true;
					await record.continuation?.settled();
				} catch (error) {
					if (!(error instanceof ResultExpired)) throw error;
					// Committed, with nothing left to acquire: settle and journal the loss.
					if (record.operation === operation) this.finish(operation);
					this.environment.report(managedText.resultRecovery, error);
				}
				if (record.operation == null) this.#forget(id);
				return true;
			}).finally(() => {
				record.completing = undefined;
				this.environment.changed();
			}),
		);
		record.completing = task;
		return task;
	}
	completeResult(operation: ManagedOperation): Promise<unknown> {
		const record = this.#record(operation.id);
		const existing = record.result;
		if (existing != null) return existing;
		const task = this.#track(
			record.lifecycle.own("acquiring", () => completeResult(this.session, operation)).then((result) => {
				this.finish(operation);
				return result;
			}).finally(() => {
				record.result = undefined;
				this.environment.changed();
			}),
		);
		record.result = task;
		return task;
	}
	perform(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		const record = this.#record(operation);
		return this.#track(record.lifecycle.own("queued", () => this.#perform(operation, prepare))).finally(() => {
			if (record.operation == null && record.completion == null && record.intent == null) {
				this.#records.delete(operation);
			}
		});
	}
	async #perform(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		if (this.environment.stopped()) throw new Error("This workspace is closed");
		const record = this.#record(operation);
		if (record.operation != null || record.preparing) {
			throw new Error("Recover the retained request before submitting another command");
		}
		record.preparing = true;
		// This viewer's writes share one revision authority, so admissions take
		// turns that end at admission. Each receipt then settles on its own, and a
		// slow upstream effect holds back no later gesture.
		const previous = this.#commandTail;
		let release!: () => void;
		this.#commandTail = new Promise<void>((resolve) => release = resolve);
		let admitted: ManagedOperation;
		try {
			await previous;
			if (this.environment.stopped()) throw new Error("This workspace is closed");
			admitted = await this.#admit(operation, prepare);
		} finally {
			record.preparing = false;
			this.environment.changed();
			release();
		}
		return await this.#settle(admitted);
	}
	async #admit(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		const request = await prepare();
		if (this.environment.stopped()) {
			request.free();
			throw new Error("This workspace is closed");
		}
		const record = this.#record(operation);
		const pending = new ManagedOperation(operation, request, undefined, (error) => record.lifecycle.orphan(error));
		record.operation = pending;
		record.lifecycle.phase = "admitting";
		record.lifecycle.outcome = "unknown";
		this.environment.changed();
		const admitted = await request.submit();
		if (admitted === "conflict") {
			record.operation = undefined;
			record.lifecycle.outcome = "notAdmitted";
			request.free();
			this.environment.changed();
			await this.refresh();
			throw new WorkspaceConflict();
		}
		record.lifecycle.phase = "settling";
		return pending;
	}
	async #settle(operation: ManagedOperation): Promise<ManagedOperation> {
		while (!this.environment.stopped()) {
			const change = this.environment.change();
			const status = await operation.status();
			const record = this.#record(operation.id);
			record.lifecycle.outcome = status === "committed"
				? "committed"
				: status === "pending"
				? "pending"
				: "unknown";
			if (status === "committed") {
				try {
					await this.refresh();
				} catch (error) {
					this.environment.changed();
					throw operation.completionError(error);
				}
				return operation;
			}
			if (status !== "pending") {
				if (status === "unsent") {
					// Admission refusal proves no dispatch and retains its exact
					// diagnostic. A locally unsent receipt may have no such result.
					try {
						await readResult(operation.request);
					} catch (error) {
						if (error instanceof TerminalObservationError) {
							throw new UnsentEffectError(error.message, { cause: error });
						}
						throw error;
					} finally {
						this.finish(operation);
					}
					throw new Error("The upstream operation was not sent.");
				}
				// Failed observations disclose their reason through the exact
				// original receipt, with current authority checked again.
				if (status === "unknown") {
					await discloseFailure(operation.request, () => this.finish(operation));
				}
				throw new Error(`The retained operation is ${status}. Recover its original receipt.`);
			}
			if (this.environment.observationFailure() != null) throw this.environment.observationFailure();
			if (change !== this.environment.change()) continue;
			operation.observe(() => this.environment.changed());
			await this.environment.wait(change);
			if (this.environment.stopped()) {
				throw new Error("The viewer closed while its original operation remained pending");
			}
		}
		throw new Error("The viewer closed while its original operation remained pending");
	}
	finish(operation: ManagedOperation): void {
		const record = this.#records.get(operation.id);
		if (record?.operation !== operation) {
			throw new Error("This operation belongs to another viewer");
		}
		operation.finish();
		if (record.completion == null) this.#forget(operation.id);
		else record.operation = undefined;
		this.environment.changed();
	}
	#forget(id: string): void {
		this.#records.get(id)?.cancellation?.dispose();
		this.#records.delete(id);
	}
	resume(operation: string): Promise<ManagedOperation> {
		if (this.environment.stopped()) return Promise.reject(new Error("This workspace is closed"));
		const record = this.#record(operation);
		if (record.recovering != null) return record.recovering;
		if (record.preparing) return Promise.reject(new Error("This operation is still preparing"));
		const task = this.#track(
			record.lifecycle.own("settling", () => this.#resume(operation)).finally(() => {
				record.recovering = undefined;
				if (record.operation == null && record.completion == null) this.#records.delete(operation);
				this.environment.changed();
			}),
		);
		record.recovering = task;
		return task;
	}
	async #resume(operation: string): Promise<ManagedOperation> {
		const record = this.#record(operation);
		const request = record.operation;
		if (request?.acquiring) {
			await request.retryAcquisition();
			await this.refresh();
			return request;
		}
		if (request != null) {
			// The held request already owns its intent and source. Continuing a
			// known receipt uses ordinary completion; cold or unknown receipts
			// still pass through privileged recovery below.
			let status: string | null;
			try {
				status = await request.status();
			} catch {
				// Recovery checks exact absence before releasing an expired wrapper.
				status = null;
			}
			if (status === "committed" || status === "pending" || status === "unsent") return this.#settle(request);
		}
		const recovered = await this.workspace.recoverEffect(operation);
		if (recovered == null) {
			// Exact absence: another viewer adopted and retired this receipt, the
			// same rule startup restoration applies. A retained wrapper has nothing
			// left to recover, so it is released rather than left to fail again.
			if (request != null) {
				this.finish(request);
				await this.refresh();
				throw new ReceiptRetired();
			}
			throw new Error("The original receipt is no longer recoverable; it cannot be resent");
		}
		let retained = false;
		try {
			const status = await resumeEffect(recovered, () => {
				if (request != null) this.finish(request);
			}, (observed) => request?.observeStatus(observed));
			if (this.environment.stopped()) throw new Error("This workspace is closed");
			if (request != null) return await this.#settle(request);
			if (status !== "committed") throw new Error(`The original receipt is ${status}.`);
			const pending = new ManagedOperation(
				operation,
				recovered,
				status,
				(error) => record.lifecycle.orphan(error),
			);
			record.operation = pending;
			retained = true;
			this.environment.changed();
			return pending;
		} finally {
			if (!retained) recovered.free();
		}
	}
	async close(): Promise<void> {
		await Promise.allSettled(this.#inFlight);
		await Promise.all([...this.pendingOperations].map((operation) => operation.close()));
		for (const record of this.#records.values()) record.cancellation?.dispose();
		this.#records.clear();
	}
}
