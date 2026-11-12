// A proof's child runs with the options its proof names, wherever the proof runs.

import { assertEquals } from "./assert.ts";
import { childEnv } from "./support/children.ts";

Deno.test("a proof child inherits no Rooms option from the shell its proof runs in", () => {
	const env = childEnv({
		PATH: "/usr/bin",
		GLOWCAP_ROOMS_HTTP_BIND: "0.0.0.0",
		GLOWCAP_ROOMS_TRACE_BIND: "0.0.0.0",
		GLOWCAP_ROOMS_DEV_HTTP_PUBLIC: "http://localhost:9080/",
		GLOWCAP_ROOMS_STATE: "/somewhere/live",
		GLOWCAP_ROOMS_SERVER_BIN: "/build/rooms-server",
		GLOWCAP_ROOMS_TEST_REAL_TOR: "1",
	}, { GLOWCAP_ROOMS_CAPABILITIES: "all" });
	assertEquals(
		Object.keys(env).filter((name) => name.startsWith("GLOWCAP_ROOMS_")).sort(),
		["GLOWCAP_ROOMS_CAPABILITIES", "GLOWCAP_ROOMS_SERVER_BIN", "GLOWCAP_ROOMS_TEST_REAL_TOR"],
	);
	assertEquals(env.PATH, "/usr/bin");
});

Deno.test("a proof child keeps the Rooms option its proof names over the shell's", () => {
	const env = childEnv({ GLOWCAP_ROOMS_STATE: "/somewhere/live" }, { GLOWCAP_ROOMS_STATE: "/proof/own" });
	assertEquals(env.GLOWCAP_ROOMS_STATE, "/proof/own");
});

Deno.test("a proof child finds glowcap's libraries unless its shell already says where they are", () => {
	assertEquals(childEnv({ LD_LIBRARY_PATH: "/elsewhere" }).LD_LIBRARY_PATH, "/elsewhere");
	assertEquals(childEnv({}).LD_LIBRARY_PATH, childEnv({}).GLOWCAP_LIB_DIR);
});
