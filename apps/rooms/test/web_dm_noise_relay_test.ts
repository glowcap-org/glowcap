// Two browser tabs direct-message over Rooms' server-reachable DM mode. Both
// advertise noise-relay locators, so one Wasm Host dials through the managed
// relay connector, the other accepts through its held rendezvous socket, and
// the room is absent from the message path. The reply rides the arriving
// session back. The prefs unit test pins `?dm=relay` to this exact wire symbol;
// this scenario proves the mapped product path carries in both directions.

import { type Browser, chromium, type Page } from "playwright";
import { reapOwned, spawnOwned } from "./support/children.ts";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const ROOM = "lobby";
const FIRST = "hello through sealed relay rendezvous";
const REPLY = "replying over the arriving Noise session";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 200; i++) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/locator`);
			await response.body?.cancel();
			if (response.ok) return;
		} catch {
			// The server owns its startup; the scenario owns only this bounded wait.
		}
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
	fail("serve.ts did not publish its room locator");
}

async function join(browser: Browser, port: number, nick: string): Promise<Page> {
	const tab = await (await browser.newContext()).newPage();
	tab.on("pageerror", (error) => console.error(`  [${nick} page error]`, error.message));
	tab.on("console", (message) => {
		if (message.type() === "error") console.error(`  [${nick} console.error]`, message.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/?dm=relay`);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 }).catch(() => fail(`${nick} did not join`));
	return tab;
}

async function openDirect(tab: Page, peer: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${peer}") button.dm-btn`);
	if (!(await button.isVisible().catch(() => false))) await tab.click("#backBtn").catch(() => {});
	await button.waitFor({ state: "visible", timeout: 10_000 }).catch(() =>
		fail(`the room never offered a direct line to ${peer}`)
	);
	await button.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 5_000 });
}

async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

async function sees(tab: Page, text: string, who: string): Promise<void> {
	await tab.waitForFunction(
		(value) => [...document.querySelectorAll(".bubble")].some((bubble) => bubble.textContent?.includes(value)),
		text,
		{ timeout: 10_000 },
	).catch(() => fail(`${who} did not render ${JSON.stringify(text)}`));
}

const deadline = setTimeout(() => fail("Rooms noise-relay DM scenario exceeded 120 seconds"), 120_000);
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

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const alice = await join(browser, httpPort, "noise-alice");
	const bob = await join(browser, httpPort, "noise-bob");

	await openDirect(alice, "noise-bob");
	await send(alice, FIRST);
	await openDirect(bob, "noise-alice");
	await sees(bob, FIRST, "Bob");
	await send(bob, REPLY);
	await sees(alice, REPLY, "Alice");

	console.log(
		"PASS: two Rooms browser peers opened a noise-relay rendezvous session off-room, " +
			"carried a direct message, and replied over the arriving sealed connection",
	);
} finally {
	clearTimeout(deadline);
	await browser?.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
