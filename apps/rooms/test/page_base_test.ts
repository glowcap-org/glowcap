// The page base: where one build of the page is served from, and what a host
// that serves one file per address hands over through its 404 page.
import { assertEquals } from "./assert.ts";
import { PATH_OFFER, pathOffer } from "../web/ui/page_base.ts";

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
