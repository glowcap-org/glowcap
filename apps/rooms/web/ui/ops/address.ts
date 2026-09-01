// Where an address stands in the /ops namespace: not in it at all, on the
// index, or on a segment. `App` reads this to decide what the content cell
// draws; the route owns what standing there does.

export function opsAddressOf(
	pathname: string,
): { on: false } | { on: true; segment: string | null } {
	if (pathname === "/ops" || pathname === "/ops/") return { on: true, segment: null };
	if (!pathname.startsWith("/ops/")) return { on: false };
	const segment = decodeURIComponent(pathname.slice("/ops/".length));
	return { on: true, segment: segment === "" ? null : segment };
}
