// What happens to a page holding management access whatever it holds: its
// link breaking and coming back, a gesture's refusal read as the code it names,
// and the page closing with every handle it made freed once.
import { assertEquals } from "../assert.ts";
import { settle, within } from "./wait.ts";
import { failureView, LocalRefusal } from "../../lib/text/failure.ts";
import type { Page } from "./held_access_page.ts";

/** Close the page, and hold every handle it made to one free and no use after. */
export async function closedClean(f: Page): Promise<void> {
	await within(f.close(), "the page to close");
	assertEquals([f.ledger.wrong(), f.ledger.misuse], [[], []], "every handle freed once, none used after");
}
/** Break the page's link, and wait out the move onto the next one. */
export async function relink(f: Page): Promise<void> {
	await f.breakLink();
	await settle();
	await f.moved();
}
/** The code a refusal or a session failure names. */
function codeOf(error: unknown): string {
	return error instanceof LocalRefusal ? error.code : failureView(error).code;
}
/** Run `gesture`, and answer the code it was refused with, if any. */
export async function refused(gesture: () => unknown): Promise<string | null> {
	try {
		await gesture();
		return null;
	} catch (error) {
		return codeOf(error);
	}
}
