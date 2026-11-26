// What a held control's Manage card offers a person and says to them, built on
// what its row offers. Everything here derives from the access owner's state
// as it stands, whoever moved it last, so the card keeps no answer of its own.
// The card offers only what can work now: an access it cannot reach takes no
// change, and the card says why and offers the Try now that reaches it. Every
// state leaves a way forward or a way out.
import type { RoomsManagedControl } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { invariant } from "../../../../lib/invariant.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import { managedAccessText as text } from "../../../../lib/text/managed_access.ts";
import type { ManagedAccess } from "./access.ts";
import type { GrantView } from "./access_powers.ts";
import { rowOffers, type RowOwner, rowShows } from "./access_row.ts";
import { type EditIntent, type EditState, sentUnconfirmed } from "./edit_state.ts";
import { described, type DescribedControl, handleOf, type HeldControl, OWN_CONTROL } from "./held_control.ts";
import type { PressRefusal } from "./press_answer.ts";
import { type PendingIssue, shareStep } from "./share_state.ts";

/** What the card says beside the setting an edit changes. */
export interface EditAnswer {
	readonly kind: EditIntent["kind"];
	/** Whether the edit still waits, so its way on shows beside it. */
	readonly open: boolean;
	readonly tone: "warning" | "failure" | "success";
	readonly said: string;
}
export interface CardOffers {
	/** The edit the card answers: one under way or in conflict, or one that
	 * ended since the card opened. */
	readonly edit: EditState | null;
	/** What the card says of that edit, or null for nothing. */
	readonly answer: EditAnswer | null;
	/** The revision the card's next change is prepared at: the one this viewer
	 * last read. */
	readonly base: string;
	/** Whether the card takes a new change: its access is reached and no edit
	 * waits on the session or the person. */
	readonly inputs: boolean;
	/** Ask the session again how a sent edit ended. */
	readonly checkAgain: boolean;
	/** Reach or read the access again, which also asks how a sent edit ended. */
	readonly tryNow: boolean;
	/** Let go of an edit never sent, or a conflict. Closing the card asks to
	 * do this first, because the person has a decision to make. A sent edit
	 * waits on the session, not on them. */
	readonly discard: boolean;
	/** Save a conflicting edit again over what the access holds now. */
	readonly reapply: boolean;
	readonly remove: boolean;
	/** Why removing cannot work now, or null when it can. */
	readonly removal: LocalRefusalKey | null;
	/** Whether removing stops checking a change that was sent and never
	 * answered, which the card's confirmation says. */
	readonly removeUnconfirmed: boolean;
	/** List the accesses made from this one, or share it onward. */
	readonly inspect: boolean;
	readonly share: boolean;
	/** Why the access cannot be worked through now, and the step its Try now
	 * makes. */
	readonly failure: string | null;
}

/** The access a card opened on the row held as `id` shows now: the control
 * the owner holds under that id, while it is described. Null once the owner
 * let go of it, which closes the card. A card decides this each time it
 * draws, so it never shows a control from an earlier draw that a release has
 * since emptied. */
export function cardSubject(owner: { readonly held: readonly HeldControl[] }, id: string): DescribedControl | null {
	const control = owner.held.find((held) => held.id === id);
	return control != null && described(control) ? control : null;
}
/** What `control`'s card offers, for a card opened while its edit was
 * `opened`. */
