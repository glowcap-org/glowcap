// The one reading of a caught value as text, for diagnostics that name it.

/** An `Error`'s message, or the value as a string when something else was thrown. */
export function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
