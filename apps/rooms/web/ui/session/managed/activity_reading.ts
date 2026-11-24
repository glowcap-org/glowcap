// The page reads the session's activity journal for one presentation owner at
// a time, from the cursor it last accepted. A failed read keeps that cursor,
// and the next change or an explicit retry reads again.
import { invariant } from "../../../../lib/invariant.ts";
import { ACTIVITY_CURSOR_STALE, roomsErrorIn } from "../../../../lib/error_codes.ts";
import { managedAccessText as text } from "../../../../lib/text/managed_access.ts";
import type { RoomsManagedActivityReader } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { ActivityDelivery } from "./activity.ts";
import { type LinkHandle, type LinkPort, stampOf } from "./link_port.ts";
import type { ActivityRead } from "./model.ts";

/** What the reader needs from the session it reads for. */
export interface ActivitySession extends Pick<LinkPort, "current" | "isCurrent" | "overStamped"> {
	permits(permission: RoomsPermission): boolean;
	stopped(): boolean;
	change(): number;
	wait(change: number): Promise<void>;
	changed(): void;
	/** A read answered, so no retry waits on it any longer. */
	answered(): void;
	/** A read failed, which the session reports under `source`. Returns
	 * whether the failure is the reader's to show, which a lost connection the
	 * link's own notice tells is not. */
	failed(source: string, error: unknown): boolean;
}

type Listener = (delivery: ActivityDelivery) => void | Promise<void>;

/** How far behind the journal a reader is: `head` is where the journal ended
 * when it began to catch up, or null until a read says where. */
export type Behind = { readonly head: string | null };

/** What one read means for a reader that was `behind` (null when every event
 * it reads is news) at `cursor`. `replayed` says the delivery is from before
 * the reader was reading. `after` is how far behind the reader is once it
 * takes the delivery. A gap skips to what the journal still holds, which ends
 * where the journal ends now. A `restarted` session says nowhere yet, so the
 * reader stays behind with no head. */
export function catchUp(
	behind: Behind | null,
	delivery: ActivityRead<unknown>,
	restarted: boolean,
	cursor: string,
): { replayed: boolean; after: Behind | null } {
	const head = restarted ? null : delivery.gap ? delivery.head : behind?.head ?? delivery.head;
	const empty = delivery.event == null && !delivery.gap && !delivery.unavailable;
	const caughtUp = !restarted && behind != null && (empty || cursor === head);
	return {
		replayed: behind != null && !caughtUp,
		after: (behind == null || caughtUp) && !delivery.gap ? null : { head },
	};
}

export class ManagedActivityReading {
	readonly #session: ActivitySession;
	readonly #listeners = new Set<Listener>();
	#reader: RoomsManagedActivityReader | null = null;
	#reading: Promise<void> | null = null;
	#failure: unknown = null;
	#cursor = "";
	/** How far behind the journal this reader is, or null once every event it
	 * reads is news. It is behind at first, and after a failed read, a gap, or
	 * a stretch with no reader, and it then reads without waiting. `head` is
	 * where the journal ended when it began to catch up, or null until a read
	 * says where. Every event up to it had already happened. */
	#behind: Behind | null = { head: null };

