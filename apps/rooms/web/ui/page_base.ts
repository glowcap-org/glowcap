/// <reference lib="dom" />
// Where this build of the page is served from. The build writes the path into
// page.html's `<base>` element, `/` by default, and the browser exposes it as
// `document.baseURI`. That element is the one authority for the page's files
// and its router, so one build works at whatever path the build named. A
// server route the page reads sits under the base too, through `pageRoute`.

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

/** A server route under the page base, such as `locator`. A name starting
 * with `/` would leave the base, so it is refused. */
export function pageRoute(name: string, base: URL = pageBase()): URL {
	if (name.startsWith("/")) throw new Error(`page route ${name} must be relative to the page base`);
	return new URL(name, base);
}
