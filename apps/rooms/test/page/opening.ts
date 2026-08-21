// The first thing a reader sees, and what the page does before it can show it.
//
// A browser peer has to boot a wasm Host and dial through the relay before any
// of this is a room at all, so most of what is checked here is the waiting: what
// is on screen during it, what is never on screen, and what a page that cannot
// run says instead of nothing.

import type { Browser, Page } from "playwright";
import { fail } from "./harness.ts";
import { railQuestions } from "./filter_form.ts";
import { inkContrast } from "../ink_contrast.ts";
import * as linked from "./linked.ts";

export async function run(tab: Page, httpPort: number, browser: Browser): Promise<void> {
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
	// The mark is its four animated pieces; each paints currentColor, so the
	// brand check reads a piece's fill rather than the container's.
	const bootMark = await tab.locator(".boot-mark .mark-piece").first().evaluate((piece) => {
		const probe = document.createElement("span");
		probe.style.color = "var(--accent)";
		document.body.append(probe);
		const brand = getComputedStyle(probe).color;
		probe.remove();
		return { painted: getComputedStyle(piece).backgroundColor, brand };
	});
	if (bootMark.painted !== bootMark.brand) {
		fail(`the opening mark is ${bootMark.painted} where the brand is ${bootMark.brand}`);
	}
	await tab.waitForSelector("#joinBtn", { timeout: 60_000 });

	const identifierKeys = await tab.evaluate(() => {
		const of = (id: string) => {
			const el = document.getElementById(id);
			if (!(el instanceof HTMLInputElement)) return null;
			return {
				autocapitalize: el.autocapitalize,
				spellcheck: el.spellcheck,
				translate: el.translate,
			};
		};
		return { locator: of("locator"), room: of("room"), nick: of("nick") };
	});
	for (const [id, keys] of Object.entries(identifierKeys)) {
		if (keys == null) fail(`#${id} is not on the join card`);
		if (keys.autocapitalize !== "none" && keys.autocapitalize !== "off") {
			fail(`#${id} still auto-capitalizes (${JSON.stringify(keys.autocapitalize)})`);
		}
		if (keys.spellcheck) fail(`#${id} still spellchecks an identifier`);
		if (keys.translate) fail(`#${id} is still offered to page translation`);
	}

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
	const coverPaint = await tab.evaluate(() => {
		const filt = (style: CSSStyleDeclaration) => {
			if (style.backdropFilter && style.backdropFilter !== "none") return style.backdropFilter;
			return style.getPropertyValue("-webkit-backdrop-filter");
		};
		const back = getComputedStyle(document.querySelector("dialog.modal")!, "::backdrop");
		const cover = getComputedStyle(document.querySelector("#cover")!);
		return {
			blur: [filt(back), filt(cover)],
			dim: [back.backgroundColor, cover.backgroundColor],
		};
	});
	if (coverPaint.blur.some((value) => value === "" || value === "none")) {
		fail("a page cover has no blur");
	}
	if (new Set(coverPaint.blur).size !== 1) {
		fail(`page covers blur differently: ${coverPaint.blur.join(" / ")}`);
	}
	if (new Set(coverPaint.dim).size !== 1) {
		fail(`page covers dim differently: ${coverPaint.dim.join(" / ")}`);
	}
	const coverRgb = coverPaint.dim[0].match(/rgba?\(\s*(\d+)/);
	const coverSrgb = coverPaint.dim[0].match(/color\(\s*srgb\s+([\d.]+)/);
	const red = coverRgb != null ? Number(coverRgb[1]) / 255 : coverSrgb != null ? Number(coverSrgb[1]) : null;
	if (red == null || red > 0.03) {
		fail(`page cover is not darkness (got ${coverPaint.dim[0]})`);
	}
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
	await tab.click("#settingsAboutDir");
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("Settings did not open this directory's card"));
	const beforeAName = await dmFact();
	if (!beforeAName.includes("no name granted")) {
		fail(`before a name was granted, the card answered ${JSON.stringify(beforeAName)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });
	await tab.waitForSelector("#settingsTitle");

	// A copy has no visible result, because the clipboard is somewhere the page
	// cannot show. So the control answers for it: a tick and a short "Copied"
	// over the field, then both go back to offering. A write the browser refused
	// is a toast above this modal, not a banner in the conversation underneath it.
	await tab.context().grantPermissions(["clipboard-read", "clipboard-write"], {
		origin: `http://127.0.0.1:${httpPort}`,
	});
	// The press lands on the text rather than on the mark in the corner, because
	// the whole field being the control is the point: a locator is shown so it
	// can be taken, so anywhere in it means the one thing it could mean.
	const locatorShown = (await tab.textContent("#directoryLocator"))?.trim() ?? "";
	await tab.click("#directoryLocator");
	await tab.waitForFunction(() => {
		const field = document.getElementById("directoryLocator")?.closest<HTMLElement>(".copy-field");
		const said = field?.querySelector(".copy-said")?.textContent?.trim() ?? "";
		return said !== "" && field?.dataset.copied !== undefined;
	}, { timeout: 5_000 }).catch(() => fail("copying a locator said nothing at all"));
	const onClipboard = await tab.evaluate(() => navigator.clipboard.readText());
	if (onClipboard.trim() !== locatorShown || locatorShown === "") {
		fail(`the copy control put ${JSON.stringify(onClipboard)} on the clipboard, not the locator`);
	}
	// The async clipboard API is what fails on an HTTP hostname that is not
	// localhost. The write still has to land, from inside this modal, using the
	// older command that keeps the user gesture.
	await tab.evaluate(() => {
		Object.defineProperty(navigator.clipboard, "writeText", {
			configurable: true,
			value: () => Promise.reject(new Error("denied")),
		});
	});
	await tab.click("#directoryLocator");
	const stillOnClipboard = await tab.evaluate(() => navigator.clipboard.readText());
	if (stillOnClipboard.trim() !== locatorShown) {
		fail("copying still needed the async clipboard API, so an HTTP host would not copy");
	}
	await tab.waitForFunction(() => {
		const field = document.getElementById("directoryLocator")?.closest<HTMLElement>(".copy-field");
		const said = field?.querySelector(".copy-said")?.textContent?.trim() ?? "";
		return said === "" && field?.dataset.copied === undefined;
	}, { timeout: 6_000 }).catch(() => fail("the copy control stayed said instead of going back to a button"));
	// A write that did not land answers above Settings, and the dismiss control
	// has to take a press while the dialog has the rest of the page inert.
	await tab.evaluate(() => {
		Reflect.set(window, "__roomsExecCommand", document.execCommand.bind(document));
		document.execCommand = () => false;
		Object.defineProperty(navigator.clipboard, "writeText", {
			configurable: true,
			value: () => Promise.reject(new Error("denied")),
		});
	});
	await tab.click("#directoryLocator");
	await tab.waitForFunction(() => {
		const toast = document.querySelector<HTMLElement>("dialog.modal[open] #toasts .toast");
		return toast?.dataset.kind === "failure";
	}, { timeout: 5_000 }).catch(() => fail("a refused copy did not answer above Settings"));
	await tab.click(".toast-dismiss");
	await tab.waitForFunction(() => document.querySelector("#toasts .toast") === null, { timeout: 5_000 })
		.catch(() => fail("dismissing the copy toast left it on screen"));
	await tab.evaluate(() => {
		const original = Reflect.get(window, "__roomsExecCommand");
		if (typeof original === "function") {
			document.execCommand = original as typeof document.execCommand;
		}
	});

	await tab.waitForSelector("#themeToggle");
	await tab.waitForSelector("#notifyToggle");
	await tab.waitForSelector("#helpBtn");
	if (await tab.locator("#helpTab").count() !== 0) {
		fail("Help is still a Settings tab");
	}
	const settingsPressed = await tab.evaluate(() =>
		document.getElementById("settingsBtn")?.getAttribute("aria-pressed")
	);
	if (settingsPressed !== "true") {
		fail("Settings is open but its topbar control is not pressed");
	}
	const helpIdle = await tab.evaluate(() => document.getElementById("helpBtn")?.getAttribute("aria-pressed"));
	if (helpIdle !== "false") {
		fail(`Help is idle but aria-pressed is ${JSON.stringify(helpIdle)}`);
	}
	await tab.click("#helpBtn");
	await tab.waitForSelector("#helpTitle");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
	await tab.waitForFunction(() => document.activeElement?.id === "helpClose")
		.catch(() => fail("Help did not give the keyboard to Close"));
	const helpPressed = await tab.evaluate(() => document.getElementById("helpBtn")?.getAttribute("aria-pressed"));
	if (helpPressed !== "true") {
		fail("Help is open but its control is not pressed");
	}
	const settingsStill = await tab.evaluate(() =>
		document.getElementById("settingsBtn")?.getAttribute("aria-pressed")
	);
	if (settingsStill !== "true") {
		fail("Help unpressed the Settings control, as if that session had ended");
	}
	if (await tab.locator("#helpTab").count() !== 0) {
		fail("Help grew a tab after opening");
	}
	// The word "secret" in the glossary is the quiet door into the parts
	// catalog. The glossary stays the surface; this is Help aimed at the
	// controls rather than the words, in the same dialog. Only the cursor
	// marks the door, so the proof also holds that it is a real press target.
	await tab.click("#glossarySecret");
	await tab.waitForSelector("#kitchenSink").catch(() =>
		fail("the glossary's secret door did not open the parts catalog")
	);
	const catalog = await tab.evaluate(() => {
		const sink = document.getElementById("kitchenSink");
		return {
			standing: sink?.querySelector(".rwhere-how") != null,
			said: sink?.querySelector(".said") != null,
			toast: sink?.querySelector(".toast") != null,
			crash: sink?.querySelector(".crash") != null,
			// The controls that carry a choice, all three of them. A control drawn
			// only where it is used is judged against the panel around it rather
			// than against its siblings, which is how one comes to have a look of
			// its own without anybody deciding it should.
			chosen: ["switch", "checkbox", "segmented"]
				.filter((control) => sink?.querySelector("." + control) == null),
		};
	});
	if (!catalog.standing || !catalog.said || !catalog.toast || !catalog.crash) {
		fail("the parts catalog is missing an answer treatment");
	}
	if (catalog.chosen.length > 0) {
		fail(`the parts catalog does not stand ${catalog.chosen.join(" and ")} beside the rest of the controls`);
	}
	// The segmented row is drawn nowhere else, so the catalog is the only place it
	// can be held to anything. What it owes a reader is that it says so. A gallery
	// is shopped from, and an entry that does not say whether anything uses it is
	// an invitation to adopt whatever state it happens to be in. It is finished
	// now, which changes what the entry has to say and not whether it has to say
	// something: a reader picking it up should know they will be the first.
	const parked = await tab.evaluate(() => {
		const track = document.getElementById("kitchenSegmentedWrap");
		const sample = track?.closest(".kitchen-sample");
		if (track === null || sample == null) return null;
		const cells = [...track.querySelectorAll(".segment")];
		return {
			cells: cells.length,
			// It stays on one line whatever it is given, because a row that breaks
			// onto a second is a short stack of buttons rather than a segmented
			// row, and staying on one line is the reason to reach for this at all.
			// Held here because the catalog is where the control is squeezed.
			lines: new Set(cells.map((cell) => Math.round(cell.getBoundingClientRect().top))).size,
			// And it does not push its way out of what holds it: it shrinks its
			// cells and cuts their words instead.
			overflows: Math.round(track.getBoundingClientRect().width) >
				Math.round((track.parentElement?.getBoundingClientRect().width ?? 0) + 1),
			said: (sample.textContent ?? "").toLowerCase(),
		};
	});
	if (parked === null) fail("the parts catalog does not stand the segmented row at the rail's own width");
	else if (parked.lines !== 1) {
		fail(`the segmented row broke onto ${parked.lines} lines, which is a stack of buttons and not this control`);
	} else if (parked.overflows) {
		fail(
			`the segmented row pushed out of what holds it rather than cutting its answers: ${JSON.stringify(parked)}`,
		);
	} else if (!parked.said.includes("draws one yet")) {
		fail("the catalog offers the segmented row without saying that nothing in the page uses one");
	}
	await tab.click("#kitchenBack");
	await tab.waitForFunction(() => document.getElementById("kitchenSink") === null)
		.catch(() => fail("the catalog's way back did not put the glossary up"));
	// The keyboard's way in: the door is a real button, so Tab reaches it and
	// Enter opens the same catalog the pointer's press does.
	await tab.locator("#glossarySecret").focus();
	await tab.keyboard.press("Enter");
	await tab.waitForSelector("#kitchenSink").catch(() =>
		fail("Enter on the focused secret door did not open the catalog")
	);
	await tab.click("#kitchenBack");
	await tab.waitForFunction(() => document.getElementById("kitchenSink") === null)
		.catch(() => fail("leaving the catalog again did not put the glossary back"));
	await tab.keyboard.press("Escape");
	await tab.waitForFunction(() => {
		const settings = document.getElementById("settingsTitle")?.closest("dialog");
		return settings?.matches(":modal") === true && document.activeElement?.id === "helpBtn";
	}).catch(() => fail("closing Help did not return focus to its opener in Settings"));
	await tab.waitForSelector("#helpTitle", { state: "hidden" });
	const helpAfter = await tab.evaluate(() => document.getElementById("helpBtn")?.getAttribute("aria-pressed"));
	if (helpAfter !== "false") {
		fail("closing Help left its control pressed");
	}
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

	// The chosen tab's own word, against the pill under it, in both appearances.
	// That pill is paper with better than a quarter of the accent poured into it,
	// and the ink named for paper sat at 3.71 to 1 on it, under the 4.5 small
	// text needs at this size and weight. Nothing in the stylesheet says so, and
	// the tab bar is only ever on screen with this dialog open, so it is measured
	// here or nowhere.
	{
		await tab.mouse.move(0, 0);
		await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
		const wasTheme = await tab.getAttribute("html", "data-theme");
		const tooFaint: string[] = [];
		for (const appearance of ["light", "dark"] as const) {
			await tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
			await tab.evaluate(() => Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))));
			const measured = await inkContrast(tab, '.tabs .tab[aria-selected="true"]');
			// A refusal is a failure of its own: the bar is on screen here, so
			// "could not measure" means the measuring broke, and a measurement
			// that quietly stops answering looks exactly like a pass.
			if (measured === null) tooFaint.push(`the chosen tab could not be measured in ${appearance}`);
			else if (measured.ratio < 4.5) {
				tooFaint.push(`the chosen tab is ${measured.ratio.toFixed(2)}:1 in ${appearance} (${measured.saw})`);
			}
		}
		await tab.evaluate((t) => {
			if (t === null) document.documentElement.removeAttribute("data-theme");
			else document.documentElement.setAttribute("data-theme", t);
		}, wasTheme);
		if (tooFaint.length > 0) {
			fail(`the chosen tab does not clear 4.5 to 1 for small text: ${tooFaint.join("; ")}`);
		}
	}
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

	await linked.run(tab);

	// Join a room as a real peer: the name goes into the card, and the room
	// into the rail's field, whose Enter submits the card — locator and name
	// included.
	await tab.fill("#nick", "web-alice");
	await tab.fill("#newRoomInput", "lobby");
	await tab.press("#newRoomInput", "Enter");

	// The composer's line input becomes usable once we are in the room.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	const sendHint = await tab.evaluate(() => {
		const line = document.getElementById("line");
		return line instanceof HTMLTextAreaElement ? line.enterKeyHint : "";
	});
	if (sendHint !== "send") {
		fail(`the composer does not offer a Send key (${JSON.stringify(sendHint)})`);
	}
	const joinHidden = await tab.evaluate(() => document.getElementById("joinScreen")?.hidden ?? false);
	if (!joinHidden) fail("the join card stayed in the tree as a visible screen after joining");

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

	// ── One directory draws the rail it always drew ──────────────────────
	// Everything about several directories — the line on a row saying which
	// directory it is on, the color it wears — arrives only when there is more
	// than one to tell apart. With one, a reader must get exactly what they got
	// before any of it existed, and this is the moment to say so: this tab holds
	// the directory that served the page and nothing else, and it will hold a
	// second one two scenes from now.
	//
	// Asserted as an exact inventory rather than as "nothing looks new", because
	// the ways to break this are all additive: a box around some of the rows, a
	// heading over them, a second field, a row naming the only directory there
	// is. Each of those draws a rail that reads fine and is not this one.
	const alone = await tab.evaluate(() => ({
		lists: {
			rooms: document.getElementById("roomList")?.tagName ?? "",
			dms: document.getElementById("dmList")?.tagName ?? "",
		},
		boxes: document.querySelectorAll("#roomList > :not(li), #dmList > :not(li)").length,
		named: document.querySelectorAll("#roomList .rwhere, #dmList .rwhere").length,
		// A row says how its directory is doing when there is something to say,
		// whether this tab holds one directory or several. Counted here because a
		// connected directory has nothing to say and this one is connected: the
		// line arrives with the news and goes with it, so a rail that carries one
		// now is a rail that would carry it for the life of the tab.
		standings: document.querySelectorAll("#roomList .rwhere-how, #dmList .rwhere-how").length,
		colored: document.querySelectorAll("#roomList li[data-dir], #dmList li[data-dir]").length,
		heads: document.querySelectorAll(".section-head").length,
		filters: document.querySelectorAll(".rail-filter").length,
		fields: document.querySelectorAll(".newroom").length,
		status: document.querySelectorAll("#status").length,
	}));
	const extra = [
		alone.lists.rooms !== "UL" && `the rooms list is a ${alone.lists.rooms} rather than the list it was`,
		alone.lists.dms !== "UL" && `the direct list is a ${alone.lists.dms} rather than the list it was`,
		alone.boxes !== 0 && `${alone.boxes} boxes stand between the rail's lists and their rows`,
		alone.named !== 0 && `${alone.named} rows name the only directory there is`,
		alone.standings !== 0 && `${alone.standings} rows report a standing for a directory that is connected`,
		alone.colored !== 0 && `${alone.colored} rows wear a directory's color with nothing to tell apart`,
		alone.heads !== 2 && `the rail has ${alone.heads} section headings rather than its two`,
		// The one piece of chrome the rail has gained since this inventory was
		// written, counted here deliberately rather than left out of it. One
		// control, on the rooms heading, because how much of the rail a reader
		// is looking at is one question and not one per list. Two would be the
		// scoping this control does not have, and none would mean a reader on
		// one directory had lost a way to narrow a long list of rooms.
		alone.filters !== 1 && `the rail holds ${alone.filters} filter controls rather than one for both lists`,
		alone.fields !== 2 && `the rail holds ${alone.fields} name fields rather than one per list`,
		alone.status !== 1 && `the rail's foot reports ${alone.status} states rather than one`,
	].filter((said) => said !== false);
	if (extra.length > 0) {
		fail(`one directory does not draw the rail it always drew: ${extra.join("; ")}`);
	}

	// The filter asks the same questions whatever this tab holds. A tab on one
	// directory is still asked which directory, for the same reason a tab in one
	// room is still asked for a name: a question with one answer today is a
	// question all the same, and a control that dropped it would change shape
	// under a reader as they joined things. What a reader gets from the answer
	// is a different matter and not this control's to decide for them.
	await tab.click("#railFilter");
	await tab.waitForSelector("#railFilterPanel", { timeout: 5_000 })
		.catch(() => fail("the rail's filter opened nothing while this tab held one directory"));
	const asked = await tab.evaluate(() =>
		[...document.querySelectorAll("#railFilterPanel .filter-ask")].map((ask) => ({
			label: ask.querySelector(".filter-label")?.textContent?.trim() ?? "",
			choices: ask.querySelectorAll(".filter-choice").length,
		}))
	);
	const directory = asked.find((ask) => ask.label === "Directory");
	if (asked.length !== railQuestions.length) {
		fail(
			`with one directory held the rail's filter asks ${JSON.stringify(asked.map((ask) => ask.label))} ` +
				`rather than ${JSON.stringify(railQuestions)}`,
		);
	} else if (directory === undefined || directory.choices !== 1) {
		fail(`with one directory held the filter offers ${JSON.stringify(directory)} to filter by`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#railFilterPanel", { state: "detached", timeout: 5_000 })
		.catch(() => fail("Escape did not put the rail's filter panel away"));

	// And now that this directory has granted a name, the same row answers the
	// question that name raises. It is a registration this directory can refuse,
	// and a refusal leaves this window in every roster looking ordinary while
	// nothing can arrive, so the healthy answer is worth pinning: a fact nobody
	// wired up reads exactly like one that is fine.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	// The dialog reopens on whichever panel was last selected, so name the
	// one holding the directory button.
	await tab.click("#overviewTab");
	await tab.click("#settingsAboutDir");
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("Settings did not open this directory's card after a name was granted"));
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
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });
	await tab.waitForSelector("#settingsTitle");
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
}
