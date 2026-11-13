// Delays govern decoration only. Admission, refusal and settled controls never wait.
import { Children, createElement, isValidElement, type ReactNode, useEffect, useMemo, useReducer } from "react";
import { controlInProgress } from "../../lib/text/controls.ts";

export const PRESENTATION = { busy: 400, feedback: 500, sending: 1000, connection: 2000 } as const;
interface PresentationClock {
	now(): number;
	later(work: () => void, ms: number): () => void;
}
const clock: PresentationClock = {
	now: () => performance.now(),
	later: (work, ms) => {
		const timer = setTimeout(work, ms);
		return () => clearTimeout(timer);
	},
};

/** Tokens fence retired timers. Monotonic time also handles a sleeping tab.
 * Completion clears progress immediately. A surface with a success treatment
 * may keep that treatment for `remaining`, never the old running state. */
export class PresentationRun {
	#token: unknown = null;
	#generation = 0;
	#started = 0;
	#shown: number | null = null;
	#cancel: (() => void) | null = null;
	constructor(readonly changed: () => void, readonly time: PresentationClock = clock) {}
	start(token: unknown, delay: number): void {
		if (this.#token === token) return;
		this.close();
		this.#token = token;
		const generation = ++this.#generation;
		this.#started = this.time.now();
		const check = () => {
			if (this.#token !== token || this.#generation !== generation) return;
			const remaining = delay - (this.time.now() - this.#started);
			if (remaining > 0) this.#cancel = this.time.later(check, remaining);
			else {
				this.#shown ??= this.time.now();
				this.#cancel = null;
				this.changed();
			}
		};
		this.#cancel = this.time.later(check, delay);
	}
	visible(token: unknown, delay: number): boolean {
		const visible = this.#token === token && this.time.now() - this.#started >= delay;
		if (visible) this.#shown ??= this.time.now();
		return visible;
	}
	get remaining(): number {
		return this.#shown == null ? 0 : Math.max(0, PRESENTATION.feedback - (this.time.now() - this.#shown));
	}
	close(): void {
		this.#cancel?.();
		this.#cancel = null;
		this.#token = null;
		this.#shown = null;
	}
}

/** A tab that slept past the delay shows a pending wait on return, so only a
 * pending wait listens for the tab becoming visible. Returns the cleanup. */
export function watchVisibility(pending: boolean, wake: () => void, target: EventTarget | undefined): () => void {
	if (!pending || target == null) return () => {};
	target.addEventListener("visibilitychange", wake);
	return () => target.removeEventListener("visibilitychange", wake);
}

export function useProgress(pending: boolean, delay: number = PRESENTATION.busy, identity: unknown = pending): boolean {
	const [, redraw] = useReducer((value: number) => value + 1, 0);
	const run = useMemo(() => new PresentationRun(redraw), []);
	useEffect(() => {
		if (pending) run.start(identity, delay);
		else run.close();
		const unwatch = watchVisibility(pending, redraw, (globalThis as { document?: EventTarget }).document);
		return () => {
			run.close();
			unwatch();
		};
	}, [run, pending, delay, identity]);
	return pending && run.visible(identity, delay);
}

// A mounted, quiet live region announces a delayed wait once. It is outside
// the disabled control, whose accessible name continues to name its action.
function controlText(node: ReactNode): string {
	return Children.toArray(node).map((child): string => {
		if (typeof child === "string" || typeof child === "number") return String(child);
		return isValidElement<{ children?: ReactNode }>(child) ? controlText(child.props.children) : "";
	}).join(" ").trim();
}
export function ControlProgress({ active, label }: { active: boolean; label: ReactNode }) {
	return createElement(
		"span",
		{ className: "control-progress", role: "status", "aria-atomic": true },
		active ? controlInProgress(controlText(label)) : "",
	);
}
