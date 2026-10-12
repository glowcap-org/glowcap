/// <reference lib="dom" />
// A reset retires the earlier publication. The existing tab must be able to
// choose another workspace through local custody without deleting its Store.
import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function proveSessionReplacement(page: Page, replacement: string): Promise<void> {
	await page.reload();
	await page.locator("#sessionSetupCapability").waitFor({ timeout: 25_000 });
	await page.locator("#sessionSetupCapabilitySaid").waitFor();
	const aligned = await page.evaluate(() => {
		const input = document.getElementById("sessionSetupCapability")!.getBoundingClientRect();
		const button = document.getElementById("sessionAttach")!.getBoundingClientRect();
		return Math.abs(input.top - button.top) <= 1;
	});
	if (!aligned) fail("a session refusal moved Attach away from its input");
	// Retain the same tab identity and persisted storage throughout the move.
	const identity = await page.evaluate(() => sessionStorage.getItem("rooms.managed-tab"));
	await page.fill("#sessionSetupCapability", replacement);
	await Promise.all([page.waitForNavigation(), page.click("#sessionAttach")]);
	await page.locator("#settingsBtn").waitFor({ timeout: 25_000 });
	if (await page.evaluate(() => sessionStorage.getItem("rooms.managed-tab")) !== identity) {
		fail("replacing a retired session discarded the browser's custody");
	}
}
