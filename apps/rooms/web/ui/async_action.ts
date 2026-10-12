// One owner for a control's asynchronous work: whether it is running, the
// refusal it met, and the way to stop it.
//
// A press starts the work once. A second press while it runs is the same
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

	/** Stop requests cancellation. The original worker owns the control until
	 * it drains, including across a development remount. */
	readonly run = (...args: A): Promise<void> => {
		if (this.#pending != null) return this.#pending;
		if (!this.#open) return Promise.resolve();
		const controller = new AbortController();
		this.#running = controller;
		this.#why = "";
		const work = this.#work();
		let begin!: (value: unknown) => void;
		let refuse!: (reason: unknown) => void;
		const task = this.#pending = new Promise((resolve, reject) => {
			begin = resolve;
			refuse = reject;
		}).then(
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
		this.#changed();
		try {
			begin(work(controller.signal, ...args));
		} catch (error) {
			refuse(error);
		}
		return task;
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
