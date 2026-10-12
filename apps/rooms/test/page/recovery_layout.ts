// How the Unfinished change dialog lies once its inventory has settled: the
// reader's sentence is showing (or the failure that replaced it), every row
// reads name, then what it needs, then the folded diagnostics, and nothing,
// the diagnostic dump included, runs past the card's edge. Diagnostics exist
// only for an operation this tab still holds, so a row without them proves
// the first and last of these and not the fold's place.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function proveRecoveryDialogLayout(tab: Page): Promise<void> {
	await tab.waitForSelector('dialog[open] #sessionRecoveryList[aria-busy="false"]', { state: "attached" });
	const folds = tab.locator("dialog[open] #sessionRecoveryList details");
	for (let at = 0; at < await folds.count(); at++) {
		await folds.nth(at).locator("summary").click();
	}
	const shape = await tab.evaluate(() => {
		const card = document.querySelector<HTMLElement>("dialog[open] .session-recovery-modal");
		if (card == null) return null;
		const lead = card.querySelector<HTMLElement>("p.lead");
		const rows = [...card.querySelectorAll<HTMLElement>("#sessionRecoveryList > .entry")];
		const overflowing = [card, ...card.querySelectorAll<HTMLElement>("pre")]
			.filter((el) => el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflowX !== "auto")
			.map((el) => el.tagName);
		const cardRight = card.getBoundingClientRect().right;
		const pastEdge = [...card.querySelectorAll<HTMLElement>("pre, summary")]
			.filter((el) => el.getBoundingClientRect().right > cardRight + 1)
			.map((el) => el.tagName);
		return {
			told: (lead != null && getComputedStyle(lead).visibility === "visible") ||
				card.querySelector(".said[data-kind='failure'], [role='alert']") != null,
			rows: rows.map((row) => {
				const kids = [...row.children];
				const hint = kids.findIndex((kid) => kid.matches("p.hint"));
				const fold = kids.findIndex((kid) => kid.matches("details"));
				return {
					folded: fold === -1 || (kids[fold].matches(".disclosure") && fold > hint && hint !== -1),
					folds: fold !== -1,
				};
			}),
			overflowing,
			pastEdge,
		};
	});
	if (shape == null) fail("the Unfinished change dialog was not open to measure");
	if (!shape.told) fail("the settled Unfinished change dialog shows neither its sentence nor why it has none");
	if (shape.rows.length === 0) fail("the Unfinished change dialog had no rows to measure");
	if (shape.rows.some((row) => !row.folded)) {
		fail(`an unfinished change put its diagnostics before what it needs: ${JSON.stringify(shape.rows)}`);
	}
	if (shape.overflowing.length > 0 || shape.pastEdge.length > 0) {
		fail(`the Unfinished change dialog runs past its card: ${JSON.stringify(shape)}`);
	}
	for (let at = 0; at < await folds.count(); at++) {
		await folds.nth(at).locator("summary").click();
	}
}
