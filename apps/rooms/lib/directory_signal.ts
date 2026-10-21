// WebRTC signaling carried by a directory connection (ADR-0035).
//
// One row per active dial. `onSignalCandidate` creates it before ICE gathering
// starts, so early local candidates can wait on `offerReady` instead of racing
// the directory's exchange admission. `Directory` owns the session and the
// local-ref table. This table owns only the exchanges.

import { type Behavior, currentSession, Ref, retainSecondaryFailure } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "./argument_custody.ts";
import { MAX_SIGNAL_CANDIDATE, MAX_SIGNAL_ID, MAX_SIGNAL_SDP, SIGNAL_EXCHANGE_TIMEOUT_MS, utf8Fits } from "./limits.ts";
import {
	OFFER_SIGNALING,
	SIG_ACCEPTED,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_REJECT,
	SIGNAL_ANSWER,
	SIGNAL_CANDIDATE,
	SIGNAL_DONE,
	SIGNAL_OFFER,
} from "./protocol.ts";
import { ask } from "./ask.ts";

interface SignalRow {
	reply: Ref;
	offerReady: Promise<string>;
	resolveOfferReady: (id: string) => void;
	rejectOfferReady: (reason?: unknown) => void;
	offerStarted: boolean;
	answer: {
		resolve: (sdp: string) => void;
		reject: (reason?: unknown) => void;
	} | null;
	sink: ((ice: string) => void) | null;
}

export class DirectorySignaling {
	readonly #signals = new Map<string, SignalRow>();
	#retainedFailure: unknown | null = null;

	constructor(
		private readonly session: Session,
		private readonly directory: Ref,
		private readonly releaseLocal: (ref: Ref) => void,
		private readonly sessionFor: () => Session | null = currentSession,
	) {}

	/** Failures from a stopped exchange that still had to send `signalDone`. */
	takeFailure(): unknown | null {
		const failure = this.#retainedFailure;
		this.#retainedFailure = null;
		return failure;
	}

	/** File this member's WebRTC signaling inbox with the directory
	 * (`offerSignaling`): offers and candidates aimed at this member's Host key
	 * arrive on it as `offer(id, sdp, from?)` / `candidate(id, ice)`. */
	async offerSignaling(inbox: Ref): Promise<void> {
		await ask(
			this.session,
			this.directory,
			OFFER_SIGNALING,
			[inbox],
			"the directory did not answer offering a signaling inbox",
		);
	}

	/** Start one signaling exchange toward `designator` and resolve the far
	 * peer's SDP answer. The answer rides a reply capability this method spawns,
	 * because directory behaviors return nothing (every signaling message is an
	 * eventual send). */
	async signalOffer(designator: string, sdp: string): Promise<string> {
		const row = this.#signalRow(designator);
		if (row.offerStarted) {
			throw new Error(`rooms: a signaling exchange for ${designator} is already active`);
		}
		row.offerStarted = true;
		const answer = new Promise<string>((resolve, reject) => {
			const timer = setTimeout(
				() => {
					const error = new Error("rooms: signaling exchange timed out");
					// Acceptance and answer are two milestones of one exchange. Refusing
					// both makes whichever one the caller awaits terminal.
					row.rejectOfferReady(error);
					row.answer?.reject(error);
				},
				SIGNAL_EXCHANGE_TIMEOUT_MS,
			);
			const settle = <T extends unknown[]>(finish: (...args: T) => void) => (...args: T): void => {
				if (row.answer == null) return;
				clearTimeout(timer);
				row.answer = null;
				finish(...args);
			};
			row.answer = {
				resolve: settle(resolve),
				reject: settle(reject),
			};
		});
		// tolerant: the caller awaits `answer` and receives its refusal. This
		// handler only keeps a refusal that lands before the await from
		// surfacing as an unhandled rejection.
		void answer.catch(() => {});
		try {
			await ask(
				this.session,
				this.directory,
				SIGNAL_OFFER,
				[designator, sdp, row.reply],
				"the directory did not answer a signaling offer",
			);
		} catch (error) {
			row.rejectOfferReady(error);
			row.answer?.reject(error);
		}
		await row.offerReady;
		return await answer;
	}

	/** Answer exchange `id` with this member's SDP answer (the answering half). */
	signalAnswer(id: string, sdp: string): Promise<void> {
		return this.session.tell(this.directory, SIGNAL_ANSWER, [id, sdp]);
	}

	/** Trickle one ICE candidate. The offering side supplies its designator key
	 * and waits for admission to resolve it to an exchange id. The answering
	 * side already supplies the id it received with the offer. */
	async signalCandidate(key: string, ice: string): Promise<void> {
		const row = this.#signals.get(key);
		const id = row === undefined ? key : await row.offerReady;
		await this.session.tell(this.directory, SIGNAL_CANDIDATE, [id, ice]);
	}

