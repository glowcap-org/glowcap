/** A deterministic RFC 4122 registration ID for schema and state fixtures. */
export function registrationId(sequence: number): string {
	if (!Number.isSafeInteger(sequence) || sequence < 0 || sequence > 0xffffffffffff) {
		throw new Error("test registration ID sequence must fit 48 bits");
	}
	return `00000000-0000-4000-8000-${sequence.toString(16).padStart(12, "0")}`;
}
