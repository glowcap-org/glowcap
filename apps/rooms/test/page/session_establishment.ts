// Establishing the controller that owns a Rooms workspace before interaction.

import type { Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { fail } from "./harness.ts";

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
	await tab.getByRole("button", { name: "Reset workspace…" }).click();
	await Promise.all([
		tab.waitForNavigation({ waitUntil: "domcontentloaded" }),
		tab.getByRole("button", { name: "Reset workspace", exact: true }).click(),
	]);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.waitForSelector("#sessionSetup");
	await establishLocalSession(tab);
	await tab.waitForSelector("#joinBtn", { timeout: 60_000 });
}
