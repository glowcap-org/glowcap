// The deploy composition's shape, held without a YAML dependency: top-level
// keys and service names each appear once, and the services an operator
// relies on are present. A mapping with a duplicated key is the exact
// damage a misplaced edit does to this file — the parser that eventually
// reads it keeps one arm silently — so uniqueness is the load-bearing
// claim, not full YAML validity.

import { assertEquals } from "./assert.ts";
import { sessionAdminSturdyref } from "../session/readiness.ts";
import { sessionHealthcheckOptions } from "../web/deploy/session_healthcheck.ts";

const COMPOSE = new URL("../web/deploy/docker-compose.yml", import.meta.url);
const LOCAL_COMPOSE = new URL("../web/deploy/docker-compose.override.yml.example", import.meta.url);
const COMPOSE_SCRIPT = new URL("../web/deploy/compose.sh", import.meta.url);
const GITIGNORE = new URL("../../../.gitignore", import.meta.url);
const UP = new URL("../web/deploy/up.sh", import.meta.url);
const SESSION_MAIN = new URL("../session/main.ts", import.meta.url);
const SESSION_BIND = new URL("../session/bind.ts", import.meta.url);
const DOCKERFILE = new URL("../web/deploy/rooms.Dockerfile", import.meta.url);

function keysAtIndent(lines: string[], indent: string, under?: string): string[] {
	const keys: string[] = [];
	let inside = under === undefined;
	for (const line of lines) {
		if (under !== undefined && /^\S/.test(line)) inside = line.startsWith(under + ":");
		if (!inside && under !== undefined) continue;
		const match = line.match(new RegExp(`^${indent}([A-Za-z0-9_-]+):`));
		if (match !== null) keys.push(match[1]);
	}
	return keys;
}

Deno.test("the compose file declares each key and service exactly once", async () => {
	const lines = (await Deno.readTextFile(COMPOSE)).split("\n");
	const compose = lines.join("\n");
	const top = keysAtIndent(lines, "");
	assertEquals(top, [...new Set(top)], "top-level keys are unique");
	assertEquals(top.includes("services") && top.includes("networks") && top.includes("volumes"), true);
	const services = keysAtIndent(lines, "  ", "services");
	assertEquals(services, [...new Set(services)], "service names are unique");
	assertEquals(services.includes("rooms"), true, "the room server is composed");
	assertEquals(services.includes("rooms-session"), true, "the durable user session is composed");
	const volumes = keysAtIndent(lines, "  ", "volumes");
	assertEquals(volumes, [...new Set(volumes)], "volume names are unique");
	assertEquals(volumes.includes("rooms-state"), true, "the directory has durable custody");
	assertEquals(volumes.includes("rooms-session-state"), true, "the user session has separate durable custody");
	assertEquals(
		compose.includes("PANCAKE_ROOMS_SESSION_STATE: /session-state") &&
			compose.includes("\n      - --allow-ffi\n") &&
			!compose.includes("--allow-ffi=/libs") &&
			compose.includes("--readiness-file=/run/rooms-session/admin.sturdyref") &&
			compose.includes("/run/rooms-session:mode=0700") &&
			compose.includes("session_healthcheck.ts"),
		true,
		"the user session has usable FFI, one durable owner, and an incarnation-local readiness fact",
	);
	assertEquals(/^\s+ports:/m.test(compose), false, "the base stack publishes a host port");
	assertEquals(
		/^\s+image: postgres:17-alpine@sha256:[0-9a-f]{64}$/m.test(compose),
		true,
		"the optional database image is not pinned by digest",
	);
});

Deno.test("the Rooms image pins both source images by digest", async () => {
	const dockerfile = await Deno.readTextFile(DOCKERFILE);
	assertEquals(/^FROM debian:[^\s]+@sha256:[0-9a-f]{64}$/m.test(dockerfile), true);
	assertEquals(
		/^COPY --from=denoland\/deno:[^\s]+@sha256:[0-9a-f]{64} /m.test(dockerfile),
		true,
		"the copied Deno binary still follows a mutable image tag",
	);
});

