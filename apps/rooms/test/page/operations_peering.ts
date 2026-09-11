// The browser's complete Peering lifecycle. A room on a second directory is
// offered through the visible picker; publishing lands a live row; dropping
// the capability deliberately releases its lease without inventing a revoke;
// the listing therefore occupies the namespace until this publisher Session
// disconnects. Reload proves that backstop by publishing the exact name again,
// then the row's own Revoke proves ordinary exact retirement.

import type { Page } from "playwright";
import { removeCapability, takeCapability } from "./capability_set.ts";
import { fail, reachDirectoryOnCard } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

async function joinForeignRoom(tab: Page, foreignLocator: string): Promise<void> {
	await tab.setViewportSize({ width: 1280, height: 800 });
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "annex");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("the rail offered no way to reach a room on another server"));
	await tab.fill("#locator", foreignLocator);
	if (await reachDirectoryOnCard(tab, "annex") === "question") await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the second directory's room did not open for the peering scene"));
}

async function takePeering(tab: Page, peeringSwiss: string): Promise<void> {
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	await tab.waitForSelector("#holdingsPanel", { state: "attached" });
	await takeCapability(tab, "#opsPeeringToggle", peeringSwiss);
	await tab.waitForSelector("#opsBtn", { timeout: 15_000 })
		.catch(() => fail("taking the peering capability did not land its toggle on"));
}

async function openPeeringPane(tab: Page): Promise<void> {
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	await tab.waitForSelector("#peeringSource");
}

async function publish(tab: Page): Promise<void> {
	await tab.fill("#peeringName", "annex-here");
	await tab.click("#peeringPublish");
}

async function dropCapability(tab: Page): Promise<void> {
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	await tab.waitForSelector("#holdingsPanel", { state: "attached" });
	await removeCapability(tab, "#opsPeeringToggle");
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
}

async function leaveForeignRoom(tab: Page): Promise<void> {
	const annex = namedRoomRow(tab, "annex");
	await annex.locator(".room-open").click();
	await tab.waitForSelector("#opsPage", { state: "detached" });
	await annex.hover();
	await annex.locator(".room-leave").click();
	await annex.waitFor({ state: "detached", timeout: 15_000 })
		.catch(() => fail("the peering scene could not leave its room"));
}

export async function runPeeringScene(
	tab: Page,
	peeringSwiss: string,
	foreignLocator: string,
): Promise<void> {
	await joinForeignRoom(tab, foreignLocator);
	await takePeering(tab, peeringSwiss);
	await openPeeringPane(tab);

	const options = await tab.evaluate(() =>
		[...document.querySelectorAll("#peeringSource option")].map((opt) => ({
			text: opt.textContent ?? "",
			value: (opt as HTMLOptionElement).value,
		}))
	);
	const annex = options.find((option) => option.text.includes("annex"));
	if (annex == null) fail(`the peering form did not offer the foreign room: ${JSON.stringify(options)}`);
	await tab.selectOption("#peeringSource", annex.value);
	await tab.waitForFunction(() =>
		(document.getElementById("peeringName") as HTMLInputElement | null)?.value === "annex"
	)
		.catch(() => fail("selecting the persisted annex room did not prefill its publication name"));

	// The submitted controls, not a lagging rendered-state closure, decide the
	// publication. The exact row proves the type-and-immediately-press path.
	await publish(tab);
	await tab.waitForSelector('#peeringList li[data-phase="live"]', { timeout: 30_000 })
		.catch(() => fail("the publication did not land a live row"));
	const published = await tab.evaluate(() => {
		const row = document.querySelector("#peeringList li");
		return {
			name: row?.querySelector(".entry-name")?.textContent ?? "",
			// The row says where the room came from in its own voice, under the
			// name: "from <directory>", with nothing set in code type.
			source: row?.querySelector(".entry-meta")?.textContent ?? "",
		};
	});
	if (published.name !== "annex-here" || !published.source.startsWith("from ")) {
		fail(`the publication row does not carry its name and source: ${JSON.stringify(published)}`);
	}

	// Dropping the capability releases its local lease. The focused server test
	// proves that release is not revoke; this browser scene owns the visible drop
	// and the publisher-session cleanup on reload below.
	await dropCapability(tab);

	// Reload ends the publisher Session, which is the server's cleanup backstop.
	// Rejoin the source, take the capability, and publish the exact name again;
	// successful reuse is the externally visible proof that teardown retired it.
	await tab.reload();
	await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
	await joinForeignRoom(tab, foreignLocator);
	await takePeering(tab, peeringSwiss);
	await openPeeringPane(tab);
	await publish(tab);
	await tab.waitForSelector('#peeringList li[data-phase="live"]', { timeout: 30_000 })
		.catch(() => fail("publisher disconnect did not free the foreign listing's exact name"));

	// The row's own explicit act removes discovery immediately.
	await tab.click("#peeringList li button");
	await tab.waitForSelector("#peeringList", { state: "detached", timeout: 15_000 })
		.catch(() => fail("revoking the publication did not retire its row"));
	await dropCapability(tab);
	const remembered = await tab.evaluate(() => {
		const state = JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null");
		const operations = state?.session?.capabilities?.operations;
		return Array.isArray(operations) ? operations : [];
	});
	if (remembered.length !== 0) fail(`the peering scene left a secret behind: ${JSON.stringify(remembered)}`);
	await leaveForeignRoom(tab);
}
