// The acquisitions a page holds: each request a gesture prepared, from its
// preparation until the session settles it, a person lets it go, or the link it
// was prepared over is lost. A request is never submitted over a link it was
// not prepared on, and one that may have reached the session is never
// submitted again. Once the session has settled one, a lost link no longer ends
// it: the page shows the settled outcome over the next link.
import { invariant } from "../../../../lib/invariant.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type {
	RoomsManagedAcquisition,
	RoomsManagedDirectoryAcquisition,
	RoomsManagedOperationsAcquisition,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { type LinkHandle, type LinkPort, type Stamp, stampOf } from "./link_port.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { Committed } from "./committed.ts";
import { submitResolvingConflicts, throwUnlessCommitted } from "./acquisition.ts";
import { LOCAL_LIMITS } from "./local_limits.ts";
import { OperationLifecycle } from "./lifecycle.ts";
import { CancellationRecovery } from "./cancellation.ts";
import { TrackedJobs } from "./tracked_jobs.ts";

interface AcquisitionRecord {
	label: string;
	intent: string;
	result?: string;
	lifecycle: OperationLifecycle;
	request?: Acquisition;
	/** The link the request was prepared over, the only one it is sent on. */
	prepared?: Stamp;
	/** The link whose handles the preparation uses, when it brings its own. */
	over?: Stamp;
	/** Whether the held request may have reached the session. */
	sent?: boolean;
	task?: Promise<void>;
	completed?: (after: Committed) => Promise<void>;
	signal?: AbortSignal;
	cancellation?: CancellationRecovery;
}

type Acquisition =
	| RoomsManagedAcquisition
	| RoomsManagedDirectoryAcquisition
	| RoomsManagedOperationsAcquisition;

/** Whether `record` holds work the session may have: a prepared request, or a
 * commit whose completion has yet to run. */
function isHeld(record: AcquisitionRecord): boolean {
	return record.request != null || record.lifecycle.outcome === "committed";
}

/** What an acquisition carries besides its request. */
export interface AcquireOptions {
	/** What the request asks for. A second press with the same id and another
	 * intent is refused. Defaults to the id. */
	readonly intent?: string;
	/** The conversation the request creates, kept out of the page while a
	 * cancelled request may still land. */
	readonly result?: string;
	readonly signal?: AbortSignal;
	/** Runs once the session committed the request, and again over the next
	 * link when a loss ends it, so it is safe to run twice. It reads and
	 * changes through `after`, which never waits for the link. */
	readonly completed?: (after: Committed) => Promise<void>;
	/** The link whose handles the preparation uses, when they are not the
	 * workspace it is handed. A preparation whose link was replaced sends
	 * nothing and ends `not-sent`, so its loss is never charged to the link
	 * that replaced it. */
	readonly over?: Stamp;
}

/** What held acquisitions read of the session: where they say they changed,
 * and the reads that follow what one settled. */
export type AcquisitionSession = Pick<ManagedRoomsSession, "acquisitionChanged" | "committed">;

