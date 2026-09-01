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

/** End the conversation on screen with the title's mark. The mark asks in that
 * conversation's card; this confirms. */
export async function confirmTitleLeave(tab: Page): Promise<void> {
	await tab.click("#leaveBtn");
	const commit = tab.locator("#convcardLeave, #dircardLeave");
	await commit.waitFor({ state: "visible", timeout: 10_000 });
	await commit.click();
}

/** Press the join card's one act until it is offering the room question.
 *
 * The card asks for the directory first and the room after, so an address this
 * tab has not reached takes two presses: one that reaches it, and one that
 * joins. A directory already reached needs no first press, which is why this
 * looks at what the button says rather than counting. It returns once the room
 * field is there to be typed into; the caller presses Join itself, because what
 * it is joining is the caller's business. */
export async function reachDirectoryOnCard(tab: Page): Promise<void> {
	const label = async () => ((await tab.textContent("#joinBtn")) ?? "").trim();
	if (await label() !== "Connect") return;
	await tab.click("#joinBtn");
	await tab.waitForFunction(
		() => {
			const room = document.getElementById("room");
			return room !== null && (room as HTMLInputElement).offsetParent !== null;
		},
		undefined,
		{ timeout: 60_000 },
	).catch(async () =>
		fail(
			"connecting to the directory never offered the room question: " +
				JSON.stringify({
					button: await label(),
					refused: await tab.evaluate(() => document.getElementById("joinError")?.textContent?.trim() ?? ""),
				}),
		)
	);
}
