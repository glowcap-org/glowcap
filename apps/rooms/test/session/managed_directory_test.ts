// Production directory gestures reuse exact directory custody: a reach of a
// held directory changes its nickname or its route, a home offer follows one
// rule, and a room link joins its exact authority without a directory fetch.
import { assert, assertEquals } from "../assert.ts";
import { fixture } from "../support/managed_controller.ts";

Deno.test("managed directory revisit reuses custody and nickname choice is local intent", async () => {
	const f = fixture();
	try {
		assertEquals(await f.controller.reachDirectory(f.route, { kind: "exact", name: "ada" }), "");
		assertEquals(f.calls, []);
		assertEquals(await f.controller.reachDirectory(f.route, { kind: "automatic", base: "visitor" }), "");
		assertEquals(f.calls, [["chooseDirectoryNickname", [f.id, "visitor", "automatic"]]]);
		assertEquals(await f.controller.releaseNick(f.id), "");
		assertEquals(f.calls[1], ["chooseDirectoryNickname", [f.id, "", "exact"]]);
	} finally {
		f.close();
	}
});
// A typed address the held directory is not reached through re-acquires it
// through that address instead of changing the nickname on the held route.
// The home offer follows the rule a new directory's does: the workspace keeps
// the held mark, and the offer takes it only where no directory is home.
Deno.test("managed directory reach re-routes a held directory through an address it is not held by", async () => {
	const f = fixture();
	f.page.managedSession!.workspace.directoryRouteHeld = () => Promise.resolve(false);
	try {
		const nick = { kind: "exact", name: "ada" } as const;
		assertEquals(await f.controller.reachDirectory(f.route, nick, { home: true }), "");
		assertEquals(f.calls, [["directory", f.id, f.route, nick, false]]);
		f.current.intent.directories[0].home = false;
		assertEquals(await f.controller.reachDirectory(f.route, nick, { home: true }), "");
		assertEquals(f.calls[1], ["directory", f.id, f.route, nick, true]);
	} finally {
		f.close();
	}
});
// A re-route that fails leaves the held directory as it was and says why.
Deno.test("managed directory reach says why a re-route failed and changes nothing else", async () => {
	const f = fixture();
	const session = f.page.managedSession!;
	session.workspace.directoryRouteHeld = () => Promise.resolve(false);
	session.actions.directory = () => Promise.reject(new Error("The relay did not answer"));
	try {
		const said = await f.controller.reachDirectory(f.route, { kind: "exact", name: "ada" });
		assert(said.includes("The relay did not answer"), said);
		assertEquals(f.calls, []);
		assertEquals(f.current.intent.directories[0].nick, "ada");
		assertEquals(f.page.projection.get().convs.size, 0);
	} finally {
		f.close();
	}
});
// The served directory becomes home only in a session with no home directory.
for (const holding of ["home", "other", "none"] as const) {
	Deno.test(`managed room link joins the exact authority without fetching it as a directory, holding=${holding}`, async () => {
		const f = fixture();
		if (holding === "other") f.current.intent.directories[0].home = false;
		if (holding === "none") f.current.intent.directories.length = 0;
		try {
			const link = "ocapn://127.0.0.1%3A1234.tcp/s/ZXhhY3Qtcm9vbQ";
			assertEquals(await f.controller.join({ locator: link, room: "shared" }, { kind: "exact", name: "ada" }), {
				ok: true,
			});
			assertEquals(f.calls, [["roomLink", f.id, link, "shared", {
				route: f.route,
				nick: { kind: "exact", name: "ada" },
				home: holding !== "home",
			}], ["select", ["room"]]]);
		} finally {
			f.close();
		}
	});
}

for (const holding of ["home", "none"] as const) {
	for (const offered of [true, false]) {
		Deno.test(`reaching a directory takes the home offer only without a home, holding=${holding} offered=${offered}`, async () => {
			const f = fixture();
			if (holding === "none") f.current.intent.directories[0].home = false;
			try {
				const other = "127.0.0.1:5678";
				const nick = { kind: "exact", name: "ada" } as const;
				// The fake holds no row afterward, so only the reach itself is read.
				await f.controller.reachDirectory(other, nick, { home: offered });
				const reached = f.calls.find((call) => call[0] === "directory");
				assertEquals(reached?.[4], offered && holding === "none");
			} finally {
				f.close();
			}
		});
	}
}

Deno.test("choosing a home directory names the row, or none", async () => {
	const f = fixture();
	try {
		assertEquals(await f.controller.chooseHomeDirectory(f.id), "");
		assertEquals(await f.controller.chooseHomeDirectory(null), "");
		assertEquals(f.calls, [["chooseHomeDirectory", [f.id]], ["chooseHomeDirectory", [""]]]);
	} finally {
		f.close();
	}
});
