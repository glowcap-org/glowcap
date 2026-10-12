// The opening screen remains usable when the browser has no WebGPU. The
// shader mark is optional decoration. Its absence must not hold startup or
// erase the product name. This checks composition before session handoff.
import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function withoutOpeningGpu(tab: Page): Promise<void> {
	await tab.addInitScript(() => {
		Object.defineProperty(navigator, "gpu", { value: undefined });
	});
}

/** The lockup as one screen draws it: the mark's box, and the distance from the
 * bottom of that box to the top of the logotype. */
export type Lockup = { size: number; fit: number };

export async function proveOpeningWithoutGpu(tab: Page): Promise<Lockup> {
	const opening = await tab.evaluate(async () => {
		const mark = document.querySelector("#boot .boot-mark");
		const name = document.querySelector("#boot .boot-name");
		if (!(mark instanceof HTMLElement) || !(name instanceof HTMLElement)) return null;
		const font = await document.fonts.load('16px "IBM Plex Sans"');
		const box = mark.getBoundingClientRect();
		return {
			canvas: mark.querySelector("canvas") !== null,
			decorative: mark.getAttribute("aria-hidden"),
			width: box.width,
			height: box.height,
			fit: name.getBoundingClientRect().top - box.bottom,
			name: name.textContent?.replace(/\s+/g, " ").trim(),
			visible: name.getClientRects().length > 0 && getComputedStyle(name).visibility === "visible",
			fontLoaded: font.length > 0 && font.every((face) => face.status === "loaded"),
		};
	});
	if (opening === null) fail("the opening lockup is absent before session establishment");
	if (opening.canvas || opening.decorative !== "true") fail("the unavailable GPU mark must remain decorative");
	if (opening.width <= 0 || opening.height <= 0) fail("the shared styles did not reserve the opening mark's space");
	if (!opening.visible || !opening.name?.includes("glowcap") || !opening.name.includes("rooms")) {
		fail("the opening screen lost its product name without WebGPU");
	}
	if (!opening.fontLoaded) fail("the opening screen could not load its shared typeface");
	return { size: opening.height, fit: opening.fit };
}

/** The session chooser is what the opening screen fades into, and both draw the
 * same lockup, so any difference between the two reads as the page redrawing
 * rather than as one screen becoming the next.
 *
 * Measured rather than read off the sheets, because the number that decides it
 * is not written anywhere: the opening screen stands its mark inside a larger
 * box so the light is not clipped, and hands that box back to the layout with a
 * negative margin. Handing back slightly too little left the opening logotype
 * three pixels closer than the chooser's, with every stylesheet involved saying
 * what it meant to say. Only the two rendered lockups know.
 *
 * Measured by breaking the code, once per thing it claims to hold: handing back
 * three pixels too little reports the fit, and leaving one home's mark box at
 * its old size reports the size. */
export async function proveLockupSurvivesHandoff(tab: Page, opening: Lockup): Promise<void> {
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.waitForSelector("#sessionSetup");
	const chooser = await tab.evaluate(() => {
		const mark = document.querySelector("#sessionSetup .brand-lockup .mark-live");
		const name = document.querySelector("#sessionSetup .brand-lockup .wordmark");
		if (!(mark instanceof HTMLElement) || !(name instanceof HTMLElement)) return null;
		const box = mark.getBoundingClientRect();
		return { size: box.height, fit: name.getBoundingClientRect().top - box.bottom };
	});
	if (chooser === null) fail("the session chooser does not draw the brand lockup the opening screen hands it");
	if (Math.abs(chooser.size - opening.size) > 0.5) {
		fail(`the mark changes size across the handoff (${opening.size} → ${chooser.size})`);
	}
	if (Math.abs(chooser.fit - opening.fit) > 0.5) {
		fail(
			`the lockup's fit changes across the handoff: the logotype sits ` +
				`${Math.round(opening.fit)}px under the mark on the opening screen and ` +
				`${Math.round(chooser.fit)}px under it on the chooser`,
		);
	}
}
