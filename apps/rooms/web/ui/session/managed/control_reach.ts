// How each held control reaches its session over the current link, and what
// becomes of it when it cannot. A control reaches its session over a
// connection of its own, which need not be the page's, so its failure is its
// own. Every call through a control counts its handle, and a handle a move
// replaced is freed once its last call ends.
import type {
	RoomsManagedApplication,
	RoomsManagedControl,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { invariant } from "../../../../lib/invariant.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type { SubmissionOutcome } from "./acquisition.ts";
import type { GrantView, ManagementView } from "./access_powers.ts";
import {
	type ControlState,
	type Description,
	handleOf,
	type HeldControl,
	OWN_CONTROL,
	reached,
} from "./held_control.ts";

/** What one move of held access onto a new link reports through. */
export interface AccessMove {
	/** Whether this move is still the newest link's. */
	current(): boolean;
	report(id: string, error: unknown): void;
	/** Ask whether the page's own link still answers. Only its answer moves the link. */
	probe(): void;
}

/** Say through `move` that `source` failed while held access moved. A lost
 * connection also asks whether the page's own link still answers, because
 * only the page's link knows whether it does. */
export function reportMoveFailure(move: Pick<AccessMove, "report" | "probe">, source: string, error: unknown): void {
	move.report(source, error);
	if (connectionLost(error)) move.probe();
}

/** What reaching a control needs from the owner that holds it. */
interface ReachOwner {
	/** Whether the owner has closed. */
	closed(): boolean;
	changed(): void;
	/** Asks whether the page's own link still answers. */
	probe(): void;
	/** `control` lost its connection, in the owner's turn. */
	lost(control: HeldControl): void;
	/** A call through a handle `control` no longer holds lost that handle's
	 * connection with `failure`, in the owner's turn. */
	outlived(control: HeldControl, failure: unknown): void;
	/** Resumes an edit under way through `control` on the handle it holds now,
	 * and says whether the edit was sent. */
	resumeEdit(control: HeldControl): boolean;
	/** Sends `control`'s edit, or joins the send under way. */
	sendEdit(control: HeldControl): Promise<unknown>;
	/** Ends an edit prepared through `control` and never sent. */
	endEdit(control: HeldControl): void;
	/** Reads `control` again over its handle. */
	refresh(control: HeldControl): Promise<void>;
}

/** What `handle` says of the access it manages. A control without Inspect
 * remains held and usable for its explicit powers, but cannot manufacture a
 * target description for the editor. */
export async function describe(handle: RoomsManagedControl): Promise<Description> {
	const powers: ManagementView = await handle.describe();
	const grant: GrantView | null = powers.available && powers.inspect ? await handle.inspect() : null;
	return { grant, powers };
}

/** How a call through a control hears of a loss. */
export interface Through<T> {
	/** Reads a loss from a value the call returns, for a call that answers
	 * with its failure. */
	readonly lostIn?: (value: T) => unknown;
	/** Applies a loss the call saw: at once for a call in the owner's turn, as
	 * by default, or in a turn of its own for a call outside one. */
	readonly apply?: (change: () => void) => void;
}
/** How a request made through a control is kept. */
type Made<T> = Through<T> & {
	/** Runs the keep: at once for a request made in the owner's turn, as by
	 * default, or in a turn of its own for one made outside. */
	readonly settle?: <R>(keep: () => R) => Promise<R>;
};

export class ControlReach {
	readonly #application: RoomsManagedApplication;
	readonly #owner: ReachOwner;
	/** How many calls run through each handle now. */
	readonly #reading = new Map<RoomsManagedControl, number>();
	/** Handles no control holds any longer, freed when their last call ends. */
	readonly #retiring = new Set<RoomsManagedControl>();

	constructor(application: RoomsManagedApplication, owner: ReachOwner) {
		this.#application = application;
		this.#owner = owner;
	}
	/** Restore `control` over the current link, and say whether `move` is still
	 * the newest. A lost one only asks whether the page's link still answers. */
	async restoreOne(control: HeldControl, move: AccessMove): Promise<boolean> {
		try {
			return await this.restore(control, move.current);
		} catch (error) {
			// A newer link restores it again and says what fails there.
			if (!move.current()) return false;
			reportMoveFailure(move, control.id, error);
			return true;
		}
	}
	/** Reach `control` over the current link in place of the handle it held,
	 * and move an edit under way with it. One never reached is described first.
	 * `reach` is how, by default its saved row or address. Returns false when
	 * `current` says a newer link took over, which reaches it instead. A control
	 * that cannot be reached holds no handle and keeps the failure, which this
	 * also throws. */
	async restore(
		control: HeldControl,
		current: () => boolean,
		reach = this.#reachOf(control),
	): Promise<boolean> {
		if (reach == null) return true;
		const moved = () => this.#owner.closed() || !current();
		// A move a newer one overtook before its turn dials nothing.
		if (moved()) return false;
		let handle: RoomsManagedControl;
		try {
			handle = await reach();
		} catch (error) {
			if (moved()) return false;
			this.#unreach(control, error);
			throw error;
		}
		if (moved()) {
			handle.free();
			return false;
		}
		const state = control.state;
		if (state.kind === "undescribed") {
			let description: Description;
			try {
				description = await describe(handle);
			} catch (error) {
				handle.free();
				if (moved()) return false;
				this.#unreach(control, error);
				throw error;
			}
			if (moved()) {
				handle.free();
				return false;
			}
			this.retire(this.replace(control, { kind: "reached", handle, ...description }));
			this.#owner.changed();
			return true;
		}
		const old = this.replace(control, { kind: "reached", handle, grant: state.grant, powers: state.powers });
		let sent: boolean;
		try {
			sent = this.#owner.resumeEdit(control);
		} finally {
			this.retire(old);
			this.#owner.changed();
		}
		// The lookup reads the edit and the handle, not a description, so a
		// describe that fails leaves no sent edit waiting on the next link.
		if (sent) await this.#owner.sendEdit(control);
		await this.#owner.refresh(control);
		return true;
	}
	/** Put `next` in place of what `control` held over the replaced link, and
	 * return the old handle for the caller to free once nothing reads it. A save
	 * prepared over that link is prepared again, and a read that failed over it
	 * says nothing of the next. */
	replace(control: HeldControl, next: ControlState): RoomsManagedControl | null {
		const old = handleOf(control);
		control.state = next;
		delete control.readFailure;
		control.saving?.free();
		delete control.saving;
		return old;
	}
	/** `control` could not be reached over the current link, for `failure`. It
	 * keeps what it was last described as, and an edit it never sent ends. */
	#unreach(control: HeldControl, failure: unknown): void {
		this.lose(control, failure);
		this.#owner.endEdit(control);
	}
	/** Run `call` through `control`'s handle over the current link. A call that
	 * loses the control's own connection is the control's failure: once `how`
	 * applies it, the control is held unreached with the failure, its handle is
	 * freed once no other call reads it, and the page's own link is asked
	 * whether it still answers. A Try now or the next link reaches it again,
	 * and an edit under way through it moves then. */
	async through<T>(
		control: HeldControl,
		call: (handle: RoomsManagedControl) => Promise<T>,
		how: Through<T> = {},
	): Promise<T> {
		const { lostIn = () => null, apply = (change) => change() } = how;
		const handle = reached(control);
		this.#reading.set(handle, (this.#reading.get(handle) ?? 0) + 1);
		try {
			const value = await call(handle);
			this.#lostThrough(control, handle, lostIn(value), apply);
			return value;
		} catch (error) {
			this.#lostThrough(control, handle, error, apply);
			throw error;
		} finally {
			const left = (this.#reading.get(handle) ?? 1) - 1;
			if (left > 0) this.#reading.set(handle, left);
			else {
				this.#reading.delete(handle);
				if (this.#retiring.delete(handle)) handle.free();
			}
		}
	}
	/** Make a request through `control`, as `through` runs a call, and `keep`
	 * it where `how.settle` runs. A request made over a handle a move replaced
	 * before then was never sent, and the move could not carry it, so it is
	 * freed and refused as not sent. */
	async madeThrough<T extends { free(): void }, R>(
		control: HeldControl,
		make: (handle: RoomsManagedControl) => Promise<T>,
		keep: (made: T) => R,
		how: Made<T> = {},
	): Promise<R> {
		const { settle = <S>(run: () => S) => Promise.resolve(run()) } = how;
		const used = handleOf(control);
		const made = await this.through(control, make, how);
		return await settle(() => {
			if (handleOf(control) === used) return keep(made);
			made.free();
			throw new LocalRefusal("not-sent");
		});
	}
	/** Submit a request made through `control`, as `through` runs a call. A
	 * submit that lost its connection may still have landed, so it resolves as
	 * uncertain with the loss as its failure. */
	submitThrough<T extends SubmissionOutcome>(control: HeldControl, submit: () => Promise<T>): Promise<T> {
		return this.through(control, submit, {
			lostIn: (outcome) => outcome.status === "uncertain" ? outcome.failure : null,
		});
	}
	/** A call through `handle` ended with `failure`. One that lost the
	 * connection unreaches `control` when `apply` runs. A control that holds
	 * another handle by then, or none, has already moved past that connection,
	 * so the loss is only the call's (`ReachOwner.outlived`). */
	#lostThrough(
		control: HeldControl,
		handle: RoomsManagedControl,
		failure: unknown,
		apply: (change: () => void) => void,
	): void {
		if (!connectionLost(failure)) return;
		apply(() => {
			const state = control.state;
			if (state.kind !== "reached" || state.handle !== handle) {
				this.#owner.outlived(control, failure);
				return;
			}
			this.lose(control, failure);
			this.#owner.lost(control);
			this.#owner.probe();
		});
	}
	/** Hold `control` unreached for `failure`, and free its handle once no call
	 * reads it. It keeps what it was last described as, and an edit under way
	 * through it stays to move with it. */
	lose(control: HeldControl, failure: unknown): void {
		const state = control.state;
		const next: ControlState = state.kind === "undescribed"
			? { kind: "undescribed", failure }
			: { kind: "unreached", failure, grant: state.grant, powers: state.powers };
		this.retire(this.replace(control, next));
		this.#owner.changed();
	}
	/** Free `handle`, which no control holds now, once no call reads it. */
	retire(handle: RoomsManagedControl | null): void {
		if (handle == null) return;
		if (this.#reading.has(handle)) this.#retiring.add(handle);
		else handle.free();
	}
	/** How a new link reaches `control` again, or null for a new access a share
	 * made and has not saved, which the share itself moves. The page's own
	 * control is held only by a page that runs its session, which has no link to
	 * lose or move, so it is never reached again. */
	#reachOf(control: HeldControl): (() => Promise<RoomsManagedControl>) | null {
		invariant(control.id !== OWN_CONTROL, "the page's own control has no link to reach it again over");
		const storage = control.storage;
		if (storage.kind === "saved") return () => this.#application.savedControl(control.id);
		const address = storage.address;
		return address == null ? null : () => this.#application.attachControl(address);
	}
}
