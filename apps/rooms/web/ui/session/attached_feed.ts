// Revisioned observations from one attached durable Rooms session.

import type { RoomsSessionLineEvent, RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { AttachedRoomsRemote } from "./remote.ts";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";

const WATCH_SETTLE_MS = 1_000;
const INITIAL_EVENT_BUFFER = 256;

type SnapshotListener = (snapshot: RoomsSessionSnapshot) => void;
type LineListener = (event: RoomsSessionLineEvent) => void;

/** Owns the attached session's one accepted snapshot and its three observation
 * streams. Commands wait here for revisions because the feed, not a command
 * caller, decides when a snapshot has actually arrived. */
export class AttachedSessionFeed {
	readonly #remote: AttachedRoomsRemote;
	readonly #snapshots = new Set<SnapshotListener>();
	#line: LineListener | null = null;
	readonly #pendingLines: RoomsSessionLineEvent[] = [];
	readonly #operationsChanged = new Set<(scope: string) => void>();
	#revisionWaiter: { revision: number; resolve(): void } | null = null;
	#snapshot: RoomsSessionSnapshot | null = null;
	#eventSource: string | null = null;
	#eventSequence = 0;
	#initialEventGapReported = false;
	#closed = false;

	constructor(remote: AttachedRoomsRemote) {
		this.#remote = remote;
	}

	get current(): RoomsSessionSnapshot | null {
		return this.#snapshot;
	}

	async start(): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		const initial = await this.#remote.watch(
			(snapshot) => this.#accept(snapshot),
			(event) => this.#acceptLine(event),
			(scope) => {
				for (const changed of this.#operationsChanged) changed(scope);
			},
		);
		this.#accept(initial);
		return initial;
	}

	onSnapshot(listener: SnapshotListener): () => void {
		this.#assertOpen();
		this.#snapshots.add(listener);
		if (this.#snapshot != null) listener(this.#snapshot);
		return () => this.#snapshots.delete(listener);
	}

	onLine(listener: LineListener): () => void {
		this.#assertOpen();
		if (this.#line != null) throw new Error("the attached Rooms feed already has a line owner");
		this.#line = listener;
		let delivered = 0;
		let completed = false;
		try {
			while (delivered < this.#pendingLines.length) {
				const event = this.#pendingLines[delivered];
				delivered += 1;
				listener(event);
			}
			completed = true;
		} finally {
			if (delivered > 0) this.#pendingLines.splice(0, delivered);
			if (!completed && this.#line === listener) this.#line = null;
		}
		this.#initialEventGapReported = false;
		return () => {
			if (this.#line === listener) this.#line = null;
		};
	}

	onOperationsInvalidated(listener: (scope: string) => void): () => void {
		this.#assertOpen();
		this.#operationsChanged.add(listener);
		return () => this.#operationsChanged.delete(listener);
	}

	async refresh(): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		this.#accept(await this.#remote.snapshot());
		return this.requireSnapshot();
	}

	/** Hand the page the snapshot it already holds.
	 *
	 * Nothing is fetched: this is the same answer read again, because something
	 * the page needs changed outside it — which of the session's pending
	 * operations this tab is still driving. The session does not report that
	 * and cannot, so when a command ends without a new revision to carry the
	 * news, this is what carries it. */
	reannounce(): void {
		const snapshot = this.#snapshot;
		if (snapshot == null || this.#closed) return;
		for (const listener of [...this.#snapshots]) listener(snapshot);
	}

	requireSnapshot(): RoomsSessionSnapshot {
		if (this.#snapshot == null) throw new Error("the attached Rooms session has not produced a snapshot");
		return this.#snapshot;
	}

	async settleRevision(revision: number): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		if ((this.#snapshot?.revision ?? -1) >= revision) return this.requireSnapshot();
		if (this.#revisionWaiter != null) throw new Error("the attached Rooms controller admitted parallel commands");
		let timer: ReturnType<typeof setTimeout> | null = null;
		const watched = Promise.withResolvers<void>();
		this.#revisionWaiter = { revision, resolve: watched.resolve };
		try {
			await Promise.race([
				watched.promise,
				new Promise<void>((resolve) => {
					timer = setTimeout(resolve, WATCH_SETTLE_MS);
				}),
			]);
			if ((this.#snapshot?.revision ?? -1) < revision) await this.refresh();
			const snapshot = this.requireSnapshot();
			if (snapshot.revision < revision) {
				throw new Error(
					`the attached Rooms session snapshot stayed at revision ${snapshot.revision} after revision ${revision}`,
				);
			}
			return snapshot;
		} finally {
			if (timer != null) clearTimeout(timer);
			if (this.#revisionWaiter?.resolve === watched.resolve) this.#revisionWaiter = null;
		}
	}

	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#snapshots.clear();
		this.#line = null;
		for (const event of this.#pendingLines) this.#releaseLine(event);
		this.#pendingLines.length = 0;
		this.#snapshot = null;
		this.#eventSource = null;
		this.#eventSequence = 0;
		this.#initialEventGapReported = false;
		this.#operationsChanged.clear();
		this.#revisionWaiter = null;
	}

	#accept(snapshot: RoomsSessionSnapshot): void {
		if (this.#closed || (this.#snapshot != null && snapshot.revision < this.#snapshot.revision)) return;
		this.#snapshot = snapshot;
		const waiter = this.#revisionWaiter;
		if (waiter != null && waiter.revision <= snapshot.revision) {
			this.#revisionWaiter = null;
			waiter.resolve();
		}
		for (const listener of this.#snapshots) listener(snapshot);
	}

	#acceptLine(event: RoomsSessionLineEvent): void {
		if (this.#closed) {
			this.#releaseLine(event);
			return;
		}
		const gap = this.#eventSource !== event.source
			? event.sequence !== 1
			: event.sequence !== this.#eventSequence + 1;
		this.#eventSource = event.source;
		this.#eventSequence = event.sequence;
		if (gap) {
			this.#reportEventGap(event.conversationId, "The shared event stream skipped a sequence.");
			// The event exposing a gap is not trustworthy enough to project.
			this.#releaseLine(event);
			return;
		}
		if (this.#line == null) {
			if (this.#pendingLines.length === INITIAL_EVENT_BUFFER) {
				const evicted = this.#pendingLines.shift();
				if (evicted != null) this.#releaseLine(evicted);
				if (!this.#initialEventGapReported) {
					this.#initialEventGapReported = true;
					this.#reportEventGap(event.conversationId, "The shared event stream exceeded its initial buffer.");
				}
			}
			this.#pendingLines.push(event);
			return;
		}
		this.#line(event);
	}

	#releaseLine(event: RoomsSessionLineEvent): void {
		for (const attachment of event.attachments) {
			settleCapabilityCleanup(
				"buffered attached file capability release failed",
				() => this.#remote.releaseAttachment(attachment),
			);
		}
	}

	#reportEventGap(conversationId: string, reason: string): void {
		if (this.#snapshot != null) {
			const detail = this.#snapshot.checkpoint.keepHistory
				? `${reason} Retained history is reconciling for this conversation.`
				: `${reason} Retained history is disabled, so the missed lines are unavailable.`;
			const subject = `event-gap:${conversationId}`;
			this.#accept({
				...this.#snapshot,
				issues: [
					...this.#snapshot.issues.filter((issue) => issue.subject !== subject),
					{ subject, reason: detail },
				],
			});
		}
		const detail =
			this.#snapshot?.issues.find((issue) => issue.subject === `event-gap:${conversationId}`)?.reason ??
				reason;
		void this.#refreshAfterEventGap(`event-gap:${conversationId}`, detail);
	}

	async #refreshAfterEventGap(subject: string, gapReason: string): Promise<void> {
		try {
			await this.refresh();
		} catch (error) {
			const snapshot = this.#snapshot;
			if (snapshot == null) return;
			const reason = error instanceof Error ? error.message : String(error);
			this.#accept({
				...snapshot,
				issues: [
					...snapshot.issues.filter((issue) => issue.subject !== subject),
					{ subject, reason: `${gapReason} Snapshot refresh failed: ${reason}` },
				],
			});
		}
	}

	#assertOpen(): void {
		if (this.#closed) throw new Error("this attached Rooms feed is closed");
	}
}
