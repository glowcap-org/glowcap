// Establishing the controller that owns a Rooms workspace before interaction.

import type { Browser, Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
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
	await tab.locator(".session-setup-advanced summary").click();
	await tab.getByRole("button", { name: "Forget rooms and settings…" }).click();
	await Promise.all([
		tab.waitForNavigation({ waitUntil: "domcontentloaded" }),
		tab.getByRole("button", { name: "Forget rooms and settings", exact: true }).click(),
	]);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.waitForSelector("#sessionSetup");
	await establishLocalSession(tab);
	await tab.waitForSelector("#joinBtn", { timeout: 60_000 });
}

export async function proveSessionOffer(browser: Browser, httpPort: number): Promise<void> {
	const linked = await browser.newContext();
	const open = await linked.newPage();
	const capability = "ocapn://offered.example/s/workspace";
	const entry = new URL(`http://127.0.0.1:${httpPort}/`);
	const routed = new URL("room/offered?view=chat", entry);
	routed.searchParams.set("server", "https://rooms.example/");
	entry.searchParams.set("path", routed.pathname + routed.search);
	entry.hash = `keep=%2f&attach=${encodeURIComponent(capability)}&tab=1`;
	routed.hash = "keep=%2f&tab=1";

	const runtime = Promise.withResolvers<void>();
	const requested = open.waitForRequest((request) => new URL(request.url()).pathname.endsWith(".wasm"));
	await open.route("**/*.wasm", async (route) => {
		await runtime.promise;
		await route.continue();
	});
	try {
		await open.goto(entry.href, { waitUntil: "domcontentloaded" });
		await requested;
		if (open.url() !== routed.href) fail("the pending runtime did not leave a clean routed address");

		runtime.resolve();
		await open.click("#serverOfferKeep");
		routed.searchParams.delete("server");
		if (open.url() !== routed.href) fail("answering the server offer changed the remaining address");
		await open.waitForSelector("#sessionSetupCapability", { timeout: 60_000 });
		if (await open.inputValue("#sessionSetupCapability") !== capability) fail("setup lost the offered session");
		if (!await open.locator("#sessionAttach").isEnabled()) fail("the offered session was not ready to confirm");
	} finally {
		runtime.resolve();
		await linked.close();
	}
}
