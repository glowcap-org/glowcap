// Where a share stands, what each standing holds, and what its card offers
// next. Each standing holds exactly the handles it owns, so ending one frees
// those and nothing else. The flow that moves a share between them lives in
// `access_share.ts`.
import type {
	RoomsManagedIssuance,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import type { ManagementPowers } from "./access_powers.ts";
import { canTryNow, type DescribedControl, type HeldControl, saved } from "./held_control.ts";

/** What a share asks the session for, as it was prepared. Its card shows these
 * values, and its request carries them. */
export interface ShareTerms {
	readonly permissions: readonly RoomsPermission[];
	readonly label: string;
	readonly paused: boolean;
	readonly depth: number;
	readonly powers: ManagementPowers;
}
/** What every standing of a share knows. `reason` says why it stands where
 * it does, and is empty when nothing went wrong. */
interface ShareCore {
	readonly id: string;
	readonly source: DescribedControl;
	readonly terms: ShareTerms;
	readonly reason: string;
}
/** What every standing of `issue` keeps. */
export function shareCore(issue: PendingIssue): ShareCore {
	return { id: issue.id, source: issue.source, terms: issue.terms, reason: issue.reason };
}
/** What became of the new access a share made. The access owner holds it
 * under the share's id, reached or not, until the person removes it once it
 * is saved. */
export type MadeAccess = { readonly kind: "held"; readonly control: HeldControl } | { readonly kind: "removed" };
/** A share from its preparation until its card is closed.
 *
 * - `prepared` and `uncertain` hold the request, which goes out again under
 *   its sequence, so the session issues at most one access for it.
 * - `committed` holds the request, so asking again answers with the same
 *   access, the access workspace while this page holds it, and the link once
 *   it is shown.
 * - `conflict` and `lost` hold nothing, and say why. */
export type PendingIssue =
	| ShareCore & { readonly phase: "prepared"; readonly request: RoomsManagedIssuance }
	| ShareCore & { readonly phase: "uncertain"; readonly request: RoomsManagedIssuance }
	| ShareCore & {
		readonly phase: "committed";
		readonly request: RoomsManagedIssuance;
		readonly access: RoomsManagedWorkspace | null;
		readonly made: MadeAccess;
		readonly link: string | null;
	}
	| ShareCore & { readonly phase: "conflict" }
	| ShareCore & { readonly phase: "lost" };
export type CommittedShare = Extract<PendingIssue, { phase: "committed" }>;
/** What submitting a share answers: where it stands now, or the session's
 * refusal, after which no share is under way. */
export type ShareOutcome = PendingIssue | {
	readonly phase: "refused";
	readonly reason: string;
	/** The refusal, for the press that sent the share to answer with. */
	readonly failure: Error;
};

/** What a share's card offers next. Sending, checking again, asking for the
 * made access again, and getting its link go through the source's connection.
 * Saving goes through the new access's own. */
type ShareStep =
	| { readonly kind: "send" | "recover" | "ask" | "publish" | "review" | "done" }
	| { readonly kind: "save"; readonly control: HeldControl };

export function shareStep(issue: PendingIssue): ShareStep {
	switch (issue.phase) {
		case "prepared":
			return { kind: "send" };
		case "uncertain":
			return { kind: "recover" };
		case "conflict":
			return { kind: "review" };
		case "lost":
			return { kind: "done" };
		case "committed":
			return committedStep(issue);
	}
}
/** A made access not yet saved has no row to reach it from, so one this page
 * cannot reach, or a share whose access workspace a replaced link dropped
 * before its link was shown, is asked for again through the source. */
function committedStep(issue: CommittedShare): ShareStep {
	const control = issue.made.kind === "held" ? issue.made.control : null;
	const unsaved = control != null && !saved(control);
	if (unsaved && control.state.kind !== "reached") return { kind: "ask" };
	if (issue.link == null && issue.access == null) return { kind: "ask" };
	if (unsaved) return { kind: "save", control };
	return { kind: issue.link == null ? "publish" : "done" };
}
/** Whether the share's next step goes through its source. */
function needsSource(step: ShareStep): boolean {
	return step.kind === "send" || step.kind === "recover" || step.kind === "ask" || step.kind === "publish";
}
/** Why the share cannot be let go of at `step`, or null when it can: it has
 * nothing left to do, its review starts over, or it sent nothing. A share is
 * `prepared` until a send of it may have left the page, so letting go of one
 * frees a request the session never saw. */
export function unfinished(step: ShareStep): LocalRefusalKey | null {
	switch (step.kind) {
		case "recover":
			return "access-share-unconfirmed";
		case "ask":
			return "access-share-unheld";
		case "save":
			return "access-share-unsaved";
		case "publish":
			return "access-share-unpublished";
		case "send":
		case "review":
		case "done":
			return null;
	}
}
/** Whether the share's next step waits on a source this page cannot reach. */
export function waitsOnSource(issue: PendingIssue): boolean {
	return needsSource(shareStep(issue)) && issue.source.state.kind !== "reached";
}
/** What the main button of a share's card does, and whether it can now. A
 * share waiting on its source cannot go on until the source's row reaches it
 * again, and its card says so. With no share, the card creates one from
 * `source` once the page reaches it. */
interface CardAction {
	readonly kind: "create" | "recover" | "goOn" | "review" | "done";
	readonly ready: boolean;
}
export function cardAction(issue: PendingIssue | null, source: HeldControl): CardAction {
	if (issue == null) return { kind: "create", ready: source.state.kind === "reached" };
	const ready = !waitsOnSource(issue);
	const step = shareStep(issue);
	switch (step.kind) {
		case "send":
			return { kind: "create", ready };
		case "recover":
			return { kind: "recover", ready };
		case "review":
		case "done":
			return { kind: step.kind, ready };
		case "ask":
		case "save":
		case "publish":
			return { kind: "goOn", ready };
	}
}
/** The new access the share made, while the access owner holds it. */
export function madeControl(issue: PendingIssue | null): HeldControl | null {
	return issue?.phase === "committed" && issue.made.kind === "held" ? issue.made.control : null;
}

/** Why a share whose source was reached again, or could not be, ends, or null
 * when it goes on or waits. `reached` says whether the source was reached
 * again. A share ends only when its next step goes through its source and the
 * source's answer will not change. Revoking an access revokes every access
 * issued under it, so a share from a revoked source left nothing behind. No
 * control here revokes another control's access, so an access it may have
 * made stays with whoever runs the session. */
export function endedShare(issue: PendingIssue, reached: boolean): LocalRefusalKey | null {
	if (!needsSource(shareStep(issue))) return null;
	const goesOn = reached || canTryNow(issue.source);
	if (issue.phase === "prepared") return goesOn ? null : "access-share-unsent";
	if (!issue.source.state.powers.available) return "access-share-revoked";
	if (goesOn) return null;
	return issue.phase === "committed" ? lostAccess(issue) : "access-share-lost-unknown";
}
/** What became of the access a share made, once nothing can ask for it again. */
export function lostAccess(issue: CommittedShare): LocalRefusalKey {
	if (issue.made.kind === "removed") return "access-share-lost-removed";
	return saved(issue.made.control) ? "access-share-unlinked" : "access-share-lost";
}
/** Free every handle `issue` holds. The made access is the owner's. */
export function freeHeld(issue: PendingIssue): void {
	if (issue.phase === "conflict" || issue.phase === "lost") return;
	issue.request.free();
	if (issue.phase === "committed") issue.access?.free();
}
