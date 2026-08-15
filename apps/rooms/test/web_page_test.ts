// The rooms web page as a real browser peer, end to end. A headless Chromium
// loads the ACTUAL page serve.ts serves — the
// bundled `@pancake/web` graph, `pancake_host.wasm`, and the UI — joins a
// room, sends a line, and sees the room echo it back. Every hop is the shipped
// path: the page's wasm Host holds the room capability, dials the room server
// through serve.ts's `/relay`, and drives `lib/room_client.ts` directly. No JSON
// bridge is on the page's path.
//
// Before that it watches the load itself, frame by frame from the first one,
// because what a reader sees on the way in is part of the page too: the screen
// that stands in while the peer opens has to be there, and the message meant for
// a browser that cannot run this page must never appear on one that can.
//
// It then holds the two rails that flank the conversation — the rooms and
// direct-message list, and the roster — to the promises they make on both
// layouts. A real browser is the only place any of this can be checked: every
// one of them is about what a reader can see or reach, and a stylesheet read on
// its own says nothing about either.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web_page_test.ts`.

import { Buffer } from "node:buffer";
import { chromium } from "playwright";
import type { Page } from "playwright";
import { inkContrast } from "./ink_contrast.ts";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;

// Throw rather than exit: `Deno.exit` skips the `finally` below, which is what
// kills the room server this test spawned. A failure used to leave that child
// alive holding the inherited stdout pipe, so whoever was reading this test's
// output — `zig build`, a CI runner — waited on an end-of-file that never came.
// A failing check has to fail, not hang.
function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}

/** Lowest ink contrast for a translucent descendant surface over either end of
 * its containing bubble's gradient. This checks the composite a person sees,
 * not the declarations in isolation. */
async function bubbleInkContrast(
	page: Page,
	selector: string,
	surfaceSelector: string = selector,
): Promise<number | null> {
	await page.hover(selector);
	return page.evaluate(({ selector, surfaceSelector }) => {
		type Rgba = [number, number, number, number];
		const colors = (value: string): Rgba[] =>
			[...value.matchAll(/rgba?\(([^)]+)\)/g)].map((match) => {
				const parts = match[1].split(/[ ,/]+/).filter(Boolean).map(Number);
				return [parts[0], parts[1], parts[2], parts[3] ?? 1];
			});
		const relative = ([r, g, b]: Rgba): number => {
			const channel = (n: number) => {
				const s = n / 255;
				return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
			};
			return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
		};
		const contrast = (a: Rgba, b: Rgba): number => {
			const [bright, dark] = [relative(a), relative(b)].sort((x, y) => y - x);
			return (bright + 0.05) / (dark + 0.05);
		};
		const over = (front: Rgba, back: Rgba): Rgba => [
			front[0] * front[3] + back[0] * (1 - front[3]),
			front[1] * front[3] + back[1] * (1 - front[3]),
			front[2] * front[3] + back[2] * (1 - front[3]),
			1,
		];

		const target = document.querySelector(selector);
		const surface = target?.closest(surfaceSelector);
		const bubble = target?.closest(".bubble");
		if (!(target instanceof HTMLElement) || !(surface instanceof HTMLElement) || !(bubble instanceof HTMLElement)) {
			return null;
		}
		const ink = colors(getComputedStyle(target).color)[0];
		const wash = colors(getComputedStyle(surface).backgroundColor)[0];
		const stops = colors(getComputedStyle(bubble).backgroundImage);
		if (!ink || !wash || stops.length < 2) return null;
		return Math.min(...stops.map((stop) => contrast(ink, over(wash, stop))));
	}, { selector, surfaceSelector });
}

function freePort(): number {
	const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (l.addr as Deno.NetAddr).port;
	l.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200) return;
		} catch {
			// not up / room not ready yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

const httpPort = freePort();
const roomPort = freePort();
const foreignRoomPort = freePort();

// A second authority, not another room on the page's own server. The browser
// relay is explicitly allowed to reach this one TCP peer for the scenario;
// production cross-server joins use authenticated iroh, whose destinations do
// not need an address allow-list.
// The second server, stood back up so a retry has somewhere to land.
let foreignAgain: Deno.ChildProcess | null = null;

const foreignRoom = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		`${ROOT}apps/rooms/server/main.ts`,
		String(foreignRoomPort),
	],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
}).spawn();

const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		// Somewhere to keep room state. Given no directory of its own, serve.ts
		// makes a temporary one at startup, so it cannot come up without this.
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	env: { PANCAKE_RELAY_TCP_PEERS: `127.0.0.1:${foreignRoomPort}` },
	stdout: "piped",
	stderr: "inherit",
}).spawn();

