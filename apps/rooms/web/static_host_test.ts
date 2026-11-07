import { assertEquals, assertThrows } from "@std/assert";
import { exportedPath, parseStaticLaunch, slashRedirect } from "./static_host.ts";

Deno.test("the static launch serves the hosted page's base unless told another", () => {
	assertEquals(parseStaticLaunch(["/bin/rooms-web", "/gen"]), {
		web: "/bin/rooms-web",
		assets: "/gen",
		base: "/rooms/app/",
		port: 5173,
	});
	assertEquals(parseStaticLaunch(["w", "a", "--base=/", "--port=8093"]), {
		web: "w",
		assets: "a",
		base: "/",
		port: 8093,
	});
	assertThrows(() => parseStaticLaunch([]), Error, "rooms-web executable");
	assertThrows(() => parseStaticLaunch(["w", "a", "--base=/rooms/app"]), Error, "not --base=/rooms/app");
	assertThrows(() => parseStaticLaunch(["w", "a", "--port=0"]), Error, "not --port=0");
	assertThrows(() => parseStaticLaunch(["w", "a", "--open"]), Error, "not --open");
});

Deno.test("a request path names a file under the export, never outside it", () => {
	assertEquals(exportedPath("/site", "/rooms/app/", "/rooms/app/"), "/site");
	assertEquals(exportedPath("/site", "/rooms/app/", "/rooms/app/assets/a.js"), "/site/assets/a.js");
	assertEquals(exportedPath("/site", "/rooms/app/", "/rooms/other/"), null);
	assertEquals(exportedPath("/site", "/rooms/app/", "/rooms/app/%2e%2e/%2e%2e/etc/passwd"), null);
	assertEquals(exportedPath("/site", "/rooms/app/", "/rooms/app/%E0%A4%A"), null);
});

Deno.test("the base without its trailing slash moves to the base, keeping its query", () => {
	assertEquals(
		slashRedirect("/rooms/app/", new URL("http://localhost:5173/rooms/app?server=x")),
		"http://localhost:5173/rooms/app/?server=x",
	);
	assertEquals(slashRedirect("/rooms/app/", new URL("http://localhost:5173/rooms/app/")), null);
	assertEquals(slashRedirect("/rooms/app/", new URL("http://localhost:5173/rooms/ap")), null);
	assertEquals(slashRedirect("/", new URL("http://localhost:5173/")), null);
});
