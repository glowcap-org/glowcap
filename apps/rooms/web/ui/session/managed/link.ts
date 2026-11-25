// The one link an attached page keeps to its shared session. This owns when
// the link is lost, when to dial it again, and what a person is told while it
// is gone. A link quiet for too long is probed, and a send that finds it
// replaced waits for the next live link through `available`. `SessionLink`
// owns the handles, and supplies dial, probe and changed.
import { CALL_BOUND_MS, REQUEST_TIMEOUT_MS } from "../../../../lib/limits.ts";
import { RoomsError, roomsErrorIn, SESSION_UNREACHABLE, structuredFailure } from "../../../../lib/error_codes.ts";
import { ROOMS_FAILURES } from "../../../../lib/failure_data.ts";
import { connectionLost } from "../../../../lib/text/failure.ts";
import { invariant } from "../../../../lib/invariant.ts";
import { FIRST_LINK, type Stamp } from "./link_port.ts";

export const BACKOFF_FIRST_MS = 1_000;
export const BACKOFF_CEILING_MS = 30_000;
/** A share of each wait that jitter may remove, so pages that lost one session together do not return together. */
const BACKOFF_JITTER = 0.2;
/** How long a probe may go unanswered before the page counts its link lost
 * without that answer. The probe is one call, which settles within
 * `CALL_BOUND_MS`. This backstop waits one request bound more, for work queued
 * ahead of the call, so it fires only when the call itself never settles. */
export const PROBE_BACKSTOP_MS = CALL_BOUND_MS + REQUEST_TIMEOUT_MS;
/** How long a read parked on a seen, live link waits before a probe asks
 * whether the connection still answers. A parked read answers only on a
 * change, so a connection that died without closing shows nothing until the
 * next call misses its bounds. It costs one small call every 30 s per seen page
 * whose session is quiet, and none on a busy link or a hidden page. */
export const QUIET_PROBE_MS = 30_000;
export const NOTICE_AFTER_MS = 1_500;
/** How long a press waits for a live link before reporting an unread
 * session or an unsent change. Reconnection continues after that wait. */
export const LINK_WAIT_MS = 2 * REQUEST_TIMEOUT_MS;

type LinkState =
	| { readonly kind: "live" }
	| {
		readonly kind: "waiting";
		readonly lostAt: number;
		/** Dials that failed since the link was last steady, counting a link lost soon after it came back. */
		readonly attempt: number;
		readonly cause: unknown;
		/** The clock time before which the session asked not to be dialed again, or 0. */
		readonly notBefore: number;
		readonly until: "backoff" | "visible" | "online";
	}
	| {
		readonly kind: "dialing";
		readonly lostAt: number;
		readonly attempt: number;
		readonly cause: unknown;
	}
	/** The session answered the dial with a refusal, or the page could not dial. No timer retries it. */
	| { readonly kind: "refused"; readonly cause: unknown; readonly answered: boolean }
	| { readonly kind: "closed" };

/** What the page says about the link. */
export type LinkNotice = "reconnecting" | "offline" | "stuck" | "refused" | "failed";

/** What a failed dial means, read from its code alone. A code the failure
 * catalog marks as a failure to reach, and any it says clears soon, clear with
 * time, so the link waits and dials again. Any other code, or a status from the
 * session or glowcap, is the session's answer. A failure with neither came
 * from inside the page, and dialing again would repeat it. */
function dialVerdict(cause: unknown): "wait" | "answered" | "inside" {
	const code = roomsErrorIn(cause)?.code;
	const failure = code == null ? null : ROOMS_FAILURES[code];
	if (failure != null && (failure.retry === "soon" || failure.reach)) return "wait";
	return code != null || structuredFailure(cause)?.status != null ? "answered" : "inside";
}

/** Time and chance, injected so tests drive them. */
export interface LinkClock {
	now(): number;
	/** Run `run` once after `ms` and return the cancel. */
	after(ms: number, run: () => void): () => void;
	random(): number;
}

export const realClock: LinkClock = {
	now: () => Date.now(),
	after(ms, run) {
		const id = setTimeout(run, ms);
		return () => clearTimeout(id);
	},
	random: () => Math.random(),
};

interface LinkHost {
	/** Replace everything held over the lost link, and call `live` in the
	 * same turn the new handles go in place, before any call over them starts.
	 * From then on `generation` stamps them. Reject with why it could not. Once
	 * `live` is called the dial has succeeded, and how its promise settles says
	 * nothing more. */
	dial(live: () => void): Promise<void>;
	/** Resolve once the current link answers, or reject. */
	probe(): Promise<unknown>;
	/** The state or the notice changed. */
	changed(): void;
}

