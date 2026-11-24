// A share issues a new access from a held control, one share per page at a
// time. The share lives from its preparation until the card that started it is
// closed, and it survives a replaced link to the session by asking for the
// same access again. `share_state.ts` says what each standing holds and what
// its card offers. Every step of a share runs in the access owner's turn.
import { invariant } from "../../../../lib/invariant.ts";
import type {
	RoomsManagedControl,
	RoomsManagedIssuance,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { LocalRefusal, refusalText } from "../../../../lib/text/failure.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import { settleSubmit, type SubmissionOutcome } from "./acquisition.ts";
import type { AccessOwner } from "./access_owner.ts";
import { keptPowers } from "./access_powers.ts";
import { type DescribedControl, type HeldControl, reached, saved } from "./held_control.ts";
import {
	type CommittedShare,
	endedShare,
	freeHeld,
	lostAccess,
	type MadeAccess,
	madeControl,
	type PendingIssue,
	shareCore,
	type ShareOutcome,
	shareStep,
	type ShareTerms,
	unfinished,
} from "./share_state.ts";

/** How holding a share's new access ended. `held` and `unreached` leave the
 * owner holding it under the share's id, `unreached` with a failure asking
 * again can clear. `final` leaves nothing held there, for a failure that will
 * not change. */
export type HoldAnswer =
	| { readonly kind: "held"; readonly control: HeldControl }
	| { readonly kind: "unreached"; readonly control: HeldControl; readonly failure: unknown }
	| { readonly kind: "final"; readonly failure: unknown };
/** What a sent share returns: the new access's workspace and its control once
 * the session committed it. */
type Returned = { access?: RoomsManagedWorkspace; control?: RoomsManagedControl };

/** What a share needs from the access owner that holds its controls. */
interface ShareOwner extends AccessOwner {
	/** Hold the new access a share made under `id`, taking `handle`. Called
	 * while the owner is open, with no await since that was checked, on return
	 * the owner holds it there or has freed it. A control already held there
	 * takes `handle` in place of the one it lost. */
	hold(id: string, handle: RoomsManagedControl): Promise<HoldAnswer>;
	/** Holds `control` unreached for `failure`, and frees its handle once no
	 * call reads it. An edit under way through it stays to move with it. */
	lose(control: HeldControl, failure: unknown): void;
	/** Reads `control` again. A failure is never thrown: a lost connection is
	 * the control's row's to show, and any other failure is reported. */
	reread(control: HeldControl): Promise<void>;
	/** Stops holding `control` and frees it. */
	release(control: HeldControl): void;
}

export class AccessShare {
	readonly #owner: ShareOwner;
	#issue: PendingIssue | null = null;

	constructor(owner: ShareOwner) {
		this.#owner = owner;
	}
	get issue(): PendingIssue | null {
		return this.#issue;
	}
	/** The new access the share under way made, while the owner holds it. */
	get made(): HeldControl | null {
		return madeControl(this.#issue);
	}
	async prepare(
		source: DescribedControl,
		permissions: RoomsPermission[],
		label: string,
		paused: boolean,
		depth: number,
		ceilings: { editCeiling: RoomsPermission[] | null; issueCeiling: RoomsPermission[] | null },
	): Promise<void> {
		this.#owner.checkOpen();
		if (this.#issue != null) throw new LocalRefusal("access-share-unfinished");
		const terms: ShareTerms = {
			permissions: [...permissions],
			label,
			paused,
			depth,
			powers: keptPowers(source.state.powers, ceilings),
		};
		const base = source.state.powers.revision;
		if (base == null) throw new LocalRefusal("access-unavailable");
		const { powers } = terms;
		const request: RoomsManagedIssuance = await this.#owner.madeThrough(
			source,
			(handle) =>
				handle.prepareIssue(
					base,
					// The smallest immutable ceiling covering initial use and the
					// explicitly selected future editing and issuance authority.
					JSON.stringify({
						configured: terms.permissions,
						ceiling: [
							...new Set([
								...terms.permissions,
								...powers.editCeiling ?? [],
								...powers.issueCeiling ?? [],
							]),
						],
					}),
					terms.label,
					terms.paused,
					terms.depth,
					JSON.stringify(powers),
				),
			(made) => this.#owner.accept(made),
		);
		this.#become({ id: crypto.randomUUID(), source, terms, reason: "", phase: "prepared", request });
	}
	/** Send the share, or ask the session again for the access it made, as the
	 * share's step says. Any other step has nothing to send. */
	async submit(): Promise<ShareOutcome> {
		this.#owner.checkOpen();
		const issue = this.#issue;
		invariant(issue != null, "there is no retained issuance");
		const step = shareStep(issue);
		if (issue.phase === "committed") return step.kind === "ask" ? await this.#ask(issue) : issue;
		if (issue.phase === "prepared" || issue.phase === "uncertain") return await this.#send(issue);
		return issue;
	}
	async #send(sent: Extract<PendingIssue, { phase: "prepared" | "uncertain" }>): Promise<ShareOutcome> {
		const { outcome: output, failure, reason } = await this.#submit(sent);
		if (output == null) return this.#become({ ...this.#unmoved(sent), phase: "uncertain", reason });
		this.#checkOpen(output);
		const issue = this.#unmoved(sent);
		switch (output.status) {
			case "committed":
				return await this.#received(output);
			case "uncertain":
				return this.#become({ ...issue, phase: "uncertain", reason });
			// A conflict or refusal admitted nothing, so the request has no replay
			// value, and the next share prepares afresh.
			case "conflict":
				issue.request.free();
				return this.#become({ ...shareCore(issue), phase: "conflict", reason });
			case "refused":
				invariant(failure != null, "a refused share says why");
				issue.request.free();
				this.#issue = null;
				this.#owner.changed();
				return { phase: "refused", reason, failure };
		}
	}
	/** Ask again for the access the session issued, through the source as it now
	 * stands. The request keeps its sequence, so the session answers with the
	 * same access, and only this page's hold on it waits on a failure. */
	async #ask(issue: CommittedShare): Promise<ShareOutcome> {
		const asked = this.#resume(issue);
		const { outcome: output, failure, reason } = await this.#submit(asked, "access-share-unheld");
		// A loss the call saw dropped what the source's connection carried, and
		// nothing else moved the share.
		if (output == null) return this.#become({ ...this.#committed(), reason });
		this.#checkOpen(output);
		if (output.status === "committed") return await this.#received(output);
		const answered = this.#committed();
		if (output.status === "uncertain") {
			return this.#become({ ...answered, reason: refusalText(new LocalRefusal("access-share-unheld")) });
		}
		// A request answered with a refusal or a conflict is answered the same way
		// again, so the share ends, and says what became of the access it made.
		this.#end(lostAccess(answered), failure);
		return this.#current();
	}
	/** Send `issue`'s request through its source, as `settleSubmit` says. An
	 * outcome nothing settled is `uncertain` in the words that name it. */
	#submit(
		issue: { readonly source: HeldControl; readonly request: RoomsManagedIssuance },
		uncertain: "access-issue-unknown" | "access-share-unheld" = "access-issue-unknown",
	) {
		return settleSubmit(
			() =>
				this.#owner.submitThrough(
					issue.source,
					(): Promise<SubmissionOutcome & Returned> => issue.request.submitOutcome(),
				),
			{ conflict: "access-issue-conflict", uncertain },
		);
	}
	/** The share as it stands after an await. Only the step in turn moves its
	 * share, so it stands where that step left it. */
	#unmoved<T extends PendingIssue>(before: T): T {
		invariant(this.#issue === before, "only the step in turn moves its share");
		return before;
	}
	/** Refuse once the owner has closed, freeing what `output` returned. */
	#checkOpen(output: Returned): void {
		try {
			this.#owner.checkOpen();
		} catch (error) {
			output.access?.free();
			output.control?.free();
			throw error;
		}
	}
	/** Take what a committed share returned. Its control goes to the owner, or
	 * is freed when the share's access is saved, whose row reaches it, or was
	 * removed. A hold that fails for good ends the share with that failure. */
	async #received(output: Returned): Promise<ShareOutcome> {
		const { access, control } = output;
		invariant(access != null && control != null, "committed issuance has no returned custody");
		const before = this.#issue;
		invariant(before != null, "a share received its access");
		const kept = before.phase === "committed" && (before.made.kind === "removed" || saved(before.made.control))
			? before.made
			: null;
		let made: MadeAccess;
		if (kept != null) {
			control.free();
			made = kept;
		} else {
			const answer = await this.#owner.hold(before.id, control);
			if (answer.kind === "final") {
				access.free();
				// The session made the access, and this page cannot hold it, so
				// nothing here can revoke it on its own.
				this.#lose(refusalText(new LocalRefusal("access-share-unread", { cause: answer.failure })));
				this.#owner.checkOpen();
				return this.#current();
			}
			made = { kind: "held", control: answer.control };
			// The hold's own read lost the connection the new access travels,
			// which is its source's, so the access went with it and the share
			// asks for it again.
			if (this.#issue !== before) {
				access.free();
				return this.#current();
			}
		}
		const issue = this.#unmoved(before);
		invariant(issue.phase !== "conflict" && issue.phase !== "lost", "a share under way holds its request");
		if (issue.phase === "committed") issue.access?.free();
		const link = issue.phase === "committed" ? issue.link : null;
		const next = this.#become({
			...shareCore(issue),
			phase: "committed",
			request: issue.request,
			access,
			made,
			link,
		});
		// Issuing advanced the source revision. A failed read costs the next
		// issuance one conflict, whose review reads the source again.
		await this.#owner.reread(issue.source);
		return next;
	}
	/** Get the made access's link, once it is saved or removed, and keep it as
	 * the share's. */
	async publish(): Promise<string> {
		this.#owner.checkOpen();
		const issue = this.#committed();
		if (issue.link != null) return issue.link;
		const step = shareStep(issue);
		const access = issue.access;
		if (step.kind !== "publish" || access == null) throw new LocalRefusal(unfinished(step) ?? "not-sent");
		// The access travels its source's connection, so a lost one is the
		// source's, and drops the access with it.
		const link = await this.#owner.through(issue.source, () => access.publish());
		this.#owner.checkOpen();
		this.#become({ ...this.#unmoved(issue), link });
		return link;
	}
	/** Let go of the share at the person's word, once it has nothing left to
	 * do: refused while its next step is unfinished. */
	discard(): void {
		this.#owner.checkOpen();
		const issue = this.#issue;
		if (issue == null) return;
		const refusal = unfinished(shareStep(issue));
		if (refusal != null) throw new LocalRefusal(refusal);
		freeHeld(issue);
		this.#issue = null;
		this.#owner.changed();
	}
	/** Move a share still under way onto the new link, once the owner has
	 * restored the controls in `restored`. What it returned travels the replaced
	 * link, and a new access not yet saved has no row to restore it from, so
	 * the share asks for it again through its source restored over the new
	 * link. The request keeps its sequence, so the session issues at most one
	 * access for it, and answers with that same access. A share whose source the
	 * link could not reach waits on it, and goes on when the source's Try now or
	 * the next link reaches it. A share with nothing left to go on through ends,
	 * and says what became of it on the card that started it. */
	relink(restored: ReadonlySet<HeldControl>): Promise<void> {
		const issue = this.#issue;
		if (issue == null) return Promise.resolve();
		if (issue.phase === "committed") this.#dropReturned(issue);
		return this.#goOn(restored.has(issue.source));
	}
	/** `control` lost its connection. What the session returned for a share
	 * travels its source's connection, so a source's loss drops it, and the
	 * share asks the source for it again. A new access not yet saved travels
	 * that connection too, so its loss is the source's. A saved one that lost
	 * its own makes the share's next step go through the source, and a source
	 * this page cannot reach, whose Try now cannot help, can carry it no
	 * further, so the share ends. */
	lost(control: HeldControl): void {
		const issue = this.#issue;
		if (issue?.phase !== "committed") return;
		const source = issue.source;
		if (source === control) return this.#dropReturned(issue);
		if (madeControl(issue) !== control) return;
		if (!saved(control) && source.state.kind === "reached" && control.state.kind !== "reached") {
			this.#owner.lose(source, control.state.failure);
			return this.#dropReturned(issue);
		}
		if (source.state.kind === "reached") return;
		const ended = endedShare(issue, false);
		if (ended != null) this.#end(ended);
	}
	/** The source's Try now reached it again, or did not. */
	sourceTried(reachedAgain: boolean): Promise<void> {
		return this.#goOn(reachedAgain);
	}
	/** The person removed `control`. Removing the share's saved new access keeps
	 * the share, which can still show its link. Removing its source ends a share
	 * with nothing left to do or that sent nothing, and the owner refuses it for
	 * any other. */
	removed(control: HeldControl): void {
		const issue = this.#issue;
		if (issue?.source === control) {
			invariant(unfinished(shareStep(issue)) == null, "a share's source stays while the share needs it");
			freeHeld(issue);
			this.#issue = null;
			this.#owner.changed();
			return;
		}
		if (madeControl(issue) !== control || issue?.phase !== "committed") return;
		this.#become({ ...issue, made: { kind: "removed" } });
	}
	/** End the share when its source can no longer carry its next step, or go
	 * on through a source reached again. */
	async #goOn(reachedAgain: boolean): Promise<void> {
		const issue = this.#issue;
		if (issue == null || issue.phase === "lost") return;
		const ended = endedShare(issue, reachedAgain);
		if (ended != null) return this.#end(ended);
		if (!reachedAgain) return;
		// A request travels the link and connection it was sent over, so it goes
		// on through the source as it now stands.
		if (issue.phase === "prepared" || issue.phase === "uncertain") this.#resume(issue);
		if (shareStep(this.#current()).kind === "ask") await this.#ask(this.#committed());
	}
	/** Let go of what the share returned over a connection that is gone. A saved new
	 * access stays, and its row restores it. One not yet saved stays in the
	 * list unreached until the share asks for it again, and the access the
	 * session answers with goes in place. */
	#dropReturned(issue: CommittedShare): void {
		issue.access?.free();
		this.#become({ ...issue, access: null });
		const made = madeControl(issue);
		if (made != null && !saved(made) && made.state.kind === "reached") {
			this.#owner.lose(made, new LocalRefusal("access-share-unheld"));
		}
	}
	/** Go on with the request through its source as it now stands. It keeps
	 * its sequence, so the session issues at most one access for it. */
	#resume<T extends Extract<PendingIssue, { request: RoomsManagedIssuance }>>(issue: T): T {
		const request: RoomsManagedIssuance = this.#owner.accept(reached(issue.source).resumeIssue(issue.request));
		issue.request.free();
		return this.#become({ ...issue, request });
	}
	/** End the share for `key`, because of `cause` when one is known. A new
	 * access not yet saved has no row, and nothing can ask for it again, so the
	 * page lets go of it with the share. */
	#end(key: LocalRefusalKey, cause?: unknown): void {
		const made = madeControl(this.#issue);
		if (made != null && !saved(made)) this.#owner.release(made);
		this.#lose(refusalText(new LocalRefusal(key, { cause })));
	}
	/** Free what the share holds, and keep `reason` on its card. */
	#lose(reason: string): void {
		const issue = this.#current();
		freeHeld(issue);
		this.#become({ ...shareCore(issue), phase: "lost", reason });
	}
	#current(): PendingIssue {
		const issue = this.#issue;
		invariant(issue != null, "a share is under way");
		return issue;
	}
	#committed(): CommittedShare {
		const issue = this.#current();
		invariant(issue.phase === "committed", "the share was made");
		return issue;
	}
	#become<T extends PendingIssue>(next: T): T {
		this.#issue = next;
		this.#owner.changed();
		return next;
	}
	/** Free what the share holds, as the owner lets go of everything it holds. */
	release(): void {
		if (this.#issue != null) freeHeld(this.#issue);
		this.#issue = null;
	}
}
