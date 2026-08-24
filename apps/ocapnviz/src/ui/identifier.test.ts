/**
 * What eliding an opaque identifier has to preserve.
 *
 * The rule is worth a test because both the failures it guards against
 * are silent. A run that keeps only one end still renders, still fits,
 * and reads perfectly well — right up to the moment two keys sharing
 * that end are shown side by side and a reader concludes they are the
 * same key. And a run that elides a short string costs the reader its
 * middle in exchange for no room at all.
 */

import { assert, assertEquals } from "@std/assert";
import { elideIdentifier, IDENTIFIER_ELIDE_ABOVE, IDENTIFIER_END_CHARS } from "./identifier.tsx";

/** A 64-character hex key, the shape an iroh node id arrives in. */
function key(seed: string): string {
	return seed.repeat(64).slice(0, 64);
}

Deno.test("a short identifier is shown whole", () => {
	assertEquals(elideIdentifier("alice"), "alice");
	const atTheLimit = "x".repeat(IDENTIFIER_ELIDE_ABOVE);
	assertEquals(elideIdentifier(atTheLimit), atTheLimit);
});

Deno.test("a long identifier keeps both of its ends", () => {
	const value = key("ab12cd34");
	const shown = elideIdentifier(value);
	assert(
		shown.startsWith(value.slice(0, IDENTIFIER_END_CHARS)),
		`${shown} dropped the head`,
	);
	assert(
		shown.endsWith(value.slice(value.length - IDENTIFIER_END_CHARS)),
		`${shown} dropped the tail`,
	);
	assert(shown.includes("…"), `${shown} does not say it was cut`);
});

Deno.test("two keys sharing a head still read apart", () => {
	const head = "deadbeefdeadbeef";
	const a = `${head}${"1".repeat(48)}`;
	const b = `${head}${"2".repeat(48)}`;
	assert(
		elideIdentifier(a) !== elideIdentifier(b),
		"a shared prefix collapsed two distinct keys into one label",
	);
});

Deno.test("two keys sharing a tail still read apart", () => {
	const tail = "cafebabecafebabe";
	const a = `${"1".repeat(48)}${tail}`;
	const b = `${"2".repeat(48)}${tail}`;
	assert(
		elideIdentifier(a) !== elideIdentifier(b),
		"a shared suffix collapsed two distinct keys into one label",
	);
});

Deno.test("eliding buys room, and the amount is fixed", () => {
	const shown = elideIdentifier(key("0f"));
	assertEquals(shown.length, IDENTIFIER_END_CHARS * 2 + 1);
	assert(
		shown.length < IDENTIFIER_ELIDE_ABOVE,
		"an elided key is no shorter than one shown whole",
	);
});
