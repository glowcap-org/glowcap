// What a held control's row offers a person, and what it tells them. A row
// offers only what can work now: a control that cannot be reached or removed
// shows no button for it, and a row whose control a share comes from always
// leads back to that share, as does the row of the access a share made. Its
// words name only what it offers.
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import { failureView, renderFailure } from "../../../../lib/text/failure.ts";
import { managedAccessText as text } from "../../../../lib/text/managed_access.ts";
import {
	canTryNow,
	described,
	type DescribedControl,
	type HeldControl,
	knownStatus,
	OWN_CONTROL,
	saved,
	standingFailure,
	unreachedView,
} from "./held_control.ts";
import { sentUnconfirmed } from "./edit_state.ts";
import { cardAction, madeControl, type PendingIssue, shareStep } from "./share_state.ts";

/** What a row reads of the access owner. */
export interface RowOwner {
	readonly issue: PendingIssue | null;
	/** Why removing `control` cannot work now, or null when it can. */
	removal(control: HeldControl): LocalRefusalKey | null;
}
/** The buttons a row shows. Remove is the row's own for an access with
 * nothing left to manage, and its card's otherwise. */
interface RowOffers {
	readonly tryNow: boolean;
	readonly save: boolean;
	readonly remove: boolean;
	readonly manage: DescribedControl | null;
	/** A share from this row's control: a new one, or the one under way. A
	 * page runs one share at a time, so no other row offers a new one meanwhile. */
	readonly share: { readonly kind: "new" | "resume"; readonly control: DescribedControl } | null;
	/** Why the row's control cannot be worked through now, and the step its
	 * offers make. */
	readonly failure: string | null;
}

export function rowOffers(owner: RowOwner, control: HeldControl): RowOffers {
	const reached = control.state.kind === "reached";
	const known = described(control) ? control : null;
	// A control never reached knows nothing it could manage, and a revoked one
	// has nothing left to. One not saved and not reached has no card that
	// works, unless a change sent through it waits there for its answer. Each
	// offers removal on its row in place of its card.
	const ended = known == null || (knownStatus(control) === "revoked" && control.id !== OWN_CONTROL);
	const manage = ended || (!reached && !saved(control) && !sentUnconfirmed(control)) ? null : known;
	const issue = owner.issue;
	let share: RowOffers["share"] = null;
	if (issue != null) {
		if (issue.source === control || madeControl(issue) === control) {
			share = { kind: "resume", control: issue.source };
		}
	} else if (reached && known?.state.powers.issueCeiling != null) {
		share = { kind: "new", control: known };
	}
	const tryNow = canTryNow(control);
	const remove = owner.removal(control) == null;
	return {
		tryNow,
		save: reached && !saved(control),
		remove,
		manage,
		share,
		failure: rowFailure(control, tryNow, remove, manage),
	};
}
/** Whether `error`, which a press on `control`'s row met, is the failure the
 * row's own line shows now. A Try now whose reach or read fails leaves that
 * failure on its control, and the row's line says it with the step after it,
 * so the press shows only a failure the row does not. */
export function rowShows(control: HeldControl, error: unknown): boolean {
	return error != null && standingFailure(control) === error;
}
/** What a person sees of `control` on its row and cards, as one string: the
 * control as JSON, its standing failure as the row reads it, what its row
 * offers, and the share under way from it as its card shows it. A press's
 * answer stands until this moves (`PressAnswers`). Every field of a held
 * control is in it unless `hidden` leaves it out. A new field is checked for
 * being a handle or a secret, which `hidden` lists, and everything else is in
 * by default. */
export function pressView(owner: RowOwner, control: HeldControl): string {
	const offers = rowOffers(owner, control);
	const failure = standingFailure(control);
	const issue = owner.issue;
	const view = {
		control,
		failure: failure == null ? null : failureView(failure),
		offers: { ...offers, manage: offers.manage != null, share: offers.share?.kind ?? null },
		removal: owner.removal(control),
		share: issue?.source === control ? shareView(issue) : null,
	};
	return JSON.stringify(view, function (this: unknown, key: string, value: unknown) {
		return hidden(control, this, key) ? undefined : value;
	});
}
/** What a share's card shows of `issue`, named field by field. A share holds
 * handles and the secret link of the access it made, so a field added to it
 * stays out of the view until it is named here. Of the link, the view holds
 * only whether the card shows one. */
function shareView(issue: PendingIssue) {
	const action = cardAction(issue, issue.source);
	return {
		phase: issue.phase,
		reason: issue.reason,
		terms: issue.terms,
		step: shareStep(issue).kind,
		action: action.kind,
		ready: action.ready,
		linked: issue.phase === "committed" && issue.link != null,
	};
}
/** Whether `key` of `holder`, a part of `control`, is left out of its view:
 * a handle or a request made through one, the edit's base revision, the
 * failures the view says as a person reads them, and the link the control was
 * attached from, which is a secret. */
function hidden(control: HeldControl, holder: unknown, key: string): boolean {
	if (holder === control) return key === "saving" || key === "readFailure";
	if (holder === control.state) return key === "handle" || key === "failure";
	if (holder === control.edit) return key === "request" || key === "base";
	if (holder === control.storage) return key === "address";
	return false;
}
/** The failure a row shows: why its control is unreached, or why its last
 * read failed. Where Try now cannot help, it names Remove where the row
 * offers it. */
function rowFailure(
	control: HeldControl,
	tryNow: boolean,
	remove: boolean,
	manage: DescribedControl | null,
): string | null {
	const failure = standingFailure(control);
	if (failure == null) return null;
	const view = unreachedView(failure);
	const removal = tryNow || !remove ? null : manage == null ? text.removeHere : text.removeInManage;
	const action = [view.action, removal].filter((step) => step != null).join(" ");
	return renderFailure({ ...view, action: action === "" ? null : action });
}
