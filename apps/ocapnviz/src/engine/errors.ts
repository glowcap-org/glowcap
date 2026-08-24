/**
 * Engine-side error vocabulary.
 *
 * Every user-visible error originates here. UI surfaces (inline field,
 * toast, modal) read the same shape and pick a presentation by context.
 * `recovery` is mandatory — never ship an error a user can't act on.
 */

export type EngineErrorCode =
	| "collision" // user supplied an ID that already exists
	| "not-found" // referenced entity doesn't exist
	| "validation" // intent payload failed a schema or invariant check
	| "import" // imported document failed to parse or has bad IDs
	| "internal"; // unexpected exception inside the engine

export interface EngineError {
	code: EngineErrorCode;
	title: string;
	detail: string;
	recovery: string;
	cause?: unknown;
}

export type EngineResult<T> =
	| { ok: true; value: T }
	| { ok: false; error: EngineError };

export const ok = <T>(value: T): EngineResult<T> => ({ ok: true, value });

export const err = <T = never>(error: EngineError): EngineResult<T> => ({
	ok: false,
	error,
});

export function collisionError(
	category: "peer" | "session" | "message",
	id: string,
): EngineError {
	return {
		code: "collision",
		title: "ID already in use",
		detail: `${category} ${id} already exists in this document.`,
		recovery: `Pick a different ID, or rename ${id} first.`,
	};
}

export function notFoundError(
	category: "peer" | "session" | "message",
	id: string,
): EngineError {
	return {
		code: "not-found",
		title: `${category.charAt(0).toUpperCase()}${category.slice(1)} not found`,
		detail: `No ${category} with id ${id} exists in this document.`,
		recovery: "The entity may have been deleted. Reload if you expected it.",
	};
}

export function validationError(
	detail: string,
	recovery: string,
): EngineError {
	return {
		code: "validation",
		title: "Invalid edit",
		detail,
		recovery,
	};
}

export function importError(detail: string, recovery: string): EngineError {
	return {
		code: "import",
		title: "Import failed",
		detail,
		recovery,
	};
}

/** The title every unexpected failure wears. Its own constant because two
 *  surfaces show it — the bus-fed modal, and the React error boundary, which
 *  trips before the bus has an error to read — and a heading spelled twice is
 *  a heading that drifts. */
export const INTERNAL_ERROR_TITLE = "Unexpected error";

export function internalError(cause: unknown): EngineError {
	const message = cause instanceof Error ? cause.message : String(cause);
	return {
		code: "internal",
		title: INTERNAL_ERROR_TITLE,
		detail: message,
		recovery: "Try the action again. If it keeps happening, reload the page.",
		cause,
	};
}
