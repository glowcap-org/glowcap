// WebRTC signaling carried by a directory connection (ADR-0089).
//
// One row per active dial. `onSignalCandidate` creates it before ICE gathering
// starts, so early local candidates can wait on `offerReady` instead of racing
// the directory's exchange admission. `Directory` owns the session and the
// local-ref table; this table owns only the exchanges.

import { Ref, retainSecondaryFailure } from "@pancake/runtime";
import type { Session } from "@pancake/runtime";
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

const SIGNALING_ANSWER_TIMEOUT_MS = 30_000;

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
	) {}

	/** Failures from a stopped exchange that still had to send `signalDone`. */
	takeFailure(): unknown | null {
		const failure = this.#retainedFailure;
		this.#retainedFailure = null;
		return failure;
	}

	/** File this member's WebRTC signaling inbox with the directory
	 * (`offerSignaling`): offers and candidates aimed at this member's `webrtc`
	 * designator arrive on it as `offer(id, sdp)` / `candidate(id, ice)`. */
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
				() => row.answer?.reject(new Error("rooms: signaling answer timed out")),
				SIGNALING_ANSWER_TIMEOUT_MS,
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
	 * and waits for admission to resolve it to an exchange id; the answering
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
			void offerReady.catch(() => {});
			const fresh: SignalRow = {
				reply: null as unknown as Ref,
				offerReady,
				resolveOfferReady,
				rejectOfferReady,
				offerStarted: false,
				answer: null,
				sink: null as ((ice: string) => void) | null,
			};
			fresh.reply = this.session.spawn((verb, args) => {
				if (verb === SIG_ACCEPTED) {
					const id = typeof args[0] === "string" ? args[0] : "";
					if (id.length > 0) fresh.resolveOfferReady(id);
				} else if (verb === SIG_ANSWER) {
					const sdp = typeof args[0] === "string" ? args[0] : "";
					if (sdp.length > 0) fresh.answer?.resolve(sdp);
				} else if (verb === SIG_CANDIDATE) {
					const ice = typeof args[0] === "string" ? args[0] : "";
					if (ice.length > 0) fresh.sink?.(ice);
				} else if (verb === SIG_REJECT) {
					const reason = typeof args[0] === "string" ? args[0] : "signaling exchange failed";
					const error = new Error(`rooms: ${reason}`);
					fresh.rejectOfferReady(error);
					fresh.answer?.reject(error);
				}
				return null;
			});
			this.#signals.set(designator, fresh);
			row = fresh;
		}
		return row;
	}
}
