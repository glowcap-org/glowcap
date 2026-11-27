// A new document in the same browser profile has no tab identity. Exercise
// that boundary with the real Store, including the previous release's marker.
import type { Browser, Page } from "playwright";
import { joinAs, ROOM } from "../support/join.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { fail } from "../support/fail.ts";
import { refuseDatabaseEnumeration } from "./workspace_inventory.ts";
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
		const refusal = await other.locator("#savedWorkspaceFailure").innerText();
		if (!refusal.includes("already open in another tab") || !refusal.includes("Close its other tab")) {
			fail("workspace contention did not explain how to resume in this tab");
		}
		if (await other.locator("#line").count()) fail("two pages opened the same local workspace");
		// Trying an occupied workspace is reversible. A separate workspace
		// leaves the first writer's identity and its draft intact.
		await Promise.all([other.waitForNavigation(), other.getByRole("button", { name: "Resume workspace" }).click()]);
		await Promise.all([
			other.waitForNavigation(),
			other.getByRole("button", { name: "Set up a separate workspace" }).click(),
		]);
		await establishLocalSession(other);
		const otherId = await other.evaluate(() => sessionStorage.getItem("rooms.managed-tab"));
		if (!otherId || otherId === id) {
			fail("the separate workspace reused the occupied identity");
		}
		await other.close();
		await owner.reload();
		await restored(owner);
		await owner.close();
		const cold = await context.newPage();
		await cold.goto(origin);
		await restored(cold);
		if (await cold.evaluate(() => sessionStorage.getItem("rooms.managed-tab")) !== id) {
			fail("cold startup replaced the local identity");
		}
		// A legacy workspace the tab left has neither an automatic choice
		// nor the previous release's per-tab "yes" marker.
		await cold.evaluate((id) => {
			localStorage.removeItem("rooms.last-workspace");
			localStorage.removeItem(`rooms.workspace-choice.${id}`);
		}, id);
		await cold.close();
		const legacy = await context.newPage();
		await refuseDatabaseEnumeration(legacy);
		const roomAddress = new URL(`room/${encodeURIComponent(ROOM)}`, origin).href;
		await legacy.goto(roomAddress);
		await legacy.setViewportSize({ width: 390, height: 844 });
		const choices = legacy.getByRole("combobox", { name: "Saved on this device" });
		await choices.waitFor();
		if (await choices.locator("option").count() !== 2) fail("setup lost one of the saved workspaces");
		const copy = await legacy.locator("#savedWorkspaceTitle").boundingBox();
		if (!copy || copy.width < 180 || copy.x + copy.width > 390) fail("the mobile recovery heading has no room");
		await choices.selectOption({ label: `Workspace · ${id.slice(0, 8)}` });
		const [resume] = await Promise.all([
			legacy.waitForRequest((request) => request.isNavigationRequest()),
			legacy.getByRole("button", { name: "Resume workspace" }).click(),
		]);
		if (resume.url() !== roomAddress) fail("resuming a saved workspace dropped the incoming room address");
		await legacy.setViewportSize({ width: 1280, height: 720 });
		await restored(legacy);
		await legacy.close();

		// Losing the private owner metadata must not mint a replacement
		// identity under the saved workspace name.
		const missing = await context.newPage();
		await missing.goto(origin + "revision");
		await missing.evaluate(() =>
			new Promise<void>((resolve, reject) => {
				const deletion = indexedDB.deleteDatabase("rooms-history");
				deletion.onsuccess = () => resolve();
				deletion.onerror = () => reject(deletion.error);
			})
		);
		await missing.evaluate(({ id, otherId }) => {
			sessionStorage.setItem("rooms.managed-tab", id);
			localStorage.setItem("rooms.last-workspace", otherId);
		}, { id, otherId });
		// The inventory can omit the broken Store. Keep the tab's actual
		// recovery target even if another workspace is the only one listed.
		await missing.addInitScript((other) => {
			Object.defineProperty(indexedDB, "databases", {
				value: () => Promise.resolve([{ name: `rooms-session-${other}` }]),
			});
		}, otherId);
		await missing.goto(origin);
		await missing.getByRole("button", { name: "Set up a separate workspace" }).waitFor();
		if (await missing.getByRole("combobox", { name: "Saved on this device" }).inputValue() !== id) {
			fail("the recovery picker replaced the refused workspace with the most recently opened one");
		}
		if (await missing.locator("#joinBtn").count()) fail("missing identity opened as a new workspace");
	} finally {
		await context.close();
	}
}
