// Ephemeral typing has one latest intent and one in-flight call. Selection
// changes release the original sender only after its last call has drained.
// A rate-limited flag waits out the room's stated delay and then sends whatever
// is latest: typing is a level, so the draft still on screen is the gesture.
// Any other refusal ends typing for that conversation.
import { roomsErrorInMessage } from "../../../../lib/error_codes.ts";
import type { RoomsManagedTyping } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";

export class ManagedTyping {
	readonly #session: ManagedRoomsSession;
	#desired: { id: string; selected: string; on: boolean } | null = null;
	#sender: { id: string; selected: string; handle: RoomsManagedTyping } | null = null;
	#running: Promise<void> | null = null;
	#stopped = false;
	#failed: string | null = null;
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	set(id: string, selected: string, on: boolean): Promise<void> {
		if (this.#stopped || this.#failed === JSON.stringify([id, selected])) return Promise.resolve();
		this.#desired = { id, selected, on };
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
		while (!this.#stopped && this.#desired != null) {
			const desired = this.#desired;
			this.#desired = null;
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
				await this.#sender.handle.set(desired.on);
			} catch (error) {
				const delay = roomsErrorInMessage(error)?.retryAfterMs ?? null;
				if (delay != null) {
					this.#desired ??= desired;
					await new Promise((resume) => setTimeout(resume, delay));
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
		this.#desired = null;
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
