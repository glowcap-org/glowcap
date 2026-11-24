// Own retained gesture coordination from preparation through result acquisition.
import { invariant } from "../../../../lib/invariant.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { conversationById } from "./conversation_lookup.ts";
import type { RoomsManagedCommand, RoomsManagedWorkspace } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import { ManagedOperation, ReceiptRetired, ResultExpired, WorkspaceConflict } from "./operation.ts";
import { releaseEffect, restoreEffects, resumeEffect } from "./recovery.ts";
import { admitCommand } from "./admission.ts";
import { rehome, resend, returned, surviving } from "./effects_link.ts";
import { watchReceipt } from "./effects_watch.ts";
import { SubmissionRefused, submitCommand } from "./acquisition.ts";
import { completeResult } from "./completion.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";

import { gesturesConflict, gestureScope } from "./gestures.ts";
import { OperationLifecycle } from "./lifecycle.ts";
import { CancellationRecovery } from "./cancellation.ts";

interface GestureContinuation {
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
	/** Whether the link to the session is live, waiting for it up to a request's time. */
	linked(): true | Promise<boolean>;
	/** After a lost connection: whether a new link comes, which is never so for a
	 * session this browser runs. Waits for as long as the page is trying. */
	relinked(): Promise<boolean>;
	/** The link a failure belongs to, so a replaced link's failures name no loss of its successor. */
	generation(): number;
	/** Why the session refused the link for good, or null. */
	refused(): unknown;
	lost(error: unknown, generation: number): void;
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
				throw new LocalRefusal("unfinished-limit");
			}
			record = { lifecycle: new OperationLifecycle(id, () => this.environment.changed()) };
			this.#records.set(id, record);
		}
		return record;
	}
	constructor(readonly session: ManagedRoomsSession, readonly environment: Environment) {}
	/** The receipt this page holds for `id`, if any. */
	held(id: string): ManagedOperation | undefined {
		return this.#records.get(id)?.operation;
	}
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
	roomStandingPending(target: string): boolean {
		const scope = gestureScope("setRoomStanding", [target]);
		return [...this.#records.values()].some(({ intent }) =>
			intent?.scope === scope &&
			(intent.name === "setRoomStanding" || intent.name === "setEffectiveStanding")
		);
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
	/** Whether any change is being prepared, sent, settled or completed. */
	get busy(): boolean {
		return [...this.#records.values()].some((record) =>
			record.preparing === true || record.operation != null || record.lifecycle.owners.size > 0
		);
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
	/** The link was replaced. A receipt held over the old link is taken up again
	 * by its operation id and finished from the session's own record. Nothing is
	 * prepared or sent a second time, and a receipt with a worker running is
	 * left to it. Receipts this page did not know of are then adopted as at
	 * startup. */
	async relink(adopt: boolean): Promise<void> {
		for (const [id, record] of [...this.#records]) {
			if (record.operation == null || record.lifecycle.owners.size > 0) continue;
			void this.completeOperation(id).catch((error: unknown) =>
				this.environment.report(managedText.resultRecovery, error)
			);
		}
		this.environment.changed();
		if (adopt) await this.restore();
	}
	async restore(): Promise<void> {
		await restoreEffects({
			workspace: this.workspace,
			known: (id) => this.#records.has(id),
			retain: (operation) => {
				const record = this.#record(operation.id);
				operation.link = this.environment.generation();
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
		try {
			if (own?.command != null) {
				invariant(
					own.intent?.name === name && JSON.stringify(own.intent.args) === JSON.stringify(args),
					"the submitted gesture has different contents",
				);
				return own.command;
			}
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
			const room = conversationById(this.session.current, args[0]);
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
					(id) => conversationById(this.session.current, id)?.directory,
				)
			) {
				throw new LocalRefusal("change-blocked");
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
			throw new LocalRefusal("change-owned");
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
			await surviving(this, operation, await prepare(), complete);
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
			return Promise.reject(new LocalRefusal("result-held"));
		}
		if (record?.operation?.acquiring) {
			return Promise.reject(new LocalRefusal("result-saving"));
		}
		if (record != null && !record.lifecycle.needsDecision) {
			return Promise.reject(new LocalRefusal("change-busy"));
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
				if (record.adopted) {
					await record.continuation?.settled();
					this.#forget(id);
					return true;
				}
				const held: { operation: ManagedOperation | null } = { operation: null };
				try {
					await surviving(this, id, null, async (operation) => {
						held.operation = operation;
						const complete = record.completion;
						if (complete == null) await this.completeResult(operation);
						else await complete(operation);
					});
					record.adopted = true;
					await record.continuation?.settled();
				} catch (error) {
					if (error instanceof ReceiptRetired) {
						record.adopted = true;
						await record.continuation?.settled();
						this.#forget(id);
						return true;
					}
					if (!(error instanceof ResultExpired)) throw error;
					// Committed, with nothing left to acquire: settle and journal the loss.
					if (held.operation != null && record.operation === held.operation) this.finish(held.operation);
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
		if (this.environment.stopped()) throw new LocalRefusal("session-closed");
		const record = this.#record(operation);
		if (record.operation != null || record.preparing) {
			throw new LocalRefusal("change-replay-required");
		}
		record.preparing = true;
		let generation = this.environment.generation();
		try {
			let admitted: ManagedOperation | null = null;
			let unacknowledged: unknown = null;
			try {
				// Nothing is admitted until the link is live, so a line sent while the
				// page reconnects goes out once, or is refused unsent at the bound.
				const linked = this.environment.linked();
				if (linked !== true && !(await linked)) {
					// A refusal the session answered says why, in its own words.
					throw this.environment.stopped()
						? new LocalRefusal("session-closed")
						: this.environment.refused() ?? new LocalRefusal("not-sent");
				}
				generation = this.environment.generation();
				try {
					admitted = await this.#turn(operation, prepare);
				} catch (error) {
					if (!connectionLost(error)) throw error;
					unacknowledged = error;
				}
			} finally {
				record.preparing = false;
				this.environment.changed();
			}
			// The connection broke around the change. If it was being prepared,
			// nothing was sent, and it is prepared again over the new link. If it
			// was sent, the session's own record says whether it landed, once the
			// link is back. With no record, it never arrived, and it goes out again
			// under the same id and base: the session lands it once, or refuses it
			// as stale.
			while (admitted == null) {
				if (!await returned(this, record.operation, unacknowledged)) throw unacknowledged;
				try {
					const again = record.operation == null ? prepare : await resend(this, record.operation, prepare);
					if (again == null) return await this.resume(operation);
					record.operation = undefined;
					admitted = await this.#turn(operation, again);
				} catch (error) {
					if (error instanceof WorkspaceConflict) throw new LocalRefusal("not-sent");
					if (!connectionLost(error)) throw error;
					unacknowledged = error;
				}
			}
			return await this.#settle(admitted);
		} catch (error) {
			this.environment.lost(error, generation);
			throw error;
		}
	}
	/** This viewer's writes share one revision authority, so admissions take
	 * turns that end at admission. Each receipt then settles on its own, and a
	 * slow upstream effect holds back no later gesture. */
	async #turn(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		const previous = this.#commandTail;
		let release!: () => void;
		this.#commandTail = new Promise<void>((resolve) => release = resolve);
		try {
			await previous;
			if (this.environment.stopped()) throw new LocalRefusal("session-closed");
			return await this.#admit(operation, prepare);
		} finally {
			release();
		}
	}
	async #admit(operation: string, prepare: () => Promise<RoomsManagedCommand>): Promise<ManagedOperation> {
		const link = this.environment.generation();
		const request = await prepare();
		if (this.environment.stopped()) {
			request.free();
			throw new LocalRefusal("session-closed");
		}
		const record = this.#record(operation);
		const pending = new ManagedOperation(operation, request, undefined, (error) => record.lifecycle.orphan(error));
		pending.link = link;
		record.operation = pending;
		record.lifecycle.phase = "admitting";
		record.lifecycle.outcome = "unknown";
		this.environment.changed();
		// A conflict or a refusal admitted nothing: no receipt holds this command,
		// so it is freed here and leaves nothing to decide. Only a submission
		// nothing settled throws through with the operation kept.
		const admitted = await submitCommand(request);
		if (admitted.status === "conflict" || admitted.status === "refused") {
			record.operation = undefined;
			record.lifecycle.outcome = "notAdmitted";
			request.free();
			this.environment.changed();
			if (admitted.status === "refused") {
				throw new SubmissionRefused(admitted.reason ?? managedText.acquisitionRefused, admitted.failure);
			}
			await this.refresh();
			throw new WorkspaceConflict();
		}
		record.lifecycle.phase = "settling";
		return pending;
	}
	/** Watch a receipt until it settles. When its link breaks, the page waits for
	 * the next one and resumes the receipt over it, so the change settles once
	 * with what the session recorded. */
	async #settle(operation: ManagedOperation): Promise<ManagedOperation> {
		try {
			return await watchReceipt(this, this.#record(operation.id).lifecycle, operation);
		} catch (error) {
			if (!await returned(this, operation, error)) throw error;
			return await this.#resume(operation.id);
		}
	}
	finish(operation: ManagedOperation): void {
		const record = this.#records.get(operation.id);
		if (record?.operation !== operation) {
			invariant(false, "this operation belongs to another viewer");
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
		if (this.environment.stopped()) return Promise.reject(new LocalRefusal("session-closed"));
		const record = this.#record(operation);
		if (record.recovering != null) return record.recovering;
		if (record.preparing) return Promise.reject(new LocalRefusal("still-working"));
		const generation = this.environment.generation();
		const task = this.#track(
			record.lifecycle.own("settling", () => this.#resume(operation)).catch((error: unknown) => {
				this.environment.lost(error, generation);
				throw error;
			}).finally(() => {
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
		if (request != null && request.link !== this.environment.generation()) {
			return await this.#settle(await rehome(this, request));
		}
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
			throw new LocalRefusal("receipt-lost");
		}
		let retained = false;
		try {
			const status = await resumeEffect(recovered, () => {
				if (request != null) this.finish(request);
			}, (observed) => request?.observeStatus(observed));
			if (this.environment.stopped()) throw new LocalRefusal("session-closed");
			if (request != null) return await this.#settle(request);
			if (status !== "committed") {
				throw new LocalRefusal("change-unconfirmed", {
					cause: `original receipt is ${status}`,
				});
			}
			const pending = new ManagedOperation(
				operation,
				recovered,
				status,
				(error) => record.lifecycle.orphan(error),
			);
			pending.link = this.environment.generation();
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
