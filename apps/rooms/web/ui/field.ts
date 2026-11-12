// Attributes for a field that holds a locator, swiss number, room name, or
// nick: an identifier, not a sentence. Mobile keyboards otherwise capitalize
// the first letter and "correct" the rest, which is how `ocapn://` becomes
// `Ocapn://` and a room name is not the name that was typed. Translation and
// writing suggestions would rewrite it the same way.

export const identifierField = {
	autoCapitalize: "none",
	autoCorrect: "off",
	spellCheck: false,
	autoComplete: "off",
	translate: "no",
} as const;

/** An identifier that is an `ocapn://` address or capability.
 *
 * It is a plain text field that asks a phone for its address keyboard. The
 * browser's own `url` type would add its history suggestions and its
 * validation bubble, and the page already says what is wrong with an address
 * in its own words. A `password` type would hide the link and have the browser
 * and every password manager offer to keep it.
 *
 * A link is nothing a password manager fills, so each one is told to leave the
 * field alone by the attribute it reads: 1Password, LastPass, Bitwarden, and
 * Dashlane, in that order. */
export const addressField = {
	...identifierField,
	type: "text",
	inputMode: "url",
	"data-1p-ignore": true,
	"data-lpignore": "true",
	"data-bwignore": true,
	"data-form-type": "other",
} as const;
