// The rooms web page as a real browser peer, end to end. A headless Chromium
// loads the ACTUAL page serve.ts serves — the
// bundled `@pancake/web` graph, `pancake_host.wasm`, and the UI — joins a
// room, sends a line, and sees the room echo it back. Every hop is the shipped
// path: the page's wasm Host holds the room capability, dials the room server
// through serve.ts's `/relay`, and drives `lib/room/client.ts` directly. No JSON
// bridge is on the page's path.
//
// Before that it watches the load itself, frame by frame from the first one,
// because what a reader sees on the way in is part of the page too: the screen
// that stands in while the peer opens has to be there, and the message meant for
// a browser that cannot run this page must never appear on one that can.
//
// It then holds the two rails that flank the conversation — the rooms and
// direct-message list, and the roster — to the promises they make on both
// layouts. A real browser is the only place any of this can be checked: every
// one of them is about what a reader can see or reach, and a stylesheet read on
// its own says nothing about either.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web/page_test.ts`.

import { chromium } from "playwright";
import { fail, freePort, ROOT, waitForHttp, WEB } from "../page/harness.ts";
import * as opening from "../page/opening.ts";
import * as firstRail from "../page/first_rail.ts";
import * as details from "../page/details.ts";
import * as rails from "../page/rails.ts";
import * as completion from "../page/completion.ts";
import * as files from "../page/files.ts";
import * as layout from "../page/layout.ts";
import * as foreign from "../page/foreign.ts";
import * as directories from "../page/directories.ts";
import * as standing from "../page/standing.ts";
import * as operations from "../page/operations.ts";
import * as registration from "../page/registration.ts";
import * as memberCard from "../page/member_card.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";

const httpPort = freePort();
// The Operations scene needs the room server started with every operator
// capability and somewhere their swiss numbers persist, so the scene can
// read what the server printed. The state directory is this test's to remove.
// The viz port is fixed so `/viz` can answer it, which is how the page's
// take of the viz capability finds the endpoint to present the swiss to.
const opsState = await Deno.makeTempDir({ prefix: "pancake-rooms-page-ops-" });
const vizPort = freePort();
const roomPort = freePort();
const foreignRoomPort = freePort();
const hangPort = freePort();
const hang = Deno.listen({ hostname: "127.0.0.1", port: hangPort });
const held: Deno.Conn[] = [];
const holding = (async () => {
	try {
		for await (const conn of hang) held.push(conn);
	} catch {
		// Closed when the scenario ends.
	}
})();

// A second authority, not another room on the page's own server. The browser
// relay is explicitly allowed to reach this one TCP peer for the scenario;
// production cross-server joins use authenticated iroh, whose destinations do
// not need an address allow-list.
const foreignRoom = spawnOwned("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		`${ROOT}apps/rooms/server/main.ts`,
		String(foreignRoomPort),
	],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});

spawnOwned("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		// Somewhere to keep room state. Given no directory of its own, serve.ts
		// makes a temporary one at startup, so it cannot come up without this.
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	env: {
		PANCAKE_RELAY_TCP_PEERS: `127.0.0.1:${foreignRoomPort},127.0.0.1:${hangPort}`,
		PANCAKE_ROOMS_STATE: opsState,
		PANCAKE_ROOMS_DIAGNOSTICS: "1",
		PANCAKE_ROOMS_ADMIN_LISTENERS: "1",
		PANCAKE_ROOMS_OPERATOR: "1",
		PANCAKE_ROOMS_PEERING: "1",
		PANCAKE_ROOMS_VIZ: "1",
		PANCAKE_ROOMS_IRC: "1",
		PANCAKE_ROOMS_VIZ_PORT: String(vizPort),
	},
	stdout: "piped",
	stderr: "inherit",
});

// The scenario's own deadline. A throw from a timer does not reach the try
// below, so the `finally` there cleans up nothing on this path. What reaps the
// servers instead is `support/children.ts`, which answers the uncaught error
// this raises.
const deadline = setTimeout(() => fail("web-page scenario timed out after 240s"), 240_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	const invalidMarkup: string[] = [];
	// Mirror the page's own console and crashes into this proof's output: a
	// scene that times out otherwise reports only the selector it never saw,
	// while the page has been saying exactly what went wrong the whole time.
	tab.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			const said = message.text();
			console.error(`PAGE-CONSOLE ${message.type()}: ${said}`);
			if (said.includes("cannot be a descendant") || said.includes("cannot contain a nested")) {
				invalidMarkup.push(said);
			}
		}
	});
	tab.on("pageerror", (error) => console.error(`PAGE-ERROR: ${error.message}`));

	// One conversation, driven in order: each phase leaves the page where the
	// next one expects to find it, which is why they are calls in a list rather
	// than tests that could be run on their own.
	await opening.run(tab, httpPort, browser);
	await firstRail.run(tab);
	await details.run(tab);
	const second = await rails.run(tab, browser, httpPort);
	await completion.run(tab, second);
	const descendersIntact = await files.run(tab, second);
	await layout.run(tab, second, descendersIntact);
	const foreignLocator = await foreign.run(tab, httpPort, foreignRoomPort, hangPort);
	await directories.run(
		tab,
		second,
		foreignLocator,
		foreignRoom,
		foreignRoomPort,
		roomPort,
		descendersIntact,
	);
	await standing.run(tab, foreignLocator, httpPort, browser, second);
	await operations.run(tab, opsState, foreignLocator);
	await registration.run(tab);
	await memberCard.run(tab);
	if (invalidMarkup.length !== 0) {
		fail(`the page rendered invalid nested markup: ${invalidMarkup.join(" | ")}`);
	}

	console.log(
		"PASS: the rooms page ran as a browser peer through every phase of one " +
			"conversation — joining, completing, posting and changing files, holding " +
			"two rooms and two directories at once, saying where its reader stands, " +
			"holding the operator capabilities over its own server, and answering " +
			"who one person is the same way from both doors that ask",
	);
} finally {
	clearTimeout(deadline);
	for (const conn of held) {
		try {
			conn.close();
		} catch {
			// already gone
		}
	}
	try {
		hang.close();
	} catch {
		// already gone
	}
	await holding.catch(() => {});
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
	await Deno.remove(opsState, { recursive: true }).catch(() => {});
}
Deno.exit(0);
