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
