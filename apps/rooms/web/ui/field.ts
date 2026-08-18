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
