// The rooms web page as a real browser peer, end to end. A headless Chromium
// loads the ACTUAL page web.ts serves — the
// bundled `@pancake/web` graph, `pancake_driver.wasm`, and the UI — joins a
// room, sends a line, and sees the room echo it back. Every hop is the shipped
// path: the page's wasm Host holds the room capability, dials the room server
// through web.ts's `/relay`, and drives `lib/room_client.ts` directly. No JSON
// bridge is on the page's path.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (web.ts's room server is native), and a Playwright Chromium
// (`npx playwright install chromium && sudo npx playwright install-deps`).
// Run: `deno run --allow-all apps/rooms/deno/web_page_test.ts`.

import { chromium } from "playwright";

const WEB = new URL("./web.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (l.addr as Deno.NetAddr).port;
	l.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200) return;
		} catch {
			// not up / room not ready yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("web.ts did not answer with a room locator");
}

const deadline = setTimeout(() => fail("web-page scenario timed out after 90s"), 90_000);

const httpPort = freePort();
const roomPort = freePort();

const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));

	await tab.goto(`http://127.0.0.1:${httpPort}/`);

	// Join a room as a real peer: fill the nick and room, press Join.
	await tab.fill("#nick", "web-alice");
	await tab.fill("#room", "lobby");
	await tab.click("#joinBtn");

	// The composer's line input becomes usable once we are in the room.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });

	// Send a line; the room echoes it to every member (including us), so it
	// arrives back through the capability stream and renders as a bubble.
	const line = "hello from a browser peer";
	await tab.fill("#line", line);
	await tab.press("#line", "Enter");

	await tab.waitForFunction(
		(text) =>
			[...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		line,
		{ timeout: 30_000 },
	).catch(() => fail("the sent line never came back from the room over the capability stream"));

	console.log(
		"PASS: the rooms page ran as a browser peer — joined a room through /relay and " +
			"round-tripped a line over the room capability, no JSON bridge",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
