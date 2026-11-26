// The controls this page holds to manage access: holding, saving, forgetting,
// attaching, sharing, editing, and reading what each manages. Held management
// is independent of workspace use, and a row becomes editable only through an
// independently retained control. `control_reach.ts` reaches each over a link,
// `access_storage.ts` keeps their rows in this page's storage, and
// `access_edit.ts` carries each edit from preparing to its end, and
// `access_read.ts` reads each again.
import { invariant } from "../../../../lib/invariant.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedControl,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import { AccessReads } from "./access_read.ts";
import { pressView } from "./access_row.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import { AccessEdits } from "./access_edit.ts";
import { NarrowerControls } from "./access_narrower.ts";
import { AccessStorage } from "./access_storage.ts";
import type { GrantView, ManagementPowers } from "./access_powers.ts";
import { AccessShare, type HoldAnswer } from "./access_share.ts";
import { type AccessMove, ControlReach, describe } from "./control_reach.ts";
import type { AccessOwner } from "./access_owner.ts";
import { type EditIntent, type EditState, liveEdit } from "./edit_state.ts";
import {
	canTryNow,
	described,
	type DescribedControl,
	handleOf,
	type HeldControl,
	OWN_CONTROL,
	saved,
	tryNowReaches,
} from "./held_control.ts";
import { PressAnswers, type PressRefusal } from "./press_answer.ts";
import { type PendingIssue, type ShareOutcome, shareStep, unfinished } from "./share_state.ts";
import { TrackedJobs } from "./tracked_jobs.ts";

/** What a share asks for besides its source, as `AccessShare.prepare` takes it. */
type ShareRequest = Parameters<AccessShare["prepare"]> extends [unknown, ...infer Terms] ? Terms : never;

/** How one held control came through a move onto a new link: reached over
 * it, kept as it was (unreached, or a new access its share moves), or left to
 * a newer move that took over. */
type ControlMove = { readonly kind: "reached"; readonly control: HeldControl } | {
	readonly kind: "kept" | "superseded";
};

/** This owner keeps wrappers through UI unmounts. Its saved row names select
 * actual strong control fields through Rust, never inventory identities. */
export class ManagedAccess {
	readonly #application: RoomsManagedApplication;
	readonly #report: (error: unknown) => void;
	/** Asks whether the page's own link still answers. */
	readonly #probe: () => void;
	readonly #controls = new Map<string, HeldControl>();
	readonly #holding = new Set<string>();
	/** Each link being attached, by its address. */
	readonly #attaching = new Map<string, Promise<HeldControl>>();
	readonly #listeners = new Set<() => void>();
	readonly #jobs = new TrackedJobs();
	readonly #reach: ControlReach;
	readonly #editing: AccessEdits;
	readonly #sharing: AccessShare;
	readonly #narrower: NarrowerControls;
	readonly #storage: AccessStorage;
	readonly #reads: AccessReads;
	readonly #answers: PressAnswers;
	/** The last event in turn, while one is under way. Held access changes only
	 * in a turn: installing, replacing or freeing a control's handle or a
	 * request made through it, and changing its state or storage. Restoring,
	 * moving onto a new link, reaching again, saving, removing, sending,
	 * discarding or ending an edit, each step of a share, and making a narrower
	 * control are events in turn. A call outside a turn (reading a control,
	 * preparing an edit, attaching one) only reads and calls. What it brings
	 * back, a lost connection, a description, a prepared edit or an attached
	 * control, is kept in a turn of its own, and only while the control still holds the
	 * handle the call went through. So no event acts on what another is
	 * changing, and each starts from what the one before it left. Each call an
	 * event makes to a session settles within `CALL_BOUND_MS`, while a write to
	 * this page's own storage has no bound of its own. The gesture that started
	 * an event shows it busy meanwhile. */
	#last: Promise<void> | null = null;
	/** Counts the moves onto a new link, so a reach begun over one link knows
	 * when a newer one took over. */
	#moves = 0;
	#version = 0;
	#retired = false;
	#closed = false;

