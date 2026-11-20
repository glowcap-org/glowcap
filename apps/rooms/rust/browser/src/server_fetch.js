// Browser reads from the selected Rooms server, shared by the page and Wasm.

/**
 * Use the server's login cookie on its own page. Across origins, try a public
 * read first. An HTTPS server behind a login may reject that read or redirect
 * it, which CORS can hide. Retry with cookies only at the selected address.
 * Both attempts share the caller's deadline and refuse redirects.
 * @param {string | URL} address
 * @param {RequestInit} options
 * @param {(address: URL, init: RequestInit) => Promise<Response>} read
 * @returns {Promise<Response>}
 */
export async function fetchRoomsServer(address, options, read = fetch) {
	const url = new URL(address);
	/** @type {RequestInit} */
	const request = { ...options, method: "GET", redirect: "error" };
	if (url.origin === globalThis.location?.origin || url.protocol !== "https:") {
		return read(url, { ...request, credentials: "same-origin" });
	}
	let anonymous;
	try {
		anonymous = await read(url, { ...request, credentials: "omit" });
	} catch (error) {
		if (request.signal?.aborted) throw error;
	}
	if (anonymous != null && anonymous.status !== 401 && anonymous.status !== 403) return anonymous;
	let signedIn;
	try {
		signedIn = await read(url, { ...request, credentials: "include" });
	} catch (error) {
		if (anonymous == null || request.signal?.aborted) throw error;
		// A blocked retry must not hide a refusal we could already read.
		return anonymous;
	}
	await anonymous?.body?.cancel();
	return signedIn;
}
