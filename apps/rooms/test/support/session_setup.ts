// Establish the explicit local controller for browser scenarios that test the
// Rooms application rather than the first-run session chooser itself.

import type { Page } from "playwright";

export async function establishLocalSession(page: Page): Promise<void> {
	await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await page.waitForSelector("#sessionSetup, #joinBtn", { state: "attached", timeout: 60_000 });
	if (await page.locator("#sessionSetup").count() === 0) return;
	await Promise.all([
		page.waitForNavigation({ waitUntil: "domcontentloaded" }),
		page.click("#sessionUseLocal"),
	]);
	await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await page.waitForSelector("#joinBtn", { state: "attached", timeout: 60_000 });
}
