// The complete Operations navigation under its real load: every server
// capability held together, at a content width that makes the destinations
// reflow. Kept apart from the individual panes' product scene so the layout
// proof and its whole-capability-set cleanup remain one readable subject.

import type { Page } from "playwright";
import { saveCapabilitySet } from "./capability_set.ts";
import { fail } from "./harness.ts";

export interface OperationSecrets {
	listeners: string;
	diagnostics: string;
	irc: string;
	operator: string;
	peering: string;
	viz: string;
}

export async function verifyCompleteOperationsNav(tab: Page, secrets: OperationSecrets): Promise<void> {
	// These are real address destinations, not labels squeezed into the
	// Settings tab control. At a narrow content width every one remains visible
	// in a balanced grid, without overlap or a hidden horizontal scroller.
	await tab.setViewportSize({ width: 760, height: 800 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	const capabilities = [
		["#opsListenersToggle", "ROOMS-ADMIN-LISTENERS", secrets.listeners],
		["#opsDiagnosticsToggle", "ROOMS-DIAGNOSTICS", secrets.diagnostics],
		["#opsIrcToggle", "ROOMS-IRC", secrets.irc],
		["#opsOperatorToggle", "ROOMS-OPERATOR", secrets.operator],
		["#opsPeeringToggle", "ROOMS-PEERING", secrets.peering],
		["#opsVizToggle", "ROOMS-VIZ", secrets.viz],
	] as const;
	await tab.click("#opsCapabilitySetEditText");
	await tab.fill(
		"#opsCapabilitySet",
		capabilities.map(([, label, swiss]) => `${label} ${swiss}`).join("\n"),
	);
	await tab.click("#opsCapabilitySetEditControls");
	for (const [toggle, label] of capabilities) {
		if (await tab.getAttribute(toggle, "aria-checked") !== "true") {
			fail(`${label} did not survive the text-to-controls capability bundle switch`);
		}
	}
	await tab.click('#opsCapabilitySetForm button[type="submit"]');
	for (const [toggle] of capabilities) {
		await tab.waitForFunction(
			(id) => document.querySelector(id)?.getAttribute("aria-checked") === "true",
			toggle,
			{ timeout: 15_000 },
		).catch(() => fail(`${toggle} did not retain its capability`));
	}
	await tab.waitForFunction(
		() => {
			const state = JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null");
			return state?.session?.capabilities?.operations?.length === 6;
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the complete capability set did not enter the session capability vault"));
	await tab.waitForFunction(() => {
		const layer = document.querySelector<HTMLDialogElement>("dialog.modal[open]");
		return layer !== null && getComputedStyle(layer).opacity === "1";
	});
	await tab.click("#opsBtn");
	await tab.waitForSelector('#opsNav[data-count="5"]').catch(async () => {
		const state = await tab.evaluate(() => {
			const save = document.querySelector<HTMLButtonElement>("#opsCapabilitySetSave");
			return {
				path: location.pathname,
				settings: document.getElementById("settingsTitle") !== null,
				commitment: document.getElementById("settingsUnsavedTitle") !== null,
				saveDisabled: save?.disabled ?? null,
				saveBusy: save?.hasAttribute("data-busy") ?? null,
				saved: document.getElementById("opsCapabilitySetSaved")?.textContent?.trim() ?? "",
				errors: [...document.querySelectorAll(".capability-set-errors")].map((row) => row.textContent?.trim()),
			};
		});
		fail(`the complete Operations control did not navigate: ${JSON.stringify(state)}`);
	});
	await tab.waitForSelector("#holdingsPanel", { state: "detached", timeout: 5_000 })
		.catch(() => fail("Settings did not finish leaving after Operations opened"));
	const layout = await tab.evaluate(() => {
		const nav = document.getElementById("opsNav");
		if (nav === null) return null;
		const bounds = nav.getBoundingClientRect();
		const items = [...nav.querySelectorAll<HTMLElement>(".ops-nav-item")].map((item) => {
			const rect = item.getBoundingClientRect();
			return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom };
		});
		let overlaps = false;
		for (let left = 0; left < items.length; left += 1) {
			for (let right = left + 1; right < items.length; right += 1) {
				const a = items[left];
				const b = items[right];
				if (a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom) overlaps = true;
			}
		}
		return {
			count: items.length,
			rows: new Set(items.map((item) => Math.round(item.top))).size,
			overlaps,
			inside: items.every((item) =>
				item.left >= bounds.left - 1 && item.right <= bounds.right + 1 &&
				item.top >= bounds.top - 1 && item.bottom <= bounds.bottom + 1
			),
			overflows: nav.scrollWidth > nav.clientWidth + 1,
		};
	});
	if (
		layout === null || layout.count !== 5 || layout.rows !== 2 || layout.overlaps || !layout.inside ||
		layout.overflows
	) {
		fail(`the complete operations navigation does not reflow cleanly: ${JSON.stringify(layout)}`);
	}

	// At phone width the same five destinations form rows of two, the last one
	// taking its row rather than sitting beside a hole. The whole chooser stays
	// on screen and none becomes an overflow-only item.
	await tab.setViewportSize({ width: 390, height: 844 });
	const phone = await tab.evaluate(() => {
		const nav = document.getElementById("opsNav");
		if (nav === null) return null;
		const items = [...nav.querySelectorAll<HTMLElement>(".ops-nav-item")];
		return {
			count: items.length,
			rows: new Set(items.map((item) => Math.round(item.getBoundingClientRect().top))).size,
			overflows: nav.scrollWidth > nav.clientWidth + 1 || document.documentElement.scrollWidth > innerWidth + 1,
		};
	});
	if (phone === null || phone.count !== 5 || phone.rows !== 3 || phone.overflows) {
		fail(`the phone operations navigation does not reflow cleanly: ${JSON.stringify(phone)}`);
	}
	await tab.setViewportSize({ width: 760, height: 800 });

	await tab.click("#directoryOpsLink");
	await tab.waitForFunction(() => location.pathname === "/ops/directory");
	await tab.waitForFunction(
		() => document.getElementById("directoryOpsLink")?.getAttribute("aria-current") === "page",
	).catch(() => fail("the selected operations address is not named as the current page"));

	// The capability's own word still answers, so a bookmark from before the
	// directory pane lands on the pane that draws it.
	await tab.goto(new URL("/ops/operator", tab.url()).href);
	await tab.waitForFunction(() => location.pathname === "/ops/directory")
		.catch(() => fail("an operator bookmark did not land on the directory pane"));

	// Finish with no deployment authority retained in this browser.
	await tab.setViewportSize({ width: 1280, height: 800 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	for (const [toggle] of capabilities) {
		await tab.click(toggle);
		await tab.waitForFunction(
			(id) => document.querySelector(id)?.getAttribute("aria-checked") === "false",
			toggle,
		).catch(() => fail(`${toggle} did not release its capability`));
	}
	await saveCapabilitySet(tab);
	await tab.waitForFunction(() => {
		const state = JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null");
		return state?.session?.capabilities?.operations?.length === 0;
	}).catch(() => fail("dropping the capability set left authority in the session vault"));
	await tab.waitForSelector("#opsBtn", { state: "detached" });
	await tab.click("#settingsClose");
}
