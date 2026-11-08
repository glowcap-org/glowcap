/// <reference lib="dom" />
// The published page, with no Rooms server, reaches a directory through a
// door this browser opens by itself, and says which door when it cannot.
//
// The scenario is `test/page/relay_door.ts`. It brings up its own web front
// with a declared `noise-relay` listener and its own static host for the
// exported page, so the only thing the page shares with the server it reaches
// is the door that server declared. It stands alone because the page journey
// in `page_proof.ts` is one conversation on one served page, and this page
// has no server at all.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives,
// the static export, and a Playwright Chromium.
// Run: `zig build rooms-web-relay-door`.

import { type Browser, chromium } from "playwright";
import { run } from "../page/relay_door.ts";
import { reapOwned } from "../support/children.ts";
import { fail } from "../support/fail.ts";

const deadline = setTimeout(() => fail("web-relay-door scenario timed out after 90s"), 90_000);

let browser: Browser | null = null;
try {
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	await run(browser);
	console.log(
		"PASS: the published page reaches a directory through its relay door with no Rooms server, " +
			"names a relay nothing answers at, and asks for a server only for the doors it cannot open",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
