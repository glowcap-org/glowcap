import type { Page } from "playwright";
import { fail } from "./harness.ts";

/** Prove the attached path after its session peer restarted: the room was
 * realized through its durable entry link, yet revoking that entry authority
 * leaves the subscribed membership able to use its manager to replace it. */
export async function proveSharedRoomAuthorityRotation(page: Page): Promise<void> {
	await page.click("#roomAbout");
	await page.click("#convcardCapabilitiesTab").catch(async (error) =>
		fail(
			`the restarted room card has no capabilities tab: ${String(error)}; ${await page.locator("body")
				.innerText()}`,
		)
	);
	await page.waitForSelector("#convcardManager", { timeout: 30_000 })
		.catch(() => fail("the restarted attached room did not retain its manager capability"));
	const retiredLink = (await page.textContent("#convcardRoomLink"))?.trim() ?? "";
	await page.click("#convcardRoomLinkRevokeAsk");
	await page.getByRole("button", { name: "Revoke room authority" }).click();
	await page.waitForSelector("#convcardCreateRoomLink", { timeout: 30_000 })
		.catch(() => fail("revoking an attached room entry link did not expose manager-backed reissue"));
	await page.click("#convcardCreateRoomLink");
	await page.waitForSelector("#convcardRoomLink", { timeout: 30_000 });
	const reissuedLink = (await page.textContent("#convcardRoomLink"))?.trim() ?? "";
	if (reissuedLink === "" || reissuedLink === retiredLink) {
		fail("the attached room manager did not create a fresh room-entry generation");
	}
	await page.click("#convcardStewardClaim");
	await page.waitForSelector("#convcardSteward", { timeout: 30_000 })
		.catch(() => fail("the attached room manager did not recreate moderation after entry-link rotation"));
	await page.click("#convcardClose");
}
