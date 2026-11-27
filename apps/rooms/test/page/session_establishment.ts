// Establishing the controller that owns a Rooms workspace before interaction.

import type { Browser, Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { sessionConfirmKeep, sessionDeleteAsk, sessionDeleteCommit } from "../../lib/text/session.ts";
import { fail } from "../support/fail.ts";

export async function establishTestSession(tab: Page): Promise<void> {
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.waitForSelector("#sessionSetup");
	const setupLayout = await tab.locator("#sessionSetup").evaluate((setup) => {
		const panel = setup.querySelector(".session-setup-choices")?.getBoundingClientRect();
		const local = setup.querySelector("#sessionUseLocal")?.getBoundingClientRect();
		const attach = setup.querySelector("#sessionAttach")?.getBoundingClientRect();
		return {
			overflows: setup.scrollWidth > setup.clientWidth,
			panel: panel == null ? null : { width: panel.width, height: panel.height },
			controlsAligned: local != null && attach != null && Math.abs(local.height - attach.height) < 1,
		};
	});
	if (
		setupLayout.overflows || setupLayout.panel == null || setupLayout.panel.width < 500 ||
		!setupLayout.controlsAligned
	) {
		fail(`the session establishment layout is unfinished: ${JSON.stringify(setupLayout)}`);
	}
	const advanced = tab.locator(".session-setup-advanced");
	await advanced.locator("summary").click();
	const actions = advanced.getByRole("button");
	if (await actions.count() !== 1) fail("setup offered a destructive action without an open workspace");
	await advanced.getByRole("button", { name: sessionDeleteAsk, exact: true }).click();
	await advanced.getByRole("button", { name: sessionDeleteCommit, exact: true }).waitFor();
	await advanced.getByRole("button", { name: sessionConfirmKeep, exact: true }).click();
	await establishLocalSession(tab);
	await tab.waitForSelector("#joinBtn", { timeout: 60_000 });
}

export async function proveSessionOffer(browser: Browser, httpPort: number): Promise<void> {
	// A link that offers a shared session opens session choice with it filled
	// in, and takes it out of the address before anything else can read it.
	// Attach is the answer, so the link attaches nothing by itself.
	{
		const linked = await browser.newContext();
		const open = await linked.newPage();
		const capability = "ocapn://offered.example/s/workspace";
		await open.goto(`http://127.0.0.1:${httpPort}/#attach=${encodeURIComponent(capability)}`);
		await open.waitForSelector("#sessionSetupCapability", { timeout: 60_000 })
			.catch(() => fail("a link that offers a shared session did not open session choice"));
		if (new URL(open.url()).hash !== "") fail("the session offer stayed in the address");
		const filled = await open.inputValue("#sessionSetupCapability");
		if (filled !== capability) fail(`the offered session filled ${JSON.stringify(filled)}`);
		await linked.close();
	}
}
