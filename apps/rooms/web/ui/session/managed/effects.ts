// Own retained gestures from preparation through result acquisition, and the
// receipts the page restores, resumes, or moves onto a new link.
import { invariant } from "../../../../lib/invariant.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { conversationById } from "./conversation_lookup.ts";
import type { RoomsManagedCommand, RoomsManagedWorkspace } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import { ManagedOperation, ReceiptRetired, ResultExpired, WorkspaceConflict } from "./operation.ts";
import { releaseEffect, restoreEffects, resumeEffect } from "./recovery.ts";
import type { ReleaseEnd, ReleaseWait } from "./release.ts";
import { admitCommand } from "./admission.ts";
import { rehome, surviving } from "./effects_link.ts";
import { type LinkHandle, type LinkPort, liveWorkspace } from "./link_port.ts";
import { watchReceipt } from "./effects_watch.ts";
import { SubmissionRefused, submitCommand } from "./acquisition.ts";
import { completeResult } from "./completion.ts";
import { Committed } from "./committed.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";

import { gesturesConflict, gestureScope } from "./gestures.ts";
import { OperationLifecycle } from "./lifecycle.ts";
import { CancellationRecovery } from "./cancellation.ts";
import { TrackedJobs } from "./tracked_jobs.ts";

interface EffectRecord {
	lifecycle: OperationLifecycle;
	operation?: ManagedOperation;
	/** The receipt the page finished while its completion still has work to
	 * run: the completion runs again over it, and the session is not asked for it. */
	finished?: ManagedOperation;
	preparing?: boolean;
	recovering?: Promise<ManagedOperation>;
	completing?: Promise<boolean>;
	result?: Promise<unknown>;
	intent?: { name: string; args: string[]; scope: string | null };
	command?: Promise<ManagedOperation>;
	completion?: (operation: ManagedOperation) => Promise<unknown>;
	adopted?: boolean;
	signal?: AbortSignal;
	cancellation?: CancellationRecovery;
}

/** Prepare a change over `workspace()`, the handle of the link its turn runs
 * over. A preparation reads that handle and no other, so its receipt belongs
 * to the link that prepared it. It reads the handle after its last await, and
 * a link replaced before then throws a loss, so the change is prepared again
 * over the new link. */
export type Preparation = (workspace: () => RoomsManagedWorkspace) => Promise<RoomsManagedCommand>;

interface Environment extends LinkPort, ReleaseWait {
	stopped(): boolean;
	observationFailure(): unknown;
	change(): number;
	changed(): void;
	wait(change: number, signal?: AbortSignal): Promise<void>;
	report(source: string, error: unknown): void;
}

