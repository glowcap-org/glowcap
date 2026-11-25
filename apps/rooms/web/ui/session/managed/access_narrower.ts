// A narrower control of a held one, made for someone else, and its link. Its
// request keeps its sequence until the session answers it, so a press after
// a lost answer asks for that same control again. The session keeps the
// control it made for each sequence, so it answers with that same control,
// and a second press never makes a second one. Every step runs in the access
// owner's turn.
import type {
	RoomsManagedAttenuation,
	RoomsManagedControl,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { roomsErrorIn, SESSION_REQUEST_TIMED_OUT } from "../../../../lib/error_codes.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type { AccessOwner } from "./access_owner.ts";
import type { ManagementPowers } from "./access_powers.ts";
import { type HeldControl, reached } from "./held_control.ts";

/** A narrower control asked for whose answer was lost: what it asks for, its
 * request, and the handle the request goes through. */
interface Pending {
	readonly powers: ManagementPowers;
	request: RoomsManagedAttenuation;
	through: RoomsManagedControl;
}

/** Whether `error` leaves the session's answer unknown, read by its type and
 * code: a lost connection (`connectionLost`: code `session-unreachable` with
 * no status), a missed deadline (code `session-request-timed-out`), or a
 * refusal this page raised itself, which the session never saw. Anything else
 * the call met is the session's answer, coded or not, such as a request the
 * session no longer holds an answer for. */
function answerUnknown(error: unknown): boolean {
	return error instanceof LocalRefusal || connectionLost(error) ||
		roomsErrorIn(error)?.code === SESSION_REQUEST_TIMED_OUT;
}

export class NarrowerControls {
	readonly #owner: AccessOwner;
	readonly #pending = new Map<HeldControl, Pending>();

	constructor(owner: AccessOwner) {
		this.#owner = owner;
	}
	/** The powers of the narrower control `control` asked for and has no answer
	 * to, or null. A press on `control` asks for that one again. */
	pending(control: HeldControl): ManagementPowers | null {
		return this.#pending.get(control)?.powers ?? null;
	}
	/** Make a control of `control` limited to `powers`, and return its link. A
	 * control with an unanswered request asks for that same control again,
	 * and refuses other powers. An unknown answer keeps the request for the
	 * next press. A resent request the session refuses may have made a control
	 * before, so it is refused with the session's answer as its cause. */
	async share(control: HeldControl, powers: ManagementPowers): Promise<string> {
		const pending = this.#pending.get(control);
		if (pending != null && JSON.stringify(pending.powers) !== JSON.stringify(powers)) {
			throw new LocalRefusal("access-narrower-pending");
		}
		const request = pending == null ? await this.#prepare(control, powers) : this.#resume(control, pending);
		let link: string;
		try {
			const narrower: RoomsManagedControl = this.#owner.accept(
				await this.#owner.through(control, () => request.submit()),
			);
			try {
				link = await this.#owner.through(control, () => narrower.publish());
			} finally {
				narrower.free();
			}
		} catch (error) {
			if (answerUnknown(error)) throw error;
			this.release(control);
			if (pending == null) throw error;
			throw new LocalRefusal("access-narrower-unconfirmed", { cause: error });
		}
		this.release(control);
		return link;
	}
	async #prepare(control: HeldControl, powers: ManagementPowers): Promise<RoomsManagedAttenuation> {
		// Nothing moves the control's handle during the turn.
		const through = reached(control);
		const request: RoomsManagedAttenuation = this.#owner.accept(
			await this.#owner.through(control, (handle) => handle.prepareAttenuation(JSON.stringify(powers))),
		);
		this.#pending.set(control, { powers, request, through });
		this.#owner.changed();
		return request;
	}
	/** `pending`'s request through the handle `control` holds now. A move onto
	 * a new link replaced the one it was made through, and the request keeps
	 * its sequence on the new one. */
	#resume(control: HeldControl, pending: Pending): RoomsManagedAttenuation {
		const handle = reached(control);
		if (handle === pending.through) return pending.request;
		const request: RoomsManagedAttenuation = this.#owner.accept(handle.resumeAttenuation(pending.request));
		pending.request.free();
		pending.request = request;
		pending.through = handle;
		return request;
	}
	/** Stop asking for `control`'s unanswered narrower control and free its
	 * request, as the request ends, the person gives it up, or the owner lets
	 * go of the control. */
	release(control: HeldControl): void {
		const pending = this.#pending.get(control);
		if (pending == null) return;
		this.#pending.delete(control);
		pending.request.free();
		this.#owner.changed();
	}
}
