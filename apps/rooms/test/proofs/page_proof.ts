import { spawnWeb } from "../support/web_front.ts";
// The rooms web page as a real browser peer, end to end. A headless Chromium
// loads the ACTUAL page rooms-web serves, the
// bundled `@glowcap/web` graph, `glowcap_host.wasm`, and the UI, joins a
// room, sends a line, and sees the room echo it back. Every hop is the shipped
// path: its managed Wasm owner retains exact authority, runs receipt-backed
// effects and dials the room server through rooms-web's `/relay`. The UI
// projects the managed workspace and its admitted activity.
//
// Before that it watches the load itself, frame by frame from the first one,
// because what a reader sees on the way in is part of the page too: the screen
// that stands in while the peer opens has to be there, and the message meant for
// a browser that cannot run this page must never appear on one that can.
//
// It then holds the two rails that flank the conversation, the rooms and
// direct-message list, and the roster, to the promises they make on both
// layouts. A real browser is the only place any of this can be checked: every
// one of them is about what a reader can see or reach, and a stylesheet read on
// its own says nothing about either.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (the web front and room server run Rust), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `zig build rooms-web-page`.

import { SERVER } from "../support/paths.ts";
import { chromium } from "playwright";
import { fail, freePort, ROOT, waitForHttp } from "../page/harness.ts";
import * as opening from "../page/opening.ts";
import { proveFocusKeepsMobileViewport } from "../page/mobile_controls.ts";
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
// The trace port is fixed so `/trace` can answer it, which is how the page's
// take of the trace capability finds the endpoint to present the swiss to.
const opsState = await Deno.makeTempDir({ prefix: "glowcap-rooms-page-ops-" });
const foreignState = await Deno.makeTempDir({ prefix: "glowcap-rooms-page-foreign-" });
const tracePort = freePort();
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
const foreignRoom = spawnOwned(SERVER, {
	args: ["--transport=tcp", `--port=${foreignRoomPort}`, `--state=${foreignState}`],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});

spawnWeb({
	args: [
		"--transport=tcp",
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	env: {
		GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${foreignRoomPort},127.0.0.1:${hangPort}`,
		GLOWCAP_ROOMS_STATE: opsState,
		GLOWCAP_ROOMS_DIAGNOSTICS: "1",
		GLOWCAP_ROOMS_ADMIN_LISTENERS: "1",
		GLOWCAP_ROOMS_OPERATOR: "1",
		GLOWCAP_ROOMS_PEERING: "1",
		GLOWCAP_ROOMS_TRACE: "1",
		GLOWCAP_ROOMS_IRC: "1",
		GLOWCAP_ROOMS_TRACE_PORT: String(tracePort),
	},
	stdout: "piped",
	stderr: "inherit",
});

// The scenario's own deadline. A throw from a timer does not reach the try
// below, so the `finally` there cleans up nothing on this path. What reaps the
// servers instead is `support/children.ts`, which answers the uncaught error
// this raises.
// The timeout names the phase it interrupted and how long each finished phase
// took, so one failed run says where it stopped instead of only that it did.
const seconds = (since: number) => ((performance.now() - since) / 1000).toFixed(1);
const finished: string[] = [];
let running = "startup";
const deadline = setTimeout(
	() => fail(`web-page scenario timed out after 300s in ${running}; finished: ${finished.join(", ") || "none"}`),
	300_000,
);
async function phase<T>(name: string, work: () => Promise<T>): Promise<T> {
	running = name;
	const at = performance.now();
	const result = await work();
	finished.push(`${name} ${seconds(at)}s`);
	return result;
}

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

try {
	await waitForHttp(httpPort);
	const activeBrowser = await chromium.launch({ args: ["--no-sandbox"] });
	browser = activeBrowser;
	const tab = await activeBrowser.newPage();
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
	await phase("opening", () => opening.run(tab, httpPort, activeBrowser));
	await phase("mobile focus", () => proveFocusKeepsMobileViewport(activeBrowser, httpPort));
	await phase("first rail", () => firstRail.run(tab));
	await phase("details", () => details.run(tab));
	const second = await phase("rails", () => rails.run(tab, activeBrowser, httpPort));
	await phase("completion", () => completion.run(tab, second));
	const descendersIntact = await phase("files", () => files.run(tab, second));
	await phase("layout", () => layout.run(tab, second, descendersIntact));
	const foreignLocator = await phase("foreign", () => foreign.run(tab, httpPort, foreignRoomPort, hangPort));
	await phase("directories", () =>
		directories.run(
			tab,
			second,
			foreignLocator,
			foreignRoom,
			foreignState,
			foreignRoomPort,
			roomPort,
			descendersIntact,
		));
	await phase("standing", () => standing.run(tab, foreignLocator, httpPort, activeBrowser, second));
	await phase("operations", () => operations.run(tab, opsState, foreignLocator));
	await phase("registration", () => registration.run(tab));
	await phase("member card", () => memberCard.run(tab));
	if (invalidMarkup.length !== 0) {
		fail(`the page rendered invalid nested markup: ${invalidMarkup.join(" | ")}`);
	}

	console.log(
		"PASS: the rooms page ran as a browser peer through every phase of one " +
			"conversation — joining, completing, posting and changing files, holding " +
			"two rooms and two directories at once, saying where its reader stands, " +
			"holding the operator capabilities over its own server, and recognizing " +
			"one person across the directory-scoped names both doors use",
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
	await Deno.remove(foreignState, { recursive: true }).catch(() => {});
}
Deno.exit(0);