	constructor(
		application: RoomsManagedApplication,
		custody: RoomsManagedWorkspace,
		report: (error: unknown) => void,
		probe: () => void,
	) {
		this.#application = application;
		this.#report = report;
		this.#probe = probe;
		this.#answers = new PressAnswers({
			held: () => this.held,
			view: (control) => pressView(this, control),
			inTurn: (event) => this.#inTurn(event),
			report: (error) => this.#report(error),
		});
		this.#reach = new ControlReach(application, {
			closed: () => this.#closed,
			changed: () => this.#changed(),
			probe: () => this.#probe(),
			lost: (control) => this.#sharing.lost(control),
			outlived: (control, failure) => this.#answers.outlived(failure, control),
			resumeEdit: (control) => this.#editing.resume(control),
			sendEdit: (control) => this.#editing.submitOnce(control),
			endEdit: (control) => this.#editing.end(control),
			refresh: (control) => this.#reads.refreshNow(control),
		});
		const owner: AccessOwner = {
			checkOpen: () => this.#checkOpen(),
			accept: (handle) => this.#accept(handle),
			track: (job) => this.#jobs.track(job),
			changed: () => this.#changed(),
			through: (control, call) => this.#reach.through(control, call),
			outside: (control, call) => this.#outside(control, call),
			madeThrough: (control, make, keep) => this.#reach.madeThrough(control, make, keep),
			madeOutside: (control, make, keep) =>
				this.#reach.madeThrough(control, make, keep, {
					apply: this.#later,
					settle: (run) => this.#inTurn(run),
				}),
			submitThrough: (control, submit) => this.#reach.submitThrough(control, submit),
			refreshNow: (control) => this.#reads.refreshNow(control),
			later: this.#later,
			refused: (error, change) =>
				this.#later(() => {
					this.#answers.saw(error);
					change();
				}),
			inTurn: (event) => this.#inTurn(event),
		};
		this.#reads = new AccessReads({ ...owner, report: (error) => this.#report(error) });
		this.#sharing = new AccessShare({
			...owner,
			hold: (id, handle) => this.#jobs.track(this.#holdIssued(id, handle)),
			lose: (control, failure) => this.#reach.lose(control, failure),
			reread: (control) => this.#reads.reread(control),
			release: (control) => this.#release(control),
		});
		this.#editing = new AccessEdits(owner);
		this.#narrower = new NarrowerControls(owner);
		this.#storage = new AccessStorage(custody, {
			...owner,
			holds: (control) => this.#holds(control),
			forgotten: (control) => {
				this.#release(control);
				this.#sharing.removed(control);
				this.#changed();
			},
		});
	}
	get held(): readonly HeldControl[] {
		return [...this.#controls.values()];
	}
	/** The share under way, from its preparation until its card is closed. */
	get issue(): PendingIssue | null {
		return this.#sharing.issue;
	}
	/** The new access the share under way made, held under the share's id. */
	get issued(): HeldControl | null {
		return this.#sharing.made;
	}
	/** Prepare a share from `source` in turn. A source the owner let go of,
	 * as a removal queued ahead of this press does, sends nothing. */
	prepareIssue(source: HeldControl, ...terms: ShareRequest): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(() => {
			if (!this.#holds(source) || !described(source)) throw new LocalRefusal("not-sent");
			return this.#sharing.prepare(source, ...terms);
		});
	}
	submitIssue(): Promise<ShareOutcome> {
		this.#checkOpen();
		return this.#inTurn(() => this.#sharing.submit());
	}
	publishIssue(): Promise<string> {
		this.#checkOpen();
		return this.#inTurn(() => this.#sharing.publish());
	}
	/** Take the share under way as far as it goes now, in one turn: send it, or
	 * ask for its new access again, then save that access and get its link. A
	 * step the share is past is skipped, and one that fails stops here and says
	 * why. */
	goOnIssue(): Promise<ShareOutcome> {
		this.#checkOpen();
		return this.#inTurn(async () => {
			const outcome = await this.#sharing.submit();
			const step = this.issue == null ? null : shareStep(this.issue);
			if (step?.kind === "save") await this.#storage.save(step.control);
			if (this.issue != null && shareStep(this.issue).kind === "publish") await this.#sharing.publish();
			return this.issue ?? outcome;
		});
	}
	/** Close the share's card, once every event before it has ended. */
	discardIssue(): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(() => this.#sharing.discard());
	}
	/** Make `press` on `control`'s row or card, and answer it as
	 * `PressAnswers.answer` says. Every press on a held access's row, its
	 * Manage card, or its share card goes through this. */
	answer(control: HeldControl, press: () => Promise<unknown>): Promise<PressRefusal | null> {
		return this.#answers.answer(control, press);
	}
	/** Make the Hold card's `press`, which answers no held access, as
	 * `PressAnswers.answerAlone` says. */
	answerAlone(press: () => Promise<string | null>): Promise<string | null> {
		return this.#answers.answerAlone(press);
	}
	/** How many times `control`'s view has moved, as `PressAnswers` counts. */
	moves(control: HeldControl): number {
		return this.#answers.moves(control);
	}
	subscribe = (listener: () => void): () => void => {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	};
	getVersion = (): number => this.#version;
	#changed(): void {
		this.#answers.changed();
		this.#version++;
		for (const listener of this.#listeners) {
			try {
				listener();
			} catch (error) {
				this.#report(error);
			}
		}
	}
	#checkOpen(): void {
		if (this.#closed) throw new LocalRefusal("session-closed");
	}
	#accept<T extends { free(): void }>(handle: T): T {
		if (this.#closed) {
			handle.free();
			throw new LocalRefusal("session-closed");
		}
		return handle;
	}
	/** Hold `handle` under `id`, kept in `storage`, from outside a turn. The
	 * control is described when it is held, and its caller reads it as it
	 * stands then, because a later event may let go of it. */
	hold(
		id: string,
		handle: RoomsManagedControl,
		storage: HeldControl["storage"] = { kind: "unsaved", address: null },
	): Promise<HeldControl> {
		return this.#jobs.track(this.#hold(id, handle, storage, (install) => this.#inTurn(install)));
	}
	/** Describe `handle` and hold it under `id`. `inTurn` runs the install: in a
	 * turn of its own from outside one, or at once inside one. */
	async #hold(
		id: string,
		handle: RoomsManagedControl,
		storage: HeldControl["storage"],
		inTurn: (install: () => DescribedControl) => DescribedControl | Promise<DescribedControl>,
	): Promise<DescribedControl> {
		this.#checkOpen();
		invariant(!(this.#controls.has(id) || this.#holding.has(id)), "this control is already held");
		this.#holding.add(id);
		try {
			const description = await describe(handle);
			return await inTurn(() => {
				this.#checkOpen();
				const held: DescribedControl = { id, state: { kind: "reached", handle, ...description }, storage };
				this.#controls.set(id, held);
				this.#changed();
				return held;
			});
		} finally {
			this.#holding.delete(id);
		}
	}
	/** Keep `change` to held access in a turn of its own, for a call outside a
	 * turn that saw it. */
	#later = (change: () => void): void => {
		this.#inTurn(() => {
			if (!this.#closed) change();
		}).catch((error: unknown) => this.#report(error));
	};
	/** Call `control` from outside a turn: a loss the call sees is kept in a
	 * turn of its own. */
	#outside<T>(control: HeldControl, call: (handle: RoomsManagedControl) => Promise<T>): Promise<T> {
		return this.#reach.through(control, call, { apply: this.#later });
	}
	/** Hold the new access a share made under `id`, taking `handle` as
	 * `ShareOwner.hold` says. One the share made before, which lost its handle over a replaced
	 * link or its own connection, takes `handle` in place, the way a move
	 * restores a saved one, so whoever holds that control acts on the live
	 * access. A read of it that fails for a reason asking again can clear holds
	 * it unreached with that failure, and its Try now asks the share again. One
	 * that will not change leaves nothing held. */
	#holdIssued(id: string, handle: RoomsManagedControl): Promise<HoldAnswer> {
		const held = this.#controls.get(id);
		return held == null ? this.#holdNew(id, handle) : this.#holdAgain(held, handle);
	}
	async #holdNew(id: string, handle: RoomsManagedControl): Promise<HoldAnswer> {
		try {
			const control = await this.#hold(
				id,
				handle,
				{ kind: "unsaved", address: null },
				(install) => install(),
			);
			return { kind: "held", control };
		} catch (error) {
			// Nothing holds the handle until its description lands.
			handle.free();
			if (!this.#retryable(error)) return { kind: "final", failure: error };
			const control: HeldControl = {
				id,
				state: { kind: "undescribed", failure: error },
				storage: { kind: "unsaved", address: null },
			};
			this.#controls.set(id, control);
			this.#changed();
			if (connectionLost(error)) this.#probe();
			return { kind: "unreached", control, failure: error };
		}
	}
	async #holdAgain(control: HeldControl, handle: RoomsManagedControl): Promise<HoldAnswer> {
		const moves = this.#moves;
		// A newer link asks the share again, and an access the person removed
		// meanwhile takes nothing.
		const current = () => moves === this.#moves && this.#holds(control);
		// The restore takes `handle` unless it stops before dialing, on a closed
		// owner or a move that is not current. Neither holds here: the share
		// checks the owner is open and reaches this restore with no await in
		// between, and `moves` and the held control were read just now.
		try {
			if (await this.#reach.restore(control, current, () => Promise.resolve(handle))) {
				return { kind: "held", control };
			}
		} catch (error) {
			if (!this.#retryable(error)) {
				this.#release(control);
				return { kind: "final", failure: error };
			}
			// A read that failed after the control took the handle leaves it
			// reached, so it is held unreached here.
			if (control.state.kind === "reached") this.#reach.lose(control, error);
			return { kind: "unreached", control, failure: error };
		}
		const state = control.state;
		return { kind: "unreached", control, failure: state.kind === "reached" ? null : state.failure };
	}
	/** Whether asking again can clear `error`, while this owner is open. */
	#retryable(error: unknown): boolean {
		return !this.#closed && tryNowReaches(error);
	}
	/** Restore each saved control `ids` names when the page opens, the way a
	 * move restores it. One that cannot be reached is held unreached, says why,
	 * and is reached again by `reachAgain` or the next link. */
	restore(ids: readonly string[], move: AccessMove): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(() => this.#restoreSaved(ids, move));
	}
	async #restoreSaved(ids: readonly string[], move: AccessMove): Promise<void> {
		for (const id of ids) {
			if (this.#closed) return;
			if (this.#controls.has(id) || this.#holding.has(id)) continue;
			this.#holding.add(id);
			try {
				// Held only once reached or refused, so no reader sees the state it
				// starts in.
				const control: HeldControl = {
					id,
					state: { kind: "undescribed", failure: null },
					storage: { kind: "saved" },
				};
				if (!await this.#reach.restoreOne(control, move)) return;
				this.#controls.set(id, control);
				this.#changed();
			} finally {
				this.#holding.delete(id);
			}
		}
	}
	/** Run `event` once every event before it has ended. Its caller hears how
	 * it ended, and close waits for it. Work inside a turn calls the owners
	 * directly, never this, so a turn never waits on itself. */
	#inTurn<T>(event: () => T | Promise<T>): Promise<T> {
		const run = (this.#last ?? Promise.resolve()).then(event);
		// Registered before `ended`, so a refusal's record is taken before the
		// next event starts.
		run.then(undefined, (error: unknown) => this.#answers.saw(error)).catch((fault: unknown) =>
			this.#report(fault)
		);
		const ended: Promise<void> = run.then(() => {}, () => {
			// tolerant: the event's caller hears how it failed.
		}).then(() => {
			if (this.#last === ended) this.#last = null;
		});
		this.#last = ended;
		return this.#jobs.track(run);
	}
	/** The link to the session was replaced. Each saved control is restored over
	 * the new link, and one attached but not yet saved is attached again from its
	 * address. Each is described again, and an edit under way through it moves
	 * with it. A control that cannot be restored holds no handle, says why, and
	 * is reached again by `reachAgain` or the next link. The controls are asked
	 * for together, and this page's storage dials saved ones one at a time,
	 * each within `CALL_BOUND_MS` counting its wait. One whose bound passes
	 * before its dial began holds `session-not-reached-yet`, not a lost
	 * connection, and its Try now asks again. Close waits for the move. A share still under way then
	 * moves too, with the new access it made. */
	relink(move: AccessMove): Promise<void> {
		this.#moves++;
		return this.#inTurn(() => this.#relink(move));
	}
	async #relink(move: AccessMove): Promise<void> {
		const moved = await Promise.all([...this.#controls.values()].map(async (control): Promise<ControlMove> => {
			if (this.#closed) return { kind: "kept" };
			const held = handleOf(control);
			// A newer link restores what this one would.
			if (!await this.#reach.restoreOne(control, move)) return { kind: "superseded" };
			// A new access a share made moves with the share, so it is not here.
			const handle = handleOf(control);
			return handle != null && handle !== held ? { kind: "reached", control } : { kind: "kept" };
		}));
		if (this.#closed || moved.some((outcome) => outcome.kind === "superseded")) return;
		await this.#sharing.relink(
			new Set(moved.flatMap((outcome) => outcome.kind === "reached" ? [outcome.control] : [])),
		);
	}
	/** Reach one control the current link, or its own connection, could not,
	 * as the next link would. An edit or share under way through it moves with
	 * it. A failure stays on the control, which says why. */
	reachAgain(control: HeldControl): Promise<void> {
		this.#checkOpen();
		const moves = this.#moves;
		return this.#inTurn(() => this.#reachAgain(control, () => moves === this.#moves));
	}
	async #reachAgain(control: HeldControl, current: () => boolean): Promise<void> {
		this.#checkOpen();
		// A control this page let go of reaches nothing, and a move that began
		// since reaches it, and moves its share, itself.
		if (!this.#holds(control) || !current()) return;
		// A reached control whose last read failed is read again.
		if (control.state.kind === "reached") {
			if (control.readFailure != null) await this.#reads.refreshNow(control);
			return;
		}
		const share = this.#sharing.issue;
		// A new access a share made and has not saved has no row or address
		// to reach it from, so its share asks for it again through the source.
		const made = share != null && this.#sharing.made === control && !saved(control);
		const target = made ? share.source : control;
		if (target.state.kind === "reached") {
			await this.#sharing.submit();
			return;
		}
		let failure: unknown = null;
		try {
			if (!await this.#reach.restore(target, current)) return;
		} catch (error) {
			failure = error;
		}
		// A source reached again holds its new handle even when the read after
		// the reach failed, and its share goes on through that handle.
		const reachedAgain = handleOf(target) != null;
		if (this.#sharing.issue?.source === target) {
			try {
				await this.#sharing.sourceTried(reachedAgain);
			} catch (error) {
				if (failure == null || !reachedAgain) throw error;
				// The read's failure is the gesture's, so the share's is reported.
				this.#report(error);
			}
		}
		// tolerant: a control still unreached holds its failure, and its row
		// says it. A failure after the reach is the gesture's, and so is the
		// failure of a source reached for its share's new access, whose row
		// holds no failure of the source's.
		if (failure != null && (reachedAgain || target !== control)) throw failure;
	}
	/** Read `control` again from outside a turn, as `AccessReads.refresh` says. */
	refresh(control: HeldControl): Promise<void> {
		return this.#reads.refresh(control);
	}
	async inventory(control: HeldControl, cursor?: Uint8Array): Promise<{
		rows: GrantView[];
		cursor: Uint8Array | null;
	}> {
		this.#checkOpen();
		return await this.#jobs.track(
			this.#reads.list(control, cursor),
		);
	}
	/** Save the access `control` manages, in turn: a move replaces the handle a
	 * save is prepared over. */
	save(control: HeldControl): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(() => this.#storage.save(control));
	}
	prepare(control: HeldControl, intent: EditIntent, base: string): Promise<void> {
		return this.#editing.prepare(control, intent, base);
	}
	submit(control: HeldControl): Promise<EditState> {
		return this.#editing.submit(control);
	}
	/** Let go of `control`'s edit, in turn, unless it was sent and is still
	 * unanswered. */
	discard(control: HeldControl): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(() => this.#editing.discard(control));
	}
	reapply(control: HeldControl): Promise<void> {
		return this.#editing.reapply(control);
	}
	/** A link to a narrower control of its own for someone else, in turn, as
	 * `NarrowerControls.share` says. Sharing the held control itself would
	 * hand over every power it has. */
	share(control: HeldControl, powers: ManagementPowers): Promise<string> {
		this.#checkOpen();
		return this.#inTurn(() => {
			if (!this.#holds(control)) throw new LocalRefusal("not-sent");
			return this.#narrower.share(control, powers);
		});
	}
	/** The powers of the narrower control `control` asked for and has no
	 * answer to, which its next share asks for again, or null. */
	narrowerPending(control: HeldControl): ManagementPowers | null {
		return this.#narrower.pending(control);
	}
	/** Stop asking for `control`'s unanswered narrower control, in turn. */
	giveUpNarrower(control: HeldControl): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(() => this.#narrower.release(control));
	}
	/** Hold the control `uri` links to under `id`. A link a held row was
	 * attached from, or is being attached from, answers that row, so attaching
	 * again makes no second handle. A row its link no longer reaches is reached
	 * again first, as its Try now does, and answers unreached if that fails. */
	attach(id: string, uri: string): Promise<HeldControl> {
		const held = [...this.#controls.values()].find((control) => control.storage.address === uri);
		if (held != null && described(held)) {
			return held.state.kind === "reached" ? Promise.resolve(held) : this.reachAgain(held).then(() => held);
		}
		const attaching = this.#attaching.get(uri);
		if (attaching != null) return attaching;
		const job = this.#jobs.track(this.#attach(id, uri)).finally(() => this.#attaching.delete(uri));
		this.#attaching.set(uri, job);
		return job;
	}
	/** No handle from a replaced link is held as reached. The move closes that
	 * link's session before `relink` asks for its turn, and turns run in the
	 * order asked. A handle described before the close is held in a turn ahead
	 * of the move's, which attaches it again, and one described after fails. */
	async #attach(id: string, uri: string): Promise<HeldControl> {
		this.#checkOpen();
		const handle = await this.#application.attachControl(uri);
		try {
			return await this.hold(id, handle, { kind: "unsaved", address: uri });
		} catch (error) {
			handle.free();
			throw error;
		}
	}
	/** Stop holding a management control: release its saved row, then its
	 * handle. The access it manages is untouched. Revoking is what ends that.
	 * Each attempt reads the current row, so a retry after a lost reply finds
	 * the row already released and only lets go of the handle. */
	forget(control: HeldControl): Promise<void> {
		this.#checkOpen();
		return this.#inTurn(async () => {
			this.#checkOpen();
			// A control this page let go of has nothing left to remove, and its row
			// may hold another control under the same id by now.
			if (!this.#holds(control)) return;
			const refusal = this.removal(control);
			if (refusal != null) throw new LocalRefusal(refusal);
			await this.#storage.forget(control);
		});
	}
	/** Why removing `control` cannot work now, or null when it can. */
	removal(control: HeldControl): LocalRefusalKey | null {
		if (control.id === OWN_CONTROL) return "access-own-stays-held";
		if (this.#editing.submitting(control)) return "access-edit-submitting";
		// A change never sent, an edit through the access or a share from it,
		// waits on the person while the access can still be asked. One sent may
		// have landed, and removing only stops checking it, which the card asks
		// about first. One whose access cannot be reached again is removed with it.
		const issue = this.#sharing.issue;
		const unsent = liveEdit(control)?.phase === "prepared"
			? "access-change-unfinished"
			: issue?.source === control && issue.phase === "prepared"
			? "access-share-source"
			: null;
		if (unsent != null && (control.state.kind === "reached" || canTryNow(control))) return unsent;
		// A share whose next step needs its source keeps it. One with nothing
		// left to do, or that sent nothing, ends with it.
		if (issue?.source === control && unfinished(shareStep(issue)) != null) return "access-share-source";
		// A share's new access not yet saved is in no saved row, so removing it
		// would leave nothing on this page to revoke it from.
		if (this.#sharing.made === control && !saved(control)) return "access-share-made-unsaved";
		return null;
	}
	/** Whether `control` is the one this page holds under its id. */
	#holds(control: HeldControl): boolean {
		return this.#controls.get(control.id) === control;
	}
	/** Stop holding `control`, and free its handle with every request made
	 * through it. A released control holds no handle, so a call through it
	 * sends nothing, and keeps no link it was attached from. */
	#release(control: HeldControl): void {
		this.#controls.delete(control.id);
		control.storage = control.storage.kind === "saved" ? { kind: "saved" } : { kind: "unsaved", address: null };
		this.#editing.release(control);
		this.#narrower.release(control);
		this.#reach.retire(
			this.#reach.replace(control, { kind: "undescribed", failure: new LocalRefusal("not-sent") }),
		);
	}
	stop(): void {
		this.#closed = true;
	}
	async close(): Promise<void> {
		if (this.#retired) return;
		this.#closed = true;
		await this.#jobs.settled();
		if (this.#retired) return;
		this.#retired = true;
		this.#sharing.release();
		for (const control of [...this.#controls.values()]) this.#release(control);
	}
}
