// Where a browser works next is one question with three answers on a shared
// session: another session, this browser, or start over. Each names itself on
// one line with the act that takes it and says underneath what taking it
// does, and every act keeps the column's right edge.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

interface Row {
	readonly acts: number;
	readonly ruled: boolean;
	readonly button: { left: number; right: number; top: number; bottom: number } | null;
	/** Whether the act shares the line its destination is named on, rather than
	 * folding under it with a hole beside itself. */
	readonly onTheNameLine: boolean;
}

interface MoveLayout {
	readonly container: { left: number; right: number };
	readonly rows: Row[];
}

async function layout(page: Page): Promise<MoveLayout | null> {
	return await page.evaluate(() => {
		const well = document.querySelector<HTMLElement>(".session-moves");
		const list = well?.querySelector<HTMLElement>(".entries");
		if (well == null || list == null) return null;
		// The list's own box, not the well's: the well pays the card's padding,
		// and every row inside it lines up against the column that leaves.
		const container = list.getBoundingClientRect();
		const box = (el: HTMLElement | null) => {
			if (el == null) return null;
			const bounds = el.getBoundingClientRect();
			return { left: bounds.left, right: bounds.right, top: bounds.top, bottom: bounds.bottom };
		};
		return {
			container: { left: container.left, right: container.right },
			rows: [...well.querySelectorAll<HTMLElement>(".entries > .entry")].map((row) => {
				const button = box(row.querySelector<HTMLElement>(".entry-head > .actions > .button"));
				const name = box(row.querySelector<HTMLElement>(".entry-name"));
				return {
					acts: row.querySelectorAll(".entry-head > .actions > .button").length,
					ruled: getComputedStyle(row).borderTopWidth === "1px",
					button,
					onTheNameLine: button != null && name != null &&
						button.top < name.bottom && name.top < button.bottom,
				};
			}),
		};
	});
}

export async function proveSharedSessionMoveLayout(page: Page): Promise<void> {
	const wide = await layout(page);
	if (
		wide == null || wide.rows.length !== 3 ||
		// One answer, one act, on the line the answer is named on.
		wide.rows.some((row) => row.acts !== 1 || row.button == null || !row.onTheNameLine) ||
		// Every act on the column's right edge, and each answer under the last.
		wide.rows.some((row) => Math.abs(row.button!.right - wide.container.right) > 1) ||
		wide.rows.some((row, at) => at > 0 && row.button!.top <= wide.rows[at - 1].button!.bottom)
	) fail(`Where this browser works did not list its destinations: ${JSON.stringify(wide)}`);

	const prior = page.viewportSize();
	await page.setViewportSize({ width: 390, height: 720 });
	const narrow = await layout(page);
	if (
		narrow == null || narrow.rows.length !== 3 ||
		// A phone gives the name its own line and puts the act under it.
		narrow.rows.some((row) => row.button == null)
	) fail(`Where this browser works did not become a clean phone stack: ${JSON.stringify(narrow)}`);
	if (prior != null) await page.setViewportSize(prior);
}

export async function proveReturnToSetupDoesNotFlashACrash(
	page: Page,
	commit: "Detach browser" | "Leave workspace",
): Promise<void> {
	const here = new URL(page.url());
	if (!here.pathname.startsWith("/ops")) {
		here.pathname = "/ops";
		await page.goto(here.href);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await page.waitForSelector("#opsPage");
	}
	if (await page.locator("#settingsTitle").isVisible() !== true) {
		await page.click("#settingsBtn");
		await page.waitForSelector("#settingsTitle");
	}
	await page.click("#sessionTab");
	await page.click("#sessionLeaveAsk");
	await page.evaluate(() => {
		new MutationObserver((records) => {
			for (const record of records) {
				for (const node of record.addedNodes) {
					if (!(node instanceof Element)) continue;
					if (node.classList.contains("crash") || node.querySelector(".crash") != null) {
						console.error("rooms: crash card presented");
					}
				}
			}
		}).observe(document.documentElement, { subtree: true, childList: true });
	});
	const reasons: string[] = [];
	const note = (text: string) => {
		if (
			text.includes("without an established session") ||
			text.includes("The page ran into a problem") ||
			text.includes("a boundary caught a render error") ||
			text.includes("crash card presented") ||
			text.includes("Rendered fewer hooks than expected") ||
			text.includes("change in the order of Hooks")
		) {
			reasons.push(text);
		}
	};
	const onPageError = (error: Error) => note(error.message);
	const onConsole = (message: { text(): string }) => note(message.text());
	page.on("pageerror", onPageError);
	page.on("console", onConsole);
	try {
		await Promise.all([
			page.waitForNavigation({ waitUntil: "domcontentloaded" }),
			page.getByRole("button", { name: commit, exact: true }).click(),
		]);
	} finally {
		page.off("pageerror", onPageError);
		page.off("console", onConsole);
	}
	if (reasons.length > 0) fail(`returning to session setup crashed: ${reasons.join("; ")}`);
	await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await page.waitForSelector("#sessionSetup");
	const path = new URL(page.url()).pathname;
	if (path !== "/") fail(`returning to session setup kept ${path}`);
}
