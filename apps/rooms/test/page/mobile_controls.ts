// The mobile viewport belongs to the application, even while a field has the
// caret. iOS otherwise enlarges any focused text control below 16px and leaves
// the rails and composer stranded outside the scaled viewport.

import type { Browser } from "playwright";
import { fail } from "./harness.ts";

export async function proveFocusKeepsMobileViewport(browser: Browser, httpPort: number): Promise<void> {
	const context = await browser.newContext({
		viewport: { width: 390, height: 844 },
		hasTouch: true,
		isMobile: true,
	});
	try {
		const page = await context.newPage();
		await page.goto(`http://127.0.0.1:${httpPort}/`);
		const measured = await page.evaluate(() => {
			const plane = document.createElement("div");
			plane.className = "card-plane";
			const capabilitySet = document.createElement("textarea");
			capabilitySet.className = "field capability-set-text";
			const filter = document.createElement("input");
			filter.className = "filter-field";
			filter.type = "text";
			const select = document.createElement("select");
			select.className = "field";
			plane.append(capabilitySet, filter, select);
			document.body.append(plane);
			return {
				coarse: matchMedia("(any-pointer: coarse)").matches,
				capabilitySet: parseFloat(getComputedStyle(capabilitySet).fontSize),
				filter: parseFloat(getComputedStyle(filter).fontSize),
				select: parseFloat(getComputedStyle(select).fontSize),
			};
		});
		if (!measured.coarse) fail("the mobile control proof did not present a coarse pointer");
		const undersized = Object.entries(measured)
			.filter(([name, size]) =>
				name !== "coarse" && (typeof size !== "number" || !Number.isFinite(size) || size < 16)
			);
		if (undersized.length > 0) {
			fail(`mobile controls can still trigger focus zoom: ${JSON.stringify(undersized)}`);
		}
	} finally {
		await context.close();
	}
}