export function cardOffers(
	owner: RowOwner,
	control: DescribedControl,
	opened: EditState | undefined,
): CardOffers {
	const row = rowOffers(owner, control);
	const reached = control.state.kind === "reached";
	const powers = control.state.powers;
	const current = control.edit ?? null;
	const edit = current?.phase === "ended" && current === opened ? null : current;
	const phase = current?.phase ?? null;
	const waits = phase === "prepared" || phase === "uncertain" || phase === "conflict";
	const removal = control.id === OWN_CONTROL ? null : owner.removal(control);
	const checkAgain = reached && phase === "uncertain";
	return {
		edit,
		answer: editAnswer(edit, checkAgain),
		base: powers.revision ?? "",
		inputs: reached && powers.available && !waits,
		checkAgain,
		tryNow: row.tryNow,
		discard: phase === "prepared" || phase === "conflict",
		reapply: reached && powers.available && phase === "conflict",
		remove: control.id !== OWN_CONTROL && removal == null,
		removal,
		removeUnconfirmed: sentUnconfirmed(control),
		inspect: reached && powers.inspect === true,
		share: reached && powers.delegateControl === true,
		failure: row.failure,
	};
}
/** What the card says of `edit` as it stands. */
function editAnswer(edit: EditState | null, checkAgain: boolean): EditAnswer | null {
	if (edit == null) return null;
	const kind = edit.intent.kind;
	if (edit.phase !== "ended") {
		// A change sent through an access this page cannot reach now waits on
		// that access, whose Try now asks how it ended.
		const said = edit.phase === "prepared"
			? text.unsentEdit
			: edit.phase === "uncertain" && !checkAgain
			? text.sentUnreached
			: edit.reason;
		return { kind, open: true, tone: "warning", said };
	}
	const committed = edit.outcome === "committed";
	if (edit.reason !== "") return { kind, open: false, tone: committed ? "warning" : "failure", said: edit.reason };
	// A committed revoke answers through the card's lead and status tag.
	if (!committed || kind === "revoke") return null;
	return { kind, open: false, tone: "success", said: text.committedEdit };
}
/** What reads a press's answer from the access owner. */
interface AnswerReader {
	/** How many times `control`'s view has moved. */
	moves(control: HeldControl): number;
}
/** The answer to `refusal`, the last refused press on `control`: its words
 * while `control`'s view has not moved since its refusal was recorded, or
 * null. A move of what the row or card shows, whoever made it, clears the
 * answer, because what they say now comes from the move. The answer is hidden
 * while `control`'s own failure line says that very error. */
export function pressRefused(refusal: PressRefusal | null, owner: AnswerReader, control: HeldControl): string | null {
	if (refusal?.moves == null || rowShows(control, refusal.error)) return null;
	return owner.moves(control) === refusal.moves ? refusal.said : null;
}
/** The refused presses on the access list, each kept by the control whose
 * row was pressed, so each row's answer stands until its own access moves or
 * its own next press. */
export type RowRefusals = ReadonlyMap<HeldControl, PressRefusal>;
/** `refusals` once a press on `control`'s row began (`refusal` null) or was
 * refused: that row's answer is replaced, every other held row keeps its own,
 * and the answer of a control no longer held goes. */
export function rowPressed(
	refusals: RowRefusals,
	owner: { readonly held: readonly HeldControl[] },
	control: HeldControl,
	refusal: PressRefusal | null,
): RowRefusals {
	const kept = new Map([...refusals].filter(([held]) => held !== control && owner.held.includes(held)));
	if (refusal != null) kept.set(control, refusal);
	return kept;
}
/** What the access list says on `control`'s row, by the rule `pressRefused`
 * keeps. A control no longer held has no row, so nothing. */
export function rowRefused(
	refusals: RowRefusals,
	owner: AnswerReader & { readonly held: readonly HeldControl[] },
	control: HeldControl,
): string | null {
	return owner.held.includes(control) ? pressRefused(refusals.get(control) ?? null, owner, control) : null;
}
/** Whether `offers` leave a way forward or a way out: a change to make, an
 * answer to ask for, an access to reach, or an edit or access to let go of. */
export function wayOn(offers: CardOffers): boolean {
	return offers.inputs || offers.checkAgain || offers.tryNow || offers.reapply || offers.discard || offers.remove;
}
/** When the card's listing of the accesses made from `control` asks for its
 * first page by itself: a key, the handle that reached the access, while the
 * card offers the listing and no page has landed, or null while it does not.
 * The listing is offered only while the access is reached, and each reach
 * holds a new handle, so the listing asks once per reach and never while the
 * access is unreached. A page refused for a lost connection holds the access
 * unreached, and the next reach asks again. Any other refusal or a fault
 * leaves the key where it was, and the listing offers to ask again
 * (`listingAgain`). */
export function listingAsk(control: HeldControl, offers: CardOffers, listed: boolean): RoomsManagedControl | null {
	return offers.inspect && !listed ? handleOf(control) : null;
}
/** How one ask for a page of the listing ended: the page, its refusal, or a
 * fault, which `ManagedAccess.answer` reported. */
export type ListingAnswer =
	| { readonly kind: "page"; readonly rows: GrantView[]; readonly cursor: Uint8Array | null }
	| { readonly kind: "refused"; readonly refusal: PressRefusal }
	| { readonly kind: "fault" };
/** Ask for the page of the accesses made from `control` after `cursor`, as a
 * press on its card. */
