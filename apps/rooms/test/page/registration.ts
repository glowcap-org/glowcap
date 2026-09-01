// A managed public name is a capability registration, not an immortal room.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

export async function run(tab: Page): Promise<void> {
	if (new URL(tab.url()).pathname.startsWith("/ops")) await tab.click(".wordmark-link");
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "registration-proof");
	await tab.press("#newRoomInput", "Enter");
	await namedRoomRow(tab, "registration-proof", true).waitFor({ timeout: 15_000 });
	await tab.click("#roomAbout");
	await tab.click("#convcardCapabilitiesTab");
	await tab.waitForSelector("#convcardManager");
	await tab.click("#convcardUnregisterAsk");
	const confirmation = tab.getByRole("group", { name: "Release the registered name #registration-proof" });
	const copy = (await confirmation.textContent()) ?? "";
	if (
		!copy.includes("public name") || !copy.includes("capabilities you hold remain") ||
		!copy.includes("register the room again")
	) fail(`room unregistration did not explain its authority and membership boundary: ${copy}`);
	if (await tab.locator("#convcardUnregisterAsk").count() !== 0) {
		fail("room unregistration confirmation did not replace the action being confirmed");
	}
	await confirmation.getByRole("button", { name: "Release registered name" }).click();
	await tab.waitForSelector("#convcardUnregisterAsk", { state: "detached" });
	if (await tab.locator("#convcardManager, #convcardRoomLink").count() !== 2) {
		fail("releasing a public name discarded independent room authority");
	}
	if (await tab.locator("#line:disabled").count() !== 0) {
		fail("room unregistration ended the manager's current membership");
	}
	await tab.locator("#convcardRoomAccessStanding", { hasText: "Private" }).waitFor();
	await tab.getByRole("button", { name: "Change room access" }).click();
	await tab.waitForSelector("#convcardUnregisterAsk");
	await tab.keyboard.press("Escape");
}
