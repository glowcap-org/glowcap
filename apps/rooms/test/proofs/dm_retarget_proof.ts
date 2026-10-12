import { spawnWeb } from "../support/web_front.ts";
// A nickname is a claim the room grants and takes back, so a direct conversation
// cannot be keyed on one. This drives the sequence that breaks that rule,
// with three real browser peers against the page serve.ts serves:
//
//   zoe is introduced to ada and they talk
//   ada leaves, so the room has the name "ada" back
//   somebody else joins and is granted the name "ada"
//   the old conversation becomes read-only
//   zoe explicitly opens a new conversation to the replacement registration
//
// The last line must not redeem a fresh introduction by name and reach the new
// holder, with the same thread, title, and history, a different human, and no
// marker anywhere. The old registration makes the composer unavailable,
// while an explicit new conversation receives a separate registration ID.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives,
// and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web/dm_retarget_test.ts`.

import { chromium } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { directOpened } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}

const httpPort = freePort();
const roomPort = freePort();

spawnWeb({
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

const deadline = setTimeout(() => fail("dm-retarget scenario timed out after 180s"), 180_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	const join = async (nick: string) => {
		const ctx = await browser!.newContext({ viewport: { width: 1100, height: 720 } });
		const page = await ctx.newPage();
		page.on("pageerror", (e) => console.error(`  [page error, ${nick}]`, e.message));
		await page.goto(`http://127.0.0.1:${httpPort}/`);
		await establishLocalSession(page);
		await page.fill("#nick", nick);
		await page.fill("#room", "design");
		await page.click("#joinBtn");
		await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
		return { page, ctx };
	};

	const ada = await join("ada");
	const zoe = await join("zoe");
	const cleanupErrors: string[] = [];
	zoe.page.on("console", (message) => {
		if (message.type() === "error") cleanupErrors.push(message.text());
	});

	// zoe is introduced to ada and opens the conversation.
	await zoe.page.waitForFunction(
		() => document.querySelectorAll("#members li .dm-btn").length > 0,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("ada never became reachable for a direct message"));
	await zoe.page.click("#members li:has-text('ada') button.dm-btn");
	await directOpened(zoe.page, "ada", 10_000);
	const originalLine = "message for the original ada";
	await zoe.page.fill("#line", originalLine);
	await zoe.page.press("#line", "Enter");
	await ada.page.waitForSelector("#dmList li", { timeout: 15_000 });
	await ada.page.click("#dmList li .dm-open");
	await ada.page.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		originalLine,
		{ timeout: 15_000 },
	);

	// ada leaves for good; the room takes the name back.
	await ada.ctx.close();
	await zoe.page.waitForFunction(
		() => document.querySelector("#dmList li")?.className.includes("closed") ?? false,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the conversation was not closed when its member left"));

	// The vanished tab cannot acknowledge a stream reset. Let the binding's
	// five-second close budget expire; that expected abort must stay quiet.
	await zoe.page.waitForTimeout(6_000);
	if (cleanupErrors.length) fail(`departed partner cleanup: ${cleanupErrors.join("; ")}`);

	// Someone else is granted the name.
	const other = await join("ada");
	await zoe.page.waitForTimeout(2_000);

	// The old conversation remains readable but cannot send to a different
	// registration merely because it has the same display name.
	await zoe.page.click("#dmList li .dm-open");
	const closedComposer = await zoe.page.evaluate(() => ({
		disabled: (document.getElementById("line") as HTMLTextAreaElement | null)?.disabled ?? null,
		// Said under the field rather than inside it, because a draft the reader
		// had already typed covers a placeholder and this has to be readable then.
		said: document.getElementById("composerAvailability")?.textContent?.trim() ?? "",
	}));
	if (closedComposer.disabled !== true || !closedComposer.said.toLowerCase().includes("closed")) {
		fail(`the old conversation composer remained actionable: ${JSON.stringify(closedComposer)}`);
	}

	// One conversation, not a second minted quietly behind the one on screen.
	const rows = await zoe.page.evaluate(() => document.querySelectorAll("#dmList li").length);
	if (rows !== 1) fail(`expected one direct conversation, found ${rows}`);

	// Next the case the keying itself protects: zoe starts a
	// conversation with the person who holds the name. That is a different
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
	const replacementLine = "message for the replacement ada";
	await zoe.page.fill("#line", replacementLine);
	await zoe.page.press("#line", "Enter");
	await other.page.waitForSelector("#dmList li", { timeout: 15_000 });
	await other.page.click("#dmList li .dm-open");
	await other.page.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		replacementLine,
		{ timeout: 15_000 },
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
		originalLine,
		{ timeout: 15_000 },
	).catch(() => fail("the closed conversation lost its history when a new one took the name"));

	console.log(
		"PASS: a name changing hands does not move a conversation — the old composer became read-only, " +
			"no second conversation was minted behind the one on screen, " +
			"and a conversation with the name's new holder is a separate one that leaves the " +
			"old history intact",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
