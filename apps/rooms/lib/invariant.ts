/** Assert an internal contract without assigning a refusal code or retry advice. */
export function invariant(condition: unknown, diagnostic: string): asserts condition {
	if (!condition) throw new Error(diagnostic);
}
