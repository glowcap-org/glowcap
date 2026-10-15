// Settings tab layout checks shared by page-sized browser scenarios.

import type { Page } from "playwright";
import { waitForFiniteAnimations } from "../support/animations.ts";
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

/** The Session card's acts lie as entries: each act on its own line, on the
 * line its subject is named on at desktop width (under it on a phone), and
 * every act on the column's right edge. A row of buttons wrapped raggedly
 * here once, two acts and then an orphan. Its rows are spaced exactly like
 * "Where this browser works": no rule between them, the same gap. */
export async function proveSessionActsLieAsEntries(page: Page): Promise<void> {
	const shown = await page.evaluate(() => document.querySelector('.tabs .tab[aria-selected="true"]')?.id ?? null);
	await page.click("#sessionTab");
	const shape = await page.evaluate(() => {
		const list = document.querySelector<HTMLElement>('[aria-labelledby="currentSessionLegend"] > .entries');
		const moves = document.querySelector<HTMLElement>(".session-moves .entries");
		if (list == null || moves == null) return null;
		const spacing = (of: HTMLElement) => {
			const rows = [...of.querySelectorAll<HTMLElement>(":scope > .entry")].slice(1).map((row) =>
				getComputedStyle(row)
			);
			return JSON.stringify([
				getComputedStyle(of).rowGap,
				...new Set(rows.map((row) => `${row.borderTopWidth}/${row.paddingTop}`)),
			]);
		};
		const spacedLikeMoves = spacing(list) === spacing(moves);
		const right = list.getBoundingClientRect().right;
		return {
			spacedLikeMoves,
			rows: [...list.querySelectorAll<HTMLElement>(":scope > .entry")].map((row) => {
				const name = row.querySelector<HTMLElement>(".entry-name")!.getBoundingClientRect();
				const acts = [...row.querySelectorAll<HTMLElement>(".actions > .button")].map((act) =>
					act.getBoundingClientRect()
				);
				return {
					acts: acts.length,
					atEdge: acts.every((act) => Math.abs(act.right - right) <= 1),
					onNameLine: acts.every((act) => act.top < name.bottom && name.top < act.bottom),
					underName: acts.every((act) => act.top >= name.bottom - 1),
				};
			}),
		};
	});
	if (shown != null && shown !== "sessionTab") await page.click(`#${shown}`);
	const narrow = (page.viewportSize()?.width ?? 1280) <= 520;
	if (shape == null || shape.rows.length < 2) {
		fail(`the Session card did not list its acts as entries: ${JSON.stringify(shape)}`);
	}
	const { rows, spacedLikeMoves } = shape;
	if (!spacedLikeMoves) fail("the Session card's acts are not spaced like the session moves under it");
	if (rows.some((row) => row.acts !== 1 || !row.atEdge || !(narrow ? row.underName : row.onNameLine))) {
		fail(`a Session act left its entry line or the column edge: ${JSON.stringify(rows)}`);
	}
}

/** No Settings tab offers a row of more than two acts. Two fit a card at any
 * width. A third wrapped into a ragged second row, and a well that offers more
 * gives each act its own entry line instead. */
export async function proveActionRowsStayShort(page: Page): Promise<void> {
	const shown = await page.evaluate(() => document.querySelector('.tabs .tab[aria-selected="true"]')?.id ?? null);
	const crowded: string[] = [];
	for (const id of ["sessionTab", "holdingsTab", "reachabilityTab"]) {
		if (await page.$(`#${id}`) == null) continue;
		await page.click(`#${id}`);
		crowded.push(
			...await page.evaluate(() =>
				[...document.querySelectorAll<HTMLElement>('dialog[open] [role="tabpanel"]:not([hidden]) .actions')]
					.filter((row) => row.offsetParent != null && row.querySelectorAll(":scope > .button").length > 2)
					.map((row) => row.textContent?.trim() ?? "")
			),
		);
	}
	if (shown != null) await page.click(`#${shown}`);
	if (crowded.length > 0) fail(`a Settings row offers more than two acts: ${JSON.stringify(crowded)}`);
}

export async function proveSelectedTabContrast(page: Page): Promise<void> {
	await page.mouse.move(0, 0);
	await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	const previous = await page.getAttribute("html", "data-theme");
	const failures: string[] = [];
	for (const appearance of ["light", "dark"] as const) {
		await page.evaluate((theme) => document.documentElement.setAttribute("data-theme", theme), appearance);
		await waitForFiniteAnimations(page);
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