/** The wait before dial number `attempt`, which counts the failed ones. */
export function backoff(attempt: number, random: number): number {
	const wait = Math.min(BACKOFF_FIRST_MS * 2 ** Math.max(attempt - 1, 0), BACKOFF_CEILING_MS);
	return Math.round(wait * (1 - BACKOFF_JITTER * random));
}

export class ManagedLink {
	readonly #ports: LinkHost;
	readonly #clock: LinkClock;
	#state: LinkState = { kind: "live" };
	#visible = true;
	#online = true;
	/** Changes whenever an outstanding dial or probe stops being the current one. */
	#epoch = 0;
	/** The generation of the live link, whose lost connections end it. */
	#generation = FIRST_LINK;
	/** The newest generation a dial was given. Each dial takes the next. */
	#minted = FIRST_LINK;
	#dialed: Promise<void> = Promise.resolve();
	#cancelWait: (() => void) | null = null;
	#cancelNotice: (() => void)[] = [];
	/** When the link last went live, and after how many failed dials. */
	#revived: { readonly at: number; readonly attempt: number } | null = null;
	/** The probe now waiting for its answer, which a hidden page abandons. */
	#probing: { cancel: () => void } | null = null;
	/** The parked read that holds the quiet bound, and the bound's cancel. */
	#quiet: { readonly hold: object; cancel: (() => void) | null } | null = null;
	/** Callers waiting for the link to come back, each told of every change. */
	readonly #watchers = new Set<() => void>();

	constructor(ports: LinkHost, clock: LinkClock = realClock) {
		this.#ports = ports;
		this.#clock = clock;
	}
	get state(): LinkState {
		return this.#state;
	}
	get live(): boolean {
		return this.#state.kind === "live";
	}
	/** Why the session refused the link for good, or null. It is `cause` once
	 * no timer retries the link, and a send held back for the link is refused
	 * with it. */
	get refusal(): unknown {
		const state = this.#state;
		return state.kind === "refused" ? state.cause : null;
	}
	/** Why the link is gone, or null while it is live. */
	get cause(): unknown {
		const state = this.#state;
		return state.kind === "waiting" || state.kind === "dialing" || state.kind === "refused" ? state.cause : null;
	}
	/** What the page says about the link, or null while nothing is worth saying. */
	get notice(): LinkNotice | null {
		const state = this.#state;
		if (state.kind === "refused") return state.answered ? "refused" : "failed";
		if (state.kind !== "waiting" && state.kind !== "dialing") return null;
		const gone = this.#clock.now() - state.lostAt;
		if (gone < NOTICE_AFTER_MS) return null;
		if (state.kind === "waiting" && state.until === "online") return "offline";
		// A dial under way is the try a person could ask for, so it says only
		// that the page is reconnecting. A link still lost after the longest
		// recovery, with no dial under way, is stuck.
		return state.kind === "waiting" && gone >= LINK_WAIT_MS ? "stuck" : "reconnecting";
	}

