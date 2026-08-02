// A nickname is a claim the room grants and takes back, so a direct conversation
// cannot be keyed on one. This drives the sequence that used to break that,
// with three real browser peers against the page serve.ts serves:
//
//   zoe is introduced to ada and they talk
//   ada leaves, so the room has the name "ada" back
//   somebody else joins and is granted the name "ada"
//   zoe types into the conversation she already had
//
// The last line used to redeem a fresh introduction by name and reach the new
// holder — same thread, same title, same history, a different human, and no
// marker anywhere. A conversation is keyed on the introduction that opened it
// now, so that message reaches nobody and says why.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives,
// and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web_dm_retarget_test.ts`.

import { chromium } from "playwright";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
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
			// not up yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

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

const deadline = setTimeout(() => {
	console.error("FAIL: dm-retarget scenario timed out after 180s");
	try {
		web.kill();
	} catch {
		// already gone
	}
	Deno.exit(1);
}, 180_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	const join = async (nick: string) => {
		const ctx = await browser!.newContext({ viewport: { width: 1100, height: 720 } });
		const page = await ctx.newPage();
		page.on("pageerror", (e) => console.error(`  [page error, ${nick}]`, e.message));
		await page.goto(`http://127.0.0.1:${httpPort}/`);
		await page.fill("#nick", nick);
		await page.fill("#room", "design");
		await page.click("#joinBtn");
		await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
		return { page, ctx };
	};

	const ada = await join("ada");
	const zoe = await join("zoe");

	// zoe is introduced to ada and opens the conversation.
	await zoe.page.waitForFunction(
		() => document.querySelectorAll("#members li .dm-btn").length > 0,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("ada never became reachable for a direct message"));
	await zoe.page.click("#members li:has-text('ada') button.dm-btn");
	await zoe.page.waitForSelector("#dmList li", { timeout: 10_000 });

	// ada leaves for good; the room takes the name back.
	await ada.ctx.close();
	await zoe.page.waitForFunction(
		() => document.querySelector("#dmList li")?.className.includes("closed") ?? false,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the conversation was not closed when its member left"));

	// Someone else is granted the name.
	const other = await join("ada");
	await zoe.page.waitForTimeout(2_000);

	// zoe types into the conversation she already had.
	await zoe.page.click("#dmList li .dm-open");
	const line = "are we still on for friday?";
	await zoe.page.fill("#line", line);
	await zoe.page.press("#line", "Enter");
	await zoe.page.waitForTimeout(3_000);

	const reached = await other.page.evaluate(
		(text) => (document.body.textContent ?? "").includes(text),
		line,
	);
	if (reached) {
		fail(
			"a message typed into the old conversation reached the person who took the name — " +
				"the conversation is being resolved by nickname again",
		);
	}

	const told = await zoe.page.evaluate(() =>
		(document.getElementById("log")?.textContent ?? "").includes("this conversation is closed")
	);
	if (!told) fail("the send failed without telling the reader the conversation is closed");

	// One conversation, not a second minted quietly behind the one on screen.
	const rows = await zoe.page.evaluate(() => document.querySelectorAll("#dmList li").length);
	if (rows !== 1) fail(`expected one direct conversation, found ${rows}`);

	// And now the case the keying itself protects: zoe deliberately starts a
	// conversation with the person who holds the name now. That is a different
	// conversation with a different person, and the closed one keeps its history.
	// Keyed on the nickname, the new one would land on top of the old and the
	// history would be gone.
	await zoe.page.click("#newDmBtn");
	await zoe.page.fill("#newDmInput", "ada");
	await zoe.page.press("#newDmInput", "Enter");
	await zoe.page.waitForFunction(
		() => document.querySelectorAll("#dmList li").length === 2,
		undefined,
		{ timeout: 15_000 },
	).catch(() =>
		fail(
			"starting a conversation with the new holder of the name did not open a second " +
				"conversation — it landed on the closed one, which is the nickname keying again",
		)
	);
	const opened = await zoe.page.evaluate(() => {
		const closed = [...document.querySelectorAll("#dmList li")]
			.find((li) => li.className.includes("closed")) as HTMLElement | undefined;
		if (!closed) return false;
		(closed.querySelector(".dm-open") as HTMLElement).click();
		return true;
	});
	if (!opened) fail("the closed conversation left no row to open");
	// Wait for the log rather than reading it in the same turn as the click. The
	// page draws from state, so a click asks for the change and the paint follows;
	// reading straight after it sees the conversation that was on screen before.
	await zoe.page.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		line,
		{ timeout: 15_000 },
	).catch(() => fail("the closed conversation lost its history when a new one took the name"));

	console.log(
		"PASS: a name changing hands does not move a conversation — the message reached nobody, " +
			"the reader was told why, no second conversation was minted behind the one on screen, " +
			"and a conversation with the name's new holder is a separate one that leaves the " +
			"old history intact",
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
