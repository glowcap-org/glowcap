// A saved room manager capability, across the reload that re-enters the room.
//
// Two facts in this page look like one. The card draws the manager capability
// from the workspace's own saved sturdyref, which survives anything, and the
// acts beside it need the live capability the room took when it was entered,
// which does not. Nothing on screen tells them apart: the locator is drawn, the
// button is enabled, and the refusal only arrives once it is pressed.
//
// The join that mints a manager and the re-entry that has to recover it are
// different arms of the same function. Entering a name the directory already
// knows answers with a room and no authority, because minting one there would
// hand management to whoever walked in. That arm is the one every reload of a
// managed room takes, so it is the one that can quietly drop what the page
// already held, and the page would go on drawing the capability it could no
// longer use.
//
// So this reloads a page that manages two rooms and presses the act. Reading
// the card proves nothing: a manager that is drawn and a manager that works are
// separate claims, and only the second is worth having.
//
// Validated by breaking the code it watches. Discarding the caller's saved
// authority in `enterRoom` — taking the ordinary entry's empty answer as the
// whole truth — leaves the locator on screen and fails here on the press, which
// is the defect this exists for. The check before the reload is the calibration:
// it fails the same way if the join never minted a manager at all, so a failure
// after the reload cannot be a proof that was aimed wrong.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives,
// and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web/room_manager_test.ts`.

/// <reference lib="dom" />

import { chromium } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { openRailRoom } from "../support/private_room_page.ts";
import { fail, freePort, ROOT, waitForHttp, WEB } from "../page/harness.ts";

const httpPort = freePort();
const roomPort = freePort();

spawnOwned("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

const deadline = setTimeout(() => fail("room-manager scenario timed out after 240s"), 240_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (error) => console.error("  [page error]", error.message));

	await tab.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", "ada");
	await tab.fill("#room", "workshop");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });

	/** Open this conversation's card on its Capabilities panel, and wait for the
	 * panel itself rather than for one element inside it: the card keeps both
	 * panels mounted, so a manager locator is findable while About is the one on
	 * screen, and pressing then reads whatever the other panel last said. */
	const openCapabilities = async (room: string) => {
		await tab.click("#roomAbout");
		await tab.locator("dialog.modal", { hasText: `#${room}` }).waitFor({ timeout: 30_000 });
		await tab.click("#convcardCapabilitiesTab");
		await tab.waitForSelector("#convcardCapabilitiesPanel", { state: "visible", timeout: 30_000 })
			.catch(() => fail(`the ${room} card never showed its capabilities`));
		await tab.waitForSelector("#convcardManager", { state: "visible", timeout: 30_000 })
			.catch(() => fail(`${room} drew no manager capability, so there was nothing to press`));
	};

	/** Press the act the manager capability is the authority for, and hold the
	 * page to the room answering it. The answer is a toast the page raises only
	 * once the room has spoken; a refusal writes into the card instead and
	 * raises nothing, which is why the wait is for the answer rather than for
	 * the absence of a complaint. Clear whatever is already on screen first, so
	 * what arrives is this press being answered and not the last one.
	 */
	const changeAccess = async (when: string) => {
		// A toast already on screen goes on its own; dismissing races that, so ask
		// for an empty tray and let whichever happens first satisfy it.
		for (let tries = 0; tries < 12; tries += 1) {
			if (await tab.locator("#toasts .toast").count() === 0) break;
			await tab.locator("#toasts .toast-dismiss").first().click({ timeout: 2_000 }).catch(() => {});
		}
		await tab.getByRole("button", { name: "Change room access" }).click();
		await tab.waitForSelector('dialog.modal[open] #toasts .toast[data-kind="success"]', { timeout: 30_000 })
			.catch(async () => {
				const card = ((await tab.innerText("dialog.modal").catch(() => "")) ?? "").replace(/\s+/g, " ");
				fail(`${when}: the room drew a manager capability it could not use: ${card.slice(0, 320)}`);
			});
		await tab.click("#convcardClose");
	};

	// Calibration. This page just minted this manager, so the act must carry. A
	// failure here is a proof aimed wrong, not the defect below.
	await openCapabilities("workshop");
	await changeAccess("before any reload");

	// A second managed room, so the reload below is a workspace rejoining its
	// rooms rather than one room's lucky path. Nothing is pressed in it: one
	// room already carries the claim, and every extra press is another way for
	// this proof to fail for a reason that is not the one it is about.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "atelier");
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	// The composer was already enabled by the room above, so waiting for it
	// proves nothing about this one. The rail row is what says the second room
	// exists, and the reload below is only a workspace rejoining its rooms if
	// there are two of them.
	await tab.waitForFunction(
		() =>
			[...document.querySelectorAll("#roomList li")].some((li) =>
				(li.querySelector(".rname")?.textContent ?? "") === "atelier"
			),
		undefined,
		{ timeout: 60_000 },
	).catch(() => fail("the second managed room never reached the rail, so the reload had one room to rejoin"));
	// ── The page is reloaded, and re-enters both rooms by name ───────────
	// The room pressed here is the one entered first, so what is recovered is a
	// capability this workspace saved a reload ago rather than one just minted.
	await tab.reload();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("the reloaded page never re-entered a room"));

	// Marked, because the calibration press above is what a manager capability
	// does: it moved this room's access one on, from open to moderated, and a
	// moderated room draws its observer where an open one draws a hash.
	await openRailRoom(tab, "workshop", true);
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	await openCapabilities("workshop");
	await changeAccess("after the reload");

	console.log(
		"PASS: a reloaded workspace re-entered the rooms it manages by name and kept its saved " +
			"manager capability usable, not merely drawn",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
