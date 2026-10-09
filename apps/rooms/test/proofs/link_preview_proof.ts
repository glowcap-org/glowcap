import { spawnWeb } from "../support/web_front.ts";
/// <reference lib="dom" />
// The link-preview product scene, isolated so UI and effect work can rerun it
// without paying for the full page proof. The web front, Rust browser app, and
// Chromium are production-shaped; only remote publisher responses are fixed.

import { chromium } from "playwright";
import { run } from "../page/link_previews.ts";
import { fail } from "../page/harness.ts";
import { reapOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const httpPort = freePort();
const roomPort = freePort();
spawnWeb({
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});

const deadline = setTimeout(() => fail("link-preview browser scenario timed out after 90s"), 90_000);
let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	await run(browser, httpPort);
	console.log(
		"PASS: link previews used bounded ready, retry, remove, image-failure and delivered-fallback states on the real Rooms page",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
