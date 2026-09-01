// Who is following one bridged room from a directory, and how it tells them.
//
// A watcher is not a member. It never joins the channel and never sees a line;
// it asked the bridge's directory to say when the room's count changes, and
// that is the whole of the relationship. Keeping it here rather than beside the
// membership tables is what stops the two being confused: they have different
// lifetimes, different bounds, and a watcher that goes away costs the IRC side
// nothing.
//
// This owns the table, the bound, the rule that a second watch from one
// connection replaces the first, and the discipline for telling them. What it
// does not own is what a row says: that is the room's identity, so the room
// supplies it.

import type { Argument, Ref, Session } from "@pancake/runtime";
import { NOTIFY } from "../../lib/protocol.ts";

interface Watcher {
	readonly session: Session;
	readonly inbox: Ref;
	/** A publications watcher takes the wider row: the same count, plus who is
	 * behind the room. */
	readonly rich: boolean;
}

export interface IrcWatcherHooks {
	release(session: Session, ref: Ref, label: string): void;
	/** Retire everything one connection holds. A notify that fails on a closed
	 * session is how a bridge usually learns a watcher is gone. */
	retire(session: Session): void;
	trouble(context: string, error: unknown): void;
}

export class IrcRoomWatchers {
	readonly #watchers = new Map<Session, Watcher>();

	constructor(readonly limit: number, readonly hooks: IrcWatcherHooks) {}

	get size(): number {
		return this.#watchers.size;
	}

	/** Take one connection's inbox as a watcher, or say why not.
	 *
	 * A refusal reason rather than a throw, because the caller is inside a
	 * capability verb and owes its arguments a release before refusing. The
	 * bound is checked against a *new* watcher only: a connection replacing its
	 * own watch is not a second one, and the inbox it held is handed back here
	 * rather than left for a reader to remember. */
	admit(session: Session, inbox: Ref, rich: boolean): string | null {
		const prior = this.#watchers.get(session);
		if (prior === undefined && this.#watchers.size >= this.limit) {
			return `this IRC bridge already has ${this.limit} directory watchers`;
		}
		if (prior !== undefined) {
			this.hooks.release(prior.session, prior.inbox, "replaced IRC bridge watcher capability release failed");
		}
		this.#watchers.set(session, { session, inbox, rich });
		return null;
	}

	/** Forget one connection's watch and hand its inbox back. Silent when it
	 * held none, because retiring a connection asks every table the same way. */
	drop(session: Session): void {
		const watcher = this.#watchers.get(session);
		if (watcher === undefined) return;
		this.#watchers.delete(session);
		this.hooks.release(watcher.session, watcher.inbox, "IRC bridge watcher capability release failed");
	}

	/** Tell every watcher, each in the shape it asked for.
	 *
	 * A failed tell is diagnostic, never authority: a watcher is retired because
	 * its session closed, which this checks for directly, rather than because one
	 * notification did not land. */
	notify(row: (rich: boolean) => Argument[]): void {
		for (const watcher of this.#watchers.values()) {
			watcher.session.tell(watcher.inbox, NOTIFY, ["count", ...row(watcher.rich)]).catch((error) => {
				if (!watcher.session.sessionOpen) {
					this.hooks.retire(watcher.session);
					return;
				}
				this.hooks.trouble("directory watcher notification failed", error);
			});
		}
	}
}
