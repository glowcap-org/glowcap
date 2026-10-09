// Which workspace view this viewer reads: one retained selection at a time,
// prepared once and submitted until it lands, so a lost reply retries the
// original choice rather than a new one.
import type {
	RoomsManagedAcquisition,
	RoomsManagedApplication,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { AcquisitionConflict, submitAcquisition } from "./acquisition.ts";
import type { WorkspaceSnapshot } from "./model.ts";

export class ManagedSelection {
	readonly #application: RoomsManagedApplication;
	readonly #custody: RoomsManagedWorkspace;
	readonly #track: <T>(task: Promise<T>) => Promise<T>;
	#selection: { uri: string | null; request: RoomsManagedAcquisition } | null = null;
	#selecting: Promise<void> | null = null;
	#selectingUri: string | null = null;
	#stopped = false;
	constructor(
		application: RoomsManagedApplication,
		custody: RoomsManagedWorkspace,
		track: <T>(task: Promise<T>) => Promise<T>,
	) {
		this.#application = application;
		this.#custody = custody;
		this.#track = track;
	}
	select(uri: string | null): Promise<void> {
		if (this.#selecting != null) {
			return this.#selectingUri === uri
				? this.#selecting
				: Promise.reject(new Error("Recover the original workspace selection before choosing another view"));
		}
		this.#selectingUri = uri;
		return this.#selecting = this.#track(this.#selectWorkspace(uri)).finally(() => {
			this.#selecting = null;
			this.#selectingUri = null;
		});
	}
	async #selectWorkspace(uri: string | null): Promise<void> {
		if (this.#stopped) throw new Error("This workspace is closed");
		if (this.#selection != null && this.#selection.uri !== uri) {
			throw new Error("Recover the original workspace selection before choosing another view");
		}
		if (this.#selection == null) {
			let request: RoomsManagedAcquisition;
			if (uri != null) {
				const view: RoomsManagedWorkspace = await this.#application.attachWorkspace(uri);
				try {
					request = await this.#custody.prepareSelectWorkspace("active-view", view);
				} finally {
					view.free();
				}
			} else {
				const snapshot: WorkspaceSnapshot = await this.#custody.snapshot();
				const selected = snapshot.intent.accesses?.find((row) => row.id === "active-view");
				if (selected?.access == null) return;
				const releases = [{ role: "sessionAccess", key: selected.access }];
				selected.access = null;
				if (selected.control == null) {
					snapshot.intent.accesses = snapshot.intent.accesses!.filter((row) => row !== selected);
				}
				request = await this.#custody.prepareAcquisition(
					snapshot.revision,
					"[]",
					JSON.stringify(releases),
					JSON.stringify(snapshot.intent),
				);
			}
			if (this.#stopped) {
				request.free();
				throw new Error("This workspace is closed");
			}
			this.#selection = { uri, request };
		}
		const outcome = await submitAcquisition(this.#selection.request);
		this.#selection.request.free();
		this.#selection = null;
		if (outcome === "conflict") throw new AcquisitionConflict();
	}
	stop(): void {
		this.#stopped = true;
	}
	close(): void {
		this.#selection?.request.free();
		this.#selection = null;
	}
}
