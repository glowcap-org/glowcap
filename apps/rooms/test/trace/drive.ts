// Driving rooms tabs through the visualizer lifecycle proof: bringing a
// conversation up from the rail, and ending one from its title.

import type { Page } from "playwright";
import { confirmTitleLeave } from "../page/harness.ts";

/** Bring a conversation up from the rail. Leaving a room puts the join card
 * back, which can take the rail with it, so the rail is asked for first. */
export async function openConv(tab: Page, open: string): Promise<void> {
	const row = tab.locator(open).first();
	if (!await row.isVisible()) await tab.locator("#backBtn").click();
	await row.waitFor({ state: "visible", timeout: 20_000 });
	await row.click();
}

/** Switch to a conversation, then end it with the title's mark, the one
 * control that leaves a room and closes a direct line. The mark asks in that
 * conversation's card. This confirms. */
export async function endConversation(tab: Page, open: string): Promise<void> {
	await openConv(tab, open);
	await confirmTitleLeave(tab);
}
