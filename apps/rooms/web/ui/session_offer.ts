// Shared-session capability offers in the URL fragment. Other route fields stay byte for byte.

/** The fragment key a link uses to offer a shared session's use link. The
 * link is a capability, so it rides in the fragment, which a browser never
 * sends to the page's host, and never in the query. */
const SESSION_OFFER = "attach";

/** The fragment's `&`-separated fields as written, split into the offer and
 * the rest. Fields beside the offer are another address's to read, so they
 * pass through byte for byte and are never parsed and written again. */
function offerAndRest(page: URL): { offer: string | null; rest: string[] } {
	const fields = page.hash.slice(1).split("&").filter((field) => field !== "");
	const isOffer = (field: string) => field.startsWith(`${SESSION_OFFER}=`);
	return { offer: fields.find(isOffer) ?? null, rest: fields.filter((field) => !isOffer(field)) };
}

/** Read and remove a shared-session offer from `page`. Only `attach` is
 * consumed. Other fragment fields stay unchanged. Null when no offer exists. */
export function sessionOffer(page: URL): { capability: string; rest: URL } | null {
	const { offer, rest: kept } = offerAndRest(page);
	if (offer === null) return null;
	const rest = new URL(page);
	rest.hash = kept.join("&");
	return { capability: (new URLSearchParams(offer).get(SESSION_OFFER) ?? "").trim(), rest };
}

/** `page` offering `capability` the way `sessionOffer` reads it. */
export function withSessionOffer(page: URL, capability: string): URL {
	const offered = new URL(page);
	const offer = new URLSearchParams({ [SESSION_OFFER]: capability }).toString();
	offered.hash = [...offerAndRest(page).rest, offer].join("&");
	return offered;
}
