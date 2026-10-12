// The original command and its result acquisition share one retained owner.
import { managedSessionText } from "../../../../lib/text/managed_session.ts";
import type {
	RoomsManagedCommand,
	RoomsManagedRecoveredEffect,
	RoomsManagedResultAcquisition,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { Coordinate, FieldKey, WorkspaceSnapshot } from "./model.ts";
import { AcquisitionConflict, submitAcquisition } from "./acquisition.ts";
import { ResultRecipe } from "./result_recipe.ts";

/** Admission proved that no effect or receipt was installed. */
export class WorkspaceConflict extends Error {
	constructor() {
		super(managedSessionText.workspaceConflict);
	}
}

/** The executor has finished observing. The upstream outcome stays unknown. */
export class TerminalObservationError extends Error {}

/** The original receipt proves absence and retains the refusal diagnostic. */
export class UnsentEffectError extends Error {}

/** The effect committed. Failure while acquiring its result cannot undo it. */
export class ResultAcquisitionError extends Error {
	constructor(readonly result: unknown, cause: unknown) {
		super(cause instanceof Error ? cause.message : String(cause), { cause });
	}
}

/** The effect committed, but the live references its result carried expired
 * with the session that held them, so that result can never be read. */
export class ResultExpired extends Error {
	constructor() {
		super(managedSessionText.resultExpired);
	}
}

export async function readResult(request: Pick<RoomsManagedCommand, "result">): Promise<unknown> {
	let value: unknown;
	try {
		value = await request.result();
	} catch (error) {
		if (String(error instanceof Error ? error.message : error).includes("LiveReferenceExpired")) {
			throw new ResultExpired();
		}
		throw error;
	}
	if (
		typeof value === "object" && value != null && "observationFailure" in value &&
		typeof value.observationFailure === "string"
	) {
		if ("knownAbsent" in value && value.knownAbsent === true) throw new UnsentEffectError(value.observationFailure);
		throw new TerminalObservationError(value.observationFailure);
	}
	return value;
}

/** The receipt is exactly absent: another viewer adopted and retired it. */
export class ReceiptRetired extends Error {
	constructor() {
		super(managedSessionText.receiptRetired);
	}
}

export class ManagedOperation {
	readonly id: string;
	readonly request: RoomsManagedCommand | RoomsManagedRecoveredEffect;
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
		this.request = request;
		if (status != null) this.observeStatus(status);
	}
	/** A later failed observation cannot undo an authenticated commit. */
	get committed(): boolean {
		return this.#committed;
	}
	observeStatus(status: string): void {
		if (status === "committed") this.#committed = true;
	}
	async status(): Promise<string> {
		try {
			const status = await this.request.status();
			this.observeStatus(status);
			return status;
		} catch (error) {
			throw this.completionError(error);
		}
	}
	completionError(error: unknown, result?: unknown): unknown {
		return !this.#committed || error instanceof ResultExpired || error instanceof ResultAcquisitionError
			? error
			: new ResultAcquisitionError(result, error);
	}
	async result(): Promise<unknown> {
		try {
			const result = await readResult(this.request);
			this.#committed = true;
			return result;
		} catch (error) {
			if (error instanceof ResultExpired) this.#committed = true;
			const failure = this.completionError(error);
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
		this.#receiving = this.request.receive().then(() => {}, (error: unknown) => {
			this.#receiveFailure = { error };
		}).finally(() => {
			this.#receiving = null;
			wake();
		});
	}
	complete(work: (recipe: ResultRecipe) => Promise<unknown>): Promise<unknown> {
		if (this.#closed) throw new Error("The original operation is no longer held");
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
		if (this.#closed) throw new Error("The original operation is no longer held");
		if (this.#acquired) throw new Error("The original result has already been acquired");
		if (this.#acquisition != null || this.#acquiring != null) {
			throw new Error("Recover the original result acquisition before preparing another one");
		}
		return this.#acquiring = (async () => {
			const prepare = createdRoom
				? this.request.prepareCreatedRoomAcquisition.bind(this.request)
				: this.request.prepareResultAcquisition.bind(this.request);
			const acquisition: RoomsManagedResultAcquisition = await prepare(
				snapshot.revision,
				JSON.stringify(mappings.map(({ result, destination }) => [result, destination])),
				JSON.stringify(releases),
				JSON.stringify(snapshot.intent),
				source == null ? undefined : JSON.stringify({ role: "sessionAccess", key: source }),
			);
			if (this.#closed) {
				acquisition.free();
				throw new Error("The original operation is no longer held");
			}
			this.#acquisition = acquisition;
			await this.#submitAcquisition();
		})().finally(() => {
			this.#acquiring = null;
		});
	}
	retryAcquisition(): Promise<void> {
		if (this.#closed) throw new Error("The original operation is no longer held");
		if (this.#acquiring != null) return this.#acquiring;
		if (this.#acquisition == null) throw new Error("There is no retained result acquisition");
		return this.#acquiring ??= this.#submitAcquisition().finally(() => {
			this.#acquiring = null;
		});
	}
	async #submitAcquisition(): Promise<void> {
		const outcome = await submitAcquisition(this.#acquisition!);
		this.#acquisition!.free();
		this.#acquisition = null;
		if (outcome === "conflict") throw new AcquisitionConflict();
		this.#acquired = true;
	}
	get acquired(): boolean {
		return this.#acquired;
	}
	get acquiring(): boolean {
		return this.#acquisition != null || this.#acquiring != null;
	}
	finish(): void {
		if (this.acquiring) throw new Error("Recover the original result acquisition before releasing its command");
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
		this.request.free();
	}
}