	/** Register the sink for candidates the far peer of `designator`'s exchange
	 * trickles back. Returns a disposer. */
	onSignalCandidate(designator: string, sink: (ice: string) => void): () => void {
		const row = this.#signalRow(designator);
		if (row.sink != null) {
			throw new Error(`rooms: a signaling exchange for ${designator} is already active`);
		}
		row.sink = sink;
		return () => {
			if (row.sink !== sink) return;
			row.sink = null;
			if (this.#signals.get(designator) === row) this.#signals.delete(designator);
			const stopped = new Error("rooms: signaling exchange stopped");
			row.rejectOfferReady(stopped);
			row.answer?.reject(stopped);
			if (!row.offerStarted) {
				this.releaseLocal(row.reply);
				return;
			}
			void row.offerReady.then(
				(id) => this.session.tell(this.directory, SIGNAL_DONE, [id]),
				() => {},
			).catch((error) => {
				this.#retainedFailure = this.#retainedFailure === null
					? error
					: retainSecondaryFailure(this.#retainedFailure, error);
			}).finally(() => this.releaseLocal(row.reply));
		};
	}

	/** Reject every live exchange and return their reply capabilities so the
	 * directory can release them with its other local refs. */
	abandon(reason: string): Ref[] {
		const replies: Ref[] = [];
		const error = new Error(reason);
		for (const row of this.#signals.values()) {
			row.rejectOfferReady(error);
			row.answer?.reject(error);
			replies.push(row.reply);
		}
		this.#signals.clear();
		return replies;
	}

	#signalRow(designator: string): SignalRow {
		let row = this.#signals.get(designator);
		if (row === undefined) {
			let resolveOfferReady!: (id: string) => void;
			let rejectOfferReady!: (reason?: unknown) => void;
			const offerReady = new Promise<string>((resolve, reject) => {
				resolveOfferReady = resolve;
				rejectOfferReady = reject;
			});
			// tolerant: an offerer or answerer that needs this exchange's id awaits
			// `offerReady` and receives its rejection there. A row nobody waits on
			// has nobody to tell, and its loss is an exchange nobody used. This
			// handler only covers the window before a waiter arrives.
			void offerReady.catch(() => {});
			const handleVerb: Behavior = (verb, args) => {
				const caller = this.sessionFor();
				if (caller == null) throw new Error("a signaling reply is reachable only during a session turn");
				if (hasCapabilityArguments(args)) {
					throwAfterReleasingCapabilities(
						caller,
						args,
						new Error(`signaling reply ${verb} does not take capability arguments`),
					);
				}
				if (verb === SIG_ACCEPTED) {
					if (
						args.length !== 1 || typeof args[0] !== "string" || args[0] === "" ||
						!utf8Fits(args[0], MAX_SIGNAL_ID)
					) {
						throw new Error("signalAccepted needs one bounded exchange id");
					}
					fresh.resolveOfferReady(args[0]);
					return null;
				}
				if (verb === SIG_ANSWER) {
					if (
						args.length !== 1 || typeof args[0] !== "string" || args[0] === "" ||
						!utf8Fits(args[0], MAX_SIGNAL_SDP)
					) {
						throw new Error("signalAnswer needs one bounded session description");
					}
					fresh.answer?.resolve(args[0]);
					return null;
				}
				if (verb === SIG_CANDIDATE) {
					if (
						args.length !== 1 || typeof args[0] !== "string" || args[0] === "" ||
						!utf8Fits(args[0], MAX_SIGNAL_CANDIDATE)
					) {
						throw new Error("signalCandidate needs one bounded ICE candidate");
					}
					fresh.sink?.(args[0]);
					return null;
				}
				if (verb === SIG_REJECT) {
					if (
						args.length !== 1 || typeof args[0] !== "string" || args[0] === "" ||
						!utf8Fits(args[0], MAX_SIGNAL_SDP)
					) {
						throw new Error("signalReject needs one bounded reason");
					}
					const reason = args[0];
					const error = new Error(`rooms: ${reason}`);
					fresh.rejectOfferReady(error);
					fresh.answer?.reject(error);
					return null;
				}
				throw new Error(`signaling reply has no method ${verb}`);
			};
			const fresh: SignalRow = {
				reply: this.session.spawn(handleVerb),
				offerReady,
				resolveOfferReady,
				rejectOfferReady,
				offerStarted: false,
				answer: null,
				sink: null,
			};
			this.#signals.set(designator, fresh);
			row = fresh;
		}
		return row;
	}
}
