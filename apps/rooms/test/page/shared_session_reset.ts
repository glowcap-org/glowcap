/// <reference lib="dom" />
// A reset retires the earlier publication. The existing tab must be able to
// choose another workspace through local custody without deleting its Store.
import type { Page } from "playwright";
import { fail } from "../support/fail.ts";
import { within } from "../support/wait.ts";

export async function proveSessionReplacement(page: Page, replacement: string): Promise<void> {
	const errors: string[] = [];
	const recordError = (error: Error) => {
		if (errors.length < 8) errors.push(error.message);
	};
	page.on("pageerror", recordError);
	const started = Date.now();
	try {
		await page.reload();
		await page.locator("#sessionSetupCapability").waitFor({ timeout: 25_000 });
	} catch (error) {
		// Retain startup evidence without replacing the failed assertion.
		console.error("SESSION-RESET-FAILURE", JSON.stringify({ elapsedMs: Date.now() - started, errors }));
		try {
			const view = await within(
				page.evaluate(() => ({
					url: location.href,
					boot: document.documentElement.dataset.boot,
					bootRoot: document.querySelector("#boot")?.getAttribute("data-boot"),
					text: document.body.innerText.slice(0, 6000),
					resources: performance.getEntriesByType("resource")
						.filter(({ name }) => /\.(?:js|wasm)(?:\?|$)/.test(name))
						.slice(-16)
						.map(({ name, startTime, duration }) => ({ name, startTime, duration })),
				})),
				"reset page diagnostic",
				2_000,
			);
			console.error("SESSION-RESET-VIEW", JSON.stringify(view));
		} catch (diagnostic) {
			console.error("SESSION-RESET-DIAGNOSTIC", String(diagnostic));
		}
		throw error;
	} finally {
		page.off("pageerror", recordError);
	}
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
