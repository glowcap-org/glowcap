// The two rails, and a name that turns out to be your own.
//
// Ignoring is the one control here with a way to hurt its own user: a reader who
// silences the name they are about to be granted would stop seeing themselves,
// which is why their own lines are exempt and why that is worth a proof.

import type { Browser, Page } from "playwright";
import { fail } from "./harness.ts";

export async function run(tab: Page, browser: Browser, httpPort: number): Promise<Page> {
	// ── The two rails ────────────────────────────────────────────────────
	// A second peer, so the roster has someone in it other than you: the row that
	// carries a direct-line button is the one the checks below are about, and you
	// never get one for yourself. The name is long on purpose.
	const second = await browser.newPage();
	second.on("pageerror", (e) => console.error("  [page error, second peer]", e.message));
	await second.goto(`http://127.0.0.1:${httpPort}/`);
	await second.fill("#nick", "bartholomew-longname");
	await second.fill("#room", "lobby");
	await second.click("#joinBtn");
	await second.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	await tab.waitForFunction(
		() => document.querySelectorAll("#members li .dm-btn").length > 0,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the second peer never appeared in the roster as directly reachable"));

	// Somebody else typing shows where the reader is about to type, and it is only
	// shown for somebody the room has said is here: a flag costs a tracked name
	// and a timer apiece, and how many arrive is not this window's choice. Checked
	// live rather than reasoned about, because a rule that drops what it should
	// keep looks exactly like a feature that was never wired up.
	await second.click("#line");
	await second.type("#line", "about to say something");
	await tab.waitForFunction(
		() => {
			const said = document.getElementById("typing");
			return said?.classList.contains("show") === true && (said.textContent ?? "").includes("bartholomew");
		},
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const said = await tab.evaluate(() => document.getElementById("typing")?.textContent ?? "(no typing line)");
		fail(`a member typing in the room did not show where the other member is typing: ${JSON.stringify(said)}`);
	});
	await second.fill("#line", "");

	// ── Ignoring a name that turns out to be your own ────────────────────
	// The ignore list is names, and a name is a claim a directory grants and
	// takes back — so a reader's own current name can sit on their own list,
	// put there against a previous holder or by a slip. That used to hide their
	// own messages from them: typed, sent, delivered to everybody else, and
	// invisible only at home, with nothing anywhere saying why.
	{
		await tab.fill("#line", "/ignore web-alice");
		await tab.press("#line", "Enter");
		await tab.waitForFunction(
			() => (document.getElementById("log")?.textContent ?? "").includes("your own name here"),
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const log = ((await tab.textContent("#log")) ?? "").slice(-160);
			fail(`ignoring your own name does not say so: ${JSON.stringify(log)}`);
		});
		// Their own line still draws. This is the reported failure: it used to
		// vanish into the same filter that hides everybody else's.
		await tab.fill("#line", "my own line, while my name is on my own ignore list");
		await tab.press("#line", "Enter");
		await tab.waitForFunction(
			() =>
				[...document.querySelectorAll(".bubble")].some((bubble) =>
					(bubble.textContent ?? "").includes("while my name is on my own ignore list")
				),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("a reader whose own name is on their ignore list cannot see their own messages"));
		// And somebody else is still heard: the list has one name on it, not two.
		await second.fill("#line", "still audible while you ignore yourself");
		await second.press("#line", "Enter");
		await tab.waitForFunction(
			() =>
				[...document.querySelectorAll(".bubble")].some((bubble) =>
					(bubble.textContent ?? "").includes("still audible while you ignore yourself")
				),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("ignoring your own name silenced somebody else"));
		// Entering a room while the list names you says so where you will type.
		await tab.click("#newRoomBtn");
		await tab.fill("#newRoomInput", "aside");
		await tab.press("#newRoomInput", "Enter");
		await tab.waitForFunction(
			() => (document.getElementById("log")?.textContent ?? "").includes("is on your ignore list"),
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const log = ((await tab.textContent("#log")) ?? "").slice(-200);
			fail(`entering a room under an ignored name of your own says nothing: ${JSON.stringify(log)}`);
		});
		// Back where the rest of the scenario expects the reader to be.
		await tab.fill("#line", "/leave");
		await tab.press("#line", "Enter");
		await tab.waitForFunction(
			() => document.getElementById("roomName")?.textContent === "lobby",
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("leaving the aside room did not return to the lobby"));
		await tab.fill("#line", "/unignore web-alice");
		await tab.press("#line", "Enter");
	}

	return second;
}
