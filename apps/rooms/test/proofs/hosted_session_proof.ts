import { spawnWeb, webPort } from "../support/web_front.ts";
// A local browser session shared from one Rooms page and attached from another.
//
// Two origins matter here. The hosting tab files its WebRTC answering inbox on
// the directory that served it, while the attaching tab begins on another
// directory and must follow the signaling-directory hint in the hosted
// sturdyref. A standalone session peer cannot exercise any of those acts.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { reapOwned } from "../support/children.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { fail } from "../support/fail.ts";
import { reachDirectoryOnCard } from "../page/harness.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import { attachThroughSettings, reattachThroughSettings, shareThroughSettings } from "../page/session_attach.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;

async function serveRooms(): Promise<number> {
	const front = spawnWeb({
		args: ["--transport=tcp", "0", "0", "--transport=iroh"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "inherit",
	});
	return await webPort(front);
}

async function pageAt(browser: Browser, port: number, label: string): Promise<{ context: BrowserContext; page: Page }> {
	const context = await browser.newContext();
	const page = await context.newPage();
	page.on("pageerror", (error) => console.error(`  [${label} page error]`, error.message));
	page.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			console.error(`  [${label} console.${message.type()}]`, message.text());
		}
	});
	await page.goto(`http://127.0.0.1:${port}/?dm=webrtc`);
	await establishLocalSession(page);
	return { context, page };
}

async function joinHome(page: Page): Promise<void> {
	await page.fill("#nick", "hosted-member");
	await reachDirectoryOnCard(page);
	await page.fill("#room", "hosted-room");
	await page.click("#joinBtn");
	await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
}

const deadline = setTimeout(() => fail("cross-directory hosted session scenario timed out after 180s"), 180_000);

const hostHttp = await serveRooms();
const attachingHttp = await serveRooms();

let browser: Browser | null = null;
try {
	await Promise.all([waitForHttp(hostHttp), waitForHttp(attachingHttp)]);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const host = await pageAt(browser, hostHttp, "host");
	const sturdyref = await shareThroughSettings(host.page);
	await host.page.click("#settingsClose");
	await reattachThroughSettings(host.page, sturdyref, "the hosting browser");

	const attaching = await pageAt(browser, attachingHttp, "attaching");
	await attachThroughSettings(attaching.page, sturdyref, "a different Rooms page");
	// The first view attaches while the host has no chosen nickname or room.
	// Replacing its signaling name must preserve this view and serve fresh dials.
	await joinHome(host.page);
	await attaching.page.locator("#roomList").getByText("hosted-room", { exact: true }).waitFor({ timeout: 60_000 })
		.catch(() => fail("the attached page did not project the hosted room"));

	const afterJoin = await pageAt(browser, attachingHttp, "after-join");
	await attachThroughSettings(afterJoin.page, sturdyref, "a fresh view after the hosting nickname changed");
	await afterJoin.page.locator("#roomList").getByText("hosted-room", { exact: true }).waitFor({ timeout: 60_000 });
	await afterJoin.context.close();

	console.log(
		"PASS: pre-join Share served foreign-page views before and after choosing a nickname and room",
	);
	await attaching.context.close();
	await host.context.close();
} finally {
	clearTimeout(deadline);
	await browser?.close().catch(() => {});
	await reapOwned();
}

Deno.exit(0);
