// The one link an attached page keeps to its shared session. This owns when
// the link is lost, when to dial it again, and what a person is told while it
// is gone. The session owns the handles, and supplies dial, probe and report.
import { REQUEST_TIMEOUT_MS } from "../../../../lib/limits.ts";
import { RoomsError, roomsErrorIn, SESSION_UNREACHABLE, structuredFailure } from "../../../../lib/error_codes.ts";
import { connectionLost } from "../../../../lib/text/failure.ts";

export const BACKOFF_FIRST_MS = 1_000;
export const BACKOFF_CEILING_MS = 30_000;
/** A share of each wait that jitter may remove, so pages that lost one session together do not return together. */
const BACKOFF_JITTER = 0.2;
export const PROBE_MS = 5_000;
export const NOTICE_AFTER_MS = 1_500;
export const STUCK_AFTER_MS = 30_000;
/** How long a send waits for a link to return. Recovery from a connection that
 * carries nothing takes one request's time to notice it, one to close it, and
 * one to dial again, so a shorter wait refuses a send recovery would have kept. */
export const RECOVERY_WAIT_MS = 3 * REQUEST_TIMEOUT_MS;

export type LinkState =
	| { readonly kind: "live" }
	| {
		readonly kind: "waiting";
		readonly lostAt: number;
		/** Dials that failed since the loss. */
		readonly attempt: number;
		readonly cause: unknown;
		readonly until: "backoff" | "visible" | "online";
	}
	| { readonly kind: "dialing"; readonly lostAt: number; readonly attempt: number; readonly cause: unknown }
	/** The session answered the dial with a refusal, or the page could not dial. No timer retries it. */
	| { readonly kind: "refused"; readonly cause: unknown; readonly answered: boolean }
	| { readonly kind: "closed" };

/** What the page says about the link, or null while nothing is worth saying. */
export type LinkNotice = "reconnecting" | "offline" | "stuck" | "refused" | "failed";

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

export interface LinkPorts {
	/** Replace everything held over the lost link, or reject with why it could not. */
	dial(): Promise<void>;
	/** Resolve once the current link answers, or reject. */
	probe(): Promise<void>;
	/** The state or the notice changed. */
	changed(): void;
	/** A failure no retry will clear. */
	report(error: unknown): void;
}

/** The wait before dial number `attempt`, which counts the failed ones. */
export function backoff(attempt: number, random: number): number {
	const wait = Math.min(BACKOFF_FIRST_MS * 2 ** Math.max(attempt - 1, 0), BACKOFF_CEILING_MS);
	return Math.round(wait * (1 - BACKOFF_JITTER * random));
}

/** Whether a failed dial says only that the session cannot be reached yet.
 * The Rust dial names that case `session-unreachable` and lets every refusal
 * the session answered keep its own code. A connection that broke after the
 * dial answered is the same case. Anything else is an answer, or a failure
 * inside the page. */
export function unreachable(error: unknown): boolean {
	return connectionLost(error) || roomsErrorIn(error)?.code === SESSION_UNREACHABLE;
}

export class ManagedLink {
	readonly #ports: LinkPorts;
	readonly #clock: LinkClock;
	#state: LinkState = { kind: "live" };
	#visible = true;
	#online = true;
	/** Changes whenever an outstanding dial or probe stops being the current one. */
	#epoch = 0;
	#dialing: Promise<void> = Promise.resolve();
	#cancelWait: (() => void) | null = null;
	#cancelNotice: (() => void)[] = [];
	#lostWhileDialing: { cause: unknown } | null = null;
	/** The probe now waiting for its answer, which a hidden page abandons. */
	#probing: { cancel: () => void } | null = null;
	/** Callers waiting for the link to come back, each told of every change. */
	readonly #watchers = new Set<() => void>();

	constructor(ports: LinkPorts, clock: LinkClock = realClock) {
		this.#ports = ports;
		this.#clock = clock;
	}
	get state(): LinkState {
		return this.#state;
	}
	get live(): boolean {
		return this.#state.kind === "live";
	}
	/** Why the link is gone, or null while it is live. */
	get cause(): unknown {
		const state = this.#state;
		return state.kind === "waiting" || state.kind === "dialing" || state.kind === "refused" ? state.cause : null;
	}
	get notice(): LinkNotice | null {
		const state = this.#state;
		if (state.kind === "refused") return state.answered ? "refused" : "failed";
		if (state.kind !== "waiting" && state.kind !== "dialing") return null;
		const gone = this.#clock.now() - state.lostAt;
		if (gone < NOTICE_AFTER_MS) return null;
		if (state.kind === "waiting" && state.until === "online") return "offline";
		return gone >= STUCK_AFTER_MS ? "stuck" : "reconnecting";
	}

