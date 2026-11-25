// The rows this page keeps for held controls in its own storage: saving one so
// the page restores it when it opens, and releasing one when the person
// removes its access from the list. Each runs in the access owner's turn.
import type {
	RoomsManagedAcquisition,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { AcquisitionConflict, type SettledOutcome, submitAcquisition, throwUnlessCommitted } from "./acquisition.ts";
import type { AccessOwner } from "./access_owner.ts";
import { type HeldControl, saved } from "./held_control.ts";

/** What storage reads of the access owner that holds the controls. */
interface StorageOwner extends Pick<AccessOwner, "checkOpen" | "accept" | "changed" | "through"> {
	/** Whether `control` is the one the owner holds under its id. */
	holds(control: HeldControl): boolean;
	/** Stop holding `control`, whose row is gone. */
	forgotten(control: HeldControl): void;
}

export class AccessStorage {
	/** The workspace whose storage keeps the saved controls. */
	readonly #custody: RoomsManagedWorkspace;
	readonly #owner: StorageOwner;

	constructor(custody: RoomsManagedWorkspace, owner: StorageOwner) {
		this.#custody = custody;
		this.#owner = owner;
	}
	/** Save `control` in the turn of the event that asked. A control this page
	 * let go of sends nothing. Preparing the save asks the access for its link
	 * over the control's own connection, so a loss there is the control's.
	 * Storage that already holds the control's row prepares nothing: an earlier
	 * save wrote it although its answer was lost, so the control is saved. */
	async save(control: HeldControl): Promise<void> {
		this.#owner.checkOpen();
		if (!this.#owner.holds(control)) throw new LocalRefusal("not-sent");
		if (saved(control)) return;
		let saving = control.saving;
		if (saving == null) {
			const prepared: RoomsManagedAcquisition | null = await this.#owner.through(
				control,
				(handle) => this.#custody.prepareSaveControl(control.id, handle),
			);
			if (prepared == null) {
				this.#saved(control);
				return;
			}
			saving = this.#owner.accept(prepared);
		}
		control.saving = saving;
		const outcome = await submitAcquisition(saving);
		this.#owner.checkOpen();
		saving.free();
		delete control.saving;
		if (outcome.status === "committed") this.#saved(control);
		else this.#owner.changed();
		throwUnlessCommitted(outcome);
	}
	#saved(control: HeldControl): void {
		control.storage = { kind: "saved", address: control.storage.address };
		this.#owner.changed();
	}
	/** Release `control`'s row, then stop holding it. Another writer can move
	 * the workspace between read and commit. Each conflict rereads it, and three
	 * in a row report the conflict. */
	async forget(control: HeldControl): Promise<void> {
		for (let attempt = 1; attempt <= 3; attempt++) {
			if (!await this.#releaseRow(control)) continue;
			this.#owner.checkOpen();
			this.#owner.forgotten(control);
			return;
		}
		throw new AcquisitionConflict();
	}
	/** Release `control`'s saved row from the current workspace. True once no
	 * row is left, false when another writer moved the workspace first. A
	 * refusal throws with its reason. */
	async #releaseRow(control: HeldControl): Promise<boolean> {
		const release: RoomsManagedAcquisition | null = await this.#custody.prepareForgetControl(control.id);
		if (release == null) return true;
		this.#owner.accept(release);
		let outcome: SettledOutcome;
		try {
			outcome = await submitAcquisition(release);
		} finally {
			release.free();
		}
		if (outcome.status === "conflict") return false;
		throwUnlessCommitted(outcome);
		return true;
	}
}
