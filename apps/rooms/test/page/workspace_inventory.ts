import type { Browser, Page } from "playwright";
import { savedWorkspaceTitle } from "../../lib/text/session.ts";
import { fail } from "../support/fail.ts";

/** Deny the device-wide inventory while leaving ordinary IndexedDB requests available. */
export async function refuseDatabaseEnumeration(page: Page): Promise<void> {
	await page.addInitScript(() => {
		Object.defineProperty(indexedDB, "databases", {
			value: () => Promise.reject(new DOMException("Inventory unavailable", "NotAllowedError")),
		});
	});
}

export async function proveWorkspaceInventory(browser: Browser, port: number): Promise<void> {
	const context = await browser.newContext();
	const origin = `http://127.0.0.1:${port}/`;
	try {
		const first = await context.newPage();
		await refuseDatabaseEnumeration(first);
		await first.goto(origin);
		await first.locator("#sessionSetup").waitFor();
		const databases = await first.evaluate(() => IDBFactory.prototype.databases.call(indexedDB));
		if (databases.length !== 0) fail("first-use inventory created a database before session choice");
		await first.close();

		const large = await context.newPage();
		await large.addInitScript(() => {
			const names = Array.from({ length: 513 }, (_, i) => ({ name: `rooms-session-legacy-${i}`, version: 1 }));
			Object.defineProperty(indexedDB, "databases", { value: async () => names });
		});
		await large.goto(origin);
		const choices = large.getByRole("combobox", { name: savedWorkspaceTitle });
		await choices.waitFor();
		if (await choices.locator("option").count() !== 513) fail("the deletion limit hid saved workspaces");
		await large.evaluate(() => sessionStorage.setItem("rooms.delete-browser-data", "yes"));
		await large.reload();
		await large.getByText("Rooms database inventory exceeds its deletion budget", { exact: false }).waitFor();
	} finally {
		await context.close();
	}
}
