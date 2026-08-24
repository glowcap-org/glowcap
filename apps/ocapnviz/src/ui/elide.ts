/**
 * Shortening an opaque identifier for display.
 *
 * A leaf: no React, no tokens, no engine. It sits apart from
 * `identifier.tsx` (which re-exports it, so panels keep one import) because
 * the stage needs the same shortening with no DOM in sight — the label a
 * node wears is measured by the layout solver long before anything draws it.
 */

/** Characters kept at each end of an elided identifier. Eight hex
 *  characters is thirty-two bits, which is far more than a reader needs
 *  to tell two keys apart by eye. */
export const IDENTIFIER_END_CHARS = 8;

/** The length at which eliding starts to pay. Below it the ellipsis and
 *  the two kept ends are nearly the whole string, so the reader loses the
 *  middle and gains no room. */
export const IDENTIFIER_ELIDE_ABOVE = IDENTIFIER_END_CHARS * 2 + 4;

/** An opaque identifier as display text: whole when it is short, and
 *  otherwise its head and tail around an ellipsis. */
export function elideIdentifier(value: string): string {
	if (value.length <= IDENTIFIER_ELIDE_ABOVE) return value;
	const head = value.slice(0, IDENTIFIER_END_CHARS);
	const tail = value.slice(value.length - IDENTIFIER_END_CHARS);
	return `${head}…${tail}`;
}
