// The original command and its result acquisition share one retained owner.
import { invariant } from "../../../../lib/invariant.ts";
import { structuredFailure } from "../../../../lib/error_codes.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type {
	RoomsManagedCommand,
	RoomsManagedRecoveredEffect,
	RoomsManagedResultAcquisition,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { Coordinate, FieldKey, WorkspaceSnapshot } from "./model.ts";
import { submitAcquisition, throwUnlessCommitted } from "./acquisition.ts";
import { ReportedFailure } from "./reported_failure.ts";
import { ResultRecipe } from "./result_recipe.ts";

/** Admission proved that no effect or receipt was installed. */
export class WorkspaceConflict extends LocalRefusal {
	constructor() {
		super("conflict");
	}
}

/** The executor has finished observing. The upstream outcome stays unknown,
 * and the receipt still names the failure it saw. */
export class TerminalObservationError extends ReportedFailure {
	constructor(reason: string, failure: unknown = null) {
		super(reason, failure);
	}
}

/** The original receipt proves absence and retains the refusal diagnostic. */
export class UnsentEffectError extends ReportedFailure {}

/** The refusals that already say why a committed result stays held. Any
 * other cause is reported as a result that needs recovery. */
const HELD_REASONS = [
	"retained-result-unreadable",
	"target-gone-held",
	"old-manager-recovery",
	"recovery-seat-lost",
] as const;

function heldReason(cause: unknown): (typeof HELD_REASONS)[number] | "result-needs-recovery" {
	if (!(cause instanceof LocalRefusal)) return "result-needs-recovery";
	return HELD_REASONS.find((key) => cause.code === `local-${key}`) ?? "result-needs-recovery";
}

/** The page step that was running when a committed result failed. A step is
 * one call into the session client, and its name is the session verb that step
 * ends in. A step can send more than that verb first, so a session log line
 * for an earlier verb belongs to the same stage:
 * - When the result maps a moderator or a manager link,
 *   `acquire-result-workspace` and `acquire-created-room` can first send `effect-adopted`, `effect-result`
 *   and `room-identity-reader`, then `roomIdentity` or `managedRoomIdentity`.
 * A failure with no stage is a refusal the page raised on its own while no
 * session step was running. */
export type AcquisitionStage =
	| "effect-status"
	| "effect-result"
	| "effect-adopted"
	| "addressed-snapshot"
	| "acquire-result-workspace"
	| "acquire-created-room"
	| "release-effect"
	| "resume-effect";

/** The effect committed. Failure while acquiring its result cannot undo it.
 * The stage names the step that failed, and the failure text renders it. A
 * null stage means the page refused on its own, and the cause stands alone. */
export class ResultAcquisitionError extends LocalRefusal {
	declare readonly stage: AcquisitionStage | null;
	constructor(readonly result: unknown, cause: unknown, stage: AcquisitionStage | null) {
		super(heldReason(cause), { cause, stage });
	}
}

/** The effect committed, but the live references its result carried expired
 * with the session that held them, so that result can never be read. */
export class ResultExpired extends LocalRefusal {
	constructor() {
		super("result-expired");
	}
}

export async function readResult(request: Pick<RoomsManagedCommand, "result">): Promise<unknown> {
	let value: unknown;
	try {
		value = await request.result();
	} catch (error) {
		// The Host breaks the call with the engine's reason name, exactly.
		const failure = structuredFailure(error);
		if (failure?.status === -12 && failure.reason === "LiveReferenceExpired") {
			throw new ResultExpired();
		}
		throw error;
	}
	if (
		typeof value === "object" && value != null && "observationFailure" in value &&
		typeof value.observationFailure === "string"
	) {
		if ("knownAbsent" in value && value.knownAbsent === true) {
			throw new UnsentEffectError(value.observationFailure, "failure" in value ? value.failure : null);
		}
		throw new TerminalObservationError(value.observationFailure, "failure" in value ? value.failure : null);
	}
	return value;
}

/** The receipt is exactly absent: another viewer adopted and retired it. */
export class ReceiptRetired extends LocalRefusal {
	constructor() {
		super("receipt-retired");
	}
}

