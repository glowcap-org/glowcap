// The first thing a reader sees, and what the page does before it can show it.
//
// A browser peer has to boot a wasm Host and dial through the relay before any
// of this is a room at all, so most of what is checked here is the waiting: what
// is on screen during it, what is never on screen, and what a page that cannot
// run says instead of nothing.

import type { Browser, Page } from "playwright";
import { fail, openDirectoryCardFromSettings } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { provePhoneSettingsTabs, proveSelectedTabContrast } from "./settings_tabs.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import * as linked from "./linked.ts";
import { establishTestSession } from "./session_establishment.ts";
import * as settingsForms from "./settings_forms.ts";

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
	await establishTestSession(tab);

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

	// A browser peer must arrive intact. Plain HTTP on another machine cannot
	// promise that, and its origin is not a secure context. Refuse before loading
	// the application bundle, with the development paths that preserve the
	// boundary instead of letting the first restricted API supply the diagnosis.
	{
		const plainHttp = await browser.newContext();
		const lan = await plainHttp.newPage();
		let bundleAsked = false;
		lan.on("request", (request) => {
			if (new URL(request.url()).pathname === "/page.js") bundleAsked = true;
		});
		const address = Deno.networkInterfaces().find((entry) =>
			entry.family === "IPv4" && !entry.address.startsWith("127.")
		)?.address;
		if (address === undefined) fail("the secure-origin proof found no non-loopback interface");
		await lan.goto(`http://${address}:${httpPort}/`);
		if (await lan.evaluate(() => isSecureContext)) {
			fail("the secure-origin proof reached a trustworthy context over network HTTP");
		}
		if (!await lan.locator(".boot-insecure").isVisible()) {
			fail("plain network HTTP did not explain the secure-origin requirement");
		}
		const explanation = (await lan.locator(".boot-insecure").textContent()) ?? "";
		if (!explanation.includes("localhost") || !explanation.includes("HTTPS")) {
			fail("the secure-origin refusal did not give either development path");
		}
		if (bundleAsked) fail("an insecure page loaded the Rooms peer bundle before refusing");
		await plainHttp.close();
	}

	// The Wasm peer can lose a race with the server building its asset. Hold
	// that asset down past the slow-start mark: the opening screen must carry
	// the newest real failure, keep the half-built interface covered, and then
	// recover by itself when the same URL starts serving the module. This also
	// proves that a rejected @pancake/web attempt is not cached forever.
	{
		const delayed = await browser.newContext();
		const recovering = await delayed.newPage();
		let rebuilding = true;
		let attempts = 0;
		await recovering.route("**/pancake_host.wasm", async (route) => {
			attempts++;
			if (rebuilding) {
				await route.fulfill({
					status: 503,
					contentType: "text/plain",
					body: "rooms: pancake_host.wasm is still building\n",
				});
				return;
			}
			await route.continue();
		});
		await recovering.goto(`http://127.0.0.1:${httpPort}/`);
		await recovering.waitForSelector(".boot-why", { state: "visible", timeout: 15_000 })
			.catch(() => fail("a slow Wasm runtime left the opening screen saying only that it was opening"));
		const why = (await recovering.locator(".boot-why").textContent())?.trim() ?? "";
		if (why === "") fail("the slow-runtime detail hid the failure it was retrying");
		if (await recovering.locator("#joinBtn").isVisible()) {
			fail("the join interface appeared before its Wasm runtime existed");
		}

		rebuilding = false;
		await recovering.waitForSelector("#sessionSetup", { timeout: 20_000 })
			.catch(() => fail("the page did not recover after its Wasm runtime became available"));
		await recovering.waitForSelector("#boot", { state: "detached", timeout: 60_000 })
			.catch(() => fail("the recovered runtime left the opening screen over the page"));
		await establishLocalSession(recovering);
		await recovering.waitForSelector("#joinBtn", { timeout: 20_000 });
		if (attempts < 2) fail("the page never retried the unavailable Wasm runtime");
		await delayed.close();
	}

	// The dialog opens on Session; Reachability owns locators and connection paths.
	// It has to be there before join, and a URL that names a transport still
	// wins over whatever this browser last saved. The opening screen has to
	// have left first: it covers the topbar until then.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.waitForFunction(() => {
		const layer = document.querySelector("dialog.modal");
		return layer?.matches(":modal") === true && document.activeElement?.id === "sessionTab";
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
	await tab.click("#reachabilityTab");
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
	await openDirectoryCardFromSettings(tab);
	const beforeAName = await dmFact();
	if (!beforeAName.includes("no name granted")) {
		fail(`before a name was granted, the card answered ${JSON.stringify(beforeAName)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });
	// The directory conversation is a detour: the rest of opening still uses the
	// join card, and later `linked` is that card and the rail as one form.
	await tab.click('a[aria-label="The front page"]');
	await tab.waitForFunction(() => location.pathname === "/", undefined, { timeout: 10_000 }).catch(() =>
		fail("leaving the directory conversation did not put the front page back")
	);
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#reachabilityTab");

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
	const compact = await tab.evaluate(() =>
		document.getElementById("directoryLocator")?.closest<HTMLElement>(".copy-field")?.dataset.compact !== undefined
	);
	if (!compact) fail("a copyable capability URI expanded instead of using the default truncated field");
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
			longWhy: sink?.querySelector("#kitchenLongWhy") != null,
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
	if (!catalog.standing || !catalog.said || !catalog.longWhy || !catalog.toast || !catalog.crash) {
		fail("the parts catalog is missing an answer treatment");
	}
	if (catalog.chosen.length > 0) {
		fail(`the parts catalog does not stand ${catalog.chosen.join(" and ")} beside the rest of the controls`);
	}
	const waits = await tab.evaluate(() => {
		const button = document.getElementById("kitchenBusyButton");
		const icon = document.getElementById("kitchenBusyIcon");
		if (button === null || icon === null) return null;
		const buttonMark = getComputedStyle(button, "::before");
		const iconMark = getComputedStyle(icon, "::after");
		return {
			button: button.dataset.busy === "true" && parseFloat(buttonMark.width) > 0,
			icon: icon.dataset.busy === "true" && parseFloat(iconMark.width) > 0,
			iconHidden: getComputedStyle(icon.querySelector("svg")!).visibility === "hidden",
		};
	});
	if (waits === null || !waits.button || !waits.icon || !waits.iconHidden) {
		fail(`a busy control did not replace its idle mark with visible progress: ${JSON.stringify(waits)}`);
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
	// Three tabs: Session, Holdings, Reachability. The arrows walk them and carry
	// focus with the selection; the ends clamp rather than wrap.
	await tab.click("#reachabilityTab");
	await tab.waitForSelector("#reachabilityPanel", { state: "attached" });
	await tab.keyboard.press("ArrowLeft");
	await tab.waitForSelector("#holdingsPanel", { state: "attached" });
	await tab.keyboard.press("ArrowLeft");
	await tab.waitForSelector("#sessionPanel", { state: "attached" });
	await tab.keyboard.press("ArrowLeft");
	await tab.waitForFunction(() =>
		document.activeElement?.id === "sessionTab" &&
		document.getElementById("sessionTab")?.getAttribute("tabindex") === "0" &&
		document.getElementById("reachabilityTab")?.getAttribute("tabindex") === "-1"
	).catch(() => fail("the Settings tabs did not move selection and focus together"));
	await tab.keyboard.press("ArrowRight");
	await tab.keyboard.press("ArrowRight");
	await tab.waitForSelector("#reachabilityPanel", { state: "attached" });
	const reachabilityForm = await tab.evaluate(() => {
		const form = document.getElementById("dmSettingsForm");
		const hint = document.getElementById("dmReloadHint");
		const save = document.getElementById("dmSave");
		return {
			ownsHint: hint?.closest("form") === form,
			ownsSave: save?.closest("form") === form,
			historyAbsent:
				document.getElementById("reachabilityPanel")?.contains(document.getElementById("historyLegend")) ===
					false,
		};
	});
	if (!reachabilityForm.ownsHint || !reachabilityForm.ownsSave || !reachabilityForm.historyAbsent) {
		fail(`the direct-message connection is not a self-contained form: ${JSON.stringify(reachabilityForm)}`);
	}
	// The chosen tab's own word, against the pill under it, in both appearances.
	// That pill is paper with better than a quarter of the accent poured into it,
	// and the ink named for paper sat at 3.71 to 1 on it, under the 4.5 small
	// text needs at this size and weight. Nothing in the stylesheet says so, and
	// the tab bar is only ever on screen with this dialog open, so it is measured
	// here or nowhere.
	await proveSelectedTabContrast(tab);
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
		await relayTab.setViewportSize({ width: 390, height: 720 });
		await relayTab.goto(`http://127.0.0.1:${httpPort}/?dm=relay`);
		await establishLocalSession(relayTab)
			.catch(() => fail("the ?dm=relay tab did not establish its local session"));
		await relayTab.click("#settingsBtn");
		await relayTab.waitForSelector("#settingsTitle");
		await provePhoneSettingsTabs(relayTab);
		await relayTab.click("#reachabilityTab");
		const relayDm = await relayTab.evaluate(() =>
			(document.querySelector('input[name="dm"]:checked') as HTMLInputElement | null)?.value ?? ""
		);
		if (relayDm !== "relay") {
			fail(`?dm=relay opened Settings on ${relayDm}, not relay`);
		}
		await relayTab.close();
	}
	await settingsForms.run(browser, httpPort);

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

	// And now that this directory has granted a name, the same row answers the
	// question that name raises. It is a registration this directory can refuse,
	// and a refusal leaves this window in every roster looking ordinary while
	// nothing can arrive, so the healthy answer is worth pinning: a fact nobody
	// wired up reads exactly like one that is fine.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	// The dialog reopens on whichever panel was last selected, so name the
	// one holding the directory button.
	await tab.click("#reachabilityTab");
	await openDirectoryCardFromSettings(tab);
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
	await namedRoomRow(tab, "lobby").locator(".room-open").click();
	await tab.waitForSelector("#line:not([disabled])").catch(() =>
		fail("returning from the directory did not put the room back")
	);
}
