// The page base: where one build of the page is served from, and what a host
// that serves one file per address hands over through its 404 page.
import { assertEquals } from "./assert.ts";
import { PATH_OFFER, pathOffer, reloadAddress } from "../web/ui/page_base.ts";

Deno.test("a path a static host handed over opens inside the page base", () => {
	const base = new URL("https://glowcap.org/rooms/app/");
	const handed = (path: string, hash = "") =>
		new URL(`${base.href}?${PATH_OFFER}=${encodeURIComponent(path)}${hash}`);
	assertEquals(pathOffer(handed("room/workshop"), base)?.href, "https://glowcap.org/rooms/app/room/workshop");
	assertEquals(
		pathOffer(handed("room/workshop?server=http%3A%2F%2Flocalhost%3A8080%2F", "#attach=x"), base)?.href,
		"https://glowcap.org/rooms/app/room/workshop?server=http%3A%2F%2Flocalhost%3A8080%2F#attach=x",
	);
	assertEquals(pathOffer(handed("../../admin"), base)?.href, base.href);
	assertEquals(pathOffer(handed("//evil.example/x"), base)?.href, "https://glowcap.org/rooms/app/evil.example/x");
	assertEquals(pathOffer(new URL(base), base), null);
});

Deno.test("a static page reloads at an address its host answers, and opens where it stood", () => {
	const base = new URL("https://glowcap.org/rooms/app/");
	for (
		const stood of [
			"https://glowcap.org/rooms/app/join#address=ocapn%3A%2F%2Fa.iroh",
			"https://glowcap.org/rooms/app/join/#address=ocapn%3A%2F%2Fa.iroh",
			"https://glowcap.org/rooms/app/room/workshop?dm=1#dir=",
			"https://glowcap.org/rooms/app/dm/ada",
		]
	) {
		const asked = reloadAddress(new URL(stood), base, false);
		assertEquals(asked?.pathname, base.pathname, stood);
		assertEquals(asked == null ? null : pathOffer(asked, base)?.href, stood);
	}
	assertEquals(reloadAddress(new URL(`${base.href}#attach=x`), base, false), null);
	assertEquals(reloadAddress(new URL("https://glowcap.org/rooms/app"), base, false), null);
});

Deno.test("a page a Rooms server sent reloads the address it stands at", () => {
	const base = new URL("http://localhost:8080/");
	assertEquals(reloadAddress(new URL("http://localhost:8080/room/workshop#dir="), base, true), null);
});
