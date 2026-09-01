// What a reader is told about a link they pasted: whether the refusal is too
// much to keep beside the control it answers, and what to say before a link is
// worth trying at all.

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

/** A refusal in the reader's words for a pasted link that was not taken.
 *
 * What arrives here is a native error code and a diagnostic, which says
 * nothing a reader can act on. What they can act on is a paste that stopped
 * short, so the sentence offers that and keeps the original words after it
 * for whoever is debugging.
 *
 * It offers rather than diagnoses, because the same shape carries refusals
 * this cannot tell apart: a peer that answered and declined reads exactly
 * like a link that was never whole. Telling a reader their link is truncated
 * when the peer simply said no sends them to check the one thing that was
 * never wrong. `noun` names what the link was meant to be. */
export function locatorRefusal(why: string, noun: string): string {
	if (why === "" || !why.startsWith("pancake error")) return why;
	return `This ${noun} was refused. Check that you pasted all of it, from ocapn:// to the end. (${why})`;
}

/** What a session capability has to look like before it is worth trying.
 *
 * Both places that take one — the establishment screen and the Settings attach
 * card — ask this first, because the two mistakes it catches are the ones a
 * reader actually makes, and neither is worth a round trip to the peer to
 * find out. The parser's own answer to either is `UriParseError`, which tells
 * a reader nothing about which of their several ocapn:// strings they should
 * have reached for. */
export function sessionCapabilityRefusal(capability: string): string {
	if (capability === "") return "";
	if (!capability.startsWith("ocapn://")) return "Paste the session's ocapn:// capability link.";
	if (!capability.includes("/s/")) {
		return "That is a peer's address rather than a capability it granted. " +
			"The session's own link has a /s/ in it, after the address.";
	}
	return "";
}
