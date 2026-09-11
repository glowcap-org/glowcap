// Stable presentation identity for the selected archive, including peer replacement.
import type { ArchiveTargetView } from "../archive_model.ts";

export class ArchiveTargetProjection {
	#peer: string | null = null;
	#error = "";
	#view: ArchiveTargetView = { kind: "owned", owner: "session" };

	update(peer: string | null, error: string): ArchiveTargetView {
		if (peer === this.#peer && error === this.#error) return this.#view;
		this.#peer = peer;
		this.#error = error;
		this.#view = peer == null ? { kind: "owned", owner: "session" } : {
			owner: "session",
			kind: "peer",
			status: error === "" ? "connected" : "unavailable",
			label: "Shared session archive peer",
			remembered: true,
			error,
		};
		return this.#view;
	}
}