	/** A read or a command failed. Only a lost connection ends a link, whether
	 * it is live or the dial that replaces it has just finished. */
	lost(cause: unknown): void {
		if (!connectionLost(cause)) return;
		const state = this.#state;
		if (state.kind === "dialing") {
			this.#lostWhileDialing ??= { cause };
			return;
		}
		if (state.kind !== "live") return;
		this.#epoch++;
		this.#waitFor({ kind: "waiting", lostAt: this.#clock.now(), attempt: 0, cause, until: "backoff" });
		this.#watchNotice(this.#clock.now());
	}
	/** The page came back to the foreground or the network returned. A live link
	 * is probed. A lost one dials now with a fresh backoff. A refused one stays
	 * refused until a person asks. */
	wake(): void {
		const state = this.#state;
		switch (state.kind) {
			case "live":
				// A hidden page spends nothing. It is probed when it is seen.
				if (this.#visible) this.#probe();
				return;
			case "waiting":
				this.#waitFor({ ...state, attempt: 0 });
				return;
			default:
				return;
		}
	}
	/** A person asked to try now. Their word that a network exists outweighs the
	 * device's, which a wrong report would hold offline for good. */
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
				until: "backoff",
			});
			this.#watchNotice(this.#clock.now());
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
	/** Retire the link. An outstanding dial settles, and none resolves into the page afterward. */
	async close(): Promise<void> {
		this.#epoch++;
		this.#state = { kind: "closed" };
		this.#stopTimers();
		this.#changed();
		await this.#dialing;
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
		if (state.attempt === 0) {
			this.#dial(state);
			return;
		}
		this.#cancelWait = this.#clock.after(backoff(state.attempt, this.#clock.random()), () => {
			this.#cancelWait = null;
			const current = this.#state;
			if (current.kind === "waiting") this.#dial(current);
		});
	}
	#dial(from: Extract<LinkState, { kind: "waiting" }>): void {
		const epoch = ++this.#epoch;
		this.#state = { kind: "dialing", lostAt: from.lostAt, attempt: from.attempt, cause: from.cause };
		this.#lostWhileDialing = null;
		this.#changed();
		this.#dialing = this.#ports.dial().then(() => {
			if (epoch !== this.#epoch) return;
			const lost = this.#lostWhileDialing;
			this.#lostWhileDialing = null;
			if (lost != null) this.#failed(from, lost.cause);
			else this.#revive();
		}, (error: unknown) => {
			if (epoch === this.#epoch) this.#failed(from, error);
		});
	}
	#revive(): void {
		this.#stopTimers();
		this.#state = { kind: "live" };
		this.#changed();
	}
	#failed(from: Extract<LinkState, { kind: "waiting" }>, cause: unknown): void {
		if (unreachable(cause)) {
			this.#waitFor({ ...from, attempt: from.attempt + 1, cause });
			return;
		}
		this.#stopTimers();
		this.#state = { kind: "refused", cause, answered: structuredFailure(cause) != null };
		this.#ports.report(cause);
		this.#changed();
	}
	#probe(): void {
		if (this.#probing != null) return;
		const epoch = this.#epoch;
		const probe = { cancel: () => {} };
		this.#probing = probe;
		const settle = (cause: unknown, failed: boolean) => {
			// A probe the page abandoned, or one already answered, says nothing.
			if (this.#probing !== probe) return;
			probe.cancel();
			this.#probing = null;
			if (failed && epoch === this.#epoch) this.#lose(cause);
		};
		probe.cancel = this.#clock.after(
			PROBE_MS,
			() => settle(new RoomsError(SESSION_UNREACHABLE, "the session did not answer"), true),
		);
		this.#ports.probe().then(() => settle(null, false), (error: unknown) => settle(error, true));
	}
	/** A probe got no answer, whatever its failure said: the link is not serving. */
	#lose(cause: unknown): void {
		if (this.#state.kind !== "live") return;
		this.#epoch++;
		this.#waitFor({ kind: "waiting", lostAt: this.#clock.now(), attempt: 0, cause, until: "backoff" });
		this.#watchNotice(this.#clock.now());
	}
	/** Redraw when the notice's thresholds pass, while the page can be seen. */
	#watchNotice(lostAt: number): void {
		for (const cancel of this.#cancelNotice) cancel();
		this.#cancelNotice = [];
		if (!this.#visible) return;
		for (const threshold of [NOTICE_AFTER_MS, STUCK_AFTER_MS]) {
			const remaining = lostAt + threshold - this.#clock.now();
			if (remaining > 0) this.#cancelNotice.push(this.#clock.after(remaining, () => this.#ports.changed()));
		}
	}
	#stopTimers(): void {
		this.#probing?.cancel();
		this.#probing = null;
		this.#cancelWait?.();
		this.#cancelWait = null;
		for (const cancel of this.#cancelNotice) cancel();
		this.#cancelNotice = [];
	}
}
