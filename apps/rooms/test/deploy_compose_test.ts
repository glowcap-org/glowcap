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
const UP = new URL("../web/deploy/up.sh", import.meta.url);

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
			compose.includes("--readiness-file=/run/rooms-session/admin.sturdyref") &&
			compose.includes("/run/rooms-session:mode=0700") &&
			compose.includes("session_healthcheck.ts"),
		true,
		"the user session has one durable owner and an incarnation-local readiness fact",
	);
	assertEquals(/^\s+ports:/m.test(compose), false, "no container port is published directly");
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
	const handoff = script.slice(script.indexOf("directory_capabilities=$("));
	assertEquals(handoff.startsWith("directory_capabilities=$(docker compose exec -T rooms $printer)"), true);
	assertEquals((handoff.match(/\nprintf /g) ?? []).length, 1, "the final handoff has one writer");
	for (const value of ["$directory_capabilities", "$locator", "$session_capability"]) {
		assertEquals(handoff.includes(`\"${value}\"`), true, `${value} belongs to the final handoff`);
	}
});
