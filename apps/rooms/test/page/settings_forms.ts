/// <reference lib="dom" />
// Settings whose submit changes browser startup state get an isolated profile:
// the proof presses the real controls and crosses the reload they promise,
// without changing the profile used by the rest of the whole-page scenario.

import type { Browser } from "playwright";
import { WORKSPACE_STATE_VERSION } from "../../lib/rooms_state.ts";
import { fail } from "./harness.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

export async function run(browser: Browser, httpPort: number): Promise<void> {
	const context = await browser.newContext();
	const page = await context.newPage();
	page.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			console.error(`SETTINGS-PAGE ${message.type()}: ${message.text()}`);
		}
	});
	page.on("pageerror", (error) => console.error(`SETTINGS-PAGE error: ${error.message}`));
	try {
		// Stand an obsolete prerelease schema on the page's origin before Rooms
		// runs. Only the explicit browser-data action may delete it; opening the
		// current archive never translates or silently erases unknown rows.
		await page.goto(`http://127.0.0.1:${httpPort}/page.css`);
		await page.evaluate(() =>
			new Promise<void>((resolve, reject) => {
				const drop = indexedDB.deleteDatabase("rooms-history");
				drop.onerror = () => reject(drop.error);
				drop.onsuccess = () => {
					const open = indexedDB.open("rooms-history", 2);
					open.onupgradeneeded = () => {
						const db = open.result;
						const lines = db.createObjectStore("lines", { autoIncrement: true });
						lines.createIndex("pair", "pair");
						const records = db.createObjectStore("archive-records", { keyPath: "key" });
						records.createIndex("revision", "revision", { unique: true });
						db.createObjectStore("archive-meta", { keyPath: "key" });
					};
					open.onerror = () => reject(open.error);
					open.onsuccess = () => {
						const db = open.result;
						const tx = db.transaction("lines", "readwrite");
						tx.objectStore("lines").add({
							pair: "old-directory\u0000alice",
							from: "alice",
							text: "prerelease plaintext",
							mine: false,
							at: 1,
						});
						tx.onerror = () => reject(tx.error);
						tx.oncomplete = () => {
							db.close();
							resolve();
						};
					};
				};
			})
		);
		await page.goto(`http://127.0.0.1:${httpPort}/`);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await page.waitForSelector("#sessionSetup");
		await page.locator(".session-setup-advanced summary").click();
		await page.getByRole("button", { name: "Delete browser data…" }).click();
		await Promise.all([
			page.waitForNavigation({ waitUntil: "domcontentloaded" }),
			page.getByRole("button", { name: "Delete browser data", exact: true }).click(),
		]);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await page.waitForSelector("#sessionSetup");
		await establishLocalSession(page);
		await page.fill("#room", "refresh-state");
		await page.fill("#nick", "refresh-member");
		await page.click("#joinBtn");
		await namedRoomRow(page, "refresh-state").waitFor().catch(async () => {
			const state = await page.evaluate(() => ({
				button: document.getElementById("joinBtn")?.textContent,
				disabled: (document.getElementById("joinBtn") as HTMLButtonElement | null)?.disabled,
				room: (document.getElementById("room") as HTMLInputElement | null)?.value,
				nick: (document.getElementById("nick") as HTMLInputElement | null)?.value,
				error: document.getElementById("joinError")?.textContent,
				setup: document.getElementById("sessionSetup") !== null,
				rooms: [...document.querySelectorAll("#roomList .rname")].map((row) => ({
					text: row.textContent,
					visible: row.getClientRects().length > 0,
				})),
				path: location.pathname,
				joinCard: document.querySelector(".join-card")?.getAttribute("class"),
				rail: getComputedStyle(document.getElementById("roomList")!).display,
				controller: JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null")?.controller ?? null,
				active: JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null")?.session?.active ?? null,
			}));
			fail(`The isolated settings profile did not join refresh-state: ${JSON.stringify(state)}`);
		});
		await page.click("#settingsBtn");
		await page.click("#sessionTab");
		if (!await page.isChecked("#keepHistoryToggle")) {
			fail("Message history did not start with its remembered choice");
		}
		await page.click("#keepHistoryToggle");
		await page.waitForFunction(() =>
			document.getElementById("keepHistoryToggle")?.getAttribute("aria-checked") === "false"
		);
		if (await page.isChecked("#keepHistoryToggle")) {
			fail("Message history did not turn off when its switch was pressed");
		}
		await page.waitForFunction(
			() => JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null")?.session?.keepHistory === false,
		).catch(() => fail("Message history did not remember that it was turned off"));
		const stores = await page.evaluate(() =>
			new Promise<string[]>((resolve, reject) => {
				const open = indexedDB.open("rooms-history");
				open.onerror = () => reject(open.error);
				open.onsuccess = () => {
					const db = open.result;
					resolve(Array.from(db.objectStoreNames).sort());
					db.close();
				};
			})
		);
		if (JSON.stringify(stores) !== JSON.stringify(["archive-blobs", "archive-meta", "archive-records"])) {
			fail(`Message history did not recreate the current schema: ${JSON.stringify(stores)}`);
		}
		await page.click("#keepHistoryToggle");
		await page.waitForFunction(() =>
			document.getElementById("keepHistoryToggle")?.getAttribute("aria-checked") === "true"
		);
		if (!await page.isChecked("#keepHistoryToggle")) {
			fail("Message history did not turn on when its switch was pressed again");
		}
		await page.waitForFunction(
			() => JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null")?.session?.keepHistory === true,
		).catch(() => fail("Message history did not remember that it was turned on"));
		await page.evaluate(() =>
			new Promise<void>((resolve, reject) => {
				const request = indexedDB.deleteDatabase("rooms-history");
				request.onsuccess = () => resolve();
				request.onerror = () => reject(request.error);
			})
		);
		await page.click("#keepHistoryToggle");
		await page.locator('#sessionPanel [role="alert"]').waitFor();
		if (!await page.isChecked("#keepHistoryToggle")) {
			fail("Message history painted itself off after its erase failed");
		}
		if (
			await page.evaluate(() =>
				JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null")?.session?.keepHistory
			) !== true
		) {
			fail("Message history remembered an erase that failed");
		}
		await page.click("#settingsTab");
		await page.click('input[name="dm"][value="relay"]');
		await Promise.all([
			page.waitForNavigation(),
			page.click("#dmSave"),
		]);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await page.waitForSelector("#line:not([disabled])", { timeout: 20_000 })
			.catch(() => fail("refresh left a saved room without reclaiming its exact nickname"));
		await page.waitForFunction(() =>
			[...document.querySelectorAll("#members li")].some((row) => row.textContent?.includes("refresh-member"))
		).catch(() => fail("refresh rejoined under no name or a changed nickname"));
		await page.click("#settingsBtn");
		await page.click("#settingsTab");
		if (!await page.isChecked('input[name="dm"][value="relay"]')) {
			fail("Save and reload did not preserve the selected direct-message connection");
		}
		await page.click("#sessionTab");
		await page.getByText("Local session", { exact: true }).waitFor();
		if (await page.locator("#currentSessionCapability").count() !== 0) {
			fail("a browser-owned local session invented an attachable capability");
		}
		await page.getByRole("button", { name: "Export or reset…" }).click();
		await page.waitForSelector("#sessionDataTitle");
		if ((await page.textContent("#sessionDataTitle"))?.trim() !== "Local session data") {
			fail("the state modal did not identify its local authority owner");
		}
		const download = page.waitForEvent("download");
		await page.click("#stateDownload");
		const saved = await download;
		if (saved.suggestedFilename() !== "pancake-rooms-state.json") {
			fail(`Rooms state downloaded as ${saved.suggestedFilename()}`);
		}
		const downloadPath = await saved.path();
		if (downloadPath == null) fail("the Rooms state download had no readable file");
		const document = JSON.parse(await Deno.readTextFile(downloadPath));
		if (document.version !== WORKSPACE_STATE_VERSION || document.session?.dmMode !== "relay") {
			fail(`the downloaded Rooms state lost its version or connection choice: ${JSON.stringify(document)}`);
		}
		document.view.theme = document.view.theme === "dark" ? "light" : "dark";
		const importedTheme = document.view.theme;
		const importPath = await Deno.makeTempFile({ suffix: ".json" });
		try {
			await Deno.writeTextFile(importPath, JSON.stringify(document));
			await page.setInputFiles("#stateImport", importPath);
			await page.waitForFunction(() => document.querySelector(".file-pick[data-chosen]") !== null).catch(() =>
				fail("the file picker did not show the chosen file")
			);
			await Promise.all([
				page.waitForNavigation(),
				page.click("#stateImportGo"),
			]);
			await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
			const restoredTheme = await page.evaluate(() => document.documentElement.dataset.theme);
			if (restoredTheme !== importedTheme) fail("loading Rooms state did not replace the saved workspace");
		} finally {
			await Deno.remove(importPath).catch(() => {});
		}
	} finally {
		await context.close();
	}
}
