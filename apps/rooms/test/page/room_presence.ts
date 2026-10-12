// Explicit departure, transport loss and return through local and shared-session pages.
/// <reference lib="dom" />
import type { Browser, Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { fillSettled, say } from "./harness.ts";

const peer = "presence-peer";
const room = "mirror-one";
const row = (page: Page) => page.locator("#members li").filter({ has: page.locator(`.name[title="${peer}"]`) });

async function join(page: Page, httpPort: number, nick: string) {
	await page.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(page);
	await page.fill("#nick", nick);
	await page.fill("#room", room);
	await page.click("#joinBtn");
	await page.waitForFunction(
		(room) =>
			document.getElementById("roomName")?.textContent?.trim() === room &&
			(document.querySelector<HTMLTextAreaElement>("#line")?.disabled === false),
		room,
		{ timeout: 30_000 },
	);
}

async function state(page: Page, expected: "online" | "offline") {
	await row(page).and(page.locator(`li.${expected}`)).waitFor({ timeout: 15_000 });
	if (expected === "offline") await row(page).getByText("offline", { exact: true }).waitFor();
}

export async function proveRoomPresence(browser: Browser, httpPort: number, attached: readonly [Page, Page]) {
	const departing = await browser.newContext();
	const visitor = await browser.newContext();
	const returning = await browser.newContext();
	try {
		const member = await departing.newPage();
		await join(member, httpPort, peer);
		for (const page of attached) await state(page, "online");
		await say(member, "/leave");
		for (const page of attached) await row(page).waitFor({ state: "detached", timeout: 15_000 });
		await member.locator("#joinBtn:enabled").waitFor();
		await fillSettled(member, "#room", room);
		await member.click("#joinBtn");
		for (const page of attached) await state(page, "online");

		// Closing the whole context ends its Wasm Host and transport, without /leave.
		await departing.close();
		for (const page of attached) await state(page, "offline");
		const fresh = await visitor.newPage();
		await join(fresh, httpPort, "presence-viewer");
		await state(fresh, "offline");
		await attached[0].reload();
		await attached[0].waitForSelector("#line:not([disabled])");
		await state(attached[0], "offline");
		await Deno.mkdir(".local/probes", { recursive: true });
		await attached[0].screenshot({ path: ".local/probes/room-offline-presence.png", fullPage: true });

		const back = await returning.newPage();
		await join(back, httpPort, peer);
		for (const page of [...attached, fresh]) await state(page, "online");
		await say(back, "/leave");
		for (const page of [...attached, fresh]) await row(page).waitFor({ state: "detached", timeout: 15_000 });
		console.log(
			"Room presence: leave removes, disconnect stays offline across arrival/reload, return restores online.",
		);
	} finally {
		await departing.close();
		await visitor.close();
		await returning.close();
	}
}
