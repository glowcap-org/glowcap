// Ephemeral typing has one latest level per conversation and one call in
// flight. Selection changes release the original sender only after its last
// call has drained.
// A line ends its author's typing where it arrives. While a line with nothing
// to upload is on its way, its conversation's typing waits for it, and the
// level its composer asks for last is read when the line settles. A line that
// lands was the stop. No stop follows it unless a start was still on its way
// when the line left, and a member typing a newer draft is said again because
// the line ended what was said before it. A line the room refused stopped
// nothing, so the level asked for is sent either way. A line typing did not
// wait for ends typing the same way, so a member still typing when it lands
// is said again then.
// A rate-limited level waits out the room's stated delay and is sent again
// unless a newer one replaced it. Any other refusal ends typing for that
// conversation.
import { roomsErrorIn } from "../../../../lib/error_codes.ts";
import type { RoomsManagedTyping } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";

interface Level {
	readonly id: string;
	readonly selected: string;
	readonly on: boolean;
}

export class ManagedTyping {
	readonly #session: ManagedRoomsSession;
	/** The latest level each conversation still has to hear, oldest first. */
	readonly #desired = new Map<string, Level>();
	/** The level each conversation's composer asked for last, until the
	 * conversation hears a stop. A line that settles reads it. */
	readonly #asked = new Map<string, Level>();
	/** Conversations with a line on its way. Each holds the start that was on
	 * its way when the draft left, if one was: it can reach the conversation
	 * behind the line, so the line is not its stop. */
	readonly #lineOut = new Map<string, Level | null>();
	/** The level whose call is on its way to the conversation. */
	#sending: Level | null = null;
	#sender: { id: string; selected: string; handle: RoomsManagedTyping } | null = null;
	#running: Promise<void> | null = null;
	#stopped = false;
	#failed: string | null = null;
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	/** A line is leaving conversation `id`. The composer sends one at a time.
	 * A level not yet sent waits with it. */
	lineLeft(id: string): void {
		this.#lineOut.set(id, this.#sending?.id === id && this.#sending.on ? this.#sending : null);
		this.#desired.delete(id);
	}
	/** The line from conversation `id` landed there, or did not. */
	lineSettled(id: string, landed: boolean): Promise<void> {
		const behind = this.#lineOut.get(id);
		if (behind === undefined) return Promise.resolve();
		this.#lineOut.delete(id);
		const asked = this.#asked.get(id);
		if (asked == null) return Promise.resolve();
		if (landed && !asked.on && behind == null) {
			this.#asked.delete(id);
			return Promise.resolve();
		}
		return this.set(asked.id, asked.selected, asked.on);
	}
	/** A line typing did not wait for landed in conversation `id`. */
	lineLanded(id: string): Promise<void> {
		const asked = this.#asked.get(id);
		return asked?.on === true ? this.set(asked.id, asked.selected, true) : Promise.resolve();
	}
	/** Conversation `id` is gone. Nothing it was owed is sent. */
	forget(id: string): void {
		this.#lineOut.delete(id);
		this.#desired.delete(id);
		this.#asked.delete(id);
	}
	set(id: string, selected: string, on: boolean): Promise<void> {
		if (this.#stopped || this.#failed === JSON.stringify([id, selected])) return Promise.resolve();
		const level = { id, selected, on };
		this.#asked.set(id, level);
		if (this.#lineOut.has(id)) return Promise.resolve();
		// A newer level takes its conversation's place at the back, so a stop
		// owed to another conversation is sent first.
		this.#desired.delete(id);
		this.#desired.set(id, level);
		// One caller owns the refusal; keystrokes joining this drain do not
		// each publish the same failure when its shared request settles.
		if (this.#running != null) {
			return this.#running.catch(() => {
				// tolerant: the initiating caller reports this shared typing failure once.
			});
		}
		return this.#running = this.#drain().finally(() => {
			this.#running = null;
		});
	}
	async #drain(): Promise<void> {
		let failure: unknown;
		while (!this.#stopped) {
			const [desired] = this.#desired.values();
			if (desired == null) break;
			this.#desired.delete(desired.id);
			if (JSON.stringify([desired.id, desired.selected]) === this.#failed) continue;
			try {
				if (this.#sender?.id !== desired.id || this.#sender.selected !== desired.selected) {
					this.#sender?.handle.free();
					this.#sender = null;
					const handle: RoomsManagedTyping = await this.#session.workspace.typingSender(
						desired.id,
						desired.selected,
					);
					if (this.#stopped) {
						handle.free();
						return;
					}
					this.#sender = { id: desired.id, selected: desired.selected, handle };
				}
				// The sender may have taken a while to open. A line that left
				// meanwhile holds the level, and a newer level or a conversation
				// that is gone leaves nothing of it to send.
				if (this.#lineOut.has(desired.id) || this.#asked.get(desired.id) !== desired) continue;
				this.#sending = desired;
				await this.#sender.handle.set(desired.on);
				this.#sending = null;
				if (!desired.on && this.#asked.get(desired.id) === desired) this.#asked.delete(desired.id);
			} catch (error) {
				this.#sending = null;
				// Nobody heard a start the conversation refused.
				if (this.#lineOut.get(desired.id) === desired) this.#lineOut.set(desired.id, null);
				const delay = roomsErrorIn(error)?.retryAfterMs ?? null;
				if (delay != null) {
					// A level the room asked to hear again later is sent again
					// while it is still the one asked for. A line that left
					// meanwhile holds it.
					if (!this.#lineOut.has(desired.id) && this.#asked.get(desired.id) === desired) {
						this.#desired.set(desired.id, desired);
					}
					if (this.#desired.size > 0) await new Promise((resume) => setTimeout(resume, delay));
					continue;
				}
				this.#failed = JSON.stringify([desired.id, desired.selected]);
				failure ??= error;
			}
		}
		if (failure != null) throw failure;
	}
	stop(): void {
		this.#stopped = true;
		this.#desired.clear();
		this.#asked.clear();
	}
	async close(): Promise<void> {
		this.stop();
		try {
			await this.#running;
		} finally {
			this.#sender?.handle.free();
			this.#sender = null;
		}
	}
}
