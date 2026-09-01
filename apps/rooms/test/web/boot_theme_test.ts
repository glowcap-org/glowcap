// The page's first paint is in the theme the reader left.
//
// A session decides the theme, and a session is not up during the first paint.
// So `page.html` guesses from the workspace it finds in this browser, before
// the bundle exists, on the bet that a reader's last theme is their next one. A
// wrong guess costs the repaint that would have happened anyway; a missing one
// means every cold load in a dark workspace flashes the light palette.
//
// That is the whole failure mode, and it is silent. Nothing throws, nothing
// logs, the page simply arrives the wrong colour for a moment. It stood that
// way here behind a schema-version range that could never match, so this proof
// exists to watch the guess actually happen rather than to watch the code that
// intends it.
//
// `/page.js` is refused for the cold tab, so nothing but the inline script can
// have painted what this reads. Blocking it is what makes the assertion about
// the guess instead of about the application agreeing with itself later.
//
//   deno run -A apps/rooms/test/web/boot_theme_test.ts

/// <reference lib="dom" />

import { chromium } from "playwright";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { freePort, ROOT, waitForHttp, WEB } from "../page/harness.ts";

function fail(message: string): never {
	console.error(`rooms-web-boot-theme FAILED: ${message}`);
	Deno.exit(1);
}

const httpPort = freePort();
const roomPort = freePort();
spawnOwned("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "null",
	stderr: "null",
});

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const context = await browser.newContext();
	const page = await context.newPage();
	await page.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(page);

	// Both themes, so a stamp that merely matches the default cannot pass. The
	// workspace is written directly: what is under test is the reading of it,
	// and driving the settings control to change it would prove that instead.
	for (const theme of ["dark", "light"] as const) {
		await page.evaluate((value) => {
			const raw = localStorage.getItem("rooms.workspace-state");
			const document_ = JSON.parse(raw ?? "null") ?? {};
			document_.view = { ...(document_.view ?? {}), theme: value };
			localStorage.setItem("rooms.workspace-state", JSON.stringify(document_));
		}, theme);

		const cold = await context.newPage();
		await cold.route("**/page.js", (route) => route.abort());
		await cold.goto(`http://127.0.0.1:${httpPort}/`);
		await cold.waitForSelector("#boot", { state: "attached", timeout: 30_000 });
		const seen = await cold.evaluate(() => ({
			stamped: document.documentElement.dataset.theme ?? null,
			bundleRan: document.getElementById("boot") === null,
			splash: getComputedStyle(document.getElementById("boot") as HTMLElement).backgroundColor,
		}));
		if (seen.bundleRan) fail("the bundle ran, so this proved nothing about the first paint");
		if (seen.stamped !== theme) {
			fail(`a ${theme} workspace painted its first frame as ${seen.stamped ?? "unstamped"}`);
		}
		if (seen.splash === "rgba(0, 0, 0, 0)") fail("the splash painted no ground to be right or wrong about");
		console.log(`  • a ${theme} workspace opens ${theme}, splash ${seen.splash}`);
		await cold.close();
	}

	// No workspace at all is not a guess to make: the stylesheet's own
	// preference query is the answer, and stamping either theme would override
	// a reader's system setting with one this browser has never been told.
	const fresh = await browser.newContext();
	const first = await fresh.newPage();
	await first.route("**/page.js", (route) => route.abort());
	await first.goto(`http://127.0.0.1:${httpPort}/`);
	await first.waitForSelector("#boot", { state: "attached", timeout: 30_000 });
	const unstamped = await first.evaluate(() => document.documentElement.dataset.theme ?? null);
	if (unstamped !== null) fail(`a browser with no workspace was stamped ${unstamped}`);
	console.log("  • a first visit is left to the system preference");
	await fresh.close();

	console.log("rooms-web-boot-theme OK");
} finally {
	if (browser !== null) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