export class HeldAcquisitions {
	readonly #session: AcquisitionSession;
	readonly #acquisitions = new Map<string, AcquisitionRecord>();
	readonly #running = new TrackedJobs();
	#stopped = false;
	readonly #port: LinkPort;
	/** Told each acquisition the session settled, and whether it committed. */
	readonly #settled: (id: string, committed: boolean) => void;
	constructor(
		session: AcquisitionSession,
		link: LinkPort,
		settled: (id: string, committed: boolean) => void,
	) {
		this.#session = session;
		this.#port = link;
		this.#settled = settled;
	}
	get diagnostics() {
		return [...this.#acquisitions.values()].map((record) => record.lifecycle.inspect());
	}
	get resources() {
		return { acquisitions: this.#acquisitions.size, workers: this.#running.size };
	}
	/** The intent and result of the acquisition `id` holds, if it is held. */
	held(id: string): { readonly intent: string; readonly result?: string } | undefined {
		return this.#acquisitions.get(id);
	}
	get pending(): readonly string[] {
		return [...this.#acquisitions].filter(([, record]) => isHeld(record)).map(([id]) => id);
	}
	get recoverable(): readonly string[] {
		return [...this.#acquisitions].filter(([, record]) =>
			isHeld(record) && record.lifecycle.needsDecision &&
			!record.cancellation?.pending
		)
			.map(([id]) => id);
	}
	/** Let a held acquisition go: the request is freed and never resubmitted.
	 * The session's own state says what it holds, so a change that did go
	 * through stays saved there, and only this page's step of showing it is
	 * dropped. One still running is not let go. Letting go of one already gone
	 * has nothing left to do. */
	release(id: string): Promise<void> {
		const record = this.#acquisitions.get(id);
		if (record == null) return Promise.resolve();
		if (record.task != null) return Promise.reject(new LocalRefusal("still-working"));
		record.request?.free();
		record.request = undefined;
		this.#forget(id);
		this.#session.acquisitionChanged();
		return Promise.resolve();
	}
	/** Only new conversations belong to acquisitions. Keep cancelled results
	 * out of presentation until this owner proves non-admission or departure. */
	get cancelledConversations(): readonly string[] {
		return [...this.#acquisitions.values()].flatMap((record) =>
			record.signal?.aborted && record.result != null ? [record.result] : []
		);
	}
	acquire(
		/** What the person started, as a notice names it. */
		label: string,
		id: string,
		/** Prepare the request over `workspace`, the handle of the link the
		 * press runs over, or over the handles of `over` when it is set. */
		prepare: (workspace: RoomsManagedWorkspace) => Promise<Acquisition>,
		{ intent = id, result, signal, completed, over }: AcquireOptions = {},
	): Promise<void> {
		if (this.#stopped) return Promise.reject(new LocalRefusal("session-closed"));
		const existing = this.#acquisitions.get(id);
		if (existing != null) {
			if (existing.intent !== intent) {
				return Promise.reject(new LocalRefusal("access-change-retained"));
			}
			return existing.task ?? this.recover(id);
		}
		if (this.#acquisitions.size >= LOCAL_LIMITS.acquisitions) {
			return Promise.reject(new LocalRefusal("unfinished-limit"));
		}
		const record: AcquisitionRecord = {
			label,
			intent,
			result,
			completed,
			signal,
			over,
			lifecycle: new OperationLifecycle(id, () => this.#session.acquisitionChanged()),
		};
		this.#acquisitions.set(id, record);
		record.cancellation = new CancellationRecovery(
			signal,
			() => !this.#stopped && record.task == null && this.#acquisitions.get(id) === record && isHeld(record),
			() => this.recover(id),
			() => this.#session.acquisitionChanged(),
		);
		const task = this.#running.track(
			record.lifecycle.own(
				"preparing",
				() => this.#severable(id, record, (link) => this.#prepared(id, record, link, prepare, signal)),
			).finally(async () => {
				record.task = undefined;
				if (record.request == null && record.lifecycle.outcome !== "committed") this.#forget(id);
				await record.cancellation?.idle();
			}).catch((error: unknown) => {
				if (!this.#acquisitions.has(id)) signal?.throwIfAborted();
				throw error;
			}),
		);
		record.task = task;
		this.#session.acquisitionChanged();
		return task;
	}
	/** Prepare `record`'s request over `link`, whose handles `record.over`
	 * names when the preparation brings its own, hold it as prepared there, and
	 * submit it. A press cancelled or a session stopped while it prepared frees
	 * the request unsent. */
	async #prepared(
		id: string,
		record: AcquisitionRecord,
		link: LinkHandle,
		prepare: (workspace: RoomsManagedWorkspace) => Promise<Acquisition>,
		signal: AbortSignal | undefined,
	): Promise<void> {
		signal?.throwIfAborted();
		const request = await prepare(link.workspace);
		if (signal?.aborted) {
			request.free();
			signal.throwIfAborted();
		}
		if (this.#stopped) {
			request.free();
			throw new LocalRefusal("session-closed");
		}
		record.request = request;
		record.prepared = stampOf(link);
		record.lifecycle.phase = "admitting";
		record.lifecycle.outcome = "unknown";
		await this.#submitAcquisition(id);
	}
	/** The link was replaced, and a request prepared over an older one no
	 * longer reaches the session. One held for a decision ends here, because
	 * the page cannot tell whether it went through, and says so once under its
	 * own name. One still running ends with its own gesture when its call
	 * fails. One prepared over the current link stays, since a move can run
	 * after the person has started work over the link it moves to. */
	relink(report: (source: string, error: unknown) => void): void {
		for (const [id, record] of [...this.#acquisitions]) {
			if (record.request == null || record.task != null) continue;
			if (record.prepared != null && this.#port.isCurrent(record.prepared)) continue;
			report(record.label, this.#sever(id, record, null));
		}
	}
	/** Run `work` for `record` once the link is live, waiting for it as any
	 * first send does. A link lost under the work ends the record, and the link
	 * hears it. The end comes inside the work, so no relink sees the record
	 * between. A request held from a replaced link ends here before it is sent,
	 * even when the move that ends it has yet to run, and so does a
	 * preparation whose own handles travel a replaced link. */
	async #severable(
		id: string,
		record: AcquisitionRecord,
		work: (link: LinkHandle) => Promise<void>,
	): Promise<void> {
		try {
			await this.#port.ready("not-sent");
			await this.#port.over((link) => {
				if (record.request != null && (record.prepared == null || !this.#port.isCurrent(record.prepared))) {
					throw this.#sever(id, record, null);
				}
				if (record.request == null && record.over != null && !this.#port.isCurrent(record.over)) {
					throw this.#sever(id, record, null);
				}
				return work(link);
			});
		} catch (error) {
			throw this.#sever(id, record, error);
		}
	}
	/** End `record` when `error` is a lost link, or when the link was replaced
	 * (`error` null), and return what its gesture says. A request already
	 * submitted may have gone through, and one never submitted sent nothing.
	 * Either way it is never submitted again. One the session committed stays
	 * held, and its gesture hears `error` itself. */
	#sever(id: string, record: AcquisitionRecord, error: unknown): unknown {
		if (error != null && !connectionLost(error)) return error;
		if (record.lifecycle.outcome === "committed") return error;
		const submitted = record.request != null && record.sent === true;
		record.request?.free();
		record.request = undefined;
		record.sent = undefined;
		if (this.#acquisitions.get(id) === record) this.#forget(id);
		this.#session.acquisitionChanged();
		return new LocalRefusal(submitted ? "receipt-lost" : "not-sent", error == null ? undefined : { cause: error });
	}
	#forget(id: string): void {
		this.#acquisitions.get(id)?.cancellation?.dispose();
		this.#acquisitions.delete(id);
	}
	recover(id: string): Promise<void> {
		if (this.#stopped) return Promise.reject(new LocalRefusal("session-closed"));
		const record = this.#acquisitions.get(id);
		if (record == null) return Promise.reject(new LocalRefusal("acquisition-gone"));
		if (record.task != null) return record.task;
		const task = this.#running.track(
			record.lifecycle.own(
				"acquiring",
				() => this.#severable(id, record, () => this.#submitAcquisition(id)),
			).finally(() => {
				record.task = undefined;
			}),
		);
		record.task = task;
		this.#session.acquisitionChanged();
		return task;
	}

	/** An acquisition whose press was cancelled keeps its result until this
	 * owner proves non-admission or completes its recovery. Wait for that
	 * proof, then say the caller may retry its work. A held acquisition that
	 * was not cancelled is left exactly where it stands. */
	async recoveredIfAborted(acquisition: string): Promise<boolean> {
		const held = this.#acquisitions.get(acquisition);
		if (held == null || !held.signal?.aborted) return false;
		await this.recover(acquisition);
		return true;
	}
	async #submitAcquisition(id: string): Promise<void> {
		const record = this.#acquisitions.get(id);
		invariant(record != null, "acquisition submission requires its retained owner");
		if (record.lifecycle.outcome === "committed") {
			await this.#shown(record, true);
			this.#forget(id);
			this.#session.acquisitionChanged();
			return;
		}
		const original = record.request;
		invariant(original != null, "an uncommitted acquisition retains its prepared request");
		const { outcome, request } = await submitResolvingConflicts<Acquisition>(
			original,
			(held, sent) => {
				record.request = held;
				record.sent = sent;
			},
			() => !this.#stopped && record.signal?.aborted !== true,
		);
		const committed = outcome.status === "committed";
		record.lifecycle.outcome = committed ? "committed" : "notAdmitted";
		request.free();
		record.request = undefined;
		if (!committed) this.#forget(id);
		this.#session.acquisitionChanged();
		this.#settled(id, committed);
		await this.#shown(record, committed);
		this.#forget(id);
		if (outcome.status === "conflict") record.signal?.throwIfAborted();
		throwUnlessCommitted(outcome);
	}
	/** Read the session's state after it settled `record`, and run the
	 * gesture's completion after a commit. The session holds the outcome, so a
	 * lost link never ends this. Over the next link the work runs again, and a
	 * completion picks up where it stopped. A refusal is shown from the session's
	 * answer, and the new link's dial reads the state that refusal left. A lost
	 * link that never comes back keeps a commit held, and its gesture hears the
	 * loss. */
	async #shown(record: AcquisitionRecord, committed: boolean): Promise<void> {
		let lost: unknown = null;
		do {
			try {
				// Each call here goes through the port, which charges its loss.
				const after = this.#session.committed;
				// The unread view is a notice: the commit stands and the next update redraws.
				await after.readOr<unknown>(null, (reads) => reads.readNow());
				if (committed) await record.completed?.(after);
				return;
			} catch (error) {
				if (!connectionLost(error)) throw error;
				// Only a commit has a completion left to run over the next link.
				if (!committed) return;
				lost = error;
			}
		} while (!this.#stopped && await this.#port.relinkedAfter(lost));
		throw lost;
	}
	/** Whether the session stopped, after which nothing new is acquired. */
	get stopped(): boolean {
		return this.#stopped;
	}
	stop(): void {
		this.#stopped = true;
	}
	/** Wait for every running acquisition, then free what is held. */
	async close(): Promise<void> {
		this.stop();
		await this.#running.settled();
		for (const record of this.#acquisitions.values()) {
			record.cancellation?.dispose();
			record.request?.free();
		}
		this.#acquisitions.clear();
	}
}
