// An edit through a held control lives from its preparation until it ends:
// the session commits, refuses, or finds it conflicts, it is lost with its
// request, or preparing it fails. The edit's owner ends it in the turn that
// hears the answer, whoever sent it: the person's press, or a new link sending
// it again. One control holds at most one edit under way, and a control reached
// again over a new link carries it, as `acquisition.ts` says of a kept request.
import type { RoomsManagedControl, RoomsManagedEdit } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { LocalRefusal, refusalText } from "../../../../lib/text/failure.ts";
import { settleSubmit } from "./acquisition.ts";
import type { AccessOwner } from "./access_owner.ts";
import { type EditIntent, editOpen, type EditState, liveEdit } from "./edit_state.ts";
import { described, type HeldControl, reached, unreached } from "./held_control.ts";

const EDIT_KEYS = { conflict: "access-edit-conflict", uncertain: "access-edit-unknown" } satisfies Parameters<
	typeof settleSubmit
>[1];

/** Prepare `intent` through `handle` at revision `base`. */
function prepareThrough(handle: RoomsManagedControl, intent: EditIntent, base: string): Promise<RoomsManagedEdit> {
	switch (intent.kind) {
		case "policy":
			return handle.preparePolicy(base, JSON.stringify(intent.permissions));
		case "label":
			return handle.prepareLabel(base, intent.label);
		case "pause":
			return handle.preparePause(base);
		case "resume":
			return handle.prepareResume(base);
		case "revoke":
			return handle.prepareRevoke(base);
	}
}

export class AccessEdits {
	readonly #owner: AccessOwner;
	readonly #preparing = new Set<HeldControl>();
	readonly #submitting = new Map<HeldControl, Promise<EditState>>();

