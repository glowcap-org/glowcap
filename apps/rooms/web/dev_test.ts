import { assertEquals, assertThrows } from "@std/assert";
import { backendFromOutput, developmentBackendArguments, parseDevelopmentLaunch } from "./dev.ts";
import { fileURLToPath } from "node:url";
import {
	backendProxy,
	developmentAllowedHosts,
	developmentListen,
	developmentPort,
	nearerPackages,
} from "./vite.config.ts";

Deno.test("a package directory nearer the sources than the locked one is found", () => {
	const path = (relative: string) => fileURLToPath(new URL(relative, import.meta.url));
	const locked = path("../node_modules");
	const source = path("./ui/main.tsx");
	const beside = path("./node_modules");
	assertEquals(nearerPackages(source, (directory) => directory === locked), null);
	assertEquals(nearerPackages(source, (directory) => directory === beside || directory === locked), beside);
	const library = path("../lib/room/node_modules");
	assertEquals(nearerPackages(path("../lib/room/model.ts"), (directory) => directory === library), library);
	// Nothing above the app's own directory answers an import from inside it.
	assertEquals(nearerPackages(source, (directory) => directory === path("../../../node_modules")), null);
	// A shared source outside the app has no locked directory above it.
	const shared = path("../../../ui/node_modules");
	assertEquals(nearerPackages(path("../../../ui/mark/field.ts"), (directory) => directory === shared), shared);
	// A package's own imports, and a module outside the repository, are not the sources'.
	assertEquals(nearerPackages(`${locked}/react/index.js`, () => true), null);
	assertEquals(nearerPackages("/elsewhere/module.ts", () => true), null);
});

Deno.test("the development launch keeps server arguments separate from its public port", () => {
	assertEquals(parseDevelopmentLaunch(["/tmp/rooms-web", "8123", "--transport=tcp"]), {
		web: "/tmp/rooms-web",
		port: 8123,
		args: ["--transport=tcp"],
	});
	assertThrows(() => parseDevelopmentLaunch([]), Error, "rooms-web executable");
	assertThrows(() => parseDevelopmentLaunch(["rooms-web", "0"]), Error, "integer from 1 through 65535");
	// The backend options this front sets are refused here by name, not by
	// rooms-web as a repeat.
	assertThrows(
		() => parseDevelopmentLaunch(["rooms-web", "8123", "--http-port=8080"]),
		Error,
		"rooms-dev owns the backend's --http-port",
	);
	assertThrows(
		() => parseDevelopmentLaunch(["rooms-web", "8123", "--no-browser-assets"]),
		Error,
		"--no-browser-assets",
	);
});

Deno.test("the backend is found at the port it announces, never at the address it tells browsers", () => {
	assertEquals(backendFromOutput("ROOMS-WEB-LISTENING 43129\n"), "http://127.0.0.1:43129");
	assertEquals(backendFromOutput("rooms: serving\n\n  web ui           http://localhost:8080\n"), null);
	assertEquals(backendFromOutput("ROOMS-WEB-LISTENING 0\n"), null);
	assertEquals(backendFromOutput("ROOMS-WEB-LISTENING 43129 more\n"), null);
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

Deno.test("development trace defaults reach the backend and explicit routes win", () => {
	const values: Record<string, string> = {
		GLOWCAP_ROOMS_DEV_TRACE_CONNECT: "ws://127.0.0.1:20300/captp",
		GLOWCAP_ROOMS_DEV_TRACE_PUBLISH: "ws://127.0.0.1:20300/publish",
	};
	const defaults = (name: string) => values[name];
	const owned = [
		"--http-bind=127.0.0.1",
		"--http-port=0",
		"--no-browser-assets",
		"--http-public=http://localhost:8123/",
	];
	assertEquals(developmentBackendArguments([], () => undefined, 8123), owned);
	assertEquals(developmentBackendArguments([], defaults, 8123), [
		...owned,
		"--trace-connect=ws://127.0.0.1:20300/captp",
		"--trace-publish=ws://127.0.0.1:20300/publish",
	]);
	const explicit = ["--trace-connect=wss://trace.example/view", "--trace-publish=wss://trace.example/send"];
	assertEquals(developmentBackendArguments(explicit, defaults, 8123), [...owned, ...explicit]);
	assertEquals(developmentBackendArguments([explicit[0]], defaults, 8123), [
		...owned,
		"--trace-publish=ws://127.0.0.1:20300/publish",
		explicit[0],
	]);
	// Invalid values and repeated explicit flags reach the backend unchanged.
	const invalid = (name: string) => name.startsWith("GLOWCAP_ROOMS_DEV_") ? "not an endpoint" : undefined;
	assertEquals(developmentBackendArguments([], invalid, 8123), [
		...owned.slice(0, 3),
		"--http-public=not an endpoint",
		"--trace-connect=not an endpoint",
		"--trace-publish=not an endpoint",
	]);
	assertEquals(developmentBackendArguments([explicit[0], explicit[0]], defaults, 8123), [
		...owned,
		"--trace-publish=ws://127.0.0.1:20300/publish",
		explicit[0],
		explicit[0],
	]);
});

Deno.test("the backend names the address browsers reach this front at", () => {
	const owned = ["--http-bind=127.0.0.1", "--http-port=0", "--no-browser-assets"];
	// The backend reads its own variable, so a default here would replace it.
	const own = (name: string) => name === "GLOWCAP_ROOMS_HTTP_PUBLIC" ? "https://tunnel.example/" : undefined;
	assertEquals(developmentBackendArguments([], own, 8080), owned);
	// An empty variable is one the backend reads as absent.
	const empty = (name: string) => name === "GLOWCAP_ROOMS_HTTP_PUBLIC" ? "" : undefined;
	assertEquals(developmentBackendArguments([], empty, 8080), [...owned, "--http-public=http://localhost:8080/"]);
	const emptyDefault = (name: string) => name.startsWith("GLOWCAP_ROOMS_DEV_") ? "" : undefined;
	assertEquals(developmentBackendArguments([], emptyDefault, 8080), [
		...owned,
		"--http-public=http://localhost:8080/",
	]);
	// A container publishes the front's port at another address and says which.
	const published = (name: string) =>
		name === "GLOWCAP_ROOMS_DEV_HTTP_PUBLIC" ? "http://localhost:19080/" : undefined;
	assertEquals(developmentBackendArguments([], published, 8080), [...owned, "--http-public=http://localhost:19080/"]);
	const named = ["--http-public=https://rooms.example/"];
	assertEquals(developmentBackendArguments(named, published, 8080), [...owned, ...named]);
});
