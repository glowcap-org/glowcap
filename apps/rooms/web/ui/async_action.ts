// One owner for a control's asynchronous work: whether it is running, the
// refusal it met, and the way to stop it.
//
// A press starts the work once; a second press while it runs is the same
// press, not another request. The work receives an `AbortSignal` so a stop can
// reach it, and a stopped run reports nothing, because stopping is the
// reader's own answer rather than a failure. A control that goes away aborts
// its run and drops the answer, so a closed card never repaints.

import { useEffect, useMemo, useReducer } from "react";
import { refusalText } from "../../lib/text/failure.ts";

export type ActionWork<A extends unknown[]> = (signal: AbortSignal, ...args: A) => Promise<unknown>;

export class ActionRun<A extends unknown[]> {
	#running: AbortController | null = null;
	#pending: Promise<void> | null = null;
	#why = "";
	#open = true;
	readonly #work: () => ActionWork<A>;
	readonly #changed: () => void;

	constructor(work: () => ActionWork<A>, changed: () => void) {
		this.#work = work;
		this.#changed = changed;
	}

	/** The work is running. Wire it onto the control's `busy`. */
	get busy(): boolean {
		return this.#running != null;
	}

	/** The refusal the last run met, or "" when it met none. */
	get why(): string {
		return this.#why;
	}

	/** Start the work unless a run is in flight; settles when the run does.
	 * A stopped run is not in flight: its answer is already dropped, so the
	 * next press starts fresh work instead of waiting on it. React's
	 * development remount closes and reopens a control between its first
	 * effect and its second, and that second press must reach the work. */
	readonly run = (...args: A): Promise<void> => {
		if (this.#pending != null && !this.#running!.signal.aborted) return this.#pending;
		if (!this.#open) return Promise.resolve();
		const controller = new AbortController();
		this.#running = controller;
		this.#why = "";
		this.#changed();
		const work = this.#work();
		return this.#pending = new Promise((resolve) => resolve(work(controller.signal, ...args))).then(
			() => undefined,
			(error: unknown) => {
				if (!controller.signal.aborted) this.#why = refusalText(error);
			},
		).finally(() => {
			// A stopped run that settles after a fresh press leaves that press alone.
			if (this.#running !== controller) return;
			this.#running = null;
			this.#pending = null;
			if (this.#open) this.#changed();
		});
	};

	/** Stop the run in flight, if its work listens to the signal. */
	readonly cancel = (): void => this.#running?.abort();

	/** Forget the last refusal, for an edit that answers it. */
	readonly clear = (): void => {
		if (this.#why === "") return;
		this.#why = "";
		this.#changed();
	};

	/** The control went away: stop the run and repaint nothing after it. */
	close(): void {
		this.#open = false;
		this.#running?.abort();
	}

	reopen(): void {
		this.#open = true;
	}
}

export function useAsyncAction<A extends unknown[]>(work: ActionWork<A>): ActionRun<A> {
	const [, redraw] = useReducer((turn: number) => turn + 1, 0);
	const latest = useMemo(() => ({ work }), []);
	latest.work = work;
	const action = useMemo(() => new ActionRun(() => latest.work, redraw), []);
	useEffect(() => {
		action.reopen();
		return () => action.close();
	}, [action]);
	return action;
}
