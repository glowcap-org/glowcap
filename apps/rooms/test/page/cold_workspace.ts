// A new document in the same browser profile has no tab identity. Exercise
// that boundary with the real Store, including the previous release's marker.
import type { Browser, Page } from "playwright";
import { joinAs, ROOM } from "../support/join.ts";
import { fail } from "../support/fail.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

export async function proveColdWorkspace(browser: Browser, port: number): Promise<void> {
	const context = await browser.newContext();
	const origin = `http://127.0.0.1:${port}/`;
	const draft = "Keep this unsent draft across a cold launch";
	const restored = async (page: Page) => {
		await namedRoomRow(page, ROOM).waitFor();
		await page.waitForFunction(
			(text) => document.querySelector<HTMLTextAreaElement>("#line")?.value === text,
			draft,
		);
	};
	try {
		const owner = await joinAs(browser, port, "cold-member", { context });
		const id = await owner.evaluate(() => sessionStorage.getItem("rooms.managed-tab"));
		if (!id) throw new Error("the open workspace has no identity");
		await owner.fill("#line", draft);
		const other = await context.newPage();
		await other.goto(origin);
		await other.getByRole("button", { name: "Resume workspace" }).waitFor();
		if (await other.locator("#line").count()) fail("two pages opened the same local workspace");
		await other.close();
		await owner.close();
		const cold = await context.newPage();
		await cold.goto(origin);
		await restored(cold);
		if (await cold.evaluate(() => sessionStorage.getItem("rooms.managed-tab")) !== id) {
			fail("cold startup replaced the local identity");
		}
		await cold.evaluate(() => localStorage.removeItem("rooms.last-workspace"));
		await cold.close();
		const legacy = await context.newPage();
		await legacy.goto(origin);
		await legacy.getByRole("button", { name: "Resume workspace" }).click();
		await restored(legacy);
	} finally {
		await context.close();
	}
}