export class ManagedOperation {
	readonly id: string;
	#request: RoomsManagedCommand | RoomsManagedRecoveredEffect;
	/** The link whose session the request travels, counted as the session counts them. */
	link = 0;
	/** The calls now running on each request this operation has held. */
	readonly #running = new Map<object, { count: number; idle: (() => void)[] }>();
	#acquisition: RoomsManagedResultAcquisition | null = null;
	#acquiring: Promise<void> | null = null;
	#completing: Promise<unknown> | null = null;
	#recipe: ResultRecipe | null = null;
	#closed = false;
	#acquired = false;
	#committed = false;
	#receiving: Promise<void> | null = null;
	#receiveFailure: { error: unknown } | null = null;
	constructor(
		id: string,
		request: RoomsManagedCommand | RoomsManagedRecoveredEffect,
		status?: string,
		readonly orphan = (_error: unknown) => {},
	) {
		this.id = id;
		this.#request = request;
		if (status != null) this.observeStatus(status);
	}
	get request(): RoomsManagedCommand | RoomsManagedRecoveredEffect {
		return this.#request;
	}
	/** Run one call on `request`, so it is not released while the call is running. */
	async #using<T>(request: object, call: () => Promise<T>): Promise<T> {
		const running = this.#running.get(request) ?? { count: 0, idle: [] };
		this.#running.set(request, running);
		running.count++;
		try {
			return await call();
		} finally {
			if (--running.count === 0) {
				this.#running.delete(request);
				for (const resume of running.idle) resume();
			}
		}
	}
	#drained(request: object): Promise<void> {
		const running = this.#running.get(request);
		return running == null ? Promise.resolve() : new Promise<void>((resume) => running.idle.push(resume));
	}
	/** The session's receipt now travels `next`, over the link numbered `link`.
	 * Everything the operation kept is the same except what was prepared on the
	 * old request, which no longer reaches the session: a held acquisition is
	 * prepared again from the receipt. The old request is released once nothing
	 * is using it. */
	async rebind(next: RoomsManagedRecoveredEffect, link: number): Promise<void> {
		if (this.#closed) {
			next.free();
			throw new LocalRefusal("receipt-retired");
		}
		const old = this.#request;
		this.#request = next;
		this.link = link;
		this.#receiveFailure = null;
		// Calls on the old request fail with its link, which ends them.
		await this.#acquiring?.catch(() => {
			// tolerant: the acquisition's caller retains its refusal.
		});
		await this.#completing?.catch(() => {
			// tolerant: the completion's caller retains its refusal.
		});
		this.#acquisition?.free();
		this.#acquisition = null;
		await this.#drained(old);
		old.free();
	}
	/** A later failed observation cannot undo an authenticated commit. */
	get committed(): boolean {
		return this.#committed;
	}
	observeStatus(status: string): void {
		if (status === "committed") this.#committed = true;
	}
	async status(): Promise<string> {
		const request = this.#request;
		try {
			const status = await this.#using(request, () => request.status());
			this.observeStatus(status);
			return status;
		} catch (error) {
			throw this.completionError(error, "effect-status");
		}
	}
	completionError(error: unknown, stage: AcquisitionStage, result?: unknown): unknown {
		// A lost connection says nothing of the commit. The link comes back and asks again.
		return !this.#committed || error instanceof ResultExpired || error instanceof ResultAcquisitionError ||
				connectionLost(error)
			? error
			: new ResultAcquisitionError(result, error, stage);
	}
	async result(): Promise<unknown> {
		try {
			const request = this.#request;
			const result = await this.#using(request, () => readResult(request));
			this.#committed = true;
			return result;
		} catch (error) {
			if (error instanceof ResultExpired) this.#committed = true;
			const failure = this.completionError(error, "effect-result");
			this.orphan(failure);
			throw failure;
		}
	}
	/** One read owns one wake, including across unrelated workspace updates. */
	observe(wake: () => void): void {
		if (this.#receiveFailure != null) {
			const { error } = this.#receiveFailure;
			this.#receiveFailure = null;
			throw error;
		}
		if (this.#receiving != null) return;
		const request = this.#request;
		this.#receiving = this.#using(request, () => request.receive()).then(() => {}, (error: unknown) => {
			// A request this operation no longer holds fails with its own link.
			if (request === this.#request) this.#receiveFailure = { error };
		}).finally(() => {
			this.#receiving = null;
			wake();
		});
	}
	complete(work: (recipe: ResultRecipe) => Promise<unknown>): Promise<unknown> {
		if (this.#closed) throw new LocalRefusal("receipt-retired");
		return this.#completing ??= work(this.#recipe ??= new ResultRecipe()).finally(() => {
			this.#completing = null;
		});
	}
	acquire(
		snapshot: WorkspaceSnapshot,
		mappings: { result: Coordinate; destination: Coordinate }[],
		releases: Coordinate[] = [],
		source?: FieldKey,
		createdRoom = false,
	): Promise<void> {
		if (this.#closed) throw new LocalRefusal("receipt-retired");
		invariant(!this.#acquired, "the original result has already been acquired");
		if (this.#acquisition != null || this.#acquiring != null) {
			throw new LocalRefusal("result-saving");
		}
		return this.#acquiring = (async () => {
			const prepare = createdRoom
				? this.#request.prepareCreatedRoomAcquisition.bind(this.#request)
				: this.#request.prepareResultAcquisition.bind(this.#request);
			const acquisition: RoomsManagedResultAcquisition = await prepare(
				snapshot.revision,
				JSON.stringify(mappings.map(({ result, destination }) => [result, destination])),
				JSON.stringify(releases),
				JSON.stringify(snapshot.intent),
				source == null ? undefined : JSON.stringify({ role: "sessionAccess", key: source }),
			);
			if (this.#closed) {
				acquisition.free();
				throw new LocalRefusal("receipt-retired");
			}
			this.#acquisition = acquisition;
			await this.#submitAcquisition();
		})().finally(() => {
			this.#acquiring = null;
		});
	}
	retryAcquisition(): Promise<void> {
		if (this.#closed) throw new LocalRefusal("receipt-retired");
		if (this.#acquiring != null) return this.#acquiring;
		invariant(this.#acquisition != null, "there is no retained result acquisition");
		return this.#acquiring ??= this.#submitAcquisition().finally(() => {
			this.#acquiring = null;
		});
	}
	async #submitAcquisition(): Promise<void> {
		const outcome = await submitAcquisition(this.#acquisition!);
		this.#acquisition!.free();
		this.#acquisition = null;
		throwUnlessCommitted(outcome);
		this.#acquired = true;
	}
	get acquired(): boolean {
		return this.#acquired;
	}
	get acquiring(): boolean {
		return this.#acquisition != null || this.#acquiring != null;
	}
	finish(): void {
		if (this.acquiring) throw new LocalRefusal("result-saving");
		this.#closed = true;
		this.#release();
	}
	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		await this.#completing?.catch(() => {
			// tolerant: shutdown waits for the completion caller to retain its
			// refusal before releasing the original wrappers.
		});
		await this.#acquiring?.catch(() => {
			// tolerant: the acquisition's caller retains its refusal. This
			// shutdown barrier only waits until it stops using the wrappers.
		});
		this.#release();
	}
	#release(): void {
		this.#recipe = null;
		this.#acquisition?.free();
		this.#acquisition = null;
		this.#request.free();
	}
}