// The scenario's own deadline. It cannot go through `fail`: a throw inside a
// timer does not reach the try below, so it tears the room server down itself
// before leaving, for the same reason `fail` throws rather than exits.
const deadline = setTimeout(() => {
	console.error("FAIL: web-page scenario timed out after 150s");
	try {
		web.kill();
	} catch {
		// already gone
	}
	try {
		foreignRoom.kill();
	} catch {
		// already gone
	}
	Deno.exit(1);
}, 150_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));

	// ── The opening screen ───────────────────────────────────────────────
	// The page draws itself, so page.html holds a screen up until it has, and
	// carries an explanation for when it never will. Three things have to hold,
	// and the first of them is the one a reader complained about: the
	// explanation is for a page that cannot run, so a page that can must never
	// lay it out — not on mount, not for a frame before it.
	//
	// Watched from the first frame rather than looked at afterwards. Asking once
	// the page is up would pass on the version that flashed the message and
	// replaced it, which is the whole defect.
	await tab.addInitScript(() => {
		const seen = { explain: 0, wait: 0 };
		(globalThis as unknown as { seenFrames: typeof seen }).seenFrames = seen;
		const laidOut = (sel: string) => (document.querySelector(sel)?.getClientRects().length ?? 0) > 0;
		const sample = () => {
			if (laidOut(".boot-explain")) seen.explain++;
			if (laidOut(".boot-wait")) seen.wait++;
			requestAnimationFrame(sample);
		};
		requestAnimationFrame(sample);
	});
	await tab.goto(`http://127.0.0.1:${httpPort}/`);
	const bootMark = await tab.locator(".boot-mark").evaluate((mark) => {
		const probe = document.createElement("span");
		probe.style.color = "var(--accent)";
		document.body.append(probe);
		const brand = getComputedStyle(probe).color;
		probe.remove();
		return { painted: getComputedStyle(mark).backgroundColor, brand };
	});
	if (bootMark.painted !== bootMark.brand) {
		fail(`the opening mark is ${bootMark.painted} where the brand is ${bootMark.brand}`);
	}
	await tab.waitForSelector("#joinBtn", { timeout: 60_000 });

	// The screen is the peer's to end, not the bundle's: it stays up until the
	// session has come back, so by the time it goes the room list behind it is
	// the real one. Ended, it leaves the document entirely.
	await tab.waitForSelector("#boot", { state: "detached", timeout: 60_000 })
		.catch(() => fail("the opening screen never handed the page over"));
	const frames = await tab.evaluate(() =>
		(globalThis as unknown as { seenFrames: { explain: number; wait: number } }).seenFrames
	);
	if (frames.explain > 0) {
		fail(
			`the "needs JavaScript" message was on screen for ${frames.explain} frames of a ` +
				`load that ran fine; a reader sees that as a flash`,
		);
	}
	if (frames.wait === 0) {
		fail("nothing was on screen while the page was opening; the reader waits on a blank");
	}

	// A reader who has asked for less motion gets a mark that sits still and
	// still gets the page. Both halves are worth holding: the mark's animation
	// yields to the sheet's own reduced-motion rule, and the screen is taken out
	// of the document when its fade ends — a fade that same rule shortens to
	// nothing. Were that end never reported, the screen would stay in the
	// document for good, and only this reader would ever find out.
	{
		const still = await browser.newContext({ reducedMotion: "reduce" });
		const calm = await still.newPage();
		await calm.addInitScript(() => {
			const held = { motion: "" };
			(globalThis as unknown as { markMotion: typeof held }).markMotion = held;
			const sample = () => {
				const mark = document.querySelector(".boot-mark");
				if (mark !== null) held.motion = getComputedStyle(mark).animationDuration;
				if (held.motion === "") requestAnimationFrame(sample);
			};
			requestAnimationFrame(sample);
		});
		await calm.goto(`http://127.0.0.1:${httpPort}/`);
		await calm.waitForSelector("#boot", { state: "detached", timeout: 60_000 })
			.catch(() => fail("with less motion asked for, the opening screen never left the document"));
		const motion = await calm.evaluate(() =>
			(globalThis as unknown as { markMotion: { motion: string } }).markMotion.motion
		);
		if (parseFloat(motion) > 0.01) {
			fail(`the opening screen's mark still animates for ${motion} under reduced motion`);
		}
		await still.close();
	}

	// The other two: a browser with scripting off is told why there is nothing
	// here, and so is one whose bundle never arrived — the case nobody sees until
	// it happens to them.
	{
		const off = await browser.newContext({ javaScriptEnabled: false });
		const quiet = await off.newPage();
		await quiet.goto(`http://127.0.0.1:${httpPort}/`);
		if (!await quiet.locator(".boot-explain").isVisible()) {
			fail("a browser with scripting off is not told why the page is empty");
		}
		if (await quiet.locator(".boot-wait").isVisible()) {
			fail("a browser with scripting off is shown a wait that will never end");
		}
		await off.close();

		const dark = await browser.newContext();
		const blind = await dark.newPage();
		await blind.route("**/page.js", (route) => route.fulfill({ status: 503, body: "" }));
		await blind.goto(`http://127.0.0.1:${httpPort}/`);
		if (!await blind.locator(".boot-explain").isVisible()) {
			fail("a page whose bundle did not load shows a reader nothing at all");
		}
		await dark.close();
	}

	// The dialog opens on Locators and keeps the knobs on Advanced.
	// It has to be there before join, and a URL that names a transport still
	// wins over whatever this browser last saved. The opening screen has to
	// have left first: it covers the topbar until then.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.waitForFunction(() => {
		const layer = document.querySelector("dialog.modal");
		return layer?.matches(":modal") === true && document.activeElement?.id === "overviewTab";
	}).catch(() => fail("Settings looked modal without becoming the focused native modal"));
	await tab.waitForFunction(() => {
		const loc = document.getElementById("directoryLocator")?.textContent ?? "";
		return loc.length > 1 && loc !== "…";
	}, { timeout: 15_000 }).catch(() => fail("Locators never showed the room locator"));

	// The card answers whether anyone can message you here, which is the question
	// a granted name raises next. That answer comes from a registration this
	// directory can refuse, and a refusal leaves this window in every roster
	// looking ordinary while nothing can arrive — so the healthy answer is worth
	// pinning: a fact that was never wired up reads exactly like one that is fine.
	const dmFact = () =>
		tab.evaluate(() => {
			const row = [...document.querySelectorAll(".dirfacts dt")]
				.find((term) => term.textContent?.trim() === "Direct messages");
			return row?.nextElementSibling?.textContent?.trim() ?? "(no row)";
		});
	const beforeAName = await dmFact();
	if (!beforeAName.includes("no name granted")) {
		fail(`before a name was granted, the card answered ${JSON.stringify(beforeAName)}`);
	}

	// A copy has no visible result, because the clipboard is somewhere the page
	// cannot show. So the control answers for it, and both halves of that answer
	// are the feature: it says the copy happened, and it goes back to offering on
	// its own rather than staying said.
	await tab.context().grantPermissions(["clipboard-read", "clipboard-write"], {
		origin: `http://127.0.0.1:${httpPort}`,
	});
	// The press lands on the text rather than on the mark in the corner, because
	// the whole field being the control is the point: a locator is shown so it
	// can be taken, so anywhere in it means the one thing it could mean.
	const locatorShown = (await tab.textContent("#directoryLocator"))?.trim() ?? "";
	await tab.click("#directoryLocator");
	// Found through the field itself rather than through its label: what the label
	// says is the surface's business and moves with the words on it, while this is
	// about whether a copy answers at all.
	await tab.waitForFunction(() => {
		const field = document.getElementById("directoryLocator")?.closest<HTMLElement>(".copy-field");
		const said = field?.querySelector(".copy-said")?.textContent?.trim() ?? "";
		return said !== "" && field?.dataset.copied !== undefined;
	}, { timeout: 5_000 }).catch(() => fail("copying a locator said nothing at all"));
	const onClipboard = await tab.evaluate(() => navigator.clipboard.readText());
	if (onClipboard.trim() !== locatorShown || locatorShown === "") {
		fail(`the copy control put ${JSON.stringify(onClipboard)} on the clipboard, not the locator`);
	}
	await tab.waitForFunction(() => {
		const field = document.getElementById("directoryLocator")?.closest<HTMLElement>(".copy-field");
		const said = field?.querySelector(".copy-said")?.textContent?.trim() ?? "";
		return said === "" && field?.dataset.copied === undefined;
	}, { timeout: 6_000 }).catch(() => fail("the copy control stayed said instead of going back to a button"));

	await tab.waitForSelector("#themeToggle");
	await tab.waitForSelector("#notifyToggle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.keyboard.press("ArrowLeft");
	await tab.waitForFunction(() =>
		document.activeElement?.id === "overviewTab" &&
		document.getElementById("overviewTab")?.getAttribute("tabindex") === "0" &&
		document.getElementById("settingsTab")?.getAttribute("tabindex") === "-1"
	).catch(() => fail("the Settings tabs did not move selection and focus together"));
	await tab.keyboard.press("ArrowRight");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	const defaultDm = await tab.evaluate(() =>
		(document.querySelector('input[name="dm"]:checked') as HTMLInputElement | null)?.value ?? ""
	);
	if (defaultDm !== "webrtc") {
		fail(`Settings opened on ${defaultDm}, not webrtc`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
	await tab.waitForFunction(() => document.activeElement?.id === "settingsBtn")
		.catch(() => fail("closing Settings did not return focus to its opener"));
	{
		const relayTab = await browser.newPage();
		await relayTab.goto(`http://127.0.0.1:${httpPort}/?dm=relay`);
		await relayTab.waitForSelector("#boot", { state: "detached", timeout: 60_000 })
			.catch(() => fail("the ?dm=relay tab's opening screen never left"));
		await relayTab.click("#settingsBtn");
		await relayTab.waitForSelector("#settingsTitle");
		await relayTab.click("#settingsTab");
		const relayDm = await relayTab.evaluate(() =>
			(document.querySelector('input[name="dm"]:checked') as HTMLInputElement | null)?.value ?? ""
		);
		if (relayDm !== "relay") {
			fail(`?dm=relay opened Settings on ${relayDm}, not relay`);
		}
		await relayTab.close();
	}

	// Join a room as a real peer: fill the nick and room, press Join.
	await tab.fill("#nick", "web-alice");
	await tab.fill("#room", "lobby");
	await tab.click("#joinBtn");

	// The composer's line input becomes usable once we are in the room.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });

	// Send a line; the room echoes it to every member (including us), so it
	// arrives back through the capability stream and renders as a bubble.
	const line = "hello from a browser peer";
	await tab.fill("#line", line);
	await tab.press("#line", "Enter");

	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		line,
		{ timeout: 30_000 },
	).catch(() => fail("the sent line never came back from the room over the capability stream"));

	// And now that this directory has granted a name, the same row answers the
	// question that name raises. It is a registration this directory can refuse,
	// and a refusal leaves this window in every roster looking ordinary while
	// nothing can arrive, so the healthy answer is worth pinning: a fact nobody
	// wired up reads exactly like one that is fine.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.waitForFunction(
		() => {
			const row = [...document.querySelectorAll(".dirfacts dt")]
				.find((term) => term.textContent?.trim() === "Direct messages");
			return (row?.nextElementSibling?.textContent ?? "").includes("can reach you");
		},
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		fail(`with a name granted, the card answers ${JSON.stringify(await dmFact())} about reaching this tab`);
	});
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });

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

	// ── Inline completion ────────────────────────────────────────────────
	// `@` plus a prefix raises the list with the roster's match; Enter accepts
	// into the draft instead of sending, which is the regression this guards:
	// with the list open, Enter belongs to the completion.
	await tab.click("#line");
	await tab.type("#line", "@bart");
	await tab.waitForSelector("#completePop [role=option]", { timeout: 10_000 })
		.catch(() => fail("typing @bart never raised the completion list"));
	await tab.press("#line", "Enter");
	const completed = await tab.inputValue("#line");
	if (completed !== "@bartholomew-longname ") {
		fail(`completion left the draft as ${JSON.stringify(completed)}`);
	}
	// Completion starts on the first useful emoji character; waiting for two or
	// more makes a fast typist outrun a discoverability feature.
	await tab.type("#line", ":r");
	await tab.waitForSelector("#completePop [role=option]", { timeout: 10_000 })
		.catch(() => fail("typing :r never raised the emoji list"));
	await tab.type("#line", "ocke");
	await tab.press("#line", "Enter");
	const withEmoji = await tab.inputValue("#line");
	if (!withEmoji.endsWith("🚀")) {
		fail(`emoji completion left the draft as ${JSON.stringify(withEmoji)}`);
	}
	await tab.fill("#line", "");

	// Commands are discoverable before the reader already knows their spelling.
	// The accepted command then rides the ordinary message protocol, and every
	// client renders it as an action rather than a literal slash-prefixed line.
	await tab.type("#line", "/");
	// Braced so these names belong to this check rather than to the whole file.
	// This module is one long scope, and three separate additions to it have now
	// collided with a name a hundred lines away.
	{
		const labels = await tab.locator("#completePop [role=option]").allTextContents();
		if (labels.length === 0) fail("typing / offered no commands at all");
		// Every one says what it does, so the list teaches rather than expecting a
		// reader to already know the vocabulary.
		const mute = labels.filter((label) => !label.includes("—"));
		if (mute.length > 0) fail(`a command was offered with nothing said about it: ${JSON.stringify(mute)}`);
		// A command the room has to hand over says so here, before a reader spends
		// a message finding out. Holding one is the whole of the permission, so the
		// names of the ones this reader does not hold are still worth meeting.
		if (!labels.some((label) => label.includes("(not granted here)"))) {
			fail(`no command said it waits on the room: ${JSON.stringify(labels)}`);
		}
	}
	// Typed far enough to name one, the list narrows to it and Enter takes it.
	await tab.type("#line", "me");
	await tab.waitForSelector('#completePop [role=option]:has-text("/me")', { timeout: 10_000 })
		.catch(() => fail("typing /me did not offer the /me command"));
	await tab.press("#line", "Enter");
	if (await tab.inputValue("#line") !== "/me ") fail("accepting /me did not leave an action draft");
	await tab.fill("#line", "/me waves hello");
	await tab.press("#line", "Enter");
	await second.waitForSelector('.sys.action:has-text("✻ web-alice waves hello")', { timeout: 30_000 })
		.catch(() => fail("the second peer did not render /me as an action"));

	// Changing and taking back a line, all the way through: the room hands back a
	// reference to each line it takes, and holding one is the authority. Asked
	// from the other tab as well as this one, because a line changing only for
	// the person who changed it would look identical from here and be useless.
	{
		const said = "frist post";
		await tab.fill("#line", said);
		await tab.press("#line", "Enter");
		await second.waitForSelector(`.bubble:has-text("${said}")`, { timeout: 30_000 })
			.catch(() => fail("the other peer never saw the line that was about to be changed"));

		await tab.fill("#line", "/edit first post");
		await tab.press("#line", "Enter");
		await second.waitForSelector('.bubble:has-text("first post")', { timeout: 30_000 })
			.catch(() => fail("an edit never reached the other peer"));
		// The old words are gone rather than sitting beside the new ones.
		if (await second.locator(`.bubble:has-text("${said}")`).count() > 0) {
			fail("the line still reads as what it used to say");
		}
		// And it says it moved, so a reader who answered the old words can tell.
		await second.waitForSelector(".edited-said", { timeout: 10_000 })
			.catch(() => fail("a changed line does not say it was changed"));

		await tab.fill("#line", "/delete");
		await tab.press("#line", "Enter");
		await second.waitForSelector(".bubble.withdrawn", { timeout: 30_000 })
			.catch(async () => {
				const there = await second.evaluate(() =>
					[...document.querySelectorAll(".bubble")].map((b) =>
						b.className + ": " + (b.textContent ?? "").slice(0, 30)
					)
				);
				const here = await tab.evaluate(() =>
					[...document.querySelectorAll("#log .sys")].map((s) => (s.textContent ?? "").slice(0, 90))
				);
				const composer = await tab.inputValue("#line");
				fail(
					`the other peer never showed a line as withdrawn; it holds ${
						JSON.stringify(there)
					}, this tab was told ${JSON.stringify(here)}, and its composer holds ${JSON.stringify(composer)}`,
				);
			});
		// It keeps its place and shows none of what it said.
		if (await second.locator('.bubble:has-text("first post")').count() > 0) {
			fail("a withdrawn line still shows what it said");
		}
		await second.waitForSelector('.withdrawn-said:has-text("Message withdrawn")', { timeout: 10_000 })
			.catch(() => fail("a withdrawn line does not say what happened to it"));
	}

	// The pencil changes the line it was pressed on. `/edit` changes the most
	// recent one, so a pencil that only filled the composer with that command
	// would quietly rewrite a different message whenever a reader picked an older
	// one — which is why the composer remembers the line rather than the words.
	{
		for (const said of ["older line", "newer line"]) {
			await tab.fill("#line", said);
			await tab.press("#line", "Enter");
			await second.waitForSelector(`.bubble:has-text("${said}")`, { timeout: 30_000 })
				.catch(() => fail(`the other peer never saw "${said}"`));
		}
		const older = tab.locator('.bubble:has-text("older line")').last();
		// The controls appear on the message under the pointer, so reach it the way
		// a reader does rather than by making them permanently visible for a test.
		await older.hover();
		await older.getByLabel("Change this message").click();
		if (await tab.inputValue("#line") !== "older line") {
			fail("the pencil did not put that line's words in the composer");
		}
		await tab.waitForSelector("#changing", { timeout: 10_000 })
			.catch(() => fail("the composer does not say it is changing a message rather than writing one"));
		await tab.fill("#line", "older line, fixed");
		await tab.press("#line", "Enter");
		await second.waitForSelector('.bubble:has-text("older line, fixed")', { timeout: 30_000 })
			.catch(() => fail("the change made with the pencil never reached the other peer"));
		// The one that says whether the right line moved: the newest line is still
		// the newest and still says what it said.
		const newest = await second.locator(".bubble").last().textContent();
		if (newest === null || !newest.includes("newer line")) {
			fail(`the pencil changed the most recent line instead of the one it was on: ${JSON.stringify(newest)}`);
		}
		// And the composer is a composer again, with nothing held over.
		if (await tab.locator("#changing").count() !== 0) {
			fail("the composer still says it is changing a message after the change was sent");
		}
	}

	// What the room is about is a capability rather than a rank. The room answers
	// every subscribe with the authority to set it, so this works from a tab that
	// did not open the room, and it reaches everybody including whoever arrives
	// afterwards.
	{
		await tab.fill("#line", "/topic what we are here for");
		await tab.press("#line", "Enter");
		await second.waitForSelector('#topic:has-text("what we are here for")', { timeout: 30_000 })
			.catch(async () => {
				const said = await tab.evaluate(() =>
					[...document.querySelectorAll("#log .sys")].map((s) => (s.textContent ?? "").slice(0, 90)).slice(-3)
				);
				fail(`the topic never reached the other peer; this tab was last told ${JSON.stringify(said)}`);
			});
		// The way to change it is offered because this membership was handed the
		// ability, and pressing it writes the command with what the topic says
		// now — so amending a topic is amending text rather than retyping it.
		await tab.waitForSelector('#topic [aria-label="Change the topic"]', { timeout: 10_000 })
			.catch(() => fail("a member the room handed the topic to was not offered a way to change it"));
		await tab.click('#topic [aria-label="Change the topic"]');
		if (await tab.inputValue("#line") !== "/topic what we are here for") {
			fail(`changing the topic did not write the command: ${JSON.stringify(await tab.inputValue("#line"))}`);
		}
		// Taking it down is a thing somebody does on purpose, so it is an empty
		// topic rather than no topic, and the bar goes rather than sitting there
		// holding a blank.
		await tab.fill("#line", "/topic -");
		await tab.press("#line", "Enter");
		await second.waitForSelector("#topic", { state: "detached", timeout: 30_000 })
			.catch(() => fail("taking the topic down left the bar on screen"));
	}

	// Stepping away is a member's own standing rather than something handed to
	// them, and it is about somebody who is still here: the room says it, and it
	// shows against their name where the question "are they reading this" is
	// actually asked.
	{
		await tab.fill("#line", "/away back in ten");
		await tab.press("#line", "Enter");
		await second.waitForSelector('#members li.away .away-said:has-text("back in ten")', { timeout: 30_000 })
			.catch(async () => {
				const rows = await second.evaluate(() =>
					[...document.querySelectorAll("#members li")].map((li) =>
						li.className + ": " + (li.textContent ?? "").slice(0, 40)
					)
				);
				fail(`the other peer's member list does not show who stepped away: ${JSON.stringify(rows)}`);
			});
		// Bare says you are back, the way it has in every client for thirty years.
		await tab.fill("#line", "/away");
		await tab.press("#line", "Enter");
		await second.waitForSelector("#members li.away", { state: "detached", timeout: 30_000 })
			.catch(() => fail("coming back left the member list saying otherwise"));
	}

	// A notice travels in the line the way an action does, so it needs nothing
	// from the room, and it keeps its author because it is somebody speaking. It
	// names the other member on purpose: the point of sending one is to say
	// something without pulling anybody back to their screen.
	{
		await tab.fill("#line", "/notice @bartholomew-longname the build is green again");
		await tab.press("#line", "Enter");
		await second.waitForSelector('.sys.notice:has-text("-web-alice- ")', { timeout: 30_000 })
			.catch(() => fail("a notice did not arrive drawn as one"));
		// Drawn as a notice rather than as an ordinary line, which is what says it
		// went quietly.
		if (await second.locator('.bubble:has-text("the build is green again")').count() > 0) {
			fail("a notice was drawn as an ordinary message");
		}
	}

	// Fenced code is posted as ordinary text but rendered as a block. Shortcodes
	// inside it stay source code: rich-text substitution must stop at the fence.
	const fenced = '```ts\nconst launch = ":rocket:";\n```';
	await tab.fill("#line", fenced);
	await tab.press("#line", "Enter");
	await second.waitForFunction(
		() =>
			[...document.querySelectorAll(".code-block code")].some((code) =>
				code.textContent === 'const launch = ":rocket:";'
			),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the second peer did not render the fenced source as an exact code block"));

	// Admission happens before Send consumes the composer. A file the shared
	// attachment contract refuses leaves both its chip and caption in place so
	// the reader can correct the problem rather than reconstruct the message.
	const invalidName = "x".repeat(300) + ".txt";
	await tab.setInputFiles("#filePick", {
		name: invalidName,
		mimeType: "text/plain",
		buffer: Buffer.from("still here"),
	});
	await tab.fill("#line", "keep this draft");
	await tab.click("#sendBtn");
	if (await tab.inputValue("#line") !== "keep this draft") {
		fail("refusing an invalid attachment consumed its caption");
	}
	await tab.waitForSelector(`.composer-file:has-text("${invalidName}")`, { timeout: 10_000 })
		.catch(() => fail("refusing an invalid attachment removed its composer chip"));
	await tab.click(`.composer-file:has-text("${invalidName}") .composer-file-remove`);
	await tab.fill("#line", "");

	// More files than a message can carry. Keeping every one of them for the
	// reader to correct is the right answer to a file the contract refuses and the
	// wrong one to a folder dropped on the composer: the correction is removing
	// them one press at a time before anything can be sent. What fits is taken and
	// the rest is refused at the gesture, saying so.
	{
		const many = Array.from({ length: 11 }, (_, at) => ({
			name: `spare-${at}.txt`,
			mimeType: "text/plain",
			buffer: Buffer.from(`file ${at}`),
		}));
		await tab.setInputFiles("#filePick", many);
		await tab.waitForFunction(
			() => (document.getElementById("log")?.textContent ?? "").includes("left out"),
			undefined,
			{ timeout: 10_000 },
		).catch(() => fail("dropping more files than a message can carry said nothing about the ones left out"));
		const chips = await tab.locator(".composer-file").count();
		if (chips !== 8) fail(`the composer took ${chips} files onto a message that can carry 8`);
		// And the ones it took are attachable: Send is ready, not refusing.
		if (await tab.isDisabled("#sendBtn")) fail("the files that fit did not make Send ready");
		for (let at = 0; at < chips; at++) await tab.click(".composer-file .composer-file-remove");
		if (await tab.locator(".composer-file").count() !== 0) {
			fail("the composer kept a file after every chip was removed");
		}
	}
	await tab.fill("#line", "");

	// ── Posting a file ───────────────────────────────────────────────────
	// A real picture through the real path: the picker takes a file, the page
	// uploads it to the room a chunk at a time, and the room broadcasts a line
	// carrying a capability to the copy it now holds. The *second* peer is
	// where the proof lands, because that tab has none of the bytes — anything
	// it draws it fetched over its own session by calling that capability.
	//
	// A real 4x2 PNG, written out as bytes rather than base64 so the file that
	// reaches the room is the file this test can name byte for byte. Its chunk
	// CRCs are correct, which matters more than it looks: an `<img>` will draw
	// a PNG with a broken CRC, and `createImageBitmap` — which is what the page
	// measures a picture with before posting it — will not. A fixture that only
	// the lenient path accepts tests the lenient path.
	//
	// Four by two rather than square, so asserting the reserved shape asserts
	// that the numbers travelled rather than that something was set.
	const png = [
		0x89,
		0x50,
		0x4e,
		0x47,
		0x0d,
		0x0a,
		0x1a,
		0x0a,
		0x00,
		0x00,
		0x00,
		0x0d,
		0x49,
		0x48,
		0x44,
		0x52,
		0x00,
		0x00,
		0x00,
		0x04,
		0x00,
		0x00,
		0x00,
		0x02,
		0x08,
		0x06,
		0x00,
		0x00,
		0x00,
		0x7f,
		0xa8,
		0x7d,
		0x63,
		0x00,
		0x00,
		0x00,
		0x20,
		0x49,
		0x44,
		0x41,
		0x54,
		0x78,
		0xda,
		0x63,
		0x60,
		0x60,
		0x68,
		0xf8,
		0x6f,
		0x03,
		0xc4,
		0x15,
		0x40,
		0xbc,
		0x05,
		0x88,
		0x19,
		0x18,
		0xa2,
		0x80,
		0x02,
		0x40,
		0x5c,
		0x01,
		0xc4,
		0x5b,
		0x80,
		0x18,
		0x00,
		0xf4,
		0xf6,
		0x10,
		0x31,
		0x6f,
		0x74,
		0x48,
		0x30,
		0x00,
		0x00,
		0x00,
		0x00,
		0x49,
		0x45,
		0x4e,
		0x44,
		0xae,
		0x42,
		0x60,
		0x82,
	];
	if (!(await tab.isDisabled("#sendBtn"))) fail("an empty composer presented Send as ready");
	await tab.setInputFiles("#filePick", {
		name: "dot.png",
		mimeType: "image/png",
		buffer: Buffer.from(png),
	});
	await tab.waitForSelector('.composer-file:has-text("dot.png")', { timeout: 10_000 })
		.catch(() => fail("the selected picture was not attached to the composer"));
	if (await tab.isDisabled("#sendBtn")) fail("attaching a picture did not make Send ready");
	const composerRows = await tab.evaluate(() => {
		const chip = document.querySelector(".composer-file")?.getBoundingClientRect();
		const text = document.querySelector("#line")?.getBoundingClientRect();
		const attach = document.querySelector("#attachBtn")?.getBoundingClientRect();
		const send = document.querySelector("#sendBtn")?.getBoundingClientRect();
		return chip && text && attach && send
			? {
				filesAboveText: chip.bottom <= text.top,
				actionsBelowText: attach.top >= text.bottom && send.top >= text.bottom,
				leftAndRightActions: attach.left < send.left,
			}
			: null;
	});
	if (
		composerRows === null || !composerRows.filesAboveText || !composerRows.actionsBelowText ||
		!composerRows.leftAndRightActions
	) {
		fail(`the composer did not keep file, text, and action rows distinct: ${JSON.stringify(composerRows)}`);
	}
	const premature = await second.$(".bubble .attach-image");
	if (premature !== null) fail("selecting a picture posted it before Send");
	await tab.click("#sendBtn");

	// The second tab draws it: an image element inside a bubble, whose source is
	// a blob URL it minted from bytes it read out of the room.
	await second.waitForFunction(
		() => {
			const img = document.querySelector(".bubble .attach-image img") as HTMLImageElement | null;
			return img !== null && img.src.startsWith("blob:") && img.naturalWidth > 0;
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the second peer never drew the posted image from the room's blob"));

	// The box was drawn at the picture's own shape, from dimensions the sender
	// measured and the room relayed. That is what stops a log of images from
	// shoving every line below it down the page as each one loads, and it is
	// invisible unless something asserts it.
	const declaredShape = await second.evaluate(() =>
		(document.querySelector(".bubble .attach-image") as HTMLElement | null)?.style.aspectRatio ?? ""
	);
	if (!/^4\s*\/\s*2$/.test(declaredShape)) {
		fail(`the picture's box reserved ${JSON.stringify(declaredShape)}, not its declared 4/2 shape`);
	}

	// Clicking a picture opens it rather than saving it. The viewer covers the
	// whole interface — it is not a panel inside the conversation column — and
	// Escape leaves it, through the same chain that dismisses Settings.
	await second.click(".bubble .attach-image");
	await second.waitForSelector(".viewer img", { timeout: 10_000 })
		.catch(() => fail("clicking the picture did not open it"));
	const covers = await second.evaluate(() => {
		const viewer = document.querySelector("dialog.viewer")!;
		const box = viewer.getBoundingClientRect();
		return viewer.matches(":modal") && document.activeElement?.getAttribute("aria-label") === "Close" &&
			box.width >= innerWidth - 1 && box.height >= innerHeight - 1 && box.top <= 1 && box.left <= 1;
	});
	if (!covers) fail("the viewer was not the focused native modal covering the interface");
	await second.keyboard.press("Escape");
	await second.waitForSelector(".viewer", { state: "detached", timeout: 10_000 })
		.catch(() => fail("Escape did not close the picture"));
	await second.waitForFunction(() => document.activeElement?.matches(".attach-image") === true)
		.catch(() => fail("closing the viewer did not return focus to its image"));

	// Pictures sent together stay one message, but become a compact, independently
	// openable gallery. Rows balance across the full gallery width; exposing a
	// vacant column or shrinking the gallery into a left-aligned island would make
	// the message feel unfinished.
	await tab.setInputFiles(
		"#filePick",
		["one", "two", "three", "four", "five"].map((name) => ({
			name: `${name}.png`,
			mimeType: "image/png",
			buffer: Buffer.from(png),
		})),
	);
	await tab.waitForSelector('.composer-file:has-text("five.png")', { timeout: 10_000 })
		.catch(() => fail("the image set was not attached to the composer"));
	await tab.click("#sendBtn");
	await second.waitForFunction(
		() => {
			const grid = document.querySelector(".attachment-set.image-grid");
			const images = [...(grid?.querySelectorAll(".attach-image img") ?? [])] as HTMLImageElement[];
			return images.length === 5 && images.every((image) => image.naturalWidth > 0);
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the image set did not arrive as one thumbnail grid"));
	const gallery = await second.evaluate(() => {
		const grid = document.querySelector(".attachment-set.image-grid") as HTMLElement | null;
		const tiles = [...(grid?.querySelectorAll(".attach-image") ?? [])] as HTMLElement[];
		if (grid === null || tiles.length !== 5) return null;
		const box = grid.getBoundingClientRect();
		const bubble = grid.closest(".bubble")!.getBoundingClientRect();
		const cells = tiles.map((tile) => tile.getBoundingClientRect());
		return {
			oneBubble: grid.closest(".bubble")?.querySelectorAll(".attach-image").length === 5,
			width: box.width,
			bubbleWidth: bubble.width,
			fullWidth: box.width >= 330,
			fitsBubble: bubble.width - box.width <= 29,
			completeFirstRow: Math.abs(cells[0].left - box.left) < 1 &&
				Math.abs(cells[0].top - cells[1].top) < 1 && Math.abs(cells[1].top - cells[2].top) < 1 &&
				cells[1].left > cells[0].left && cells[2].left > cells[1].left &&
				Math.abs(cells[2].right - box.right) < 1,
			completeSecondRow: cells[3].top > cells[0].bottom && Math.abs(cells[3].top - cells[4].top) < 1 &&
				Math.abs(cells[3].left - box.left) < 1 && cells[4].left > cells[3].left &&
				Math.abs(cells[4].right - box.right) < 1,
			compact: box.height < box.width * 0.75,
			thumbnailSized: cells.slice(0, 3).every((cell) => cell.width <= 115),
			squareFirstRow: cells.slice(0, 3).every((cell) => Math.abs(cell.width - cell.height) < 1),
			cropped: getComputedStyle(tiles[0].querySelector("img")!).objectFit === "cover",
		};
	});
	if (
		gallery === null || !gallery.oneBubble || !gallery.fullWidth || !gallery.fitsBubble ||
		!gallery.completeFirstRow || !gallery.completeSecondRow || !gallery.compact || !gallery.thumbnailSized ||
		!gallery.squareFirstRow || !gallery.cropped
	) {
		fail(`the multi-image message left an incomplete gallery row: ${JSON.stringify(gallery)}`);
	}

	// The full-screen viewer follows conversation order rather than gallery DOM
	// boundaries: Left crosses from the first gallery image to the earlier
	// standalone picture, and Right walks back into and through the gallery.
	await second.click('[aria-label="View one.png"]');
	await second.waitForSelector('.viewer[aria-label="one.png"] img');
	await second.keyboard.press("ArrowLeft");
	await second.waitForSelector('.viewer[aria-label="dot.png"] img');
	await second.keyboard.press("ArrowRight");
	await second.waitForSelector('.viewer[aria-label="one.png"] img');
	await second.keyboard.press("ArrowRight");
	await second.waitForSelector('.viewer[aria-label="two.png"] img');
	await second.keyboard.press("Escape");
	await second.waitForSelector(".viewer", { state: "detached" });
	await second.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "View one.png")
		.catch(() => fail("closing a navigated viewer did not return focus to its opening image"));

	// A file that is not an image is a row with a name and one control, and that
	// control does the whole job in one press: fetch the bytes from the room,
	// then hand them to the browser to save. Nothing downloads by itself.
	await tab.setInputFiles("#filePick", [
		{
			name: "notes.txt",
			mimeType: "text/plain",
			buffer: Buffer.from("pancake"),
		},
		{
			name: "ledger.csv",
			mimeType: "text/csv",
			buffer: Buffer.from("layer,cost\nui,one-bubble\n"),
		},
	]);
	await tab.waitForSelector('.composer-file:has-text("notes.txt")', { timeout: 10_000 })
		.catch(() => fail("the first selected file was not attached to the composer"));
	await tab.waitForSelector('.composer-file:has-text("ledger.csv")', { timeout: 10_000 })
		.catch(() => fail("the second selected file was not attached to the composer"));
	await tab.click("#sendBtn");
	await tab.waitForSelector(".row.mine .attach-file .icon-button", { timeout: 30_000 })
		.catch(() => fail("the sender never saw its own file action"));
	const originalTheme = await tab.getAttribute("html", "data-theme");
	for (const theme of ["light", "dark"] as const) {
		await tab.evaluate((theme) => document.documentElement.setAttribute("data-theme", theme), theme);
		const ratio = await bubbleInkContrast(tab, ".row.mine .attach-file .icon-button");
		if (ratio === null || ratio < 4.5) {
			const style = await tab.evaluate(() => {
				const action = document.querySelector(".row.mine .attach-file .icon-button") as HTMLElement;
				const bubble = action.closest(".bubble") as HTMLElement;
				return {
					tone: action.dataset.tone,
					color: getComputedStyle(action).color,
					background: getComputedStyle(action).backgroundColor,
					bubble: getComputedStyle(bubble).backgroundImage,
				};
			});
			fail(
				`the ${theme} authored-file action falls to ${ratio?.toFixed(2) ?? "unknown"}:1 on hover: ${
					JSON.stringify(style)
				}`,
			);
		}
		for (const selector of [".row.mine .attach-file .glyph", ".row.mine .attach-file .sub"]) {
			const inkRatio = await bubbleInkContrast(tab, selector, ".attach-file");
			if (inkRatio === null || inkRatio < 4.5) {
				fail(`${theme} ${selector} falls to ${inkRatio?.toFixed(2) ?? "unknown"}:1 in an authored file`);
			}
		}
	}
	await tab.evaluate((theme) => {
		if (theme === null) document.documentElement.removeAttribute("data-theme");
		else document.documentElement.setAttribute("data-theme", theme);
	}, originalTheme);
	await second.waitForFunction(
		() => {
			const rows = [...document.querySelectorAll(".bubble .attach-file")];
			const names = rows.map((row) => row.querySelector(".name")?.textContent);
			return names.includes("notes.txt") && names.includes("ledger.csv");
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the second peer never saw both posted text files"));
	const groupedFiles = await second.evaluate(() => {
		const byName = (name: string) =>
			[...document.querySelectorAll(".attach-file")].find((row) =>
				row.querySelector(".name")?.textContent === name
			);
		const first = byName("notes.txt")?.closest(".bubble");
		const second = byName("ledger.csv")?.closest(".bubble");
		return first !== null && first !== undefined && first === second &&
			first.querySelectorAll(".attach-file").length === 2;
	});
	if (!groupedFiles) fail("one send of two files did not render as one bubble containing both files");
	const fileAction = await second.evaluate(() => {
		const rows = [...document.querySelectorAll(".bubble .attach-file")];
		const row = rows.find((candidate) => candidate.querySelector(".name")?.textContent === "notes.txt");
		const action = row?.querySelector(".icon-button");
		return action
			? { icon: action.querySelector(".icon-svg") !== null, visibleLabel: action.textContent?.trim() ?? "" }
			: null;
	});
	if (fileAction === null || !fileAction.icon || fileAction.visibleLabel !== "") {
		fail(`the file download was not a named icon button: ${JSON.stringify(fileAction)}`);
	}
	const copyAction = await second.evaluate(() => {
		const action = document.querySelector('.acts button[aria-label="Copy message"]');
		return action?.matches(".icon-button") === true && action.querySelector(".icon-svg") !== null &&
			action.textContent?.trim() === "";
	});
	if (!copyAction) fail("the ubiquitous Copy action was not an accessible icon button");
	const iconButtonContract = await second.evaluate(() =>
		[...document.querySelectorAll<HTMLButtonElement>(".icon-button")].flatMap((button) => {
			if (!button.checkVisibility({ visibilityProperty: true })) return [];
			const label = button.getAttribute("aria-label")?.trim() ?? "";
			const size = button.dataset.size;
			const expected = size === "small" ? 26 : size === "normal" ? 36 : size === "large" ? 42 : 0;
			const box = button.getBoundingClientRect();
			return label !== "" && expected > 0 && Math.abs(box.height - expected) <= 0.5
				? []
				: [`${button.id || button.className}: label=${
					JSON.stringify(label)
				}, size=${size}, height=${box.height}`];
		})
	);
	if (iconButtonContract.length > 0) {
		fail(`icon buttons escaped their accessible three-size baseline: ${iconButtonContract.join("; ")}`);
	}
	const saved = second.waitForEvent("download", { timeout: 30_000 });
	await second.click(".bubble .attach-file .icon-button");
	const download = await saved.catch(() =>
		fail("pressing the download icon never produced a download; the reader asked for the file, not its transfer")
	);
	if (download.suggestedFilename() !== "notes.txt") {
		fail(`the download was named ${JSON.stringify(download.suggestedFilename())}`);
	}

	// The roster's direct-line button used to be revealed on hover while still
	// holding its place in the row, so every name it sat behind was cut short
	// with a stretch of empty space beside it. Nothing a reader cannot see may
	// take width away from a name — which is the invariant, rather than "this
	// particular name fits", a claim any change to the rail's width would make
	// true again without fixing anything.
	// Direct children only: those are the flex items the row's width is shared
	// between, and an icon nested inside a hidden button is the same one finding.
	const ghosts = await tab.evaluate(() =>
		[...document.querySelectorAll("#members li > *")]
			.filter((el) =>
				el.getBoundingClientRect().width > 0 &&
				!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })
			)
			.map((el) => (typeof el.className === "string" && el.className) || el.tagName)
	);
	if (ghosts.length > 0) {
		fail(`invisible controls are holding width in a roster row: ${JSON.stringify(ghosts)}`);
	}

	// They are the same kind of surface, so they take one width and start their
	// rows on one vertical line. Measured from each rail's padding box, since one
	// of the two carries a border on the side facing the conversation.
	const rails = await tab.evaluate(() => {
		// Where a heading's glyphs begin, measured from the inside of its rail.
		const inset = (rail: Element, heading: Node) => {
			const range = document.createRange();
			range.selectNodeContents(heading);
			return range.getBoundingClientRect().left -
				rail.getBoundingClientRect().left - rail.clientLeft;
		};
		const sidebar = document.querySelector(".sidebar")!;
		const roster = document.querySelector(".members")!;
		return {
			widths: [sidebar.clientWidth, roster.clientWidth],
			insets: [
				inset(sidebar, document.querySelector(".section-head span")!),
				inset(roster, roster.querySelector("h2")!),
			],
		};
	});
	if (rails.widths[0] !== rails.widths[1]) {
		fail(`the two rails disagree on width: ${rails.widths.join(" / ")}`);
	}
	if (Math.abs(rails.insets[0] - rails.insets[1]) > 0.5) {
		fail(`the two rails start their rows at different insets: ${rails.insets.join(" / ")}`);
	}

	// And they draw the same row. Two rails flank the conversation and a reader
	// sees both at once, so a name in one that starts a few pixels off a name in
	// the other reads as one of the two having been nudged, without saying which.
	// The headings go with them: both label a list of the same kind, so both are
	// set the same way and both land on one line.
	//
	// Measured on the glyphs, not on the boxes around them. One heading is a span
	// centred inside a flex row that a "+" makes taller and the other is a padded
	// `h2`, so their element rectangles disagree by several pixels while the words
	// sit exactly level — which is the reading that matters and the one a reader
	// has. Row heights are deliberately not compared: a roster row carries its
	// direct-line button in a column of its own, always showing rather than
	// revealed, so it stands taller than a rail row by that decision rather than
	// by an oversight.
	const alike = await tab.evaluate(() => {
		const glyphs = (el: Node) => {
			const range = document.createRange();
			range.selectNodeContents(el);
			return range.getBoundingClientRect();
		};
		const nameInset = (row: Element, name: Element) => glyphs(name).left - row.getBoundingClientRect().left;
		const railRow = document.querySelector("#roomList .room-open");
		const railName = document.querySelector("#roomList .rname");
		const rosterRow = document.querySelector("#members li");
		const rosterName = document.querySelector("#members .name");
		const railHead = document.querySelector(".section-head span");
		const rosterHead = document.querySelector(".members h2");
		if (!railRow || !railName || !rosterRow || !rosterName || !railHead || !rosterHead) return null;
		const drawn = (el: Element) => {
			const s = getComputedStyle(el);
			return [s.fontSize, s.fontWeight, s.letterSpacing, s.textTransform].join(" ");
		};
		return {
			insets: [nameInset(railRow, railName), nameInset(rosterRow, rosterName)] as const,
			nameInset: Math.abs(nameInset(railRow, railName) - nameInset(rosterRow, rosterName)),
			headTop: Math.abs(glyphs(railHead).top - glyphs(rosterHead).top),
			headDrawn: [drawn(railHead), drawn(rosterHead)] as const,
		};
	});
	if (alike === null) fail("the two rails were not both showing a heading and a row to compare");
	else {
		// Reported together rather than one at a time. These are one question asked
		// three ways, and stopping at the first answer hides how far apart the two
		// rails actually are — which is what decides whether the fix is a number or
		// a shared rule.
		const apart = [
			alike.nameInset > 1 &&
			`a name starts ${alike.nameInset.toFixed(1)}px further into one row than the other (rail ${
				alike.insets[0].toFixed(1)
			}px, roster ${alike.insets[1].toFixed(1)}px)`,
			alike.headTop > 1 && `their headings sit ${alike.headTop.toFixed(1)}px apart rather than on one line`,
			alike.headDrawn[0] !== alike.headDrawn[1] &&
			`their headings are drawn differently: ${alike.headDrawn.join(" against ")}`,
		].filter((said) => said !== false);
		if (apart.length > 0) fail(`the two rails do not draw one row: ${apart.join("; ")}`);
	}

	// Drawing alike is only half of it: the same treatment has to keep meaning the
	// same thing. A wash under the pointer means "this row opens" everywhere in
	// the rail, so a roster row — a name, a state, and a button that answers for
	// itself — must not wear one. Both halves are asked, because "nothing lights
	// up" is also what a broken selector looks like.
	const ground = (row: string) =>
		tab.evaluate((r) => {
			const el = document.querySelector(r);
			return el === null ? null : getComputedStyle(el).backgroundColor;
		}, row);
	const lights = async (row: string) => {
		const before = await ground(row);
		if (before === null) fail(`no ${row} to ask whether it answers the pointer`);
		// Somewhere neutral first, so the row is not already under the pointer from
		// whatever was measured before it.
		await tab.mouse.move(0, 0);
		const cold = await ground(row);
		await tab.hover(row);
		return cold !== await ground(row);
	};
	if (!await lights("#roomList li")) {
		fail("a room row does not answer the pointer, so nothing in the rail says which row a press would open");
	}
	if (await lights("#members li")) {
		fail("a roster row lights up under the pointer like a row that opens, but pressing it does nothing");
	}

	// The mark is one control with two homes: the rail holds it while the list is
	// up and the topbar picks it up when the list goes away. Whichever is holding
	// it, it has to be in the same place and the same size, or putting the rail
	// away reads as the page redrawing rather than as one control travelling. The
	// bars are measured, not the button frame around them, because two frames can
	// land on the same pixel while the marks inside them differ.
	const markBox = (sel: string) =>
		tab.evaluate((s) => {
			const e = document.querySelector(s)!.querySelector(".icon-mark")!;
			const r = e.getBoundingClientRect();
			return { x: r.left, y: r.top, size: `${r.width}×${r.height}` };
		}, sel);
	type Mark = Awaited<ReturnType<typeof markBox>>;
	// Anything that truncates has to be tall enough for the text it truncates.
	// An element that clips horizontally for an ellipsis clips vertically too, so
	// a line box shorter than the font's own metrics takes the descenders off with
	// it — a `g` loses its tail, and only on the layout where the truncation is
	// switched on. The stylesheet cannot be read for this: it depends on the
	// font's metrics at the size in force, which is why it is measured here.
	const descendersIntact = async (where: string) => {
		const clipped = await tab.evaluate(() =>
			[...document.querySelectorAll<HTMLElement>("*")].flatMap((e) => {
				const style = getComputedStyle(e);
				if (style.textOverflow !== "ellipsis" || style.overflow === "visible") return [];
				const text = e.textContent?.trim();
				if (!text) return [];
				const box = e.getBoundingClientRect();
				if (box.height === 0) return [];
				const range = document.createRange();
				range.selectNodeContents(e);
				const ink = range.getBoundingClientRect();
				const above = box.top - ink.top, below = ink.bottom - box.bottom;
				if (above <= 0.5 && below <= 0.5) return [];
				const named = e.id ? "#" + e.id : "." + e.className.split(" ")[0];
				return [
					`${named} ("${text.slice(0, 20)}") loses ${above.toFixed(1)}px above and ` +
					`${below.toFixed(1)}px below, at line-height ${style.lineHeight}`,
				];
			})
		);
		if (clipped.length > 0) fail(`text is cut off ${where}: ${clipped.join("; ")}`);
	};
	await descendersIntact("beside the conversation");

	const sameMark = (where: string, a: Mark, b: Mark) => {
		for (const axis of ["x", "y"] as const) {
			if (Math.abs(a[axis] - b[axis]) > 0.5) {
				fail(
					`${where}: the mark moves ${Math.round(b[axis] - a[axis])}px along ` +
						`${axis} when the rail is put away (${a[axis]} → ${b[axis]})`,
				);
			}
		}
		if (a.size !== b.size) {
			fail(`${where}: the mark changes size when it changes homes (${a.size} → ${b.size})`);
		}
	};

	const railHeld = await markBox("#railToggle");
	await tab.click("#railToggle");
	await tab.waitForSelector("#backBtn", { state: "visible", timeout: 5_000 })
		.catch(() => fail("collapsing the rail beside the conversation left no way back"));
	sameMark("beside the conversation", railHeld, await markBox("#backBtn"));
	await tab.click("#backBtn");
	await tab.waitForSelector("#railToggle", { state: "visible", timeout: 5_000 })
		.catch(() => fail("the collapsed rail could not be brought back"));

	// Held on is accent for every toggle, whatever its own tone, so a toggle that
	// takes an accent tone of its own hovers in the colour of its pressed state
	// and the two stop differing in kind. A control that wants brand ink paints
	// the glyph and leaves the states alone, the way `.mark-btn` does.
	const tonedToggles = await tab.evaluate(() =>
		Array.from(document.querySelectorAll<HTMLButtonElement>(".icon-button[aria-pressed]"))
			.filter((button) => button.dataset.tone === "accent" || button.dataset.tone === "on-accent")
			.map((button) => `#${button.id}: tone=${button.dataset.tone}`)
	);
	if (tonedToggles.length > 0) {
		fail(`a toggle wears its pressed colour on hover: ${tonedToggles.join("; ")}`);
	}

	// The mark hands one exact brand colour from the opening screen to both of
	// its homes. Check the actual glyphs in both palettes: a token spelling in
	// one restored theme would not hold that visible handoff.
	const markTheme = await tab.evaluate(() => document.documentElement.getAttribute("data-theme"));
	for (const theme of ["light", "dark"] as const) {
		await tab.evaluate((theme) => document.documentElement.setAttribute("data-theme", theme), theme);
		const marks = await tab.evaluate(() => {
			const probe = document.createElement("span");
			probe.style.color = "var(--accent)";
			document.body.append(probe);
			const brand = getComputedStyle(probe).color;
			probe.remove();
			return {
				brand,
				rail: getComputedStyle(document.querySelector("#railToggle .icon-mark")!).backgroundColor,
				bar: getComputedStyle(document.querySelector("#backBtn .icon-mark")!).backgroundColor,
			};
		});
		for (const [home, painted] of [["rail", marks.rail], ["bar", marks.bar]]) {
			if (painted !== marks.brand) {
				fail(`the ${theme} ${home} mark is ${painted} where the brand is ${marks.brand}`);
			}
		}
	}
	await tab.evaluate((theme) => {
		if (theme === null) document.documentElement.removeAttribute("data-theme");
		else document.documentElement.setAttribute("data-theme", theme);
	}, markTheme);

	// ── The narrow layout ────────────────────────────────────────────────
	// On a phone each rail takes the whole screen or slides over it, so each one
	// owes the reader a way back to the conversation it covered.
	await tab.setViewportSize({ width: 390, height: 844 });
	await tab.waitForTimeout(400);
	const largeControls = await tab.evaluate(() =>
		["#backBtn", "#settingsBtn", "#membersToggle", "#attachBtn", "#emojiBtn", "#sendBtn"].flatMap((selector) => {
			const button = document.querySelector<HTMLButtonElement>(selector);
			if (button === null || !button.checkVisibility({ visibilityProperty: true })) return [];
			const height = button.getBoundingClientRect().height;
			return button.dataset.size === "large" && Math.abs(height - 42) <= 0.5
				? []
				: [`${selector}: size=${button.dataset.size}, height=${height}`];
		})
	);
	if (largeControls.length > 0) {
		fail(`phone-primary icon buttons escaped the large baseline: ${largeControls.join("; ")}`);
	}
	// The narrow layout is where the room name truncates, so it is where a line
	// box too short for its glyphs actually shows.
	await descendersIntact("on a phone");

	const reachable = await tab.evaluate(() =>
		document.querySelector("#members .dm-btn")!
			.checkVisibility({ visibilityProperty: true })
	);
	if (reachable) {
		fail(
			"a closed roster sheet still offers its buttons to the keyboard and to " +
				"assistive software: it is off the bottom of the screen, not hidden",
		);
	}

	const opened = ".app.members-open", listed = ".app.show-list";
	await tab.click("#membersToggle");
	await tab.waitForSelector(opened, { timeout: 5_000 })
		.catch(() => fail("the Members button did not open the roster sheet"));
	await tab.keyboard.press("Escape");
	await tab.waitForSelector(opened, { state: "detached", timeout: 5_000 })
		.catch(() => fail("Escape did not close the roster sheet"));

	// Picking a room used to be the only way out of the list, so a glance at what
	// else was live cost you the conversation you were reading.
	const barHeld = await markBox("#backBtn");
	await tab.click("#backBtn");
	await tab.waitForSelector(listed, { timeout: 5_000 })
		.catch(() => fail("the menu button did not open the rooms list"));
	// Ask for the control by name before clicking it. Clicking one that is not
	// there waits for it until the scenario's own deadline, and reports a timeout
	// rather than the thing that is actually missing.
	await tab.waitForSelector("#railToggle", { state: "visible", timeout: 5_000 })
		.catch(() => fail("the rooms list offers no way back to the conversation it covers"));
	// Here the whole screen changes hands, so the mark is the one fixed thing in
	// it. The two headers are never up together, which is what makes a shift of a
	// pixel or two hard to see and worth measuring.
	sameMark("on a phone", barHeld, await markBox("#railToggle"));
	await tab.click("#railToggle");
	await tab.waitForSelector(listed, { state: "detached", timeout: 5_000 })
		.catch(() => fail("the rooms list could not be left without picking a conversation"));

	// ── Two rooms at once ────────────────────────────────────────────────
	// Entering a room no longer gives one up, so the rail's "+" puts a second
	// room beside the first. The part worth proving is the part a page that only
	// ever held one room could fake by switching: a room nobody is looking at
	// keeps receiving, and its own history is still there on the way back.
	await tab.setViewportSize({ width: 1280, height: 800 });
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "annex");
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForFunction(
		() => {
			const joined = [...document.querySelectorAll("#roomList .rname")]
				.map((row) => row.textContent?.trim());
			return joined.includes("lobby") && joined.includes("annex");
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("entering a second room did not leave both rooms marked as joined in the rail"));

	// A name at the longest the field will take, because the middle of the range
	// is the one length a layout is never wrong about. The rail is a fixed narrow
	// column, so this is where truncation actually happens, and truncation that
	// keeps no copy of what it cut is a name a reader can no longer read.
	//
	// Every element on the page is asked, not the rooms list alone: names of
	// rooms, of people, and of files all truncate in narrow places, and only the
	// rooms list had ever been given a title to hold the whole of it. An element
	// is asked only when it is really overflowing, so nothing here fires on text
	// that happens to fit.
	const longRoom = "a".repeat(28) + "-end";
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", longRoom);
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForFunction(
		(named) => [...document.querySelectorAll("#roomList .rname")].some((r) => r.textContent?.trim() === named),
		longRoom,
		{ timeout: 30_000 },
	).catch(() => fail("a room named at the length the field allows never reached the rail"));
	const cutOff = await tab.evaluate(() =>
		[...document.querySelectorAll<HTMLElement>("*")].flatMap((el) => {
			if (getComputedStyle(el).textOverflow !== "ellipsis") return [];
			if (el.scrollWidth <= el.clientWidth + 1) return [];
			const text = el.textContent?.trim() ?? "";
			if (text === "") return [];
			// A title, its own or an ancestor's, because a title is what a pointer can
			// reach. An accessible name is not accepted here and that is the point:
			// every one of these rows already carries the whole value in the label on
			// the control around it, so a reader who is listening was never the one
			// losing it. Taking `aria-label` as an answer let this check pass with the
			// defect it was written for still in place.
			const holder = el.closest<HTMLElement>("[title]");
			if ((holder?.getAttribute("title") ?? "").includes(text)) return [];
			const named = el.id !== "" ? "#" + el.id : "." + el.className.split(" ")[0];
			return [`${named} ("${text.slice(0, 24)}…")`];
		})
	);
	if (cutOff.length > 0) {
		fail(`a name is cut off with no copy of the whole of it anywhere: ${cutOff.join("; ")}`);
	}
	await tab.click(`.room-open:has-text("annex")`);

	// The new room is on screen and carries its own line.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
	const annexLine = "a line that belongs to the annex";
	await tab.fill("#line", annexLine);
	await tab.press("#line", "Enter");
	await tab.waitForSelector(`.bubble:has-text("${annexLine}")`, { timeout: 30_000 })
		.catch(() => fail("the second room did not echo its own line back"));

	// The other peer is still in the first room, so this line has to arrive at a
	// conversation nobody is watching. Switching back is what shows it, and that
	// is the proof: the log draws only what the room already delivered, so a line
	// that is there on arrival was carried while the annex held the screen.
	const whileAway = "posted to lobby while the annex was on screen";
	await second.fill("#line", whileAway);
	await second.press("#line", "Enter");
	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForSelector(`.bubble:has-text("${whileAway}")`, { timeout: 30_000 })
		.catch(() => fail("the room that was off screen stopped receiving while the other one was up"));

	// Changing or withdrawing a line is offered on your own and on nobody else's.
	//
	// Asked here because this is the first moment both tabs hold lines from each
	// other: before the exchange above, each had only its own, and "none of
	// somebody else's carried a control" was true because there were none to
	// carry one. A check that passes for want of anything to look at is not a
	// check, and this one said nothing twice before it was moved.
	{
		const seen = async (page: Page) =>
			await page.evaluate(() => ({
				own: document.querySelectorAll(".row.mine .bubble").length,
				ownOffered: document.querySelectorAll(".row.mine .bubble .line-acts").length,
				others: document.querySelectorAll(".row.them .bubble").length,
				othersOffered: document.querySelectorAll(".row.them .bubble .line-acts").length,
			}));
		for (const [who, page] of [["the first tab", tab], ["the second", second]] as const) {
			const held = await seen(page);
			if (held.own === 0 || held.others === 0) {
				fail(`${who} cannot answer the question: it holds ${JSON.stringify(held)}`);
			}
			if (held.ownOffered === 0) fail(`${who} was offered no way to change a line of its own`);
			if (held.othersOffered > 0) {
				fail(`${who} was offered to change ${held.othersOffered} of somebody else's lines`);
			}
		}
	}
	// Having just watched this same log paint an arriving line, its silence about
	// the other room's line means the two histories are genuinely separate.
	const bled = await tab.locator(`.bubble:has-text("${annexLine}")`).count();
	if (bled !== 0) fail("a line from the annex was drawn in the first room's log");
	await tab.waitForSelector('.bubble:has-text("hello from a browser peer")', { timeout: 10_000 })
		.catch(() => fail("the first room lost the history it had before the second room was entered"));

	// The badge on a room counts who is in it, not who has been.
	//
	// A roster keeps everyone it has seen — leaving turns a member offline rather
	// than taking their name off the list, because the pane beside the rail shows
	// both numbers. So the badge counting the whole roster read as the room being
	// fuller than it is, and it read that way for as long as the tab stayed open.
	// The two surfaces are asked together, because the bug is exactly that they
	// disagreed: the badge said two while the pane said one online of two seen.
	{
		// No click to get here: this tab is already reading the lobby, and pressing
		// the room you are already in is how a reader puts the rail away.
		const lobby = tab.locator("#roomList li").filter({ has: tab.locator('.rname:text-is("lobby")') });
		await tab.waitForFunction(
			() => {
				const row = [...document.querySelectorAll("#roomList li")]
					.find((li) => li.querySelector(".rname")?.textContent?.trim() === "lobby");
				return row?.querySelector(".rcount")?.textContent === "2";
			},
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("the lobby's badge never counted the second member"));

		// The other member leaves, by the way a reader leaves: the mark on its own
		// row in its own rail.
		const theirs = second.locator("#roomList li").filter({ has: second.locator('.rname:text-is("lobby")') });
		await theirs.hover();
		await theirs.locator(".room-leave").click();

		await tab.waitForFunction(
			() => {
				const row = [...document.querySelectorAll("#roomList li")]
					.find((li) => li.querySelector(".rname")?.textContent?.trim() === "lobby");
				return row?.querySelector(".rcount")?.textContent === "1";
			},
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const said = await tab.textContent("#presenceSummary").catch(() => "?");
			const badge = await lobby.locator(".rcount").textContent().catch(() => "?");
			fail(`the badge still reads ${JSON.stringify(badge)} after a member left, while the pane says ${said}`);
		});
		// And the pane still knows they were here, which is what makes the badge's
		// number a different question rather than the same one counted twice.
		const summary = (await tab.textContent("#presenceSummary")) ?? "";
		if (!summary.includes("1 online") || !summary.includes("2 seen")) {
			fail(`the members pane lost the distinction the badge depends on: ${JSON.stringify(summary)}`);
		}
	}

	// A half-written line belongs to the conversation it was written in.
	//
	// Two rooms are open, so switching between them is something a reader does
	// constantly — to check one thing before finishing a sentence in the other.
	// A draft held once for the whole page turns that into either losing the
	// sentence or, worse, finding it in the wrong room: the composer would be
	// offering the annex's words under the lobby's name, and one press would
	// post them there. Attachments make the same mistake expensive rather than
	// merely annoying, because files picked for a room could leave in a direct
	// message to somebody.
	//
	// So each conversation keeps its own, and switching away and back is what
	// shows it.
	const halfWritten = "a sentence I had not finished in the annex";
	await tab.click('.room-open:has-text("annex")');
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
	await tab.fill("#line", halfWritten);
	await tab.click('.room-open:has-text("lobby")');
	const followed = await tab.inputValue("#line");
	if (followed !== "") {
		fail(
			`a half-written line followed the reader into another room; the lobby's composer holds ` +
				`${JSON.stringify(followed)}, and one press would have posted it there`,
		);
	}
	await tab.click('.room-open:has-text("annex")');
	const resumed = await tab.inputValue("#line");
	if (resumed !== halfWritten) {
		fail(`the annex lost the sentence left half-written in it; its composer holds ${JSON.stringify(resumed)}`);
	}
	// And it does not outlive the conversation it belonged to: leaving the room
	// and coming back is a new conversation, not a resumed one.
	await tab.fill("#line", "");

	// Leaving one room is leaving one room.
	await tab.click('[aria-label="Leave #annex"]');
	await tab.waitForFunction(
		() => {
			const joined = [...document.querySelectorAll("#roomList .rname")]
				.map((row) => row.textContent?.trim());
			return joined.includes("lobby") && !joined.includes("annex");
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("leaving the second room did not leave the first one joined"));
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 })
		.catch(() => fail("leaving one of two rooms left the reader with nowhere to type"));

	// Every row carries its own way out and its own badge. Both are keyed on the
	// row rather than on a membership class, because every room listed here is one
	// you are in — a class that used to mean something and now means nothing is
	// how the leave mark and its hover swap stopped matching anything at all.
	const rowParts = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li");
		if (row === null) return null;
		const leave = row.querySelector<HTMLElement>(".room-leave");
		const badge = row.querySelector<HTMLElement>(".rcount");
		return {
			leave: leave === null ? null : leave.getAttribute("aria-label"),
			// Existing is not the same as reachable. The mark is drawn at zero
			// opacity and revealed under the pointer, so the reveal rule matching
			// nothing leaves a control that is present, findable, and invisible —
			// which is exactly what happened when it was keyed on a class the rail
			// had stopped emitting.
			leaveShown: leave === null ? null : getComputedStyle(leave).opacity,
			badge: badge?.textContent ?? null,
		};
	});
	if (rowParts === null) fail("the rail listed no room at all");
	if (rowParts.leave === null) fail("a room row carried no way to leave it");
	if (rowParts.badge === null) fail("a room row carried no badge: neither unread nor how many are in it");
	// Hovering swaps the badge for the way out. Measured rather than assumed,
	// because both are always in the tree and only their opacity says which one a
	// reader can actually see and press.
	await tab.hover("#roomList li");
	// Waited for rather than sampled: the swap is a 120ms fade each way, so a
	// reading taken the instant the pointer lands catches it part done and says
	// the control is missing when it is only arriving.
	await tab.waitForFunction(
		() => {
			const row = document.querySelector("#roomList li");
			const leave = row?.querySelector(".room-leave");
			const badge = row?.querySelector(".rcount");
			if (!leave || !badge) return false;
			return Number(getComputedStyle(leave).opacity) > 0.9 &&
				Number(getComputedStyle(badge).opacity) < 0.1;
		},
		undefined,
		{ timeout: 5_000 },
	).catch(() => fail("hovering a room row did not swap its badge for its way out"));

	// ── A room owned by another server ──────────────────────────────────
	// The locator changes which directory the room is entered on; the page does
	// not proxy a foreign room through the server that served its HTML. Staying in
	// the local room while doing it is the point: a second directory is opened
	// beside the first, not instead of it.
	await tab.setViewportSize({ width: 1280, height: 800 });
	const foreignLocator = `127.0.0.1:${foreignRoomPort}`;
	// Reached from the rail's own field, which is the way a reader finds it: type
	// a name, then say it is somewhere else. The name goes with you to the card.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "elsewhere");
	// The room being named is drawn as one of the rooms already named: a mark, a
	// name, and under it the line saying where it will land. So the panel's line
	// is measured the way a row's is — one piece in the middle of a rectangle it
	// is drawn on, rather than two entries placed by the columns above, which is
	// what both of them stopped being.
	const panel = await tab.evaluate(() => {
		const box = document.querySelector("#newRoom");
		const line = box?.querySelector(".rwhere");
		const glyph = box?.querySelector(".rwhere .icon-svg");
		const said = box?.querySelector(".rwhere-said");
		if (!line || !glyph || !said) return null;
		const at = (el: Element) => {
			const b = el.getBoundingClientRect();
			return { l: b.left, r: b.right };
		};
		const c = at(line), i = at(glyph), w = at(said);
		return {
			markBesideItsWords: Math.abs(w.l - i.r) > 12 ? Math.abs(w.l - i.r) : 0,
			centredInTheLine: Math.abs((i.l - c.l) - (c.r - w.r)),
			edge: parseFloat(getComputedStyle(line).borderTopWidth),
		};
	});
	if (panel === null) fail("the panel for a room being named carried no line saying where it lands");
	else {
		// Asked apart from the measurements, because it is a yes and not a
		// distance: folded in as a number it would have to pick one that trips the
		// threshold below, and picking one that did not is how a check comes to
		// pass with its own defect in front of it.
		if (!(panel.edge > 0)) fail("the panel's directory line is drawn with no rectangle at rest");
		for (const [what, off] of Object.entries(panel)) {
			if (what !== "edge" && off > 1) {
				fail(`the panel for a new room is not built like a room row: ${what} is out by ${off.toFixed(1)}px`);
			}
		}
	}
	// Reached by keyboard on purpose. A pointer press and a key press take
	// different paths into a button — Enter and Space raise a click with no
	// mousedown before it — so a proof that only ever clicks cannot tell a
	// control that works from one that is focusable, visibly focused, and dead.
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("the rail offered no way to reach a room on another server"));
	const carried = await tab.inputValue("#room");
	if (carried !== "elsewhere") {
		fail(`the room name did not travel to the join card; it holds ${JSON.stringify(carried)}`);
	}

	// The addresses offered under the locator field belong to that field, and the
	// form has to say so with space: one gap runs between one question and the
	// next, and anything inside a single question sits closer than that. Measured
	// as a comparison rather than against a number, because what a reader sees is
	// the grouping — these nearer to the field they fill than to the question
	// after them — and any pair of paddings that holds it is fine.
	const grouped = await tab.evaluate(() => {
		const field = document.getElementById("locator");
		const picks = document.querySelector(".locator-picks");
		const next = document.querySelector('label[for="room"]');
		if (!field || !picks || !next) return null;
		const box = (el: Element) => el.getBoundingClientRect();
		return {
			toItsField: box(picks).top - box(field).bottom,
			toTheNext: box(next).top - box(picks).bottom,
		};
	});
	if (grouped === null) fail("the join form offered no addresses under its locator field to place");
	else if (!(grouped.toItsField < grouped.toTheNext)) {
		fail(
			`the addresses under the locator field are ${grouped.toItsField.toFixed(0)}px from it and ` +
				`${grouped.toTheNext.toFixed(0)}px from the next question, so they read as their own row rather ` +
				`than as part of the field they fill`,
		);
	}

	// A typo first. An address nobody has ever reached is most likely wrong, so
	// the page must let it go rather than keep a row for it and dial it forever —
	// and it must leave what was typed in the field, because correcting an
	// address is an edit and not a retype.
	const typo = `127.0.0.1:${freePort()}`;
	await tab.fill("#locator", typo);
	await tab.click("#joinBtn");
	await tab.waitForFunction(
		() => (document.getElementById("joinError")?.textContent ?? "").length > 0,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("a locator that cannot be reached never settled; the card waits for good"));
	// And the line under the rail stops claiming an attempt that has ended.
	await tab.waitForFunction(
		() => !(document.getElementById("status")?.textContent ?? "").startsWith("reaching"),
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the status line went on reaching for a server the page had given up on"));
	const kept = await tab.inputValue("#locator");
	if (kept !== typo) {
		fail(`a refused locator was not left in the field to correct; it holds ${JSON.stringify(kept)}`);
	}
	// Nothing was kept for it. A second server would have drawn the grouped rail.
	const marks = await tab.locator("#roomList .rwhere").count();
	if (marks !== 0) fail("an address that never answered was kept as a server in the rail");

	// Then text that is not an address at all, which is the other half of the same
	// mistake and the half that used to take the page down. The one above points
	// nowhere and is refused by the dial; this one cannot be parsed, and the parse
	// threw where nothing was catching — so a person who mistyped badly enough got
	// the error screen instead of a correction, losing the room they were in.
	// Checked as a crash rather than as a message: the interface has to still be
	// there afterwards.
	await tab.fill("#locator", "not a locator at all");
	await tab.click("#joinBtn");
	await tab.waitForFunction(
		() => (document.getElementById("joinError")?.textContent ?? "").length > 0,
		undefined,
		{ timeout: 20_000 },
	).catch(() => fail("text that is not an address was never refused on the join card"));
	const survived = await tab.evaluate(() => ({
		rail: document.getElementById("roomList") !== null,
		rooms: document.querySelectorAll("#roomList li").length,
		kept: (document.getElementById("locator") as HTMLInputElement | null)?.value ?? null,
	}));
	if (!survived.rail) fail("text that is not an address took the whole interface down to the error screen");
	if (survived.rooms === 0) fail("text that is not an address cost the reader the room they were already in");
	if (survived.kept !== "not a locator at all") {
		fail(`what was typed was not left to correct; the field holds ${JSON.stringify(survived.kept)}`);
	}

	// Under a different name on purpose. A directory grants the name, and grants
	// it for itself alone, so being alice on one and bo on another is ordinary
	// rather than exotic — and it is the state in which anything claiming a single
	// name for every room a reader is in has to be wrong about some of them.
	await tab.fill("#locator", foreignLocator);
	await tab.fill("#nick", "bo");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("the browser did not join the room owned by the second server"));
	// The line under the rail counts rooms across every directory, so it may not
	// name one of the names it found. Saying the first room's is the kind of wrong
	// that reads as right: a real name, on a real directory, and not the one the
	// other rooms know this reader by.
	await tab.waitForFunction(
		() => /in \d+ rooms/.test(document.getElementById("status")?.textContent ?? ""),
		undefined,
		{ timeout: 15_000 },
	).catch(async () =>
		fail(
			"the line under the rail never counted the rooms held across two directories; it says " +
				JSON.stringify((await tab.textContent("#status"))?.trim() ?? ""),
		)
	);
	const acrossNames = (await tab.textContent("#status"))?.trim() ?? "";
	if (/\bas\b/.test(acrossNames)) {
		fail(`the status line claimed one name across directories that granted two: ${JSON.stringify(acrossNames)}`);
	}
	await tab.fill("#line", "hello across servers");
	await tab.press("#line", "Enter");
	await tab.waitForSelector('.bubble:has-text("hello across servers")', { timeout: 30_000 })
		.catch(() => fail("the foreign room did not echo over its own capability"));
	// Settings is about *this* directory, and stays about it while a room on
	// another one is being read. It used to answer with whichever directory the
	// conversation on screen was on, so the same heading meant two different
	// things depending on where you had been — checked from the foreign room for
	// exactly that reason, because that is the state in which the two answers
	// differ.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	const shownLocator = (await tab.textContent("#directoryLocator"))?.trim() ?? "";
	if (shownLocator === foreignLocator) {
		fail("Settings described the directory of the room being read, not the one the page came from");
	}
	const homeAnswer = await fetch(`http://127.0.0.1:${httpPort}/locator`);
	const homeLocator = (await homeAnswer.text()).trim();
	if (shownLocator !== homeLocator) {
		fail(`Settings names ${JSON.stringify(shownLocator)} as this directory, but the page came from ${homeLocator}`);
	}
	await tab.keyboard.press("Escape");

	// Both servers at once, which is the whole of it: the rail groups by
	// directory the moment there is more than one to group by, the local room is
	// still listed and still joined, and going back to it is one press.
	// Every room row now says which server it is on, in words as well as colour.
	await tab.waitForFunction(
		() => {
			const said = [...document.querySelectorAll("#roomList .rwhere")]
				.map((row) => row.textContent?.trim() ?? "");
			return said.length >= 2 && new Set(said).size >= 2;
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("holding two servers did not say which server each room is on"));
	await tab.waitForFunction(
		() => {
			const joined = [...document.querySelectorAll("#roomList .rname")]
				.map((row) => row.textContent?.trim());
			return joined.includes("lobby") && joined.includes("elsewhere");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("reaching a second server gave up the room held on the first"));

	// The directory line is a caption under the room's name, not a second name
	// beside it, and the difference is carried entirely by its size. That size is
	// worth measuring because it is quiet to lose: the line is drawn as a link,
	// links here take their surroundings' font so one inside a sentence matches
	// the sentence, and that rule outranks the caption's own size unless the
	// caption is written to beat it. Nothing about the page looks broken when it
	// does not — the words are all still there, in the wrong place in the reading
	// order.
	const scale = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li");
		const name = row?.querySelector(".rname");
		const where = row?.querySelector(".rwhere");
		if (name === null || name === undefined || where === null || where === undefined) return null;
		const px = (el: Element) => parseFloat(getComputedStyle(el).fontSize);
		return { name: px(name), where: px(where) };
	});
	if (scale === null) fail("a room row held no directory caption to size");
	else if (!(scale.where <= scale.name * 0.85)) {
		fail(
			`the directory caption is set at ${scale.where}px against a ${scale.name}px room name, ` +
				"so it reads as a second name rather than a caption under the first",
		);
	}

	// The caption under a room's name opens what is known about the directory it
	// names, and where that lands depends on which directory it is. Settings
	// already describes the one this page came from, so that caption opens
	// Settings rather than a second surface repeating it; every other directory
	// gets a card of its own. Both are checked, because the split is the whole
	// design and a single surface answering both would pass any test that only
	// asked whether something opened.
	const captionOf = (room: string) => {
		const row = tab.locator("#roomList li").filter({ has: tab.locator(`.rname:text-is("${room}")`) });
		return row.locator(".rwhere");
	};
	await (captionOf("lobby")).click();
	await tab.waitForSelector("#settingsTitle", { timeout: 10_000 })
		.catch(() => fail("the caption on a room in this page's own directory did not open Settings"));
	// And Settings is about this directory, not about directories in general: the
	// name it granted is one of the three things it has to answer.
	const settingsSaid = await tab.evaluate(() => {
		const facts = document.querySelectorAll("#overviewPanel .dirfacts dt");
		return [...facts].map((dt) => dt.textContent?.trim() ?? "");
	});
	if (!settingsSaid.includes("Your name here")) {
		fail(`Settings does not say what this directory granted you; it lists ${JSON.stringify(settingsSaid)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "detached", timeout: 10_000 });

	await (captionOf("elsewhere")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("the caption on a room in another directory did not open a card about it"));
	const cardSaid = await tab.evaluate(() => ({
		title: document.getElementById("dircardTitle")?.textContent?.trim() ?? "",
		locator: document.getElementById("dircardLocator")?.textContent?.trim() ?? "",
		facts: [...document.querySelectorAll(".dircard-title, #dircardTitle")].length,
		rows: document.querySelectorAll(".modal .dirfacts dt").length,
	}));
	// The title is the readable name and the field is the exact locator, which is
	// the split that lets one be read aloud and the other pasted.
	if (cardSaid.title === "" || cardSaid.title.includes("%")) {
		fail(`the card titled a directory with something unreadable: ${JSON.stringify(cardSaid.title)}`);
	}
	if (cardSaid.rows < 3) {
		fail(`the card answered ${cardSaid.rows} of the three questions a directory raises`);
	}
	// And it wears the directory's own mark, in the colour that directory's rows
	// wear in the rail. Compared rather than asserted as a value, because the
	// claim is that the two agree: a card carrying some other colour, or the
	// ink's default because the variable never reached it, both read as this
	// card being about something else.
	const marksAgree = await tab.evaluate(() => {
		const inCard = document.querySelector(".dircard .dircard-mark");
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => (li.querySelector(".rname")?.textContent ?? "").includes("elsewhere"));
		const inRail = row?.querySelector(".rwhere .icon-svg");
		if (inCard === null || inRail === null || inRail === undefined) return null;
		return {
			card: getComputedStyle(inCard).color,
			rail: getComputedStyle(inRail).color,
		};
	});
	if (marksAgree === null) fail("the card or the rail carried no directory mark to compare");
	else if (marksAgree.card !== marksAgree.rail) {
		fail(
			`the card's directory mark is ${marksAgree.card} where the rail draws that directory ${marksAgree.rail}`,
		);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });

	// The line under a room's name is a target of its own, so it has to look like
	// one: it spans the row's whole content box, starting where the sigil starts
	// and ending where the count and the leave mark end, and what is written on
	// it — the directory's mark and the words naming it — sits in the middle of
	// that box as one piece. Measured, because every one of these was wrong at
	// some point while the line still read fine in a screenshot: an indent that
	// put it past the name, a right edge short of the marks, and words that
	// centred while the glyph stayed pinned at the far left, which is the shape
	// this replaced.
	const laidOut = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => li.querySelector(".rwhere") !== null);
		const cap = row?.querySelector(".rwhere");
		const hash = row?.querySelector(".hash");
		const leave = row?.querySelector(".room-leave");
		const icon = cap?.querySelector(".icon-svg");
		const said = cap?.querySelector(".rwhere-said");
		if (!cap || !hash || !leave || !icon || !said) return null;
		const box = (el: Element) => {
			const b = el.getBoundingClientRect();
			return { l: b.left, r: b.right, cx: b.x + b.width / 2 };
		};
		const c = box(cap), h = box(hash), v = box(leave);
		const i = box(icon), w = box(said);
		return {
			startsAtTheMark: Math.abs(c.l - h.l),
			endsAtTheMarks: Math.abs(c.r - v.r),
			// One piece: the words follow the glyph across the family's own gap,
			// rather than each being placed by a column of the row above.
			markBesideItsWords: Math.abs(w.l - i.r) > 12 ? Math.abs(w.l - i.r) : 0,
			// And the piece sits in the middle, which is what leaves the glyph the
			// air on its left that being placed by the mark column took away.
			centredInTheLine: Math.abs((i.l - c.l) - (c.r - w.r)),
			// Drawn at rest, not only under a pointer. A distance, so it is asked
			// as one below rather than folded in among them.
			edge: parseFloat(getComputedStyle(cap).borderTopWidth),
		};
	});
	// The bar marking the row being read is the row's height less a little at
	// each end, not a number of its own. A row is one line tall until it names its
	// directory and then it is two: measured against a fixed bar that reads as
	// half of a short row, a tall one gets a third, and nothing about that looks
	// broken enough to notice without measuring it.
	const marking = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li.here")]
			.find((li) => li.querySelector(".rwhere") !== null);
		if (row === undefined) return null;
		const mark = parseFloat(getComputedStyle(row, "::before").height);
		return { row: row.getBoundingClientRect().height, mark };
	});
	if (marking === null) fail("no room being read carried a directory line, so the mark had nothing to grow with");
	else if (!(marking.mark > 0) || Math.abs(marking.row - marking.mark - 14) > 1) {
		fail(
			`the mark on the row being read is ${marking.mark.toFixed(1)}px on a ${
				marking.row.toFixed(1)
			}px row, which is not that row's height less its inset`,
		);
	}

	if (laidOut === null) fail("no room row carried a directory line with a mark and words in it");
	else {
		if (!(laidOut.edge > 0)) {
			fail("the directory line is drawn with no rectangle at rest, so it is a target only under a pointer");
		}
		for (const [what, off] of Object.entries(laidOut)) {
			if (what !== "edge" && off > 1) {
				fail(`the directory line does not line up: ${what} is out by ${off.toFixed(1)}px`);
			}
		}
	}

	// One takes the other's place, so they have to occupy the same place, and the
	// place a reader aims at is the middle of the mark rather than its right edge.
	// A row grows a second line the moment it names a directory, and anything
	// anchored to the row's full height then drifts below anything anchored to the
	// line the name is on. Measured on a captioned row for that reason: on a
	// single-line row the two anchors agree and the defect cannot appear.
	//
	// The press is measured too, and separately, because every other reading here
	// was already perfect while the control could not be pressed: the count fades
	// to nothing when the mark takes its slot, and something at zero opacity still
	// takes clicks. Visible, enabled, aligned, and dead through its own middle is
	// a state only this question can see.
	const slot = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => li.querySelector(".rwhere") !== null);
		const leave = row?.querySelector(".room-leave");
		const badge = row?.querySelector(".rcount");
		if (!leave || !badge) return null;
		const a = leave.getBoundingClientRect();
		const b = badge.getBoundingClientRect();
		const at = document.elementFromPoint(a.x + a.width / 2, a.y + a.height / 2);
		return {
			dy: Math.abs((a.y + a.height / 2) - (b.y + b.height / 2)),
			dx: Math.abs((a.x + a.width / 2) - (b.x + b.width / 2)),
			pressable: at !== null && leave.contains(at),
			covering: at === null ? "nothing" : at.nodeName + "." + String(at.getAttribute("class") ?? ""),
		};
	});
	if (slot === null) fail("no room row carried both a directory caption and the pair of marks that share its slot");
	else if (slot.dy > 1 || slot.dx > 1) {
		fail(
			`the leave mark and the badge do not share a slot on a two-line row: ` +
				`${slot.dy.toFixed(1)}px apart vertically and ${slot.dx.toFixed(1)}px across`,
		);
	} else if (!slot.pressable) {
		fail(`a press at the centre of the leave mark lands on ${slot.covering} instead of the mark`);
	}

	// Every word in the rails clears the 4.5 to 1 small text asks for, against
	// what is really behind it, in both appearances.
	//
	// The stylesheet argues two of these numbers in prose — the caption on a
	// selected row was diluted, measured, and undiluted again because the quieter
	// ink came out at 4.0 on the amber and 3.1 on the teal. Nothing held the
	// answer, so any of the tokens underneath could have moved it back under the
	// line without a word changing. And the whole argument had only ever been made
	// in light: the rail is drawn from the same tokens in syrup, at different
	// values, and nothing had ever measured it there.
	//
	// This is the point in the run where the rail carries the most: two
	// directories, so every row wears a caption, one of them selected, and a
	// roster beside it.
	const RAIL_INK = [
		["the caption on the row being read", "#roomList li.here .rwhere-said"],
		["the caption on an ordinary row", "#roomList li:not(.here) .rwhere-said"],
		["the name of the room being read", "#roomList li.here .rname"],
		["a room's name", "#roomList li:not(.here) .rname"],
		["a room's count", "#roomList .rcount"],
		["a list's label", ".section-head span"],
		["the roster's label", ".members h2"],
		["a member's name", "#members .online .name"],
		["what the connection is doing", "#status"],
	] as const;
	const wasTheme = await tab.getAttribute("html", "data-theme");
	const tooFaint: string[] = [];
	// At rest, which takes saying twice: the pointer sent away and the keyboard
	// let go. Earlier checks left the pointer parked on a row and focus on the
	// caption it pressed, and either one swaps that caption's ink for the teal a
	// link wears — hover changes its ground too. What came back was an interactive
	// state wearing a resting state's name, and its numbers said nothing about the
	// rail a reader is looking at.
	await tab.mouse.move(0, 0);
	await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	for (const appearance of ["light", "dark"] as const) {
		await tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
		// Settled first. Changing the appearance re-renders the rail, and a rail
		// arriving runs a two-tenths fade that starts at nothing — so a reading
		// taken straight after the switch is of a half-drawn panel, and it lands
		// near one to one however the colours are set. That is what a colour bug
		// looks like from here, and it does not move when you fix colours.
		await tab.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))));
		for (const [what, selector] of RAIL_INK) {
			const measured = await inkContrast(tab, selector);
			// A refusal is a failure of its own. Every one of these is on screen here,
			// so "could not measure" means the measuring broke, and a measurement that
			// quietly stops answering is indistinguishable from one that passes.
			if (measured === null) tooFaint.push(`${what} could not be measured in ${appearance}`);
			else if (measured.ratio < 4.5) {
				tooFaint.push(`${what} is ${measured.ratio.toFixed(2)}:1 in ${appearance} (${measured.saw})`);
			}
		}
	}
	await tab.evaluate((t) => {
		if (t === null) document.documentElement.removeAttribute("data-theme");
		else document.documentElement.setAttribute("data-theme", t);
	}, wasTheme);
	if (tooFaint.length > 0) {
		fail(`the rail does not clear 4.5 to 1 for small text: ${tooFaint.join("; ")}`);
	}

	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForSelector('.bubble:has-text("hello from a browser peer")', { timeout: 10_000 })
		.catch(() => fail("the first server's room did not come back with its history"));

	// A directory with nothing open on it is still a directory this tab is on: a
	// live session, and a name registered on it that nobody else can take. Leaving
	// the last room on one used to leave exactly that, with no row anywhere saying
	// so — a connection nobody could see and therefore nobody could end. It also
	// kept every other row wearing a directory caption, to tell rooms apart from
	// rooms on a directory that was not on screen at all.
	const before = tab.locator("#roomList li").filter({ has: tab.locator('.rname:text-is("elsewhere")') });
	await before.hover();
	await before.locator(".room-leave").click();
	await tab.waitForFunction(
		() => {
			const named = [...document.querySelectorAll("#roomList .rname")].map((el) => el.textContent?.trim());
			return !named.includes("elsewhere");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("leaving the last room on a directory did not take the room out of the rail"));
	const stranded = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li.dirrow")][0];
		if (row === undefined) return null;
		// This row's caption says why the directory is here rather than where it
		// is, so it is the one caption in the rail that carries no little glyph.
		// Its words are still centred on the line the way a caption's are, which
		// with nothing beside them means centred in the row: a lone span left to
		// flow would sit against one edge of its own rectangle, and a rectangle
		// with its words jammed into a corner reads as a mistake rather than as
		// the quiet line it is.
		const said = row.querySelector(".rwhere-said");
		const line = row.querySelector(".rwhere");
		return {
			named: row.querySelector(".rname")?.textContent?.trim() ?? "",
			said: line?.textContent?.trim() ?? "",
			canLeave: row.querySelector(".room-leave") !== null,
			underTheName: said === null || line === null ? Number.NaN : (() => {
				const w = said.getBoundingClientRect(), c = line.getBoundingClientRect();
				return Math.abs((w.left - c.left) - (c.right - w.right));
			})(),
		};
	});
	if (stranded === null) {
		fail("a directory with nothing open on it left no row, so its session could not be seen or ended");
	} else if (!stranded.canLeave || stranded.named === "") {
		fail(`the row for a directory with nothing on it is unusable: ${JSON.stringify(stranded)}`);
	} else if (!(stranded.underTheName <= 1)) {
		fail(
			`the line under a stranded directory's name is not centred on its own rectangle: ` +
				`out by ${stranded.underTheName.toFixed(1)}px`,
		);
	}
	// And it is the same directory, reachable again from its own row.
	await tab.click("#roomList li.dirrow .room-open");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("a directory with nothing on it did not offer a way to join a room on it"));
	// Filled with the directory's own identity rather than with what was once
	// typed, so the check is that it names that peer, not that it matches a
	// spelling of it.
	const aimed = await tab.inputValue("#locator");
	if (!aimed.includes(String(foreignRoomPort))) {
		fail(`joining from a directory's own row aimed at ${JSON.stringify(aimed)} rather than that directory`);
	}
	await tab.fill("#room", "elsewhere");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("a room could not be joined from the row of a directory with nothing on it"));

	// Leaving a directory, which is the other end of reaching one. Holding a
	// directory is a live session, a name registered on it, and everything
	// reachable through that name, so letting it go has to be all of that. A row
	// removed from a list while the session went on running is the failure worth
	// checking for, and it does not look like a failure at the moment it happens:
	// it looks like it worked, and then the directory comes back on its own.
	await (captionOf("elsewhere")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 });
	await tab.click("#dircardLeaveAsk");
	// Asked before it is done, and asked with the cost in it: a reader who is
	// about to lose a room should be told how many.
	const asked = (await tab.textContent("#dircardLeaveSaid"))?.trim() ?? "";
	if (!asked.includes("1 room")) {
		fail(`leaving did not say what it would close; it said ${JSON.stringify(asked)}`);
	}
	await tab.click("#dircardLeave");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("leaving a directory left its card open"));
	await tab.waitForFunction(
		() => {
			const named = [...document.querySelectorAll("#roomList .rname")].map((el) => el.textContent?.trim());
			return !named.includes("elsewhere") && named.includes("lobby");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("leaving a directory did not take its rooms with it, or took the other directory's too"));
	// And it stays left. A session that was dropped from the list without being
	// released still has a reconnect timer, and that timer opens the directory
	// again a second or two later — the tell is a row that comes back by itself.
	await tab.waitForTimeout(4000);
	const cameBack = await tab.evaluate(() =>
		[...document.querySelectorAll("#roomList .rname")].some((el) => el.textContent?.trim() === "elsewhere")
	);
	if (cameBack) fail("a directory that was left dialled itself back and returned to the rail");
	// With one directory left there is nothing to tell apart, so the rail stops
	// naming directories at all.
	const stillNaming = await tab.locator("#roomList .rwhere").count();
	if (stillNaming !== 0) {
		fail(`the rail went on naming directories with only one left; ${stillNaming} rows still say which`);
	}

	// The name goes back, which is the part of leaving that nothing on screen can
	// show and the part most likely to be got wrong. A directory grants a name for
	// the length of a connection; if leaving drops the row but leaves the session
	// running, the directory is still holding that name and hands out a suffixed
	// one to whoever asks next — including us, walking back in. So this walks back
	// in, and the name it is given is the whole answer.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "elsewhere");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 });
	await tab.fill("#locator", foreignLocator);
	await tab.fill("#nick", "bo");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("a directory that had been left could not be reached again"));
	await (captionOf("elsewhere")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 });
	const grantedAgain = await tab.evaluate(() => {
		const rows = [...document.querySelectorAll(".modal .dirfacts dt")];
		const which = rows.find((dt) => dt.textContent?.trim() === "Your name here");
		return which?.nextElementSibling?.textContent?.trim() ?? "";
	});
	if (grantedAgain !== "bo") {
		fail(
			`walking back into a directory that was left was granted ${JSON.stringify(grantedAgain)} rather ` +
				"than the name it gave up, so leaving did not hand the name back",
		);
	}
	await tab.keyboard.press("Escape");

	// The join card offers the addresses already in hand. A locator is forty
	// characters nobody retypes, and every one of these was pasted once already,
	// so the field can be filled from what the tab is holding instead. Leaving it
	// empty means this page's own directory, so that one clears rather than fills
	// — the two directions are different actions and both are checked.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "wherever");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 });
	const offered = await tab.evaluate(() =>
		[...document.querySelectorAll(".locator-picks .button")].map((b) => b.textContent?.trim() ?? "")
	);
	if (!offered.includes("this directory")) {
		fail(`the join card did not offer this page's own directory; it offered ${JSON.stringify(offered)}`);
	}
	if (offered.length < 2) {
		fail(`the join card offered nothing but this directory while the tab held another: ${JSON.stringify(offered)}`);
	}
	await tab.click(`.locator-picks .button:not(:text-is("this directory"))`);
	const filled = await tab.inputValue("#locator");
	if (filled === "") fail("pressing a held directory did not fill the locator field");
	await tab.click(`.locator-picks .button:text-is("this directory")`);
	const cleared = await tab.inputValue("#locator");
	if (cleared !== "") {
		fail(`pressing "this directory" left ${JSON.stringify(cleared)} in the field instead of clearing it`);
	}

	// A directory going away, while another is still up. "Reconnecting…" is the
	// whole message when there is one directory it could be about and a riddle
	// when there are two: the rooms on the other one are still live, and a reader
	// watching one of those go quiet cannot tell whether this is about them. Last
	// in the run, because it ends the second server for good.
	const nameOfForeign = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => (li.querySelector(".rwhere")?.textContent ?? "").includes("127.0.0.1"));
		return (row?.querySelector(".rwhere")?.textContent ?? "").replace(/^in\s+/, "").trim();
	});
	if (nameOfForeign === "") fail("no room in the rail said it was on the second server");
	// Said into that room as the server goes, so there is a line in flight when
	// the session dies. This is how an ordinary reader meets a failed send: not
	// by typing into a dead page, which the composer already refuses, but by
	// having said something a moment before the ground moved.
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .room-open`);
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the room on the second server would not take a line before that server went"));
	// And a file posted into it while it was up. A file reference is only good on
	// the connection it arrived over, so this one is about to become unfetchable
	// while its row stays on screen offering to fetch it.
	await tab.setInputFiles("#filePick", {
		name: "before.txt",
		mimeType: "text/plain",
		buffer: Buffer.from("posted while the second server was up"),
	});
	await tab.waitForSelector('.composer-file:has-text("before.txt")', { timeout: 10_000 })
		.catch(() => fail("the file for the second server was not attached to the composer"));
	await tab.click("#sendBtn");
	await tab.waitForSelector('.row.mine .attach-file:has-text("before.txt") .icon-button', { timeout: 60_000 })
		.catch(() => fail("a file posted to the room on the second server never landed"));
	// Uploaded, not merely announced. The row is drawn from the optimistic bubble
	// the moment Send is pressed, so waiting for it proves nothing; the bubble
	// stops saying it is sending when the last byte is on the room. Killing the
	// server before that is a different scenario, an upload cut off mid-flight.
	// This one is about a file the room has.
	await tab.waitForFunction(
		() => {
			const bubble = [...document.querySelectorAll(".bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes("before.txt"));
			return bubble !== undefined && !(bubble.textContent ?? "").includes("Sending");
		},
		undefined,
		{ timeout: 60_000 },
	).catch(() => fail("a file posted to the room on the second server never finished uploading"));

	// And a line said while it was up, which the room answers with the reference
	// that governs it. That reference came over this connection, so what happens
	// to the pencil and the close beside it when the connection goes is the point
	// of the pair of checks below.
	const keptLine = "said while the second server was up";
	await tab.fill("#line", keptLine);
	await tab.press("#line", "Enter");
	// The room's echo first, because that is this scenario's barrier: everything
	// below turns on the server going away at a known moment, and a wait that can
	// be satisfied by the bubble this tab painted for itself is no barrier at all.
	await tab.waitForFunction(
		(text) => {
			const bubble = [...document.querySelectorAll(".row.mine .bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			return bubble !== undefined && !bubble.classList.contains("sending");
		},
		keptLine,
		{ timeout: 30_000 },
	).catch(() => fail("the room on the second server never confirmed a line said into it"));
	await tab.waitForFunction(
		(text) => {
			const bubble = [...document.querySelectorAll(".row.mine .bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			return bubble !== undefined && bubble.querySelector(".line-acts") !== null;
		},
		keptLine,
		{ timeout: 30_000 },
	).catch(() => fail("a line posted to the room on the second server was never offered a way to change it"));

	const inFlight = "said as the second server went away";
	await tab.fill("#line", inFlight);
	const pressed = tab.press("#line", "Enter");
	try {
		foreignRoom.kill();
	} catch {
		// already gone
	}
	await pressed;
	// Back to the room on this page's own directory. Pressing the room you are
	// already in is how a reader puts the rail away, so leaving the tab in this
	// one would turn the next press on its row — the one below, which expects to
	// open it — into a press that closes the rail instead.
	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForFunction(
		() => (document.querySelector(".banner")?.textContent ?? "").includes("Reconnecting"),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("a directory going away while another was up said nothing at all"));
	const announced = (await tab.textContent(".banner"))?.trim() ?? "";
	if (!announced.includes(nameOfForeign)) {
		fail(
			`the reconnect notice does not say which directory it is about: ${JSON.stringify(announced)} ` +
				`while holding one named ${JSON.stringify(nameOfForeign)}`,
		);
	}

	// And the field a reader would type into says so itself. Opening a room on
	// the directory that went away leaves the composer unusable, and a control
	// that refuses without saying why is a dead box under an invitation to type
	// in it. The banner and the rail's foot both carry the news, but the banner
	// goes away and the foot is at the far corner of a wide screen and a
	// different screen entirely on a phone — and with two directories held it is
	// answering about the page while this field is refusing for one of them.
	// A room on the directory that went away is still a room this tab is in, and
	// opening it has to show it. Gating that on a live session put a reader in
	// front of a form asking them to join a room they were already in, with the
	// history they came for behind it — so this asserts the conversation opens
	// before it asks what the field says.
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .room-open`);
	await tab.waitForFunction(
		() => (document.getElementById("roomName")?.textContent ?? "") !== "No room yet",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("opening a room on a directory that had gone away showed no conversation, only the join card"));
	const refusing = await tab.evaluate(() => {
		const line = document.getElementById("line") as HTMLTextAreaElement | null;
		return line === null ? null : {
			disabled: line.disabled,
			said: line.placeholder,
			// What the rail and the header actually hold, so a wrong answer names
			// the state it was taken in rather than leaving it to be guessed at.
			open: document.getElementById("roomName")?.textContent ?? "(none)",
			rows: [...document.querySelectorAll("#roomList li")].map((li) =>
				(li.querySelector(".rname")?.textContent ?? "?") + "/" +
				(li.querySelector(".rwhere")?.textContent ?? "-")
			).join(", "),
		};
	});
	if (refusing === null) fail("the conversation on a directory that went away drew no composer at all");
	else if (!refusing.disabled) {
		fail("the composer stayed usable on a directory that had gone away");
	} else if (refusing.said === "" || /^Message\b/.test(refusing.said)) {
		fail(
			`a composer that cannot be used still invites typing: it says ${JSON.stringify(refusing.said)} ` +
				`rather than what the directory is doing, with ${JSON.stringify(refusing.open)} open and the ` +
				`rail holding ${JSON.stringify(refusing.rows)}`,
		);
	}

	// And the card that exists to answer "what is wrong with this one" says what.
	// The banner goes away, the foot speaks for whichever directory is on screen,
	// and this card is where a reader goes when one of two is misbehaving — so
	// the phase word on its own is the single thing they already knew.
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .rwhere`);
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("the line under a room on a directory that went away no longer opens its card"));
	await tab.waitForFunction(
		() => {
			const dt = [...document.querySelectorAll(".modal .dirfacts dt")]
				.find((row) => row.textContent?.trim() === "Connection");
			const said = dt?.nextElementSibling?.textContent?.trim() ?? "";
			return /reach|retry/i.test(said);
		},
		undefined,
		{ timeout: 60_000 },
	).catch(async () => {
		const said = await tab.evaluate(() => {
			const dt = [...document.querySelectorAll(".modal .dirfacts dt")]
				.find((row) => row.textContent?.trim() === "Connection");
			return dt?.nextElementSibling?.textContent?.trim() ?? "(no connection row)";
		});
		fail(`the card for a directory that went away says only ${JSON.stringify(said)}`);
	});
	await tab.keyboard.press("Escape");

	{
		// The line that was in flight when the server went. It is not sent, it says
		// so, and — unlike one typed into a conversation that closed for good — it
		// carries the way to send it again, because a session is a thing that comes
		// back.
		const unsent = await tab.waitForSelector(".delivery-failure", { timeout: 60_000 })
			.catch(async () => {
				// What the log holds instead. A line that was confirmed before the
				// server went and a line that vanished are different failures, and
				// this used to report neither.
				const shown = await tab.evaluate(() => ({
					mine: [...document.querySelectorAll(".row.mine .bubble")].map((bubble) =>
						(bubble.textContent ?? "").slice(0, 60)
					),
					banner: document.querySelector(".banner")?.textContent?.trim() ?? "",
				}));
				fail(
					`a line in flight when its server went was never marked unsent: ${inFlight}; ` +
						`the log holds ${JSON.stringify(shown)}`,
				);
			});
		// Named by the line it is about. A conversation can hold more than one
		// unsent message, and they do not all carry the same answer: this one is
		// a line a session took with it, and the file beside it is a transfer
		// nothing can resume.
		const carried = await tab.evaluate((text) => {
			const row = [...document.querySelectorAll(".row.mine")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			const failure = row?.querySelector(".delivery-failure");
			return failure == null ? null : {
				said: failure.textContent?.trim() ?? "",
				retries: failure.querySelectorAll("button").length,
			};
		}, inFlight);
		if (carried === null || carried.retries !== 1) {
			fail(`a line that could be sent again offers ${JSON.stringify(carried)} rather than one retry`);
		}
		void unsent;

		// Pressed while the server is still away. The control is live — it is in
		// the bubble, not in the composer the directory disables — so a reader can
		// and will press it, and it cannot work yet. What it must not do is
		// nothing: a press that changes nothing reads as a broken button rather
		// than as a room that is not back.
		await tab.click(".delivery-failure button");
		await tab.waitForFunction(
			() => (document.getElementById("log")?.textContent ?? "").includes("Not in this room at the moment"),
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const log = await tab.evaluate(() => (document.getElementById("log")?.textContent ?? "").slice(-200));
			fail(`retrying before the room was back said nothing: ${JSON.stringify(log)}`);
		});
		if (await tab.locator(".delivery-failure").count() !== 1) {
			fail("a retry that could not go left the message looking sent");
		}

		// The file that was posted before the server went. The room may well still
		// hold its bytes; what ended was the connection they were offered over, and
		// no later press can get them back. So the press says that, once, and the
		// row then stops offering. A control that cannot succeed invites a reader
		// to keep pressing for as long as they are willing to believe it might.
		const fileRow = '.row.mine .attach-file:has-text("before.txt")';
		if (await tab.locator(`${fileRow} .icon-button`).count() !== 1) {
			fail("the file posted before the server went lost its control before it was ever pressed");
		}
		await tab.click(`${fileRow} .icon-button`);
		const saidOfFile = () =>
			tab.evaluate(() => {
				const row = [...document.querySelectorAll(".attach-file")]
					.find((candidate) => (candidate.textContent ?? "").includes("before.txt"));
				return row === undefined ? "(no row)" : row.querySelector(".sub")?.textContent ?? "(no reason)";
			});
		await tab.waitForFunction(
			() => {
				const row = [...document.querySelectorAll(".attach-file")]
					.find((candidate) => (candidate.textContent ?? "").includes("before.txt"));
				return (row?.querySelector(".sub")?.textContent ?? "").includes("earlier connection");
			},
			undefined,
			{ timeout: 15_000 },
		).catch(async () => {
			fail(`asking for a file whose connection had ended said ${JSON.stringify(await saidOfFile())}`);
		});
		if (await tab.locator(`${fileRow} .icon-button`).count() !== 0) {
			fail("a file that can never be fetched again still offers a control that fetches it");
		}

		// And the line that was posted while the server was up. Changing or
		// withdrawing one is holding the reference the room answered with, and a
		// reference cannot outlive the connection it came over. What was said is
		// still there; what could be done to it is not, so the controls go rather
		// than staying to refuse.
		const offeredStill = await tab.evaluate((text) => {
			const bubble = [...document.querySelectorAll(".row.mine .bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			return bubble === undefined ? -1 : bubble.querySelectorAll(".line-acts").length;
		}, keptLine);
		if (offeredStill === -1) fail("the line said before the server went was lost with it");
		if (offeredStill !== 0) {
			fail("a line whose governing reference died with its connection still offers to change it");
		}

		// Stand the server back up and press it. Pressing is the point: a control
		// that draws and cannot be reached is the failure this page has had before,
		// and only a press tells the two apart.
		foreignAgain = new Deno.Command("deno", {
			args: [
				"run",
				"--allow-ffi",
				"--allow-read",
				"--allow-net",
				"--allow-env",
				`${ROOT}apps/rooms/server/main.ts`,
				String(foreignRoomPort),
			],
			cwd: ROOT,
			stdout: "null",
			stderr: "inherit",
		}).spawn();
		// The page dials on its own with a backoff, and re-enters the rooms it
		// holds. Waited for by the room's own welcome rather than by the composer
		// coming back: the composer answers for the directory, which reconnects
		// first, and a retry pressed in that gap has no membership to post
		// through. What this is here to prove is that a reader who waits and then
		// presses gets their line sent, so it presses when the room is back.
		await tab.waitForFunction(
			() => ((document.getElementById("log")?.textContent ?? "").match(/welcome bo\b/g) ?? []).length >= 2,
			undefined,
			{ timeout: 90_000 },
		).catch(() => fail("the page never re-entered the room on the second server after it came back"));
		await tab.click(".delivery-failure button");
		await tab.waitForFunction(
			(text) => {
				const failed = document.querySelector(".delivery-failure");
				const drawn = [...document.querySelectorAll(".bubble")].some((b) =>
					(b.textContent ?? "").includes(text)
				);
				return failed === null && drawn;
			},
			inFlight,
			{ timeout: 60_000 },
		).catch(async () => {
			const state = await tab.evaluate(() => ({
				failure: document.querySelector(".delivery-failure")?.textContent?.trim() ?? "(none)",
				log: (document.getElementById("log")?.textContent ?? "").slice(-160),
			}));
			fail(`pressing retry did not send the line: ${JSON.stringify(state)}`);
		});
	}

	console.log(
		"PASS: the rooms page ran as a browser peer — joined local and foreign rooms through /relay and " +
			"round-tripped a line and a grouped multi-file message over the room capability, " +
			"no JSON bridge; held two rooms at once, where the one off screen kept " +
			"receiving and kept its own history and leaving it left the other alone; held two " +
			"directories at once, where each room said which one it was on and that line opened " +
			"Settings for this page's own and a card for the other; a directory with nothing left " +
			"open on it kept a row of its own to be seen and ended by; leaving one gave back the " +
			"name it had granted, which walking back in proved; both rails " +
			"hold their layout and their way back on a phone; nothing that truncates " +
			"cuts off its own descenders; the opening screen waited for the peer and " +
			"never flashed the message meant for a browser that cannot run it; and a " +
			"page that cannot draw itself says so",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
	try {
		foreignRoom.kill();
	} catch {
		// already gone
	}
	await foreignRoom.status;
	if (foreignAgain !== null) {
		try {
			foreignAgain.kill();
		} catch {
			// already gone
		}
		await foreignAgain.status;
	}
}
Deno.exit(0);
