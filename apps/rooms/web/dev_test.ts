import { assertEquals, assertThrows } from "@std/assert";
import { backendFromOutput, parseDevelopmentLaunch } from "./dev.ts";
import { backendProxy, developmentAllowedHosts, developmentListen, developmentPort } from "./vite.config.ts";

Deno.test("the development launch keeps server arguments separate from its public port", () => {
	assertEquals(parseDevelopmentLaunch(["/tmp/rooms-web", "8123", "--transport=tcp"]), {
		web: "/tmp/rooms-web",
		port: 8123,
		args: ["--transport=tcp"],
	});
	assertThrows(() => parseDevelopmentLaunch([]), Error, "rooms-web executable");
	assertThrows(() => parseDevelopmentLaunch(["rooms-web", "0"]), Error, "integer from 1 through 65535");
});

Deno.test("the readiness report yields only a loopback backend", () => {
	assertEquals(
		backendFromOutput("rooms: serving\n\n  web ui           http://localhost:43129\n"),
		"http://127.0.0.1:43129",
	);
	assertEquals(backendFromOutput("web ui http://example.test:43129\n"), null);
	assertEquals(backendFromOutput("web ui http://localhost:0\n"), null);
});

Deno.test("the Vite listener is loopback by default and explicit when container-published", () => {
	assertEquals(developmentListen(undefined), { host: "127.0.0.1" });
	assertEquals(developmentListen("localhost"), { host: "localhost" });
	assertEquals(developmentListen("0.0.0.0"), { host: "0.0.0.0" });
	assertEquals(developmentPort(undefined), 8080);
	assertEquals(developmentPort("8123"), 8123);
	assertThrows(() => developmentPort("free"), Error, "integer from 1 through 65535");
});

Deno.test("the development server answers to a tailnet name as well as an address", () => {
	// Vite allows an address and `localhost` on its own. A name has to be listed,
	// and a leading dot covers everything under it, so one entry reaches any
	// machine in a tailnet.
	assertEquals(developmentAllowedHosts(undefined), [".ts.net"]);
	assertEquals(developmentAllowedHosts("  "), [".ts.net"]);
	assertEquals(developmentAllowedHosts("rooms.example"), ["rooms.example"]);
	assertEquals(developmentAllowedHosts("rooms.example, .ts.net ,"), ["rooms.example", ".ts.net"]);
});

Deno.test("the development proxy accepts only the ephemeral loopback backend", () => {
	const proxy = backendProxy("http://127.0.0.1:43129");
	assertEquals(Object.values(proxy), [{ target: "http://127.0.0.1:43129", ws: true }]);
	assertThrows(() => backendProxy("http://rooms.example:8000"), Error, "loopback Rooms backend");
	assertThrows(() => backendProxy("http://127.0.0.1:99999"), Error, "loopback Rooms backend");
});
