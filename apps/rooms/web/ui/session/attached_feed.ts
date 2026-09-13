import type { AttachedLineEvent as RoomsSessionLineEvent } from "./remote.ts";
// Revisioned observations from one attached durable Rooms session.

import type { HistoryChange } from "../../../lib/session/history.ts";
import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { AttachedRoomsRemote } from "./remote.ts";

type SnapshotListener = (snapshot: RoomsSessionSnapshot) => void;
type LineListener = (event: RoomsSessionLineEvent) => void;

/** Owns the attached session's one accepted snapshot and its observation
 * streams. Commands wait here for revisions because the feed, not a command
 * caller, decides when a snapshot has actually arrived. The Rust attachment
 * owns line delivery, gap detection and revision settling; this feed hands the
 * line listener straight to it and never buffers or reorders events. */
export class AttachedSessionFeed {
	readonly #remote: AttachedRoomsRemote;
	readonly #snapshots = new Set<SnapshotListener>();
	#line: LineListener | null = null;
	readonly #operationsChanged = new Set<(scope: string) => void>();
	readonly #historyChanged = new Set<(change: HistoryChange) => void>();
	#snapshot: RoomsSessionSnapshot | null = null;
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
			(scope) => {
				for (const changed of this.#operationsChanged) changed(scope);
			},
			(change) => {
				for (const changed of this.#historyChanged) changed(change);
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
		try {
			this.#remote.listenLines(listener);
		} catch (error) {
			this.#line = null;
			throw error;
		}
		return () => {
			if (this.#line === listener) {
				this.#line = null;
				if (!this.#closed) this.#remote.listenLines(undefined);
			}
		};
	}

	onOperationsInvalidated(listener: (scope: string) => void): () => void {
		this.#assertOpen();
		this.#operationsChanged.add(listener);
		return () => this.#operationsChanged.delete(listener);
	}

	onHistoryInvalidated(listener: (change: HistoryChange) => void): () => void {
		this.#assertOpen();
		this.#historyChanged.add(listener);
		return () => this.#historyChanged.delete(listener);
	}

	/** Read the latest snapshot again. The Rust call announces through the
	 * `changed` observer before it resolves, so the accepted snapshot is already
	 * current when this returns. */
	async refresh(): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		await this.#remote.snapshot();
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

	/** Wait for a command's revision to arrive. The Rust attachment settles the
	 * revision and announces it through the `changed` observer, so the accepted
	 * snapshot is current when this returns. */
	async settleRevision(revision: number): Promise<RoomsSessionSnapshot> {
		this.#assertOpen();
		await this.#remote.settleRevision(revision);
		return this.requireSnapshot();
	}

	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#snapshots.clear();
		this.#remote.listenLines(undefined);
		this.#line = null;
		this.#snapshot = null;
		this.#operationsChanged.clear();
		this.#historyChanged.clear();
	}

	#accept(snapshot: RoomsSessionSnapshot): void {
		if (this.#closed || (this.#snapshot != null && snapshot.revision < this.#snapshot.revision)) return;
		this.#snapshot = snapshot;
		for (const listener of this.#snapshots) listener(snapshot);
	}

	#assertOpen(): void {
		if (this.#closed) throw new Error("this attached Rooms feed is closed");
	}
}
