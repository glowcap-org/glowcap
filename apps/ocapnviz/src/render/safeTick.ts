/**
 * Wrappers that quarantine PixiJS errors that fall outside React's
 * lifecycle. Two surfaces:
 *
 *   - safeTick: wrap a ticker callback so a per-frame throw is
 *     reported once (via the error bus) and the ticker keeps
 *     running. A bare `app.ticker.add(cb)` would lose the
 *     subsequent frames if `cb` throws, because the throw escapes
 *     into Pixi's rAF loop and Pixi de-registers nothing on its
 *     own — but the React boundary doesn't see it either (the
 *     callback is invoked outside React's render path).
 *
 *   - safeListener: same shape for `addEventListener` callbacks
 *     (window resize, Pixi pointer events, etc.).
 *
 * Both helpers de-dupe repeated errors at most once per second per
 * callsite so a ticker that throws every frame doesn't spam 60
 * toasts per second.
 */

import { internalError } from "../engine/errors.ts";
import { pushError } from "../ui/error/error-bus.ts";

const DEDUPE_MS = 1000;

interface DedupeState {
	lastMessage: string;
	lastAt: number;
}

function tryEmit(state: DedupeState, caught: unknown): void {
	const message = caught instanceof Error ? caught.message : String(caught);
	const now = Date.now();
	if (state.lastMessage === message && now - state.lastAt < DEDUPE_MS) {
		state.lastAt = now;
		return;
	}
	state.lastMessage = message;
	state.lastAt = now;
	pushError({ error: internalError(caught), source: "window" });
}

/** Wrap a Pixi ticker callback so per-frame throws emit to the bus
 * (deduped) instead of escaping into Pixi's rAF loop. */
export function safeTick<Args extends unknown[]>(
	fn: (...args: Args) => void,
): (...args: Args) => void {
	const state: DedupeState = { lastMessage: "", lastAt: 0 };
	return (...args: Args) => {
		try {
			fn(...args);
		} catch (caught) {
			tryEmit(state, caught);
		}
	};
}

/** Wrap a DOM event listener callback. Same dedupe shape as `safeTick`. */
export function safeListener<E extends Event>(
	fn: (event: E) => void,
): (event: E) => void {
	const state: DedupeState = { lastMessage: "", lastAt: 0 };
	return (event: E) => {
		try {
			fn(event);
		} catch (caught) {
			tryEmit(state, caught);
		}
	};
}
