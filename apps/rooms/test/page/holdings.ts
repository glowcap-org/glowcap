// Capability custody as Settings presents it: saved bearer authority is named
// independently from live session possession.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function provePrivateRoomHolding(page: Page, name: string): Promise<void> {
	await page.waitForSelector("#liveHoldingsLegend");
	const row = page.locator('[aria-labelledby="savedHoldingsLegend"] .entry').filter({ hasText: name });
	await row.waitFor();
	if (await row.getByRole("button", { name: "Open room controls" }).count() !== 1) {
		fail("the saved room holding did not expose its administration path");
	}
}

export async function proveAttachedSessionHolding(page: Page, sturdyref: string): Promise<void> {
	await page.click("#holdingsTab");
	if ((await page.textContent("#currentSessionCapability"))?.trim() !== sturdyref) {
		fail("an attached browser did not expose the exact session capability that owns its workspace");
	}
	if (await page.locator(".copy-field[data-compact]:has(#currentSessionCapability)").count() !== 1) {
		fail("the attached session capability did not use the compact copy field");
	}
}