Deno.test("the ignored local Compose override template publishes only host loopback", async () => {
	const local = await Deno.readTextFile(LOCAL_COMPOSE);
	const ignored = await Deno.readTextFile(GITIGNORE);
	assertEquals(ignored.includes("apps/rooms/web/deploy/docker-compose.override.yml"), true);
	assertEquals(local.includes('- "127.0.0.1:8000:8000"'), true);
	assertEquals(local.includes('"8000:8000"'), false, "the local override publishes every host interface");
	assertEquals(local.includes("0.0.0.0"), false, "the local override publishes a LAN interface");
});

Deno.test("the Compose front disables implicit env and explicitly owns its files", async () => {
	const script = await Deno.readTextFile(COMPOSE_SCRIPT);
	assertEquals(script.includes("export COMPOSE_DISABLE_ENV_FILE=1"), true);
	assertEquals(script.includes('base="$deploy_dir/docker-compose.yml"'), true);
	assertEquals(script.includes('override="$deploy_dir/docker-compose.override.yml"'), true);
	assertEquals(script.includes('-f "$base" -f "$override" "$@"'), true);
	assertEquals(script.includes('-f "$base" "$@"'), true);
});

Deno.test("the session readiness document is exactly one capability", () => {
	const sturdyref = "ocapn://session.example/s/administrator";
	assertEquals(sessionAdminSturdyref(`${sturdyref}\n`), sturdyref);
	let refused = false;
	try {
		sessionAdminSturdyref(`${sturdyref}\n\u001b[31mROOMS-OPERATOR deadbeef`);
	} catch {
		refused = true;
	}
	assertEquals(refused, true, "a second startup line was accepted as part of the session capability");
});

Deno.test("the session capability printer keeps its flag separate from its file", () => {
	assertEquals(sessionHealthcheckOptions(["--print"]), {
		path: "/run/rooms-session/admin.sturdyref",
		print: true,
	});
	assertEquals(sessionHealthcheckOptions(["--print", "/tmp/session-ready"]), {
		path: "/tmp/session-ready",
		print: true,
	});
});

Deno.test("startup presents every capability in one operator handoff", async () => {
	const script = await Deno.readTextFile(UP);
	assertEquals(
		script.includes("--wait --wait-timeout 210"),
		true,
		"Compose does not own the complete declared health budget",
	);
	assertEquals(script.includes('bounded_exec "$compose" exec'), true, "post-health reads have no deadline");
	assertEquals(
		script.includes('while [ "$attempt" -le 6 ]') &&
			script.includes('[ "$attempt" -eq 6 ] && return 1') &&
			script.includes("session_capability=$(read_session_capability)"),
		true,
		"the incarnation-local readiness handoff has no fixed retry bound",
	);
	const handoff = script.slice(script.indexOf("directory_capabilities=$("));
	assertEquals(
		handoff.startsWith('directory_capabilities=$(bounded_exec "$compose" exec -T rooms $printer)'),
		true,
	);
	assertEquals((handoff.match(/\nprintf /g) ?? []).length, 1, "the final handoff has one writer");
	for (const value of ["$directory_capabilities", "$locator", "$session_capability"]) {
		assertEquals(handoff.includes(`\"${value}\"`), true, `${value} belongs to the final handoff`);
	}
});

Deno.test("session readiness does not wait for saved network intent", async () => {
	const source = await Deno.readTextFile(SESSION_MAIN);
	const bind = await Deno.readTextFile(SESSION_BIND);
	assertEquals(
		source.indexOf("await listenStandalone(") < source.indexOf("await openRoomsRuntime("),
		true,
		"the runtime installed a second listener provider before the listener could own it",
	);
	assertEquals(source.includes("installedTransport: listening.transport"), true);
	assertEquals(source.includes("await live.reconcile("), false);
	assertEquals(bind.includes("await live.reconcile("), false);
	assertEquals(bind.includes("void live.reconcile("), true);
});
