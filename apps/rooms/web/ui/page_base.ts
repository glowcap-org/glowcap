/// <reference lib="dom" />
// Where this build of the page is served from. The build writes the path into
// page.html's `<base>` element, `/` by default, and the browser exposes it as
// `document.baseURI`. That element is the one authority for the page's files
// and its router, so one build works at whatever path the build named. A
// server route the page reads sits under the base too, through `pageRoute`.

import { invariant } from "../../lib/invariant.ts";

/** The page base as a URL, always ending in `/`. */
export function pageBase(): URL {
	return new URL(".", document.baseURI);
}

/** The router's basename: the base path without its trailing `/`, and `/` at
 * the root, which is the form react-router expects. */
export function routerBasename(base: URL = pageBase()): string {
	const path = base.pathname.replace(/\/$/, "");
	return path === "" ? "/" : path;
}

/** The address bar's path inside the page, starting with `/`, as the router
 * sees it. An address outside the base reads as the base itself. */
export function pagePath(pathname: string = location.pathname, base: URL = pageBase()): string {
	const root = base.pathname;
	if (pathname === root.replace(/\/$/, "")) return "/";
	return pathname.startsWith(root) ? `/${pathname.slice(root.length)}` : "/";
}

/** Whether a Rooms server sent this page, so its routes under the base can
 * answer. A static export marks its page `rooms-host` `static`, and asking it
 * for a route only earns a 404. */
export function servedByRooms(
	mark: string | null = document.querySelector('meta[name="rooms-host"]')?.getAttribute("content") ?? null,
): boolean {
	return mark !== "static";
}

/** The query key a host's 404 page hands a deep link under, when the host
 * serves one file per address and so cannot answer a path below the page. */
export const PATH_OFFER = "path";

/** The address to stand at for a path handed over under `PATH_OFFER`: that
 * path below the base, with the query it carried and the hash kept. A path
 * that would leave the base reads as the base itself. Null when none was. */
export function pathOffer(page: URL, base: URL = pageBase()): URL | null {
	const offered = page.searchParams.get(PATH_OFFER);
	if (offered == null) return null;
	const at = new URL(offered.replace(/^\/+/, ""), base);
	const inside = at.origin === base.origin && at.pathname.startsWith(base.pathname);
	const rest = inside ? at : new URL(base);
	rest.hash = page.hash;
	return rest;
}

/** The address a reload asks a static host for, or null where reloading the
 * address as it stands is answered. A Rooms server answers every path under
 * the base with the page. A static host answers only the page's own file, so a
 * place below the base goes under `PATH_OFFER`, in the form `pathOffer` reads
 * back. A host whose 404 page hands deep links over would get there by a
 * failed request. A host without one, as a development preview is, would
 * strand the reader on its own 404. */
export function reloadAddress(page: URL, base: URL = pageBase(), served: boolean = servedByRooms()): URL | null {
	if (served) return null;
	const below = pagePath(page.pathname, base).slice(1);
	if (below === "") return null;
	const at = new URL(base);
	at.searchParams.set(PATH_OFFER, below + page.search);
	at.hash = page.hash;
	return at;
}

/** Load the page again where it stands. The one way the page reloads itself,
 * so each reload asks its host for an address that host answers. */
export function reloadPage(): void {
	const at = reloadAddress(new URL(location.href));
	if (at == null) location.reload();
	else location.replace(at);
}

/** A server route under the page base, such as `locator`. A name starting
 * with `/` would leave the base, so it is refused. */
export function pageRoute(name: string, base: URL = pageBase()): URL {
	invariant(!name.startsWith("/"), `page route ${name} must be relative to the page base`);
	return new URL(name, base);
}
