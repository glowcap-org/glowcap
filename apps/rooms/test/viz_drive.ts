// Driving rooms tabs for the visualizer lifecycle proof.

import { type Browser, type Page } from "playwright";
import { establishLocalSession } from "./support/session_setup.ts";
export { openDmTo } from "./support/page.ts";

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

export async function joinAs(
	browser: Browser,
	port: number,
	nick: string,
	room: string,
	seed?: { key: string; value: string },
): Promise<Page> {
	const context = await browser.newContext();
	// The viz capability, remembered the way a reader's "Remember on this
	// device" would have left it, so the tab's publishing arms on first load.
	if (seed !== undefined) {
		await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), seed);
	}
	const tab = await context.newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	await tab.goto(`http://127.0.0.1:${port}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", nick);
	await tab.fill("#room", room);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}

export async function say(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

export async function seesLine(tab: Page, text: string, who: string): Promise<void> {
	await tab.waitForFunction(
		(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
		text,
		{ timeout: 30_000 },
	).catch(() => fail(`${who} never saw "${text}"`));
}

/** Bring a conversation up from the rail. Leaving a room puts the join card
 * back, which can take the rail with it, so the rail is asked for first. */
export async function openConv(tab: Page, open: string): Promise<void> {
	const row = tab.locator(open).first();
	if (!await row.isVisible()) await tab.locator("#backBtn").click();
	await row.waitFor({ state: "visible", timeout: 20_000 });
	await row.click();
}

/** Switch to a conversation, then end it with the title's mark — the one
 * control that leaves a room and closes a direct line. */
export async function endConversation(tab: Page, open: string): Promise<void> {
	await openConv(tab, open);
	await tab.locator("#leaveBtn").click();
}
