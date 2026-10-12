// A device's own archive is the device's own archive.
//
// The bytes of a file kept here are in this browser's own storage. Whether the
// directory the conversation lives on happens to be reachable has nothing to do
// with reading them back, and a reader who is offline, or who has not
// finished connecting yet, is owed their own history and the files in it.
//
// So this stands the page up with no way to reach any directory at all and asks
// for a file back. The page's own assets still load. The one socket a session is
// made of never reaches anything, which is the same state every cold start
// passes through before its first connection lands.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { namedDirectRow } from "../support/conversation_row.ts";

const ARCHIVED_FILE = "workspace-archive.txt";
const ARCHIVED_BYTES = "workspace archive bytes";

/** What the row says about itself, for a failure that names the state rather
 * than leaving the next reader to go and look. */
async function fileState(tab: Page): Promise<unknown> {
	return await tab.evaluate((name) => {
		const row = [...document.querySelectorAll(".attach-file")]
			.find((el) => el.querySelector(".name")?.textContent === name);
		if (row == null) return { row: false };
		return {
			row: true,
			said: (row.textContent ?? "").trim().slice(0, 120),
			offers: row.querySelectorAll("button").length,
		};
	}, ARCHIVED_FILE);
}

export async function run(tab: Page, dmName: string): Promise<void> {
	// One route for both halves of this, rather than installing and removing one:
	// what a removal leaves behind is the browser's business, and this needs the
	// wire back for whatever runs next.
	let cut = true;
	await tab.routeWebSocket(/\/relay/, (ws) => {
		if (cut) ws.close();
		else ws.connectToServer();
	});
	try {
		await tab.reload();
		await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
		await namedDirectRow(tab, dmName).locator(".dm-open").click();
		const file = tab.locator(`.attach-file:has(.name:text-is("${ARCHIVED_FILE}"))`).last();
		await file.waitFor({ state: "visible", timeout: 20_000 })
			.catch(() => fail("the archived file line did not survive a reload with no directory to reach"));
		// Offered at all. A file whose bytes this device holds must not be put
		// beyond reach because nothing has connected yet: that is a fact about the
		// network, and this one is about the disk.
		if (await file.locator("button").count() === 0) {
			fail(`a file this device holds the bytes of was not offered: ${JSON.stringify(await fileState(tab))}`);
		}
		const [download] = await Promise.all([
			tab.waitForEvent("download", { timeout: 30_000 }),
			file.locator("button").click(),
		]);
		const saved = await download.path();
		if (saved == null || await Deno.readTextFile(saved) !== ARCHIVED_BYTES) {
			fail(`the archive did not give back the bytes it holds: ${JSON.stringify(await fileState(tab))}`);
		}
	} finally {
		// Back on the wire, and back in the conversation this was standing in,
		// with a session actually established: what runs next reads capabilities
		// this page redeems as its home session comes up, and a reload alone only
		// starts that.
		cut = false;
		await tab.reload();
		await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
		await namedDirectRow(tab, dmName).locator(".dm-open").click();
		// The new page Host has no live direct route. Reintroduce this saved
		// conversation through its exact peer registration before using it.
		await tab.waitForSelector("#dmReconnect", { timeout: 20_000 });
		await tab.click("#dmReconnect");
		await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	}
}
