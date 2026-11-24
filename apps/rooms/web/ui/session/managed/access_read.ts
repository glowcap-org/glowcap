// Reading a held control again, and keeping what the read says of its access:
// its grant and powers, or why the read failed. A lost connection is the
// control reach's to keep, so a read keeps only a failure of another kind, on
// the control as its `readFailure`, until a read replaces it.
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type { AccessOwner } from "./access_owner.ts";
import { grantIdentity, type GrantView } from "./access_powers.ts";
import { describe } from "./control_reach.ts";
import { type Description, handleOf, type HeldControl } from "./held_control.ts";

/** What reading needs from the access owner. */
interface ReadOwner
	extends Pick<AccessOwner, "checkOpen" | "track" | "changed" | "through" | "outside" | "later" | "inTurn"> {
	/** Says a failure that lands on no row. */
	report(error: unknown): void;
}

export class AccessReads {
	readonly #owner: ReadOwner;

	constructor(owner: ReadOwner) {
		this.#owner = owner;
	}
	/** A page of the accesses made from `control`, from outside a turn. A page
	 * lost with the connection of a handle a reach has already replaced is
	 * asked for again over the new one, because a read changes nothing and the
	 * card asks again only when the access moves. Like every call outside a
	 * turn, it reads the control as it stands and waits on no turn. */
	async list(control: HeldControl, cursor?: Uint8Array): Promise<{ rows: GrantView[]; cursor: Uint8Array | null }> {
		const used = handleOf(control);
		try {
			return await this.#owner.outside(control, (handle) => handle.inventory(cursor));
		} catch (error) {
			const replaced = control.state.kind === "reached" && handleOf(control) !== used;
			if (!connectionLost(error) || !replaced) throw error;
			return await this.list(control, cursor);
		}
	}
	/** Read `control` again from outside a turn. What the read says is kept in a
	 * turn of its own, unless the control holds another handle by then, whose
	 * move or Try now reads it again. */
	refresh(control: HeldControl): Promise<void> {
		return this.#owner.track(this.#refresh(control));
	}
	async #refresh(control: HeldControl): Promise<void> {
		this.#owner.checkOpen();
		const read = handleOf(control);
		let description: Description;
		try {
			description = await this.#owner.outside(control, describe);
		} catch (error) {
			this.#owner.later(() => {
				if (handleOf(control) === read) this.#failed(control, error);
			});
			throw error;
		}
		await this.#owner.inTurn(() => {
			if (handleOf(control) === read) this.#keep(control, description);
		});
	}
	/** Read `control` again in the turn under way. */
	async refreshNow(control: HeldControl): Promise<void> {
		this.#owner.checkOpen();
		let description: Description;
		try {
			description = await this.#owner.through(control, describe);
		} catch (error) {
			this.#failed(control, error);
			throw error;
		}
		this.#keep(control, description);
	}
	/** Read `control` again in the turn under way, for a step nobody awaits a
	 * read from. The reach already charged a lost connection to the control's
	 * row, or dropped it as a superseded link's, so only a failure that lands
	 * nowhere else is reported. */
	reread(control: HeldControl): Promise<void> {
		return this.refreshNow(control).catch((error: unknown) => {
			if (!connectionLost(error)) this.#owner.report(error);
		});
	}
	/** A read of reached `control` failed. A lost connection already left it
	 * unreached, and any other failure stays on it until a read replaces it. */
	#failed(control: HeldControl, error: unknown): void {
		if (control.state.kind !== "reached" || connectionLost(error)) return;
		control.readFailure = error;
		this.#owner.changed();
	}
	/** Keep what a read of `control` said of its access. */
	#keep(control: HeldControl, { grant: current, powers }: Description): void {
		this.#owner.checkOpen();
		const state = control.state;
		// A refreshed control was reached, and so described. One undescribed
		// since was let go of meanwhile, and has nothing left to read into.
		if (state.kind === "undescribed") return;
		const known = state.grant;
		if (current != null && known != null && grantIdentity(current) !== grantIdentity(known)) {
			throw new LocalRefusal("access-changed");
		}
		// A control that stops inspecting, as a revoked one does, still knows
		// what its access was called and allowed when it last could.
		if (current == null && known != null) {
			control.committed = { label: known.label, permissions: [...known.configured.permissions] };
		}
		control.state = { ...state, grant: current, powers };
		delete control.readFailure;
		this.#owner.changed();
	}
}
