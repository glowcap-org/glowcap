// The published page, with no Rooms server, offers one direct-message route,
// browser to browser, and says so when it cannot open.
//
// Chromium runs with every non-proxied UDP route disabled, so ICE gathers no
// candidates and the WebRTC attempt can only give up at its connect bound.
// Two members join a directory through its relay door, one opens a direct
// message to the other, and the page asks for a Rooms server with words that
// name the person it could not reach. Settings then says there is no second
// route to choose and draws no choice.

import type { Browser, Page } from "playwright";
import { SIGNAL_CONNECT_TIMEOUT_MS } from "../../lib/limits.ts";
import { settingsDmNoServer } from "../../lib/text/settings.ts";
import { serverAskAfterDirect, sessionServerTitle } from "../../lib/text/session.ts";
import { stopOwned } from "../support/children.ts";
import { fail } from "../support/fail.ts";
import { ROOT } from "../support/paths.ts";
import { roomLocator } from "../support/rooms_server.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { serveStaticExport } from "../support/static_host.ts";
import { spawnWeb, webPort } from "../support/web_front.ts";
import { fillSettled, reachDirectoryOnCard } from "./harness.ts";

/** Time past the connect bound for the page to turn a failed attempt into the
 * ask: the attempt gives up at the bound and the dialog renders after it. */
const ASK_MARGIN_MS = 10_000;

export async function run(browser: Browser): Promise<void> {
	const front = spawnWeb({
		args: ["--transport=tcp", "0", "0", "--listen=noise-relay"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "inherit",
	});
	const host = await serveStaticExport();
	const contexts = [await browser.newContext(), await browser.newContext()];
	try {
		const address = await roomLocator(await webPort(front), "the front with a relay door");
		const alice = await join(contexts[0], host.origin, address, "alice");
		await join(contexts[1], host.origin, address, "bob");
		await alice.locator('#members li:has-text("bob") button.dm-btn').waitFor({ timeout: 20_000 });
		await alice.locator('#members li:has-text("bob") button.dm-btn').click();
		const dialog = alice.locator('dialog[aria-labelledby="serverAskTitle"]');
		await dialog.locator(".lead").waitFor({ state: "visible", timeout: SIGNAL_CONNECT_TIMEOUT_MS + ASK_MARGIN_MS })
			.catch(() =>
				fail(
					`a direct message with no route on a page with no server did not ask for one within ${
						SIGNAL_CONNECT_TIMEOUT_MS + ASK_MARGIN_MS
					} ms`,
				)
			);
		const title = ((await dialog.locator("#serverAskTitle").textContent()) ?? "").trim();
		const lead = ((await dialog.locator(".lead").textContent()) ?? "").trim();
		if (title !== sessionServerTitle || lead !== serverAskAfterDirect("bob")) {
			fail(`the ask did not name the person it could not reach: ${JSON.stringify({ title, lead })}`);
		}
		await alice.keyboard.press("Escape");
		await dialog.waitFor({ state: "hidden", timeout: 5_000 }).catch(() => fail("the server ask did not close"));
		await alice.click("#settingsBtn");
		await alice.click("#connectionTab");
		const said = alice.locator("#dmNoServer");
		await said.waitFor({ timeout: 5_000 }).catch(() =>
			fail("Settings did not say direct messages go browser to browser")
		);
		const text = ((await said.textContent()) ?? "").trim();
		if (text !== settingsDmNoServer) fail(`Settings said ${JSON.stringify(text)} about the missing server`);
		if (await alice.locator('input[name="dm"]').count() !== 0) {
			fail("Settings drew a direct-message choice on a page with no second route");
		}
	} finally {
		for (const context of contexts) await context.close();
		await host.close();
		await stopOwned(front);
	}
}

async function join(
	context: Awaited<ReturnType<Browser["newContext"]>>,
	origin: string,
	address: string,
	nick: string,
): Promise<Page> {
	const tab = await context.newPage();
	await tab.goto(`${origin}/`);
	await establishLocalSession(tab);
	await fillSettled(tab, "#joinAddressField", address);
	await fillSettled(tab, "#nick", nick);
	if (await reachDirectoryOnCard(tab, "garden") === "question") {
		await fillSettled(tab, "#room", "garden");
		await tab.click("#joinBtn");
	}
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(() =>
		fail(`${nick} did not join through the relay door`)
	);
	return tab;
}