	/** The generation of the live link, which stamps every handle a call reads. */
	get generation(): number {
		return this.#generation;
	}
	/** A call over handles stamped `stamp` failed. Only a lost connection ends
	 * a link, and only the live link those handles travel. A loss over a link
	 * already replaced says nothing new. Rust names a connection that
	 * closed or broke under a call, and a dial that never reached the session,
	 * `session-unreachable`, as a probe that gets no answer does here. Every
	 * refusal the session answered keeps its own code. */
	lost(cause: unknown, stamp: Stamp): void {
		if (!connectionLost(cause)) return;
		if (this.#state.kind === "live" && stamp.generation === this.#generation) this.#lose(cause);
	}
	/** End the live link. */
	#lose(cause: unknown): void {
		this.#epoch++;
		this.#stopTimers();
		const now = this.#clock.now();
		const revived = this.#revived;
		// A link lost before it stayed live for the quiet bound counts as one more
		// failed dial, so a session that accepts each dial and drops it at once is
		// dialed less and less often. A link live that long has carried a read or
		// answered a probe, which a dial alone does not show.
		const attempt = revived != null && now - revived.at < QUIET_PROBE_MS ? revived.attempt + 1 : 0;
		this.#waitFor({ kind: "waiting", lostAt: now, attempt, cause, notBefore: 0, until: "backoff" });
		this.#watchNotice(now);
	}
	/** The page came back to the foreground or the network returned. A live link
	 * is probed. A lost one dials with a fresh backoff, as soon as the session
	 * allows. A refused one stays refused until a person asks. */
	wake(): void {
		const state = this.#state;
		switch (state.kind) {
			case "live":
				this.probeIfSeen();
				return;
			case "waiting":
				this.#waitFor({ ...state, attempt: 0 });
				return;
			default:
				return;
		}
	}
	/** Ask whether a live link still answers. A call over another connection
	 * that lost its own asks this, and only the probe's answer moves the link. A
	 * hidden page spends nothing, and is probed when it is seen. */
	probeIfSeen(): void {
		if (this.#state.kind === "live" && this.#visible) this.#probe();
	}
	/** A person asked to try now. Their word that a network exists outweighs the
	 * device's, which a wrong report would hold offline for good, and the
	 * session's word of when to ask again. */
	tryNow(): void {
		this.#online = true;
		const state = this.#state;
		// Only a person's word dials again a link the session refused.
		if (state.kind === "refused") {
			this.#epoch++;
			this.#waitFor({
				kind: "waiting",
				lostAt: this.#clock.now(),
				attempt: 0,
				cause: state.cause,
				notBefore: 0,
				until: "backoff",
			});
			this.#watchNotice(this.#clock.now());
			return;
		}
		if (state.kind === "waiting") {
			this.#waitFor({ ...state, attempt: 0, notBefore: 0 });
			return;
		}
		this.wake();
	}
	/** Resolve true once the link is live, and false once it cannot come back:
	 * it was refused or closed, or it stayed down for `boundMs` of time the page
	 * was seen. With no bound the wait ends only with the link. A hidden page
	 * spends no timer. */
	available(boundMs: number | null): Promise<boolean> {
		return new Promise<boolean>((resolve) => {
			let remaining = boundMs;
			let armed: { at: number; cancel: () => void } | null = null;
			const disarm = () => {
				if (armed == null) return;
				armed.cancel();
				if (remaining != null) remaining -= this.#clock.now() - armed.at;
				armed = null;
			};
			const settle = (answer: boolean) => {
				disarm();
				this.#watchers.delete(check);
				resolve(answer);
			};
			const check = () => {
				const kind = this.#state.kind;
				if (kind === "live") settle(true);
				else if (kind === "refused" || kind === "closed") settle(false);
				else if (!this.#visible) disarm();
				else if (armed == null && remaining != null) {
					armed = {
						at: this.#clock.now(),
						cancel: this.#clock.after(Math.max(remaining, 0), () => {
							armed = null;
							settle(false);
						}),
					};
				}
			};
			this.#watchers.add(check);
			check();
		});
	}
	/** Whether the page is in the foreground. A hidden page runs no timer. */
	visibility(visible: boolean): void {
		if (this.#visible === visible) return;
		this.#visible = visible;
		if (visible) {
			const state = this.#state;
			if (state.kind === "waiting" || state.kind === "dialing") this.#watchNotice(state.lostAt);
			this.wake();
			this.#changed();
			return;
		}
		this.#stopTimers();
		const state = this.#state;
		if (state.kind === "waiting") this.#state = { ...state, until: "visible" };
		this.#changed();
	}
	/** Whether the device reports a network. A device with none runs no timer either. */
	connectivity(online: boolean): void {
		if (this.#online === online) return;
		this.#online = online;
		if (online) {
			this.wake();
			return;
		}
		this.#cancelWait?.();
		this.#cancelWait = null;
		const state = this.#state;
		if (state.kind === "waiting") {
			this.#state = { ...state, until: "online" };
			this.#changed();
		}
	}
	/** Hold the quiet bound while a read waits on the link, until the release
	 * this returns. While the page is seen and the link is live, a read that
	 * waits `QUIET_PROBE_MS` brings a probe, and a probe that answers starts the
	 * bound over. A later hold replaces this one. */
	quiet(): () => void {
		const hold = {};
		this.#quiet?.cancel?.();
		this.#quiet = { hold, cancel: null };
		this.#armQuiet();
		return () => {
			if (this.#quiet?.hold !== hold) return;
			this.#quiet.cancel?.();
			this.#quiet = null;
		};
	}
	/** Retire the link. An outstanding dial settles, and none resolves into the page afterward. */
	async close(): Promise<void> {
		this.#epoch++;
		this.#state = { kind: "closed" };
		this.#stopTimers();
		this.#changed();
		await this.#dialed;
	}

	/** The state, the notice or the page's visibility changed. */
	#changed(): void {
		this.#ports.changed();
		for (const watcher of [...this.#watchers]) watcher();
	}
	/** Enter `waiting` as `state` and act on what that state waits for. */
	#waitFor(state: Extract<LinkState, { kind: "waiting" }>): void {
		this.#cancelWait?.();
		this.#cancelWait = null;
		const until = !this.#online ? "online" : !this.#visible ? "visible" : "backoff";
		this.#state = { ...state, until };
		this.#changed();
		if (until !== "backoff") return;
		// A session that says when to ask again is not dialed sooner, except
		// when a person asks (`tryNow`).
		const advised = Math.max(0, state.notBefore - this.#clock.now());
		const wait = state.attempt === 0 ? advised : Math.max(backoff(state.attempt, this.#clock.random()), advised);
		if (wait === 0) {
			this.#dial(state);
			return;
		}
		this.#cancelWait = this.#clock.after(wait, () => {
			this.#cancelWait = null;
			const current = this.#state;
			if (current.kind === "waiting") this.#dial(current);
		});
	}
	#dial(from: Extract<LinkState, { kind: "waiting" }>): void {
		const epoch = ++this.#epoch;
		const generation = ++this.#minted;
		this.#state = { kind: "dialing", lostAt: from.lostAt, attempt: from.attempt, cause: from.cause };
		this.#changed();
		let installed = false;
		// A dial the page closed under goes live nowhere.
		const live = () => {
			if (installed || epoch !== this.#epoch) return;
			installed = true;
			this.#revive(from.attempt, generation);
		};
		// A host that resolves without calling `live` broke its contract, and
		// the dial fails with that broken contract as its cause.
		this.#dialed = this.#ports.dial(live).then(() => {
			invariant(installed || epoch !== this.#epoch, "a dial that resolves has put its link in place");
		}).catch((error: unknown) => {
			if (!installed && epoch === this.#epoch) this.#failed(from, error);
		});
	}
	#revive(attempt: number, generation: number): void {
		this.#stopTimers();
		this.#state = { kind: "live" };
		this.#generation = generation;
		this.#revived = { at: this.#clock.now(), attempt };
		// The new link's read may already hold the quiet bound.
		this.#armQuiet();
		this.#changed();
	}
	/** A dial failed. One that time clears waits and dials again. Anything else
	 * is the session's answer, or a failure inside the page, which the notice
	 * shows until a person asks to try again. */
	#failed(from: Extract<LinkState, { kind: "waiting" }>, cause: unknown): void {
		const verdict = dialVerdict(cause);
		if (verdict === "wait") {
			const advised = roomsErrorIn(cause)?.retryAfterMs;
			const notBefore = advised == null ? 0 : this.#clock.now() + advised;
			this.#waitFor({ ...from, attempt: from.attempt + 1, cause, notBefore });
			return;
		}
		this.#stopTimers();
		this.#state = { kind: "refused", cause, answered: verdict === "answered" };
		this.#changed();
	}
	#probe(): void {
		if (this.#probing != null) return;
		const stamp = { generation: this.#generation };
		const probe = { cancel: () => {} };
		this.#probing = probe;
		const settle = (cause: unknown, failed: boolean) => {
			// A probe the page abandoned, or one already answered, says nothing.
			if (this.#probing !== probe) return;
			probe.cancel();
			this.#probing = null;
			if (failed) this.lost(cause, stamp);
			// A refusal the session answered leaves the link live, so the bound starts over.
			this.#armQuiet();
		};
		probe.cancel = this.#clock.after(
			PROBE_BACKSTOP_MS,
			() => settle(new RoomsError(SESSION_UNREACHABLE, "the session did not answer"), true),
		);
		this.#ports.probe().then(() => settle(null, false), (error: unknown) => settle(error, true));
	}
	/** Redraw when the notice's thresholds pass, while the page can be seen. */
	#watchNotice(lostAt: number): void {
		for (const cancel of this.#cancelNotice) cancel();
		this.#cancelNotice = [];
		if (!this.#visible) return;
		for (const threshold of [NOTICE_AFTER_MS, LINK_WAIT_MS]) {
			const remaining = lostAt + threshold - this.#clock.now();
			if (remaining > 0) this.#cancelNotice.push(this.#clock.after(remaining, () => this.#ports.changed()));
		}
	}
	/** Start the quiet bound over for the read that holds it. */
	#armQuiet(): void {
		const quiet = this.#quiet;
		if (quiet == null) return;
		quiet.cancel?.();
		quiet.cancel = null;
		if (this.#state.kind !== "live" || !this.#visible) return;
		quiet.cancel = this.#clock.after(QUIET_PROBE_MS, () => {
			quiet.cancel = null;
			this.#probe();
		});
	}
	#disarmQuiet(): void {
		this.#quiet?.cancel?.();
		if (this.#quiet != null) this.#quiet.cancel = null;
	}
	#stopTimers(): void {
		this.#disarmQuiet();
		this.#probing?.cancel();
		this.#probing = null;
		this.#cancelWait?.();
		this.#cancelWait = null;
		for (const cancel of this.#cancelNotice) cancel();
		this.#cancelNotice = [];
	}
}
