// Settings tab layout checks shared by page-sized browser scenarios.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { inkContrast } from "../ink_contrast.ts";

export async function provePhoneSettingsTabs(page: Page): Promise<void> {
	const shape = await page.evaluate(() => {
		const bar = document.querySelector<HTMLElement>('.tabs[data-count="3"]');
		const ids = ["sessionTab", "holdingsTab", "reachabilityTab"];
		if (bar == null) return null;
		const bounds = bar.getBoundingClientRect();
		const cells = ids.map((id) => document.getElementById(id)?.getBoundingClientRect()).filter((cell) =>
			cell != null
		);
		return {
			count: cells.length,
			inside: cells.every((cell) => cell.left >= bounds.left - 1 && cell.right <= bounds.right + 1),
			oneRow: cells.length === 3 && cells.every((cell) => Math.abs(cell.top - cells[0].top) <= 1),
			usable: cells.every((cell) => cell.height >= 34),
		};
	});
	if (
		shape == null || shape.count !== 3 || !shape.inside || !shape.oneRow || !shape.usable
	) fail(`the Settings tabs do not fit one usable phone row: ${JSON.stringify(shape)}`);
}

export async function proveSelectedTabContrast(page: Page): Promise<void> {
	await page.mouse.move(0, 0);
	await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	const previous = await page.getAttribute("html", "data-theme");
	const failures: string[] = [];
	for (const appearance of ["light", "dark"] as const) {
		await page.evaluate((theme) => document.documentElement.setAttribute("data-theme", theme), appearance);
		await page.evaluate(() =>
			Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => {})))
		);
		const measured = await inkContrast(page, '.tabs .tab[aria-selected="true"]');
		if (measured === null) failures.push(`the chosen tab could not be measured in ${appearance}`);
		else if (measured.ratio < 4.5) {
			failures.push(`the chosen tab is ${measured.ratio.toFixed(2)}:1 in ${appearance} (${measured.saw})`);
		}
	}
	await page.evaluate((theme) => {
		if (theme === null) document.documentElement.removeAttribute("data-theme");
		else document.documentElement.setAttribute("data-theme", theme);
	}, previous);
	if (failures.length > 0) {
		fail(`the chosen tab does not clear 4.5 to 1 for small text: ${failures.join("; ")}`);
	}
}
