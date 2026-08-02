// The rooms web page as a real browser peer, end to end. A headless Chromium
// loads the ACTUAL page serve.ts serves — the
// bundled `@pancake/web` graph, `pancake_host.wasm`, and the UI — joins a
// room, sends a line, and sees the room echo it back. Every hop is the shipped
// path: the page's wasm Host holds the room capability, dials the room server
// through serve.ts's `/relay`, and drives `lib/room_client.ts` directly. No JSON
// bridge is on the page's path.
//
// It then holds the two rails that flank the conversation — the rooms and
// direct-message list, and the roster — to the promises they make on both
// layouts. A real browser is the only place those can be checked: every one of
// them is about what a reader can see or reach, and a stylesheet read on its own
// says nothing about either.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium
// (`npx playwright install chromium && sudo npx playwright install-deps`).
// Run: `deno run --allow-all apps/rooms/test/web_page_test.ts`.

import { chromium } from "playwright";

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

const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
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
	Deno.exit(1);
}, 150_000);

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	await waitForHttp(httpPort);

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));

	await tab.goto(`http://127.0.0.1:${httpPort}/`);

	// The page draws itself, so page.html carries an explanation for when it
	// cannot. Two things have to hold: the interface replaces it on mount, or the
	// message would sit under a working page; and it is actually reached when the
	// bundle is not, which is the case nobody sees until it happens to them.
	if (await tab.locator(".boot").count() !== 0) {
		fail("the boot message survived mount; it would sit under the running page");
	}
	{
		const dark = await browser.newContext();
		const blind = await dark.newPage();
		await blind.route("**/page.js", (route) => route.fulfill({ status: 503, body: "" }));
		await blind.goto(`http://127.0.0.1:${httpPort}/`);
		if (!await blind.locator(".boot").isVisible()) {
			fail("a page whose bundle did not load shows a reader nothing at all");
		}
		await dark.close();
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
		(text) =>
			[...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		line,
		{ timeout: 30_000 },
	).catch(() => fail("the sent line never came back from the room over the capability stream"));

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

	// The mark is one control with two homes: the rail holds it while the list is
	// up and the topbar picks it up when the list goes away. Whichever is holding
	// it, it has to be in the same place and the same size, or putting the rail
	// away reads as the page redrawing rather than as one control travelling. The
	// bars are measured, not the button frame around them, because two frames can
	// land on the same pixel while the marks inside them differ.
	const markBox = (sel: string) =>
		tab.evaluate((s) => {
			const e = document.querySelector(s)!;
			const r = e.getBoundingClientRect();
			const bars = getComputedStyle(e, "::before");
			return { x: r.left, y: r.top, size: `${bars.width}×${bars.height}` };
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

	// ── The narrow layout ────────────────────────────────────────────────
	// On a phone each rail takes the whole screen or slides over it, so each one
	// owes the reader a way back to the conversation it covered.
	await tab.setViewportSize({ width: 390, height: 844 });
	await tab.waitForTimeout(400);
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

	console.log(
		"PASS: the rooms page ran as a browser peer — joined a room through /relay and " +
			"round-tripped a line over the room capability, no JSON bridge; both rails " +
			"hold their layout and their way back on a phone; nothing that truncates " +
			"cuts off its own descenders; and a page that cannot draw itself says so",
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
}
Deno.exit(0);