export async function askListing(
	management: ManagedAccess,
	control: HeldControl,
	cursor?: Uint8Array,
): Promise<ListingAnswer> {
	const landed: { page?: { rows: GrantView[]; cursor: Uint8Array | null } } = {};
	try {
		const refusal = await management.answer(control, async () => {
			landed.page = await management.inventory(control, cursor);
		});
		if (refusal != null) return { kind: "refused", refusal };
	} catch {
		// tolerant: `answer` reported the fault once, and the listing offers to
		// ask again.
		return { kind: "fault" };
	}
	invariant(landed.page != null, "a listing that was not refused landed its page");
	return { kind: "page", ...landed.page };
}
/** Whether the listing offers a press that asks for its first page again:
 * the card offers it, no page has landed, and the last ask, `last`, ended
 * refused or faulted. */
export function listingAgain(offers: CardOffers, listed: boolean, last: ListingAnswer | null): boolean {
	return offers.inspect && !listed && last != null && last.kind !== "page";
}
/** What the share card's buttons do, through the access owner, for a share
 * from `source`. A share the session refused is over, and that refusal is the
 * press's answer. */
export function shareGestures(management: ManagedAccess, source: DescribedControl) {
	return {
		/** Prepare a share of `terms` when none is under way, then take the
		 * share as far as it goes now. */
		goOn: async (...terms: ShareRequest): Promise<void> => {
			if (management.issue == null) await management.prepareIssue(source, ...terms);
			const outcome = await management.goOnIssue();
			if (outcome.phase === "refused") throw outcome.failure;
		},
		/** Let go of a share in conflict, and read its source again. A source
		 * the page cannot reach is read once its row reaches it. */
		review: async (): Promise<void> => {
			await management.discardIssue();
			if (source.state.kind === "reached") await management.refresh(source);
		},
		/** Let go of the share as its card closes, when closing lets it go
		 * (`closeFinishes`). A refusal is the press's answer, and the card stays
		 * open to say it. */
		finish: (): Promise<void> => management.discardIssue(),
	};
}
/** Whether closing the share card waits for `finish` to let go of `issue`: a
 * share with nothing left to do, or one that sent nothing, while no press of
 * the card is under way. A press under way, and a share waiting on its link or
 * an answer, stay with management, so the card closes at once. */
export function closeFinishes(issue: PendingIssue | null, busy: boolean): boolean {
	const step = issue == null ? null : shareStep(issue).kind;
	return !busy && (step === "done" || step === "send");
}
/** What a share asks for besides its source, as `ManagedAccess.prepareIssue`
 * takes it. */
type ShareRequest = Parameters<ManagedAccess["prepareIssue"]> extends [unknown, ...infer Terms] ? Terms : never;
/** The Hold card's press, answered as `ManagedAccess.answerAlone` says: null
 * once the row is saved, the row's failure when it holds one, or the
 * refusal's words. */
export function holdPress(management: ManagedAccess, id: string, uri: string): Promise<string | null> {
	return management.answerAlone(() => holdLink(management, id, uri));
}
/** What the Hold card's press does: hold the control `uri` links to, as `id`
 * unless a held row already has it, and save it. A held row its link no longer
 * reaches is reached first, and one still unreached is not saved: its failure
 * is returned, in its row's words. Returns null once the row is saved. */
export async function holdLink(management: ManagedAccess, id: string, uri: string): Promise<string | null> {
	const held = await management.attach(id, uri);
	if (held.state.kind !== "reached") return rowOffers(management, held).failure;
	await management.save(held);
	return null;
}
/** What each of the card's buttons does, through the access owner. Each
 * outcome lands in the owner's state, where the card reads it. */
export function cardGestures(management: ManagedAccess, control: HeldControl) {
	return {
		/** Send `intent` at `base`, the revision the card shows. */
		press: async (intent: EditIntent, base: string): Promise<EditState> => {
			await management.prepare(control, intent, base);
			return await management.submit(control);
		},
		checkAgain: (): Promise<EditState> => management.submit(control),
		tryNow: (): Promise<void> => management.reachAgain(control),
		discard: (): Promise<void> => management.discard(control),
		reapply: async (): Promise<EditState> => {
			await management.reapply(control);
			return await management.submit(control);
		},
		remove: (): Promise<void> => management.forget(control),
		/** What closing a card that `offers` describe lets go of. */
		close: (offers: CardOffers): Promise<void> => offers.discard ? management.discard(control) : Promise.resolve(),
	};
}
