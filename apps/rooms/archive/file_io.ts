// The archive peer's crash boundary: complete writes, fsync, and same-directory
// replacement. Storage and identity use this one implementation so neither can
// accidentally treat a short filesystem write as durable state.

import { DirectoryCustody } from "../lib/directory_custody.ts";
export { appendSynced, atomicWrite } from "../lib/durable_file.ts";

/** One live archive peer's OS-released custody of a state directory. The lock
 * file itself may survive a crash; its kernel lock cannot, so restart needs no
 * stale-pid guessing and a second live process refuses immediately. */
export class ArchiveDirectoryCustody {
	readonly #held: DirectoryCustody;

	private constructor(held: DirectoryCustody) {
		this.#held = held;
	}

	static async acquire(directory: string): Promise<ArchiveDirectoryCustody> {
		return new ArchiveDirectoryCustody(await DirectoryCustody.acquire(directory, "archive.lock", "archive"));
	}

	close(): void {
		this.#held.close();
	}
}
