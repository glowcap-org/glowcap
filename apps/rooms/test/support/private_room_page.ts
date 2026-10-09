// Browser operations the private-room scenario and its siblings share: making
// a room from the rail, standing in one, reading or redeeming a link. The
// private-room proof owns the authority story and its process topology.

import type { Page } from "playwright";

import { fail } from "./fail.ts";
import { delay } from "./wait.ts";
import { namedRoomRow } from "./conversation_row.ts";

/** Name a room in the rail's own field, privately or not. */
export async function makeRoom(tab: Page, label: string, privately: boolean): Promise<void> {
	await tab.click("#newRoomBtn");
	const publicName = await tab.getAttribute("#newRoomInput", "placeholder");
	if (publicName !== "open room name") {
		fail(`the rail field said ${JSON.stringify(publicName)} before the access control was pressed`);
	}
	await tab.fill("#newRoomInput", label);
	if (privately) {
		// The control cycles open, moderated, private, so private is two presses
		// from the default. The placeholder below is what says which one this
		// stopped on, which is why it is read rather than assumed.
		await tab.click(".newroom-private");
		await tab.click(".newroom-private");
		const privateName = await tab.getAttribute("#newRoomInput", "placeholder");
		if (privateName !== "private room name") {
			fail(`the rail field said ${JSON.stringify(privateName)} after pressing through to private`);
		}
	}
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForFunction(
		({ label, privately }) => {
			const line = document.querySelector<HTMLInputElement>("#line");
			return line !== null && !line.disabled &&
				[...document.querySelectorAll("#roomList li")].some((row) =>
					(row.querySelector(".rname")?.textContent ?? "") === label &&
					(row.querySelector(".hash svg") !== null) === privately &&
					row.classList.contains("here")
				);
		},
		{ label, privately },
		{ timeout: 30_000 },
	).catch(() => fail(`creating ${privately ? "private " : ""}${JSON.stringify(label)} never opened it`));
}

/** Every room row this tab holds, as a reader sees it. */
export function railRooms(tab: Page): Promise<{ name: string; locked: boolean; here: boolean }[]> {
	return tab.evaluate(() =>
		[...document.querySelectorAll("#roomList li")].map((row) => ({
			name: row.querySelector(".rname")?.textContent ?? "",
			locked: row.querySelector(".hash svg") !== null,
			here: row.classList.contains("here"),
		}))
	);
}

/** Stand in the rail row called `name`, telling two rooms of one name apart by
 * their mark.
 *
 * `marked` is whether the row draws a glyph rather than the plain `#`, which is
 * every access except the open one: a private room draws its lock and a
 * moderated one its observer. So this is not only "the private one" — a room
 * whose access was changed to moderated is marked too, and asking for the
 * unmarked row would look past it. */
export async function openRailRoom(tab: Page, name: string, marked: boolean): Promise<void> {
	// A reload can realize the saved row before its live policy arrives.
	// Wait for the requested policy mark before choosing between equal names.
	const mark = tab.locator(".hash svg");
	const row = namedRoomRow(tab, name).filter(marked ? { has: mark } : { hasNot: mark });
	await row.locator(".rname").click({ timeout: 15_000 }).catch(() =>
		fail(`no ${marked ? "marked" : "open-access"} room called ${JSON.stringify(name)} to stand in`)
	);
	await tab.waitForFunction(
		({ name, marked }) =>
			[...document.querySelectorAll("#roomList li")].some((li) =>
				(li.querySelector(".rname")?.textContent ?? "") === name &&
				(li.querySelector(".hash svg") !== null) === marked &&
				li.classList.contains("here")
			),
		{ name, marked },
		{ timeout: 15_000 },
	).catch(() => fail(`standing in ${JSON.stringify(name)} never became the open conversation`));
}

export function said(tab: Page): Promise<string> {
	return tab.evaluate(() => document.getElementById("log")?.textContent ?? "");
}

/** Wait until something is accepting connections on `port`. */
export async function waitForTcp(port: number, what: string): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const probe = await Deno.connect({ hostname: "127.0.0.1", port });
			probe.close();
			return;
		} catch {
			// not listening yet
		}
		await delay(50);
	}
	fail(`${what} never began listening on ${port}`);
}

/** The link one tab reads out of its own room, as copyable text. */
export async function roomLink(tab: Page, who: string): Promise<string> {
	await tab.click("#roomAbout");
	await tab.click("#convcardCapabilitiesTab");
	const explanation = (await tab.textContent("#convcardRoomLinkHint")) ?? "";
	if (
		!explanation.includes("durable bearer link") || !explanation.includes("pass it on") ||
		!explanation.includes("across restarts") || !explanation.includes("message history")
	) {
		fail(`the room-link control did not explain its authority and lifetime: ${JSON.stringify(explanation)}`);
	}
	if (await tab.locator("#convcardRoomLink").count() === 0) {
		if (await tab.locator("#convcardCreateRoomLink").count() !== 1) {
			fail(`the Capabilities tab did not offer a room-link control for ${who}`);
		}
		await tab.click("#convcardCreateRoomLink");
		await tab.waitForSelector("#convcardRoomLink", { timeout: 30_000 })
			.catch(() => fail(`pressing Create room link did not expose ${who}'s link`));
	}
	// The control appears while the managed command settles. Its content is
	// the evidence that the room minted a link, rather than the pending shell.
	await tab.waitForFunction(
		() => document.querySelector("#convcardRoomLink")?.textContent?.includes("/s/"),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail(`the room did not finish minting ${who}'s link`));
	const shown = (await tab.textContent("#convcardRoomLink"))?.trim() ?? null;
	if (typeof shown !== "string" || !shown.includes("/s/")) {
		fail(`the Capabilities tab did not expose a link to ${who}'s room: ${JSON.stringify(shown)}`);
	}
	await tab.click("#convcardClose");
	return shown;
}

/** Whether this tab visibly holds more than its home directory. */
export function directoriesNamed(tab: Page): Promise<number> {
	return tab.locator("#roomList .rwhere").count();
}

/** What the page said last about a link that was pasted into it. */
export function refusalAbout(tab: Page): Promise<string> {
	return tab.evaluate(() =>
		[...document.querySelectorAll("#log .sys")]
			.map((row) => row.textContent ?? "")
			.filter((text) => text.includes("That link did not open a room"))
			.at(-1) ?? ""
	);
}
