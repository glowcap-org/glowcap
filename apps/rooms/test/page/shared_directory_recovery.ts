// Adding a directory to an attached workspace, carrying it across a server
// restart, and opening the directory card from Settings.

import type { Page } from "playwright";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { stopOwned } from "../support/children.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { readPort, restartStatefulServer, startStatefulServer } from "../support/rooms_server.ts";
import { fail, openDirectoryCardFromSettings, reachDirectoryOnCard } from "./harness.ts";

export async function proveSharedDirectoryRecovery(page: Page, port: number): Promise<void> {
	const state = await Deno.makeTempDir({ prefix: "glowcap-rooms-shared-web-other-room-" });
	let peer: Deno.ChildProcess | null = startStatefulServer(port, state);
	try {
		await readPort(peer);
		await page.click("#newRoomBtn");
		await page.fill("#newRoomInput", "other-room");
		await page.focus("#newRoomElsewhere");
		await page.press("#newRoomElsewhere", "Enter");
		await page.waitForSelector("#joinForm", { state: "visible" });
		await page.fill("#locator", loopbackTcpDesignator(port));
		await page.fill("#nick", "setup-member");
		await reachDirectoryOnCard(page);
		await page.fill("#room", "other-room");
		await page.click("#joinBtn");
		await namedRoomRow(page, "other-room", false, "membership-joined").waitFor({ timeout: 30_000 })
			.catch(() => fail("an attached session could not add and join another directory"));

		await stopOwned(peer);
		peer = null;
		await namedRoomRow(page, "other-room", false, "membership-unavailable").waitFor({ timeout: 30_000 })
			.catch(() => fail("an attached session did not expose a room whose directory restarted"));
		peer = await restartStatefulServer(port, state);
		await namedRoomRow(page, "other-room", false, "membership-joined").waitFor({ timeout: 60_000 })
			.catch(() => fail("an attached session did not rejoin its room after the directory restarted"));

		await page.click("#newRoomBtn");
		await page.fill("#newRoomInput", "after-restart");
		await page.press("#newRoomInput", "Enter");
		await namedRoomRow(page, "after-restart", false, "membership-joined").waitFor({ timeout: 30_000 })
			.catch(() => fail("an attached session could not join another room after its directory restarted"));

		await page.click("#settingsBtn");
		await page.click("#reachabilityTab");
		await openDirectoryCardFromSettings(page);
		const centered = await page.evaluate(() => {
			const dialog = document.querySelector<HTMLDialogElement>("#dircardTitle")?.closest("dialog");
			const card = document.querySelector<HTMLElement>("#dircardTitle")?.closest(".modal-card");
			if (dialog == null || card == null) return null;
			const bounds = card.getBoundingClientRect();
			return {
				modal: dialog.matches(":modal"),
				left: bounds.left,
				right: innerWidth - bounds.right,
				delta: Math.abs(bounds.left + bounds.width / 2 - innerWidth / 2),
			};
		});
		if (centered == null || !centered.modal || centered.delta > 1) {
			fail(`the attached directory card was not a centered top-layer modal: ${JSON.stringify(centered)}`);
		}
		await page.click("#dircardClose");
	} finally {
		if (peer !== null) await stopOwned(peer).catch(() => {});
		await Deno.remove(state, { recursive: true }).catch(() => {});
	}
}