	constructor(owner: AccessOwner) {
		this.#owner = owner;
	}
	/** Whether an edit through `control` is being submitted. */
	submitting(control: HeldControl): boolean {
		return this.#submitting.has(control);
	}
	/** Prepare `intent` through `control` from outside a turn. It is kept in a
	 * turn of its own, in place of how an earlier edit ended. One that fails to
	 * prepare through a reached control ends `unsent` and says why, and one whose
	 * control is unreached leaves the control's failure to say it. */
	prepare(control: HeldControl, intent: EditIntent, base: string): Promise<void> {
		return this.#owner.track(this.#prepare(control, intent, base));
	}
	async #prepare(control: HeldControl, intent: EditIntent, base: string): Promise<void> {
		this.#owner.checkOpen();
		if (editOpen(control) || this.#preparing.has(control)) throw new LocalRefusal("access-edit-unfinished");
		this.#preparing.add(control);
		try {
			await this.#owner.madeOutside(
				control,
				(handle) => prepareThrough(handle, intent, base),
				(request) =>
					this.#become(control, {
						phase: "prepared",
						intent,
						base,
						request: this.#owner.accept(request),
						reason: "",
					}),
			);
		} catch (error) {
			this.#owner.refused(error, () => {
				if (control.state.kind !== "reached" || editOpen(control)) return;
				const reason = refusalText(error);
				this.#become(control, { phase: "ended", intent, outcome: "unsent", reason });
			});
			throw error;
		} finally {
			this.#preparing.delete(control);
		}
	}
	submit(control: HeldControl): Promise<EditState> {
		this.#owner.checkOpen();
		return this.#owner.inTurn(() => this.submitOnce(control));
	}
	/** Submit `control`'s edit in the turn under way, or join the submission
	 * already under way in it. */
	submitOnce(control: HeldControl): Promise<EditState> {
		this.#owner.checkOpen();
		const existing = this.#submitting.get(control);
		if (existing != null) return existing;
		// A submission under way keeps its access from being removed, so its end
		// is a change of what the access's row and card offer.
		const task = this.#owner.track(this.#submit(control)).finally(() => {
			this.#submitting.delete(control);
			this.#owner.changed();
		});
		this.#submitting.set(control, task);
		return task;
	}
	async #submit(control: HeldControl): Promise<EditState> {
		const edit = control.edit;
		if (edit?.phase === "conflict" || edit?.phase === "ended") return edit;
		// A control the link could not reach sends nothing until it is reached.
		// One sent stays sent, and its access's Try now asks how it ended. One
		// never sent ends here.
		const unreachable = unreached(control);
		if (unreachable != null) {
			if (edit?.phase === "uncertain") return edit;
			this.end(control);
			throw unreachable;
		}
		// An edit that ended unsent with a control the new link could not reach,
		// or was never prepared, has nothing to send.
		if (edit == null) throw new LocalRefusal("not-sent");
		const { intent, base, request } = edit;
		const { outcome, reason } = await settleSubmit(
			() => this.#owner.submitThrough(control, () => request.submitOutcome()),
			EDIT_KEYS,
		);
		if (outcome != null) this.#owner.checkOpen();
		if (outcome == null || outcome.status === "uncertain") {
			return this.#become(control, { phase: "uncertain", intent, base, request, reason });
		}
		// The session answered, so the request has no replay value left.
		request.free();
		if (outcome.status === "committed") this.#committed(control, intent);
		const next = this.#become(
			control,
			outcome.status === "conflict"
				? { phase: "conflict", intent, reason }
				: { phase: "ended", intent, outcome: outcome.status, reason },
		);
		// The access moved on, through this change or another, so it is read
		// again, and the card's next change starts from what it holds now.
		if (outcome.status !== "refused") {
			await this.#owner.refreshNow(control).catch(() => {
				// tolerant: a failed read stays on the control, as its loss or its
				// readFailure, and its row says it.
			});
		}
		return next;
	}
	/** The session committed exactly `intent`, so it is known now even before
	 * (or without) a fresh inspection of the target. */
	#committed(control: HeldControl, intent: EditIntent): void {
		if (intent.kind !== "label" && intent.kind !== "policy") return;
		control.committed = intent.kind === "label"
			? { ...control.committed, label: intent.label }
			: { ...control.committed, permissions: intent.permissions };
		const state = control.state;
		if (state.kind === "undescribed" || state.grant == null) return;
		const grant = intent.kind === "label"
			? { ...state.grant, label: intent.label }
			: { ...state.grant, configured: { ...state.grant.configured, permissions: intent.permissions } };
		control.state = { ...state, grant };
	}
	#become(control: HeldControl, next: EditState): EditState {
		control.edit = next;
		this.#owner.changed();
		return next;
	}
	/** Let go of `control`'s edit in the turn under way: one never sent, a
	 * conflict the person gives up, or how one ended. One sent and unanswered
	 * may still land, so it stays until the session answers. */
	discard(control: HeldControl): void {
		this.#owner.checkOpen();
		if (this.#submitting.has(control)) throw new LocalRefusal("access-edit-submitting");
		const edit = control.edit;
		if (edit == null) return;
		if (edit.phase === "uncertain") throw new LocalRefusal("access-edit-unconfirmed");
		if (edit.phase === "prepared") edit.request.free();
		delete control.edit;
		this.#owner.changed();
	}
	/** Save a conflicting edit again over what its access holds now: read the
	 * access in a turn, then prepare the same intent at its new revision. */
	async reapply(control: HeldControl): Promise<void> {
		const next = await this.#owner.inTurn(async () => {
			this.#owner.checkOpen();
			const edit = control.edit;
			// A conflict the person discarded or removed meanwhile has nothing to save.
			if (edit?.phase !== "conflict") return null;
			await this.#owner.refreshNow(control);
			const revision = described(control) ? control.state.powers.revision : null;
			if (revision == null) throw new LocalRefusal("access-unavailable");
			delete control.edit;
			this.#owner.changed();
			return { intent: edit.intent, revision };
		});
		if (next == null) throw new LocalRefusal("not-sent");
		await this.prepare(control, next.intent, next.revision);
	}
	/** Resume an edit under way through `control` on its restored handle, and
	 * say whether it was sent. The edit keeps its sequence, so one never sent
	 * goes out once when its gesture sends it, and sending one sent again looks
	 * it up: the session applies an edit at most once. An edit the new handle
	 * cannot take ends here: one never sent sent nothing, and one sent says its
	 * outcome cannot be checked. */
	resume(control: HeldControl): boolean {
		const edit = liveEdit(control);
		if (edit == null) return false;
		let request: RoomsManagedEdit;
		try {
			request = reached(control).resumeEdit(edit.request);
		} catch (error) {
			edit.request.free();
			// tolerant: a sent edit's row says its outcome cannot be checked. A
			// prepared one was never sent, so it ends with nothing sent and its
			// gesture hears `not-sent` when it sends. The handle's refusal is
			// dropped with it.
			if (edit.phase === "prepared") delete control.edit;
			else {
				const reason = refusalText(new LocalRefusal("access-edit-lost", { cause: error }));
				control.edit = { phase: "ended", intent: edit.intent, outcome: "unknown", reason };
			}
			this.#owner.changed();
			return false;
		}
		edit.request.free();
		control.edit = { ...edit, request };
		return edit.phase === "uncertain";
	}
	/** End an edit prepared through `control` and never sent. Nothing it named
	 * was sent. */
	end(control: HeldControl): void {
		const edit = control.edit;
		if (edit?.phase !== "prepared") return;
		edit.request.free();
		delete control.edit;
		this.#owner.changed();
	}
	/** Free the request `control`'s edit holds, as its control is let go of. */
	release(control: HeldControl): void {
		liveEdit(control)?.request.free();
		delete control.edit;
	}
}
