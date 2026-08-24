import { type Argument, type Ref, type Session } from "@pancake/runtime";
import { MAX_WATCHERS } from "./limits.ts";
import { UPDATE } from "./protocol.ts";

interface Watcher {
	readonly session: Session;
	readonly ref: Ref;
	active: boolean;
	pending: Argument | null;
	sending: boolean;
}

/** One bounded latest-snapshot pipeline per accepted session. */
export class TaskWatcherTable {
	readonly #bySession = new Map<Session, Watcher>();
	readonly #report: (message: string, error: unknown) => void;

	constructor(report: (message: string, error: unknown) => void) {
		this.#report = report;
	}

	get length(): number {
		return this.#bySession.size;
	}

	register(session: Session, ref: Ref): void {
		const prior = this.#bySession.get(session);
		if (prior === undefined && this.#bySession.size >= MAX_WATCHERS) {
			try {
				session.release(ref);
			} catch (error) {
				this.#report("refused task watcher capability release failed", error);
			}
			throw new Error(`the board already has ${MAX_WATCHERS} watchers`);
		}
		if (prior !== undefined) {
			this.#bySession.delete(session);
			this.#retire(prior);
		}
		this.#bySession.set(session, {
			session,
			ref,
			active: true,
			pending: null,
			sending: false,
		});
	}

	remove(session: Session): void {
		const watcher = this.#bySession.get(session);
		if (watcher === undefined) return;
		this.#bySession.delete(session);
		this.#retire(watcher);
	}

	notify(snapshot: Argument): void {
		for (const watcher of this.#bySession.values()) {
			watcher.pending = snapshot;
			this.#pump(watcher);
		}
	}

	#pump(watcher: Watcher): void {
		if (!watcher.active || watcher.sending || watcher.pending === null) return;
		const snapshot = watcher.pending;
		watcher.pending = null;
		watcher.sending = true;
		let delivery: Promise<void>;
		try {
			delivery = watcher.session.tell(watcher.ref, UPDATE, [snapshot]);
		} catch (error) {
			watcher.sending = false;
			this.#failed(watcher, error);
			return;
		}
		void delivery.then(
			() => {
				watcher.sending = false;
				this.#pump(watcher);
			},
			(error) => {
				watcher.sending = false;
				this.#failed(watcher, error);
			},
		).catch((error) => this.#failed(watcher, error));
	}

	#failed(watcher: Watcher, error: unknown): void {
		if (!watcher.active) return;
		this.#report("task watcher delivery failed", error);
		this.remove(watcher.session);
	}

	#retire(watcher: Watcher): void {
		watcher.active = false;
		watcher.pending = null;
		try {
			watcher.session.release(watcher.ref);
		} catch (error) {
			this.#report("task watcher capability release failed", error);
		}
	}
}
