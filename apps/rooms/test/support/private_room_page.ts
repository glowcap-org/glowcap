// Browser operations shared by the private-room scenario. This is the page
// vocabulary — join, speak, inspect the rail, and read or redeem a link — while
// web_private_room_test.ts owns the authority story and its process topology.

import type { Browser, Page } from "playwright";

export const ROOM = "lobby";

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

export function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

export async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const answer = await fetch(`http://127.0.0.1:${port}/locator`);
			await answer.body?.cancel();
			if (answer.status === 200) return;
		} catch {
			// not up yet
		}
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

export async function joinAs(browser: Browser, port: number, nick: string): Promise<Page> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (error) => console.error(`  [${nick} page error]`, error.message));
	tab.on("console", (message) => {
		if (message.type() === "error") console.error(`  [${nick} console.error]`, message.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/`);
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}

export async function say(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

/** Name a room in the rail's own field, privately or not. */
export async function makeRoom(tab: Page, label: string, privately: boolean): Promise<void> {
	await tab.click("#newRoomBtn");
	const publicName = await tab.getAttribute("#newRoomInput", "placeholder");
	if (publicName !== "room name") {
		fail(`the rail field said ${JSON.stringify(publicName)} before the lock was pressed`);
	}
	await tab.fill("#newRoomInput", label);
	if (privately) {
		await tab.click(".newroom-private");
		const privateName = await tab.getAttribute("#newRoomInput", "placeholder");
		if (privateName !== "private room name") {
			fail(`the rail field said ${JSON.stringify(privateName)} after the lock was pressed`);
		}
	}
	await tab.press("#newRoomInput", "Enter");
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

/** Stand in the rail row called `name` — the locked one, or the listed one. */
export async function openRailRoom(tab: Page, name: string, locked: boolean): Promise<void> {
	const opened = await tab.evaluate(({ name, locked }) => {
		const row = [...document.querySelectorAll("#roomList li")].find((li) =>
			(li.querySelector(".rname")?.textContent ?? "") === name &&
			(li.querySelector(".hash svg") !== null) === locked
		);
		if (row === undefined) return false;
		((row.querySelector(".rname") ?? row) as HTMLElement).click();
		return true;
	}, { name, locked });
	if (!opened) fail(`no ${locked ? "locked" : "listed"} room called ${JSON.stringify(name)} to stand in`);
	await tab.waitForFunction(
		({ name, locked }) =>
			[...document.querySelectorAll("#roomList li")].some((li) =>
				(li.querySelector(".rname")?.textContent ?? "") === name &&
				(li.querySelector(".hash svg") !== null) === locked &&
				li.classList.contains("here")
			),
		{ name, locked },
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
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	fail(`${what} never began listening on ${port}`);
}

/** The link one tab reads out of its own room, as copyable text. */
export async function roomLink(tab: Page, who: string): Promise<string> {
	await say(tab, "/link");
	const shown = await tab.waitForFunction(
		() => {
			const line = [...document.querySelectorAll("#log .sys")]
				.map((row) => row.textContent ?? "")
				.find((text) => text.includes("ocapn://"));
			return line === undefined ? null : (line.match(/ocapn:\/\/\S+/) ?? [null])[0];
		},
		undefined,
		{ timeout: 30_000 },
	).then((handle) => handle.jsonValue()).catch(() => null);
	if (typeof shown !== "string" || !shown.includes("/s/")) {
		fail(`/link did not say a link to ${who}'s room: ${JSON.stringify(shown)}`);
	}
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
