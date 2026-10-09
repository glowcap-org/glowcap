// Ephemeral typing has one latest intent and one in-flight call. Selection
// changes release the original sender only after its last call has drained.
import type { RoomsManagedTyping } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";

export class ManagedTyping {
	readonly #session: ManagedRoomsSession;
	#desired: { id: string; selected: string; on: boolean } | null = null;
	#sender: { id: string; selected: string; handle: RoomsManagedTyping } | null = null;
	#running: Promise<void> | null = null;
	#stopped = false;
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	set(id: string, selected: string, on: boolean): Promise<void> {
		if (this.#stopped) return Promise.resolve();
		this.#desired = { id, selected, on };
		return this.#running ??= this.#drain().finally(() => {
			this.#running = null;
		});
	}
	async #drain(): Promise<void> {
		while (!this.#stopped && this.#desired != null) {
			const desired = this.#desired;
			this.#desired = null;
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
		}
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
