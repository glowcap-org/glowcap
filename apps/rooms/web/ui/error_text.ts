// Whether a refusal is too much to keep next to the control it answers.

/** Whether the rest of an error belongs in a card rather than only where it
 * appeared.
 *
 * A short refusal stays with the field, the notice, or the tile it describes.
 * A locator, a paragraph, or anything that would shove that control off the
 * page is the same fact: the place it appeared still says that something went
 * wrong, and the card is where the rest of it is read. */
export function needsErrorDetail(text: string): boolean {
	if (text.includes("\n")) return true;
	if (/ocapn:\/\//i.test(text)) return true;
	return [...text].length > 96;
}

/** What the card is called, from the kind of notice that opened it. */
export function errorDetailTitle(kind: "failure" | "warning" | "success"): string {
	return kind === "failure" ? "What went wrong" : "The full message";
}

/** A refusal in the reader's words for a pasted link the peer could not read.
 *
 * The parser's sentence names the shape it could not read, which says what to
 * do only once it is said as that: paste the whole link. The parser's own
 * words stay after it, for whoever is debugging. `noun` names what the link
 * was meant to be, so the sentence is about the reader's mistake and not the
 * parser's. */
export function locatorRefusal(why: string, noun: string): string {
	if (why === "" || !why.startsWith("pancake error")) return why;
	return `This is not a whole ${noun}. Paste everything that was printed, from ocapn:// to the end. (${why})`;
}
