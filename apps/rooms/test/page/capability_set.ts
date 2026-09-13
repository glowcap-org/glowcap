import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function addCapability(tab: Page, toggle: string, swiss: string): Promise<void> {
	await tab.click(toggle);
	await tab.waitForSelector("#capabilityValueSwiss");
	await tab.fill("#capabilityValueSwiss", swiss);
	await tab.press("#capabilityValueSwiss", "Enter");
	await tab.waitForSelector("#capabilityValueTitle", { state: "detached" });
	await tab.waitForSelector("#holdingsPanel", { state: "visible" });
}

export async function saveCapabilitySet(tab: Page): Promise<void> {
	await tab.click("#opsCapabilitySetSave");
	await tab.waitForFunction(() => {
		const button = document.querySelector<HTMLButtonElement>("#opsCapabilitySetSave");
		return button != null && button.disabled && !button.hasAttribute("data-busy") &&
			document.getElementById("opsCapabilitySetSaved") !== null;
	}).catch(async () => {
		const state = await tab.evaluate(() => {
			const button = document.querySelector<HTMLButtonElement>("#opsCapabilitySetSave");
			return {
				url: location.href,
				traceOverride: (() => {
					try {
						return JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null")?.session
							?.traceOverride;
					} catch {
						return "invalid workspace";
					}
				})(),
				label: button?.textContent?.trim() ?? "",
				disabled: button?.disabled ?? null,
				busy: button?.hasAttribute("data-busy") ?? null,
				saved: document.getElementById("opsCapabilitySetSaved")?.textContent?.trim() ?? "",
				errors: [...document.querySelectorAll(".capability-set-errors")].map((row) => row.textContent?.trim()),
			};
		});
		fail(`the capability set did not finish saving: ${JSON.stringify(state)}`);
	});
}

export async function takeCapability(tab: Page, toggle: string, swiss: string): Promise<void> {
	await addCapability(tab, toggle, swiss);
	await saveCapabilitySet(tab);
}

export async function removeCapability(tab: Page, toggle: string): Promise<void> {
	await tab.click(toggle);
	await saveCapabilitySet(tab);
	await tab.waitForFunction(
		(selector) => document.querySelector(selector)?.getAttribute("aria-checked") === "false",
		toggle,
	).catch(() => fail(`${toggle} remained in the saved capability set`));
}
