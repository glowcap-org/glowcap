// Narrow screens keep navigation, hit targets and conversation text reachable.
import type { Page } from "playwright";
import { fail } from "../harness.ts";

export async function run(tab: Page, descendersIntact: (where: string) => Promise<void>): Promise<void> {
	// ── The narrow layout ────────────────────────────────────────────────
	// On a phone the rooms list covers most of the screen and leaves a peek of
	// the conversation; the members sheet still slides over. Each layer owes a
	// way back.
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
	const sheetCover = await tab.evaluate(() => {
		const box = document.querySelector("#cover")!.getBoundingClientRect();
		return { w: box.width, view: globalThis.innerWidth };
	});
	if (Math.abs(sheetCover.w - sheetCover.view) > 1) {
		fail("the members cover is not the whole page");
	}
	// Same contract as the wide roster: the heading and the names share one
	// region, and the sheet handle is chrome around it, not inside it.
	const sheetScroll = await tab.evaluate(() => {
		const scrolling = (el: Element | null) => {
			if (el == null) return false;
			const y = getComputedStyle(el).overflowY;
			return y === "auto" || y === "scroll";
		};
		const ancestor = (el: Element | null) => {
			for (let at = el?.parentElement ?? null; at != null; at = at.parentElement) {
				if (scrolling(at)) return at;
			}
			return null;
		};
		const pane = document.querySelector(".members");
		const body = document.querySelector(".members-body");
		const list = document.querySelector("#members");
		const head = pane?.querySelector("h2") ?? null;
		if (pane == null || body == null || list == null || head == null) return null;
		return {
			pane: scrolling(pane),
			body: scrolling(body),
			list: scrolling(list),
			shared: ancestor(list) === body && ancestor(head) === body,
		};
	});
	if (sheetScroll == null) fail("the roster sheet had no pane, body, heading, and list to compare");
	const sheetBroken = [
		sheetScroll.pane && "the sheet still scrolls around its body",
		!sheetScroll.body && "the region under the handle does not scroll",
		sheetScroll.list && "the member list still scrolls on its own",
		!sheetScroll.shared && "the heading and the names do not share that region",
	].filter((said) => said !== false);
	if (sheetBroken.length > 0) fail(`the roster sheet is not one scroller: ${sheetBroken.join("; ")}`);
	await tab.locator("#cover").click({ position: { x: 24, y: 24 } });
	await tab.waitForSelector(opened, { state: "detached", timeout: 5_000 })
		.catch(() => fail("tapping the cover did not close the roster sheet"));
	await tab.click("#membersToggle");
	await tab.waitForSelector(opened, { timeout: 5_000 })
		.catch(() => fail("the Members button did not reopen the roster sheet"));
	await tab.keyboard.press("Escape");
	await tab.waitForSelector(opened, { state: "detached", timeout: 5_000 })
		.catch(() => fail("Escape did not close the roster sheet"));

	// Back returns to the list, so a glance at what else is live does not cost
	// the conversation being read.
	await tab.click("#backBtn");
	await tab.waitForSelector(listed, { timeout: 5_000 })
		.catch(() => fail("the menu button did not open the rooms list"));
	await tab.waitForSelector("#cover", { state: "visible", timeout: 5_000 })
		.catch(() => fail("the rooms list leaves no peek of the conversation it covers"));
	await tab.waitForSelector("#railToggle", { state: "visible", timeout: 5_000 })
		.catch(() => fail("the rooms list offers no way back to the conversation it covers"));
	await tab.waitForFunction(() => {
		const chat = document.querySelector(".workarea")?.getBoundingClientRect();
		const strip = document.querySelector("#cover")?.getBoundingClientRect();
		const dim = getComputedStyle(document.querySelector(".workarea")!, "::after");
		return chat != null && strip != null && Math.abs(chat.left - strip.left) < 2 &&
			Number(dim.opacity) > 0.95;
	}, { timeout: 5_000 }).catch(() => fail("the conversation did not slide with the rooms list"));
	const peek = await tab.evaluate(() => {
		const strip = document.querySelector("#cover")!.getBoundingClientRect();
		const chat = document.querySelector(".workarea")!.getBoundingClientRect();
		const topbar = document.querySelector(".topbar")!;
		const after = getComputedStyle(document.querySelector(".workarea")!, "::after");
		return {
			stripW: strip.width,
			stripLeft: strip.left,
			stripRight: strip.right,
			viewW: globalThis.innerWidth,
			chatW: chat.width,
			chatH: chat.height,
			chatLeft: chat.left,
			dimW: parseFloat(after.width),
			dimH: parseFloat(after.height),
			dimOpacity: after.opacity,
			dimZ: Number(after.zIndex),
			topZ: Number(getComputedStyle(topbar).zIndex),
			markShown: document.querySelector("#backBtn")!.checkVisibility({
				visibilityProperty: true,
			}),
			inert: document.querySelector(".workarea")!.hasAttribute("inert"),
			hidden: document.querySelector("#cover")?.getAttribute("aria-hidden"),
		};
	});
	if (Math.abs(peek.chatW - peek.viewW) > 1) {
		fail(`the peeked conversation is ${peek.chatW}px wide, not the viewport`);
	}
	if (Math.abs(peek.chatLeft - peek.stripLeft) > 2) {
		fail("the peek is not the left of the conversation, next to the rail");
	}
	if (Math.abs(peek.dimW - peek.chatW) > 2) {
		fail("the rooms-list dimmer is a peek strip, not the sliding conversation");
	}
	if (Math.abs(peek.stripRight - peek.viewW) > 1) {
		fail("the peek strip is not on the right edge of the screen");
	}
	if (peek.stripW < 40) {
		fail(`the peek strip is only ${peek.stripW}px, too narrow to tap`);
	}
	if (peek.markShown) {
		fail("the rooms mark in the peeked conversation is still showing");
	}
	if (!(peek.dimZ > peek.topZ)) {
		fail("the rooms-list dimmer sits under the conversation title");
	}
	if (Math.abs(peek.dimH - peek.chatH) > 2) {
		fail("the rooms-list dimmer does not cover the conversation title");
	}
	if (!peek.inert) fail("the peeked conversation is still in the tab order");
	if (Number(peek.dimOpacity) < 0.95) {
		fail("the rooms-list dimmer is not on the sliding conversation");
	}
	if (peek.hidden !== "true") {
		fail("the peek strip is a named control; it should be a tap target");
	}
	await tab.click("#cover");
	await tab.waitForSelector(listed, { state: "detached", timeout: 5_000 })
		.catch(() => fail("tapping the peek did not leave the rooms list"));
	await tab.click("#backBtn");
	await tab.waitForSelector(listed, { timeout: 5_000 })
		.catch(() => fail("the menu button did not open the rooms list a second time"));
	await tab.click("#railToggle");
	await tab.waitForSelector(listed, { state: "detached", timeout: 5_000 })
		.catch(() => fail("the rooms list could not be left from its own header"));
}