export class ManagedEffects {
	readonly #records = new Map<string, EffectRecord>();
	#commandTail: Promise<void> = Promise.resolve();
	readonly #inFlight = new TrackedJobs();
	/** Startup's adoption of receipts has begun and has not yet finished. */
	#adopting = false;
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
	heldOperation(id: string): ManagedOperation | undefined {
		return this.#records.get(id)?.operation;
	}
	readNow(): Promise<WorkspaceSnapshot> {
		return this.session.readNow();
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
	/** Whether a change is being prepared and not yet submitted, so the
	 * session holds no record of it. */
	get preparing(): boolean {
		return [...this.#records.values()].some((record) => record.preparing === true);
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
			record.intent?.name === "openManagedRoom" && record.signal?.aborted
		).map(([id]) => id);
	}
	/** Adopt the receipts the session holds that this page has no record of, as
	 * startup does once, when the page's access may resolve them. A lost link
	 * leaves the rest to `resumeRestore`, and so does an access not yet known
	 * because the link was lost before the page learned it. */
	async restore(): Promise<void> {
		this.#adopting = true;
		await this.resumeRestore();
	}
	/** Go on with startup's adoption over the newest link, after a lost one ended
	 * it. Once a pass finishes, there is nothing left to adopt. */
	async resumeRestore(): Promise<void> {
		if (!this.#adopting || !this.session.permits("resolvePending")) return;
		const finished = await restoreEffects({
			port: this.environment,
			known: (id) => this.#records.has(id),
			retain: (operation) => {
				this.#record(operation.id).operation = operation;
			},
			orphan: (operation) => this.#records.get(operation.id)?.lifecycle.orphan(),
			finish: (operation) => this.finish(operation),
			complete: (operation) => this.completeResult(operation),
			report: (error) => this.environment.report(managedText.resultRecovery, error),
		});
		if (finished) this.#adopting = false;
		this.environment.changed();
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
		const record = this.#records.get(operation);
		invariant(record != null, "a reserved gesture has its record");
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
	async execute<T>(
		operation: string,
		prepare: () => Promise<ManagedOperation>,
		then: (operation: ManagedOperation, after: Committed) => Promise<T>,
		signal?: AbortSignal,
	): Promise<T> {
		const after = new Committed(this.session, (source, error) => this.environment.report(source, error));
		const complete = (held: ManagedOperation) => then(held, after);
		let value: T | undefined;
		if (this.#records.get(operation)?.completion != null) {
			throw new LocalRefusal("change-owned");
		}
		const record = this.#record(operation);
		record.completion = complete;
		record.signal = signal;
		record.cancellation = new CancellationRecovery(
			signal,
			() =>
				!this.environment.stopped() && record.completing == null && this.#records.get(operation) === record &&
				(record.operation != null || record.finished != null || record.adopted === true),
			() => this.completeOperation(operation),
			() => this.environment.changed(),
		);
		const task = this.#inFlight.track(record.lifecycle.own("preparing", async () => {
			value = await surviving(this, operation, await prepare(), complete) as T;
			record.adopted = true;
			return true;
		}));
		record.completing = task;
		try {
			await task;
			record.completion = undefined;
			if (record.operation == null) this.#forget(operation);
			return value as T;
		} catch (error) {
			if (record.operation == null && !record.adopted && record.finished == null) this.#forget(operation);
			record.completing = undefined;
			const recovery = record.cancellation?.idle();
			if (recovery != null) {
				await recovery;
				signal?.throwIfAborted();
			}
			throw error;
		} finally {
			record.completing = undefined;
			this.environment.changed();
		}
	}
	/** Give up on a retained operation for good, and say how the session
	 * answered. See `releaseEffect`. */
	releaseOperation(id: string): Promise<ReleaseEnd> {
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
		return this.#inFlight.track(
			releaseEffect(this.environment, id, record?.operation, (held) => this.finish(held)).then((answer) => {
				this.#forget(id);
				this.environment.changed();
				return answer;
			}),
		);
	}
	completeOperation(id: string): Promise<boolean> {
		const record = this.#record(id);
		const existing = record.completing;
		if (existing != null) return existing;
		const result = record.result;
		if (result != null) return result.then(() => true);
		const task = this.#inFlight.track(
			record.lifecycle.own("completing", async () => {
				if (record.adopted) {
					this.#forget(id);
					return true;
				}
				const held: { operation: ManagedOperation | null } = { operation: null };
				try {
					// A receipt the page finished is kept, as `surviving` keeps it across a
					// loss: a completion that failed after its result was acquired runs
					// again over it, and the receipt is not looked up as lost.
					const kept = record.operation ?? record.finished;
					const finished = kept?.finished ? kept : null;
					await surviving(this, id, finished, async (operation) => {
						held.operation = operation;
						const complete = record.completion;
						if (complete == null) await this.completeResult(operation);
						else await complete(operation);
					});
					record.adopted = true;
					record.finished = undefined;
				} catch (error) {
					if (error instanceof ReceiptRetired) {
						record.adopted = true;
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
		const task = this.#inFlight.track(
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
	perform(operation: string, prepare: Preparation): Promise<ManagedOperation> {
		const record = this.#record(operation);
		return this.#inFlight.track(record.lifecycle.own("queued", () => this.#perform(operation, prepare))).finally(
			() => {
				if (record.operation == null && record.completion == null && record.intent == null) {
					this.#records.delete(operation);
				}
			},
		);
	}
	async #perform(operation: string, prepare: Preparation): Promise<ManagedOperation> {
		if (this.environment.stopped()) throw new LocalRefusal("session-closed");
		const record = this.#record(operation);
		if (record.operation != null || record.preparing) {
			throw new LocalRefusal("change-replay-required");
		}
		// One first send over a live link. A connection lost on the way was charged
		// to the link the send ran on and is the caller's to read. Any other
		// failure stands.
		const attempt = async (): Promise<{ admitted: ManagedOperation | null; lost: unknown }> => {
			record.preparing = true;
			try {
				await this.environment.ready("not-sent");
				return { admitted: await this.#turn(operation, prepare), lost: null };
			} catch (error) {
				if (!connectionLost(error)) throw error;
				return { admitted: null, lost: error };
			} finally {
				record.preparing = false;
				this.environment.changed();
			}
		};
		// A connection lost before the change was submitted sent nothing, so it
		// is prepared again as a first send, which waits for a live link as any
		// first send does. Only an attached page meets that loss here. Each
		// attempt waits at most the link's wait for a live link and then ends the
		// press with the link's refusal, but no count bounds the attempts: each
		// needs a link that came back after the last loss, so only a link that
		// keeps coming back and dropping before the submit keeps the press
		// working, and the link's notice says why. Of the calls a change prepares, Rust
		// names only an attached one unreachable with no status, and
		// `liveWorkspace` names a replaced link, which a session this browser
		// runs never has. One lost while or after it was submitted is looked up
		// by its id over the next link: the session's record settles it, and
		// with none the page never sends it again.
		let sent = await attempt();
		while (sent.admitted == null) {
			const submitted = this.heldOperation(operation);
			if (submitted == null) {
				sent = await attempt();
				continue;
			}
			if (!await this.environment.relinkedAfter(sent.lost)) throw sent.lost;
			return await this.#settle(await rehome(this, submitted));
		}
		return await this.#settle(sent.admitted);
	}
	/** This viewer's writes share one revision authority, so admissions take
	 * turns that end at admission. Each receipt then settles on its own, and a
	 * slow upstream effect holds back no later gesture. */
	async #turn(operation: string, prepare: Preparation): Promise<ManagedOperation> {
		const previous = this.#commandTail;
		const { promise: turn, resolve: release } = Promise.withResolvers<void>();
		this.#commandTail = turn;
		try {
			await previous;
			if (this.environment.stopped()) throw new LocalRefusal("session-closed");
			return await this.environment.over((link) => this.#admit(operation, link, prepare));
		} finally {
			release();
		}
	}
	/** Prepare and submit `operation` over `link`, the link current when its
	 * turn came. */
	async #admit(
		operation: string,
		link: LinkHandle,
		prepare: Preparation,
	): Promise<ManagedOperation> {
		const request = await prepare(liveWorkspace(this.environment, link));
		if (this.environment.stopped()) {
			request.free();
			throw new LocalRefusal("session-closed");
		}
		const record = this.#record(operation);
		const pending = new ManagedOperation(
			operation,
			request,
			link,
			undefined,
			(error) => record.lifecycle.orphan(error),
		);
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
			await this.readNow();
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
			return await this.environment.overStamped(
				operation.stamp,
				() => watchReceipt(this, this.#record(operation.id).lifecycle, operation),
			);
		} catch (error) {
			if (!await this.environment.relinkedAfter(error)) throw error;
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
		else {
			record.finished = operation;
			record.operation = undefined;
		}
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
		const task = this.#inFlight.track(
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
		if (request != null && !this.environment.isCurrent(request.stamp)) {
			return await this.#settle(await rehome(this, request));
		}
		if (request?.acquiring) {
			await this.environment.overStamped(request.stamp, () => request.retryAcquisition());
			await this.session.committed.readOr<unknown>(null, (reads) => reads.readNow());
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
		// The record travels the link it was recovered over, even if a newer one
		// replaces it while the lookup waits.
		const { recovered, link } = await this.environment.over(async (link) => ({
			recovered: await link.workspace.recoverEffect(operation),
			link,
		}));
		if (recovered == null) {
			// Exact absence: another viewer adopted and retired this receipt, the
			// same rule startup restoration applies. A retained wrapper has nothing
			// left to recover, so it is released rather than left to fail again.
			if (request != null) {
				this.finish(request);
				await this.session.committed.readOr<unknown>(null, (reads) => reads.readNow());
				throw new ReceiptRetired();
			}
			throw new LocalRefusal("receipt-lost");
		}
		let retained = false;
		try {
			const status = await this.environment.overStamped(
				link,
				() =>
					resumeEffect(recovered, () => {
						if (request != null) this.finish(request);
					}, (observed) => request?.observeStatus(observed)),
			);
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
				link,
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
		await this.#inFlight.settled();
		await Promise.all([...this.pendingOperations].map((operation) => operation.close()));
		for (const record of this.#records.values()) record.cancellation?.dispose();
		this.#records.clear();
	}
}
