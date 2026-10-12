/**
 * App-wide error bus. Errors from four sources land here and the UI
 * surfaces (toast, modal, future inline) read from a single channel:
 *
 *   - Engine: forwarded from `engine.onError(...)` in `useEngineErrors`.
 *   - Window: `window.addEventListener("error", ...)` in `main.tsx`.
 *   - Unhandled rejection: `window.addEventListener("unhandledrejection", ...)`.
 *   - React error boundary: `AppErrorBoundary.componentDidCatch`.
 *
 * Singleton, only one process owns the UI, and error
 * surfaces need a stable subscription target that exists before the
 * first React render (the window listeners install before
 * `createRoot`).
 *
 * Errors that arrive before any listener subscribes are dropped on
 * the floor. We do NOT buffer historical errors. There is no useful
 * UX for "play back errors from before the page loaded", and a buffer
 * would mask listener bugs. The window listeners installed in
 * `main.tsx` precede React render so the toast/modal mount with the
 * bus ready.
 */

import type { EngineError } from "../../engine/errors.ts";

export type ErrorSource =
	| "engine"
	| "window"
	| "unhandled-rejection"
	| "react-boundary";

export interface AppError {
	error: EngineError;
	source: ErrorSource;
}

type Listener = (event: AppError) => void;

const listeners = new Set<Listener>();

export function pushError(event: AppError): void {
	for (const listener of listeners) {
		try {
			listener(event);
		} catch (listenerErr) {
			// A listener that throws can't be allowed to starve the rest.
			// Logging here only. We don't push another error
			// through the bus (that would risk a loop).
			console.error("error-bus: listener threw", listenerErr);
		}
	}
}

export function subscribeErrors(listener: Listener): () => void {
	listeners.add(listener);
	return () => {
		listeners.delete(listener);
	};
}

/** Test-only. Resets the listener set. Production code should never
 * call this. */
export function _resetErrorBusForTesting(): void {
	listeners.clear();
}
