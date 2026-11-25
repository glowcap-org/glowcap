// The seam between `ManagedAccess` and the parts that act on its held
// controls: its edits, its share, and its storage. Each part reads the owner
// only through this.
import type { RoomsManagedControl } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { SubmissionOutcome } from "./acquisition.ts";
import type { HeldControl } from "./held_control.ts";

export interface AccessOwner {
	/** Refuses once the owner has closed. */
	checkOpen(): void;
	/** Returns `handle`, or frees it and refuses once the owner has closed. */
	accept<T extends { free(): void }>(handle: T): T;
	/** Keeps the owner's close waiting until `job` ends. */
	track<T>(job: Promise<T>): Promise<T>;
	changed(): void;
	/** As `ControlReach.through`, for a call in the owner's turn. */
	through<T>(control: HeldControl, call: (handle: RoomsManagedControl) => Promise<T>): Promise<T>;
	/** As `ControlReach.through`, for a call outside the owner's turn: a loss it
	 * sees is applied in a turn of its own. */
	outside<T>(control: HeldControl, call: (handle: RoomsManagedControl) => Promise<T>): Promise<T>;
	/** As `ControlReach.madeThrough`, for a request made in the owner's turn. */
	madeThrough<T extends { free(): void }, R>(
		control: HeldControl,
		make: (handle: RoomsManagedControl) => Promise<T>,
		keep: (made: T) => R,
	): Promise<R>;
	/** As `ControlReach.madeThrough`, for a request made outside the owner's
	 * turn: it is kept, or a loss it saw applied, in a turn of its own. */
	madeOutside<T extends { free(): void }, R>(
		control: HeldControl,
		make: (handle: RoomsManagedControl) => Promise<T>,
		keep: (made: T) => R,
	): Promise<R>;
	/** As `ControlReach.submitThrough`. */
	submitThrough<T extends SubmissionOutcome>(control: HeldControl, submit: () => Promise<T>): Promise<T>;
	/** Reads `control` again in the turn under way. A failure other than a lost
	 * connection stays on the control as its `readFailure`. */
	refreshNow(control: HeldControl): Promise<void>;
	/** Keeps `change` in a turn of its own, for a call outside a turn that saw
	 * it. Nobody waits on it, and the owner reports a failure it meets. */
	later(change: () => void): void;
	/** Keeps `change`, what a call outside a turn does on meeting `error`, as
	 * `later` does, recording first what each held access shows for a press
	 * that `error` refused (`press_answer.ts`). */
	refused(error: unknown, change: () => void): void;
	/** Runs `event` in the owner's turn. */
	inTurn<T>(event: () => T | Promise<T>): Promise<T>;
}
