// Attaching a browser to a durable session from Settings.
//
// Two acts wear the same form and are not the same act. Handing over a
// capability for another session moves this browser to it, and the page
// reloads onto what that session keeps. Handing over the one it is already
// holding names no change, so it makes none: no second pair to the peer, and
// no reload, because a reload is what ends hosting for a tab that is sharing
// its session with everyone attached to it.
//
// Both are proved here so that a bare timeout in the middle of a run says
// which browser was doing what, and so what the form said when it refused is
// read where it was shown rather than left on a page nobody looks at again.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

async function openAttachForm(page: Page, capability: string): Promise<void> {
	await page.click("#settingsBtn");
	await page.waitForSelector("#settingsTitle");
	await page.click("#sessionTab");
	await page.click("#sessionAttachOpen");
	await page.waitForSelector("#sessionAttachTitle");
	await page.fill("#sharedSessionCapability", capability);
}

/** What the attach form said, so a refusal is read where it was shown.
 *
 * The field draws this only while it is refusing, so its absence is the field
 * saying it accepted what it was given. Not every element the control points
 * at with `aria-describedby`: the hint beside it is always there, and reading
 * that as a refusal reports one on every attach that worked. */
function attachRefusal(page: Page): Promise<string> {
	return page.locator("#sharedSessionCapabilitySaid").textContent({ timeout: 1_000 })
		.then((said) => said?.trim() ?? "", () => "");
}

/** Move a browser onto the session a capability names. */
export async function attachThroughSettings(page: Page, capability: string, what: string): Promise<void> {
	await openAttachForm(page, capability);
	await Promise.all([
		page.waitForNavigation({ waitUntil: "domcontentloaded" }),
		page.click("#sessionAttachGo"),
	]).catch(async () =>
		fail(`${what} did not come back from attaching through Settings: ${await attachRefusal(page)}`)
	);
	await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
}

/** Hand a browser the capability it is already holding, and prove nothing
 * happened.
 *
 * Its own act rather than the attach above with the navigation left out: what
 * this proves is an absence, and an absence has to be asserted rather than
 * awaited. The browser stays on the session it was already on, never opens a
 * second pair to that peer to find out, and does not reload. */
export async function reattachThroughSettings(page: Page, capability: string, what: string): Promise<void> {
	await openAttachForm(page, capability);
	const mark = await page.evaluate(() => {
		const marked = globalThis as unknown as { __attachMark?: number };
		marked.__attachMark = (marked.__attachMark ?? 0) + 1;
		return marked.__attachMark;
	});
	await page.click("#sessionAttachGo");
	// The field, not the button, says the attempt has settled: the field is
	// disabled exactly while the attempt runs, and the button stays disabled
	// after a success too, because a used capability empties the field.
	await page.waitForSelector("#sharedSessionCapability:not([disabled])", { timeout: 60_000 })
		.catch(async () => fail(`${what} left the attach form working: ${await attachRefusal(page)}`));
	const refusal = await attachRefusal(page);
	if (refusal !== "") fail(`${what} was refused the capability it is already holding: ${refusal}`);
	const survived = await page.evaluate(() => (globalThis as unknown as { __attachMark?: number }).__attachMark);
	if (survived !== mark) {
		fail(`${what} reloaded over a capability that asked for no change and ended hosting`);
	}
	// A capability that has been used is not a pending change. Left in the field
	// it is one, and Settings stops the reader on the way out to ask about work
	// that is already done.
	if (await page.inputValue("#sharedSessionCapability") !== "") {
		fail(`${what} left the attach form still holding the capability it had already used`);
	}
	await page.locator(".session-attach-modal").getByRole("button", { name: "Close" }).click();
	await page.click("#settingsClose");
	await page.click("#settingsBtn");
	await page.click("#holdingsTab");
	if ((await page.textContent("#currentSessionCapability"))?.trim() !== capability) {
		fail(`${what} moved somewhere over its own capability`);
	}
	await page.click("#settingsClose");
}
