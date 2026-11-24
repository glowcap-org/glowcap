// The answer to a press on a held access's row or card. Each held control
// counts the moves of its view (`pressView`): its count goes up each time the
// owner's held access changes and the control's view differs from the last one
// seen. A refused press is answered in its words while the pressed control's
// count is the one its refusal recorded, so a move anyone makes of what the row
// or card shows clears it, and a view that moves back does not bring it back.
// The record is every held control's count, kept by the refusal's error, and a
// refusal reaches it one of four ways:
// - An event in turn rejects with it. The owner records the counts in that
//   turn, before the next event starts, so a press that waited behind a
//   relink is answered against what the relink left.
// - A call outside a turn fails with it and applies that failure in a turn of
//   its own (`AccessOwner.refused`). That turn records the counts first, so
//   the failure's own move clears the answer the move already says.
// - Nothing recorded it, as with the owner's open check. `answer` records it
//   in a turn queued at once.
// - A call lost the connection of a handle its control no longer holds,
//   because a reach replaced it or a loss retired it first (`outlived`). The
//   control has moved past that connection and its row says how it stands, so
//   the refusal is recorded with no count for that control, and a press
//   through it answers nothing.
// A refusal is a failure of a type that classifies itself: the page's own
// `LocalRefusal`, a `ReportedFailure` or `RoomsError`, or a failure carried
// from Rust. Anything else is a fault, which is reported and rethrown.
//
// The Hold card's press answers no held control, because the access it holds
// is not held until it succeeds. `answerAlone` answers it in its words by the
// same test, and its card clears the answer when the link it answered changes.
import { RoomsError, structuredFailure } from "../../../../lib/error_codes.ts";
import { LocalRefusal, refusalText } from "../../../../lib/text/failure.ts";
import type { HeldControl } from "./held_control.ts";
import { ReportedFailure } from "./reported_failure.ts";

/** A refused press: its words, the error it met, and the pressed control's
 * count of moves in the refusal's record, or null for a control no longer
 * held then, whose answer never shows. */
export interface PressRefusal {
	readonly said: string;
	readonly error: unknown;
	readonly moves: number | null;
}

/** What answering needs from the access owner. */
interface AnswerOwner {
	/** The controls held now. */
	held(): readonly HeldControl[];
	/** What `control`'s row and card show, as `pressView` writes it. */
	view(control: HeldControl): string;
	inTurn<T>(event: () => T | Promise<T>): Promise<T>;
	/** Says a fault a press met. */
	report(error: unknown): void;
}

/** Whether `error` is a refusal, by its type. */
function refusal(error: unknown): error is object {
	return error instanceof LocalRefusal || error instanceof ReportedFailure || error instanceof RoomsError ||
		structuredFailure(error) != null;
}

export class PressAnswers {
	readonly #owner: AnswerOwner;
	/** Each refusal's record. Every refusal is an error built where it is
	 * thrown, never one kept and thrown again, so a record is one refusal's,
	 * and it goes when nothing holds that error any more. */
	readonly #records = new WeakMap<object, ReadonlyMap<HeldControl, number>>();
	/** Each held control's last view seen, and its count of moves. */
	readonly #seen = new WeakMap<HeldControl, { readonly view: string; readonly moves: number }>();

	constructor(owner: AnswerOwner) {
		this.#owner = owner;
	}
	/** The owner's held access changed, as every move of it says: count a move
	 * for each control whose view differs from the last one seen. */
	changed(): void {
		for (const control of this.#owner.held()) {
			const view = this.#owner.view(control);
			const last = this.#seen.get(control);
			if (last?.view !== view) this.#seen.set(control, { view, moves: (last?.moves ?? 0) + 1 });
		}
	}
	/** How many times `control`'s view has moved. */
	moves(control: HeldControl): number {
		return this.#seen.get(control)?.moves ?? 0;
	}
	/** Record each held control's count for `error`, in the owner's turn,
	 * unless an earlier turn did. */
	saw(error: unknown): void {
		if (!refusal(error) || this.#records.has(error)) return;
		this.#records.set(error, new Map(this.#owner.held().map((control) => [control, this.moves(control)])));
	}
	/** Record `error`, a loss through a connection `control` no longer holds,
	 * in the owner's turn, with no count for `control`. */
	outlived(error: unknown, control: HeldControl): void {
		if (!refusal(error) || this.#records.has(error)) return;
		const held = this.#owner.held().filter((other) => other !== control);
		this.#records.set(error, new Map(held.map((other) => [other, this.moves(other)])));
	}
	/** Make `press` on `control`, and answer it: null once it succeeds, or how
	 * it was refused. */
	async answer(control: HeldControl, press: () => Promise<unknown>): Promise<PressRefusal | null> {
		try {
			await press();
			return null;
		} catch (error) {
			this.#refusal(error);
			const record = this.#records.get(error) ?? await this.#owner.inTurn(() => {
				this.saw(error);
				return this.#records.get(error);
			});
			return { said: refusalText(error), error, moves: record?.get(control) ?? null };
		}
	}
	/** Make `press`, which answers no held control, and answer it: what it
	 * says itself once it succeeds, or its refusal's words. */
	async answerAlone(press: () => Promise<string | null>): Promise<string | null> {
		try {
			return await press();
		} catch (error) {
			this.#refusal(error);
			return refusalText(error);
		}
	}
	/** Report and rethrow `error` unless it is a refusal. */
	#refusal(error: unknown): asserts error is object {
		if (refusal(error)) return;
		this.#owner.report(error);
		throw error;
	}
}