	constructor(session: ActivitySession) {
		this.#session = session;
	}
	/** Why the last read failed, or null while reads succeed. */
	get failure(): unknown {
		return this.#failure;
	}
	get listeners(): number {
		return this.#listeners.size;
	}
	get open(): boolean {
		return this.#reader != null;
	}
	/** The loop, once started, which ends when the session stops. */
	get running(): Promise<void> | null {
		return this.#reading;
	}
	listen(listener: Listener): () => void {
		invariant(this.#listeners.size === 0, "activity custody already has a presentation owner");
		this.#listeners.add(listener);
		this.#session.changed();
		return () => {
			this.#listeners.delete(listener);
			this.#session.changed();
		};
	}
	start(): void {
		this.#reading = this.#read();
	}
	/** A new link replaced the last. Its reader goes, and the next one catches
	 * up from the cursor this page kept, as a reload does. */
	relink(): void {
		const stale = this.#reader;
		this.#reader = null;
		this.#failure = null;
		this.#behind = { head: null };
		// A read still pending on the stale reader keeps what it uses: the wasm
		// call holds its own copies of the reader and workspace until it settles.
		stale?.free();
	}
	/** Release the reader once the loop has ended. */
	free(): void {
		this.#reader?.free();
		this.#reader = null;
		this.#listeners.clear();
	}
	/** The failure this reader showed is over. */
	#cleared(): void {
		if (this.#failure == null) return;
		this.#failure = null;
		this.#session.answered();
		this.#session.changed();
	}
	async #read(): Promise<void> {
		const session = this.#session;
		while (!session.stopped()) {
			const change = session.change();
			const link = session.current();
			if (!session.permits("observeWorkspace") || this.#listeners.size === 0) {
				// Whatever happens while nothing reads has already happened to the
				// next reader.
				this.#behind = { head: null };
				// Nothing reads activity now, so no failure of it is waiting on a retry.
				this.#cleared();
				await session.wait(change);
				continue;
			}
			let offered: ActivityDelivery | undefined;
			try {
				const reader = this.#reader ?? await this.#opened(link);
				if (reader == null) continue;
				const behind = this.#behind;
				const { delivery, restarted } = await this.#fetch(link, reader, behind);
				const { replayed, after } = catchUp(behind, delivery, restarted, this.#cursor);
				offered = new ActivityDelivery(delivery, replayed, stampOf(link));
				if (!session.isCurrent(link)) {
					offered.close();
					continue;
				}
				const listener = this.#listeners.values().next().value;
				if (session.stopped() || listener == null) {
					offered.close();
					continue;
				}
				if (delivery.gap) await session.overStamped(link, () => link.workspace.resynchronizeDiscovery());
				await listener(offered);
				this.#cursor = delivery.cursor;
				// A link installed while the listener ran left this reader behind,
				// and the next link's reads catch up from here.
				if (!session.isCurrent(link)) continue;
				this.#behind = after;
				this.#cleared();
			} catch (error) {
				offered?.close();
				if (session.stopped()) break;
				if (!session.isCurrent(link)) continue;
				if (session.failed(text.activity, error)) this.#failure = error;
				this.#behind = { head: null };
				session.answered();
				session.changed();
				// A source observation or an explicit retry wakes this exact reader.
				// Refusal preserves both its custody and its last accepted cursor.
				await session.wait(session.change());
			} finally {
				offered?.close();
			}
		}
	}
	/** Open a reader over `link` and keep it, or null when a newer link
	 * replaced `link` while it opened. */
	async #opened(link: LinkHandle): Promise<RoomsManagedActivityReader | null> {
		const opened: RoomsManagedActivityReader = await this.#session.overStamped(
			link,
			() => link.workspace.activityReader(),
		);
		if (!this.#session.isCurrent(link)) {
			opened.free();
			return null;
		}
		return this.#reader = opened;
	}
	/** Read the next delivery after the kept cursor, waiting for one only once
	 * caught up. A session restarted since the cursor was kept starts from the
	 * beginning of what it holds, as a gap does. */
	async #fetch(
		link: LinkHandle,
		reader: RoomsManagedActivityReader,
		behind: Behind | null,
	): Promise<{ delivery: ActivityRead<unknown>; restarted: boolean }> {
		try {
			return {
				delivery: await this.#session.overStamped(link, () => reader.read(this.#cursor, behind == null)),
				restarted: false,
			};
		} catch (error) {
			if (roomsErrorIn(error)?.code !== ACTIVITY_CURSOR_STALE) throw error;
			return { delivery: { cursor: "", gap: true, head: "" }, restarted: true };
		}
	}
}
