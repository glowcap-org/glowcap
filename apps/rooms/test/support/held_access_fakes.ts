// The fake controls a page holding management access dials and calls: a saved
// access, the request a share sends through it and the new access it returns,
// the page's own access and an attached one, and the edits made through each.
// Each answers as the test's plan says, can be held open at any one call, and
// travels the connection it was made over, so it fails once that drops, as the
// binding's handles do. Every handle is made through the ledger.
import { OWN_CONTROL } from "../../web/ui/session/managed/held_control.ts";
import { browserFailure } from "./browser_failure.ts";
import { closed, closedOutcome, failedOutcome, timedOutOutcome } from "./managed_link.ts";
import {
	type Connection,
	gone,
	type Held,
	type Ledger,
	type Plan,
	type RestoreFailure,
	timedOut,
} from "./held_access_plan.ts";

export class Fakes {
	readonly #ledger: Ledger;
	readonly #plan: Plan;
	/** The connection of the page's current link. */
	#line: Connection = { dead: false };
	/** The newest source's own connection. */
	#sourceConnection: Connection | null = null;
	/** The revision each edit was prepared at, which a resume carries. */
	readonly #bases = new WeakMap<object, string>();
	/** The sequence each narrower control's request carries, which a resume
	 * keeps. */
	readonly #sequences = new WeakMap<object, number>();
	/** The sequences the session made a narrower control for, which it
	 * answers again with that same control. */
	readonly #answered = new Set<number>();
	#nextSequence = 0;

