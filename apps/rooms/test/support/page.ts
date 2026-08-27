// Browser-page vocabulary the rooms web proofs share: failing loudly, waiting
// on a predicate, opening a direct message from the member list, and waiting
// for a bubble to render. Each proof owns its own topology and story; these are
// the verbs they all speak.

import type { Page } from "playwright";

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

/** Poll `ready` until it holds or `ms` elapse, then fail naming `what`. */
export async function until(ready: () => boolean, what: string, ms = 30_000): Promise<void> {
	const deadline = Date.now() + ms;
	while (!ready()) {
		if (Date.now() > deadline) fail(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
}

/** Press the direct-message control beside `peer` in the member list and wait
 * until the composer is live again. */
export async function openDmTo(tab: Page, peer: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${peer}") button.dm-btn`);
	await button.waitFor({ state: "visible", timeout: 60_000 });
	await button.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 });
}

/** Wait for a bubble containing `text` to render in `tab`; on timeout, dump the
 * page's #log so the failure says what the page actually showed. */
export async function awaitBubble(tab: Page, text: string, who: string): Promise<void> {
	await tab.waitForFunction(
		(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
		text,
		{ timeout: 30_000 },
	).catch(async () => {
		const log = (await tab.textContent("#log").catch(() => "?")) ?? "?";
		console.error(`  [${who} #log] ${JSON.stringify(log)}`);
		fail(`${who} never rendered "${text}"`);
	});
}
