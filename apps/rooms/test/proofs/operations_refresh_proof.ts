import { spawnWeb } from "../support/web_front.ts";
// The shipped page refreshes operator inventories through its Rust read owner.
import { chromium } from "playwright";

import { reapOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { removeCapability, takeCapability } from "../page/capability_set.ts";
import { fail } from "../support/fail.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";

const root = new URL("../../../../", import.meta.url).pathname;
const state = await Deno.makeTempDir({ prefix: "rooms-operations-refresh-" });
const http = freePort();
const room = freePort();
let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined;
const deadline = setTimeout(() => fail("operations-refresh scenario timed out after 180s"), 180_000);
try {
	spawnWeb({
		args: ["--transport=tcp", String(http), String(room)],
		cwd: root,
		env: { GLOWCAP_ROOMS_STATE: state, GLOWCAP_ROOMS_OPERATOR: "1" },
		stdout: "null",
		stderr: "inherit",
	});
	await waitForHttp(http);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("console", (event) => {
		if (event.type() === "error") console.error(`PAGE-CONSOLE ${event.text()}`);
	});
	tab.on("pageerror", (error) => console.error(`PAGE-ERROR ${error.message}`));
	await tab.goto(`http://127.0.0.1:${http}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", "ada");
	await tab.fill("#room", "refresh-proof");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	for (let index = 0; index < 35; index += 1) {
		const name = `page-${String(index).padStart(2, "0")}`;
		await tab.click("#newRoomBtn");
		await tab.fill("#newRoomInput", name);
		await tab.press("#newRoomInput", "Enter");
		await namedRoomRow(tab, name, true).waitFor({ timeout: 10_000 }).catch(async () =>
			fail(`room ${name} was not installed: ${await tab.locator("body").innerText()}`)
		);
	}
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	const locator = await (await fetch(`http://127.0.0.1:${http}/locator`)).text();
	const operator = formatRoomsSturdyref(
		roomsLocator(locator.trim()),
		(await Deno.readTextFile(`${state}/operator`)).trim(),
	);
	await takeCapability(tab, "#opsOperatorToggle", operator);
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operatorSearch");
	await tab.waitForFunction(() => document.querySelectorAll("#operatorRooms .entry").length === 32);
	await tab.locator("#operatorRooms").getByRole("button", { name: "Load more", exact: true }).click();
	await tab.waitForFunction(() => document.querySelectorAll("#operatorRooms .entry").length === 36);
	await tab.fill("#operatorSearch", "no-such-room");
	await tab.fill("#operatorSearch", "refresh-proof");
	await tab.waitForFunction(() =>
		document.getElementById("operatorSearchSaid")?.textContent?.includes("refresh-proof") === true &&
		document.querySelectorAll("#operatorRooms .entry").length === 1
	);
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await removeCapability(tab, "#opsOperatorToggle");
	await tab.click("#settingsClose");
	await tab.waitForSelector("#operatorRooms", { state: "detached" });
	await tab.reload();
	await tab.waitForSelector("#settingsBtn");
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await tab.waitForFunction(() =>
		document.getElementById("opsOperatorToggle")?.getAttribute("aria-checked") === "false"
	);
	console.log("PASS: Rust operations reads, retained pagination, latest search, credential removal and reload");
} finally {
	clearTimeout(deadline);
	await browser?.close();
	await reapOwned();
	await Deno.remove(state, { recursive: true });
}