	constructor(ledger: Ledger, plan: Plan) {
		this.#ledger = ledger;
		this.#plan = plan;
	}
	/** Drop the current link's connection, and open the next one's. */
	breakLine(): void {
		this.#line.dead = true;
		this.#line = { dead: false };
	}
	/** Drop the source's own connection with no call to see it, as a session
	 * that went away does. */
	dropSource(): void {
		if (this.#sourceConnection != null) this.#sourceConnection.dead = true;
	}
	/** `answer`, unless this is the call the plan holds open. */
	call<T>(answer: () => Promise<T>): Promise<T> {
		const park = this.#plan.park;
		if (park == null || ++park.count !== park.at) return answer();
		park.hit.resolve();
		return park.release.promise.then(answer);
	}
	/** Dial the saved control `id`: the source as the plan's next restore says,
	 * or a new access a share made and saved. */
	dial(id: string): Promise<unknown> {
		return this.call(() => {
			this.#plan.dials++;
			if (id === "source") return this.#plan.sources.shift()?.() ?? Promise.resolve(this.source());
			// The page's own control has no saved row, as Rust's restore says.
			if (id === OWN_CONTROL) {
				return Promise.reject(browserFailure(null, "No held management control for this row"));
			}
			return Promise.resolve(this.#savedMade());
		});
	}
	/** The save and forget calls of a link's workspace. Saving reads the
	 * access's link over the control's own connection. */
	workspace() {
		return {
			prepareSaveControl: (id: string, control: { recipe?: () => Promise<unknown> }) =>
				this.call(async () => {
					await control.recipe?.();
					if (this.#plan.savedRows.has(id)) return null;
					return this.#ledger.handle("save", {
						submit: () => this.#stored(this.#plan.save, () => this.#plan.savedRows.add(id)),
					});
				}),
			// The release of a row's control, or nothing for a row that holds none,
			// as the binding prepares it.
			prepareForgetControl: (id: string) =>
				this.call(() =>
					Promise.resolve(
						this.#plan.savedRows.has(id)
							? this.#ledger.handle("forget", {
								submit: () => this.#stored(this.#plan.forget, () => this.#plan.savedRows.delete(id)),
							})
							: null,
					)
				),
		};
	}
	/** Submit a change to storage that the session answers with `answer`, or
	 * commits, and `commit` once it commits. */
	#stored(answer: Promise<unknown> | null, commit: () => void): Promise<unknown> {
		return this.call(async () => {
			const outcome = await (answer ?? Promise.resolve({ status: "committed" }));
			if (Reflect.get(Object(outcome), "status") === "committed") commit();
			return outcome;
		});
	}
	/** A saved source over the page's current link, unavailable once revoked.
	 * A source whose own connection was lost stays dead, and a request made or
	 * resumed through it travels that connection, so it fails when sent, as
	 * does the access and the control it returns. */
	source(options: { revoked?: boolean } = {}) {
		const connection: Connection = { dead: false };
		this.#sourceConnection = connection;
		const over = this.#line;
		const lost = this.#own("source", over);
		return this.#ledger.handle("source", {
			describe: () =>
				this.call(() => {
					if (this.#plan.sourceLost || lost()) connection.dead = true;
					if (connection.dead || over.dead) return Promise.reject(closed());
					if (this.#plan.sourceRead === "transient") {
						this.#plan.sourceRead = "ok";
						return Promise.reject(timedOut());
					}
					if (options.revoked) return Promise.resolve({ available: false });
					const { inspect, delegates } = this.#plan;
					return this.#ok().then((view) => ({
						...view,
						...(inspect ? { inspect: true } : {}),
						...(delegates ? { delegateControl: true } : {}),
					}));
				}),
			// The source's own record, which no test reads.
			inspect: () => Promise.resolve(null),
			prepareIssue: () =>
				this.call(() =>
					connection.dead || over.dead
						? Promise.reject(closed())
						: Promise.resolve(this.#request(connection, over, false))
				),
			resumeIssue: () => this.#request(connection, over, true),
			...this.#outside("source", () => lost() || connection.dead),
		});
	}
	/** The page's own access or the attached one over the current link, unless
	 * the plan fails its restore. */
	holder(held: "own" | "attached") {
		const failure = this.#plan.restore[held];
		delete this.#plan.restore[held];
		if (failure != null) return Promise.reject(held === "attached" ? attachFailure(failure) : ownFailure(failure));
		const lost = this.#own(held, this.#line);
		return Promise.resolve(this.#ledger.handle(`${held} control`, {
			describe: () => this.call(() => lost() ? Promise.reject(closed()) : this.#ok()),
			// Saving reads the access's link over its own connection.
			recipe: () => lost() ? Promise.reject(closed()) : Promise.resolve(`the ${held} access's link`),
			...this.#outside(held, lost),
		}));
	}

	#ok() {
		return Promise.resolve({ available: true, revision: String(this.#plan.revision) });
	}
	/** A held control's own connection over `over`. Whether it is lost now:
	 * the plan's `cut` loses it for good. */
	#own(held: Held, over: Connection): () => boolean {
		const connection = { dead: false };
		return () => {
			if (this.#plan.cut === held) {
				this.#plan.cut = null;
				connection.dead = true;
			}
			return connection.dead || over.dead;
		};
	}
	/** An edit made through `held` at revision `base`, which travels its
	 * connection and answers as the plan says. */
	#edit(held: Held, lost: () => boolean, resumed: boolean, base: string) {
		const plan = this.#plan;
		const made = this.#ledger.handle(resumed ? "moved edit" : "edit", {
			submitOutcome: () =>
				this.call((): Promise<unknown> => {
					plan.editSends++;
					if (lost()) return Promise.resolve(closedOutcome());
					const answer = plan.edit;
					plan.edit = "committed";
					if (answer === "lost") {
						plan.cut = held;
						lost();
						return Promise.resolve(closedOutcome());
					}
					if (answer === "uncertain") return Promise.resolve(timedOutOutcome());
					if (answer === "refused") return Promise.resolve(sessionRefused("no such access"));
					if (answer === "conflict" || base !== String(plan.revision)) {
						if (answer === "conflict") plan.revision++;
						return Promise.resolve({ status: "conflict" });
					}
					plan.revision++;
					return Promise.resolve({ status: "committed" });
				}),
		});
		this.#bases.set(made, base);
		return made;
	}
	/** What a held control answers outside a turn, at once: its listing, an
	 * edit prepared through it, and a narrower control made from it, whose link
	 * is read over the same connection. An edit resumes onto a handle a new
	 * link restored unless the plan fails it, and a narrower control's request
	 * resumes with its sequence. */
	#outside(held: Held, lost: () => boolean) {
		const plan = this.#plan;
		const answer = <T>(value: () => T) => () => lost() ? Promise.reject(closed()) : Promise.resolve(value());
		return {
			inventory: () => {
				plan.listings++;
				const fails = plan.listingFails;
				plan.listingFails = null;
				if (fails === "refused") return Promise.reject(timedOut());
				if (fails === "fault") return Promise.reject(new Error("the listing broke"));
				return this.call(answer(() => ({ rows: [], cursor: null })));
			},
			prepareLabel: (base: string) => {
				if (lost()) return Promise.reject(closed());
				if (!plan.prepareFails) return Promise.resolve(this.#edit(held, lost, false, base));
				plan.prepareFails = false;
				return Promise.reject(timedOut());
			},
			resumeEdit: (prior: object) => {
				if (!plan.resumeFails) return this.#edit(held, lost, true, this.#bases.get(prior) ?? "");
				plan.resumeFails = false;
				throw new Error("the edit could not move");
			},
			prepareAttenuation: answer(() => this.#attenuation(held, lost, "attenuation", this.#nextSequence++)),
			resumeAttenuation: (prior: object) => {
				const sequence = this.#sequences.get(prior);
				if (sequence == null) throw new Error("not an attenuation these fakes made");
				return this.#attenuation(held, lost, "resumed attenuation", sequence);
			},
		};
	}
	/** A narrower control's request at `sequence`, sent through `held`. The
	 * session makes one control per sequence and answers a resend with it,
	 * until the plan has it drop those answers. */
	#attenuation(held: Held, lost: () => boolean, name: string, sequence: number) {
		const plan = this.#plan;
		const request = this.#ledger.handle(name, {
			submit: () => {
				if (lost()) return Promise.reject(closed());
				const resent = this.#answered.has(sequence);
				if (resent && plan.narrowerExpired) {
					return Promise.reject(browserFailure(-12, "the session no longer holds this answer"));
				}
				this.#answered.add(sequence);
				return Promise.resolve(
					this.#ledger.handle(resent ? "narrower control again" : "narrower control", {
						publish: () =>
							this.call(() => {
								if (plan.narrowerLost) {
									plan.narrowerLost = false;
									plan.cut = held;
								}
								return lost() ? Promise.reject(closed()) : Promise.resolve(`link ${sequence}`);
							}),
					}),
				);
			},
		});
		this.#sequences.set(request, sequence);
		return request;
	}
	/** The request a share sends through a source over `through`, its own
	 * connection, on link `over`. */
	#request(through: Connection, over: Connection, resumed: boolean) {
		const plan = this.#plan;
		return this.#ledger.handle("request", {
			submitOutcome: () =>
				this.call(() => {
					plan.sends++;
					if (resumed) plan.replays++;
					if (through.dead || over.dead) return Promise.resolve(closedOutcome());
					if (resumed && plan.replayFails) {
						plan.replayFails = false;
						return Promise.resolve(closedOutcome());
					}
					const answer = plan.answer;
					if (answer === "uncertain") {
						plan.answer = "committed";
						return Promise.resolve(timedOutOutcome());
					}
					if (answer === "conflict") return Promise.resolve({ status: "conflict" });
					if (answer === "refused") return Promise.resolve(sessionRefused("no such receipt"));
					const access = this.#ledger.handle("access", {
						publish: () =>
							this.call(() =>
								through.dead || over.dead ? Promise.reject(closed()) : Promise.resolve(plan.accessLink)
							),
					});
					return Promise.resolve({ status: "committed", access, control: this.#made(through, over) });
				}),
		});
	}
	/** The new access a share returned over `through`, the source's connection,
	 * which it travels as the binding's returned handles do: the plan's `cut`
	 * on it loses that connection, and the source's with it. */
	#made(through: Connection, over: Connection) {
		const plan = this.#plan;
		const read = plan.read;
		plan.read = "ok";
		const lost = () => {
			if (plan.cut === "made") {
				plan.cut = null;
				through.dead = true;
			}
			return through.dead || over.dead;
		};
		return this.#ledger.handle("made control", {
			describe: () =>
				this.call(() => {
					plan.reads++;
					if (lost()) return Promise.reject(closed());
					if (read === "ok") return this.#ok();
					return Promise.reject(read === "transient" ? timedOut() : read === "lost" ? closed() : gone());
				}),
			recipe: () => lost() ? Promise.reject(closed()) : Promise.resolve("the new access's link"),
			...this.#outside("made", lost),
		});
	}
	/** A new access a share made and saved, dialed from its row. */
	#savedMade() {
		const lost = this.#own("made", this.#line);
		return this.#ledger.handle("saved made control", {
			describe: () => lost() ? Promise.reject(closed()) : this.#ok(),
			...this.#outside("made", lost),
		});
	}
}

/** How `attachControl` rejects, as `dial_session` in
 * rust/glowcap/src/client/caller.rs answers it and a saved row's dial. A dial
 * that runs out of time, or reaches no peer, is `session-unreachable` with no
 * binding status. A link the session no longer publishes is gone. */
function attachFailure(failure: RestoreFailure): Error {
	if (failure === "gone") return gone();
	if (failure === "timed out") return browserFailure(null, "Management connection timed out", "session-unreachable");
	return browserFailure(null, "ExporterUnreachable", "session-unreachable");
}
/** How the page's own control rejects in the plan. */
function ownFailure(failure: RestoreFailure): Error {
	return failure === "gone" ? gone() : failure === "timed out" ? timedOut() : closed();
}
/** A request the session refused before it took effect, whose words name no
 * Rooms failure: a `RefusedObservation`, projected with no status and no code. */
function sessionRefused(reason: string) {
	return failedOutcome("refused", { status: null, reason, code: null });
}
