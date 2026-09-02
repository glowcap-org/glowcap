// The chrome both rails share, and the mark that travels between them.
//
// Called from the file proof after posting, because that is when both rails
// are on screen with a room and a roster, and none of these questions are
// about the files themselves. Settings lives in the rail title while the list
// is up and on the conversation bar when it is away; the glowcap mark is the
// same control in both homes.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function runChrome(
	tab: Page,
): Promise<(where: string) => Promise<void>> {
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
	//
	// Where a heading begins is where its own ink begins, whatever that ink is.
	// The rooms heading is also what opens the rail's questions, so it carries a
	// funnel in front of its words and is built like a row below it: the mark on
	// the line both rails start on, and the words a mark's width in. Reading the
	// words alone would call that a rail out of true by exactly the width of a
	// mark, which is the one thing it is not, so what is measured is the whole
	// heading's contents. The rooms heading answers to its own id while it is a
	// control, and the second half of the pair is what an ordinary label is.
	const rails = await tab.evaluate(() => {
		// Where a heading's ink begins, measured from the inside of its rail.
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
				inset(sidebar, document.querySelector("#railFilter, .section-head span")!),
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

	// The left rail is one column from under the title to above the status line.
	// Rooms and direct messages used to scroll in their own boxes, so a long
	// list of one buried the heading of the other. Both lists share the body
	// under `.workspace`, and neither list is a scroller of its own.
	const railScroll = await tab.evaluate(() => {
		const scrolling = (el: Element) => {
			const y = getComputedStyle(el).overflowY;
			return y === "auto" || y === "scroll";
		};
		const ancestor = (el: Element | null) => {
			for (let at = el?.parentElement ?? null; at != null; at = at.parentElement) {
				if (scrolling(at)) return at;
			}
			return null;
		};
		const body = document.querySelector(".sidebar-body");
		const rooms = document.querySelector("#roomList");
		const dms = document.querySelector("#dmList");
		const title = document.querySelector(".workspace");
		const foot = document.querySelector(".sidebar-foot");
		const roster = document.querySelector(".members");
		const rosterBody = document.querySelector(".members-body");
		const rosterList = document.querySelector("#members");
		const rosterHead = roster?.querySelector("h2") ?? null;
		if (body == null || rooms == null || dms == null || title == null || foot == null) return null;
		if (roster == null || rosterBody == null || rosterList == null || rosterHead == null) return null;
		const box = body.getBoundingClientRect();
		return {
			body: scrolling(body),
			rooms: scrolling(rooms),
			dms: scrolling(dms),
			shared: ancestor(rooms) === body && ancestor(dms) === body,
			belowTitle: box.top >= title.getBoundingClientRect().bottom - 1,
			aboveFoot: box.bottom <= foot.getBoundingClientRect().top + 1,
			rosterPane: scrolling(roster),
			roster: scrolling(rosterBody),
			rosterList: scrolling(rosterList),
			rosterShared: ancestor(rosterList) === rosterBody && ancestor(rosterHead) === rosterBody,
		};
	});
	if (railScroll == null) fail("the rails had no title, body, lists, roster, and status line to compare");
	const broken = [
		!railScroll.body && "the region under the title does not scroll",
		railScroll.rooms && "the rooms list still scrolls on its own",
		railScroll.dms && "the direct-message list still scrolls on its own",
		!railScroll.shared && "the two lists do not share the region under the title",
		!railScroll.belowTitle && "that region starts above the title rather than under it",
		!railScroll.aboveFoot && "that region runs into the status line rather than stopping above it",
	].filter((said) => said !== false);
	if (broken.length > 0) fail(`the left rail is not one scroller: ${broken.join("; ")}`);
	// The roster is the same kind of region with no title or foot of its own, so
	// `.members-body` is the scroller. The heading used to stay pinned while
	// the names moved in a box of their own, which is the nested scroller the
	// rooms list used to be. The pane around it is chrome, not a second
	// scroller — on a phone that chrome is the sheet handle.
	const rosterBroken = [
		railScroll.rosterPane && "the pane still scrolls around its body",
		!railScroll.roster && "the roster body does not scroll",
		railScroll.rosterList && "the member list still scrolls on its own",
		!railScroll.rosterShared && "the heading and the names do not share that region",
	].filter((said) => said !== false);
	if (rosterBroken.length > 0) fail(`the roster is not one scroller: ${rosterBroken.join("; ")}`);

	// And they draw the same row. Two rails flank the conversation and a reader
	// sees both at once, so a name in one that starts a few pixels off a name in
	// the other reads as one of the two having been nudged, without saying which.
	//
	// The two also begin together, measured on the regions rather than on the
	// first thing in each. The rooms rail opens with the line that says how much
	// of it you are looking at, and the roster opens with its heading, so the
	// promise is that the two rails start on one line and not that they start
	// with the same kind of thing. Their list labels are still set alike, which
	// is the other half of reading as one surface.
	//
	// Row heights are deliberately not compared: a roster row carries its
	// direct-line button in a column of its own, always showing rather than
	// revealed, so it stands taller than a rail row by that decision rather than
	// by an oversight.
	const alike = await tab.evaluate(() => {
		const railRow = document.querySelector("#roomList .room-open");
		const railName = document.querySelector("#roomList .rname");
		const rosterRow = document.querySelector("#members li");
		const rosterName = document.querySelector("#members .name");
		const rosterChip = document.querySelector("#members .avatar-presence");
		const railHead = document.querySelector(".section-head span");
		const rosterHead = document.querySelector(".members h2");
		const railBody = document.querySelector(".sidebar-body");
		const roster = document.querySelector(".members");
		if (!railRow || !railName || !rosterRow || !rosterName || !rosterChip || !railHead || !rosterHead) return null;
		if (!railBody || !roster) return null;
		const drawn = (el: Element) => {
			const s = getComputedStyle(el);
			return [s.fontSize, s.fontWeight, s.letterSpacing, s.textTransform].join(" ");
		};
		return {
			// The roster row is a person lockup — a chip spanning its two lines
			// of text — so its name column is set by the chip, not by the other
			// rail's mark column. What is held instead is the lockup's own air:
			// the name starts a hand's width after the chip, every row.
			lockupAir: rosterName.getBoundingClientRect().left - rosterChip.getBoundingClientRect().right,
			// The two regions, not the first thing in each, and it is worth saying
			// what a zero here means. These two are not placed by one grid that
			// would hold them level whatever they contained: the roster starts
			// under the conversation's topbar and the rooms rail starts under a
			// header of its own, so this reading is what keeps those two headers
			// coming to the same height. Both halves were moved to check that it
			// can say so. A top margin on this region, and then the rail's own
			// header grown six pixels, each read back the six they were given.
			bodyTop: Math.abs(railBody.getBoundingClientRect().top - roster.getBoundingClientRect().top),
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
			(alike.lockupAir < 5 || alike.lockupAir > 14) &&
			`the roster lockup's air is off: ${alike.lockupAir.toFixed(1)}px between the chip and the name`,
			alike.bodyTop > 1 && `their contents start ${alike.bodyTop.toFixed(1)}px apart rather than on one line`,
			alike.headDrawn[0] !== alike.headDrawn[1] &&
			`their headings are drawn differently: ${alike.headDrawn.join(" against ")}`,
		].filter((said) => said !== false);
		if (apart.length > 0) fail(`the two rails do not draw one row: ${apart.join("; ")}`);
	}

	// Drawing alike is only half of it: the same treatment has to keep meaning the
	// same thing. A wash under the pointer means "this row opens", and in both
	// rails it now does — a room row opens the room, a roster row opens what is
	// known about that member, which `member_card.ts` presses. So both light, and
	// both are asked, because "nothing lights up" is also what a broken selector
	// looks like.
	//
	// This asked the opposite while a roster row had nothing to press. It kept
	// passing through the change that gave it one, because the wash went on the
	// button and this reads the row around it — a proof still agreeing with a
	// design it had stopped describing. The row is the button now, so there is
	// no longer a gap between them for that to hide in.
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
	for (const [row, what] of [["#roomList li", "a room row"], ["#members li", "a roster row"]] as const) {
		if (!await lights(row)) {
			fail(`${what} does not answer the pointer, so nothing says which row a press would open`);
		}
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

	// The rail title sits in the gap between the glowcap mark and Settings.
	// Mixed type on one line shares a baseline: centering the two boxes was
	// what parked ROOMS high, because the smaller caps sit in the top of their
	// em while glowcap's descender sits in the bottom of its. Measured on the
	// feet of letters that have none.
	const title = await tab.evaluate(() => {
		const glyphs = (el: Element, from?: number, to?: number) => {
			const range = document.createRange();
			const node = el.firstChild;
			if (from == null || to == null || node == null) range.selectNodeContents(el);
			else range.setStart(node, from), range.setEnd(node, to);
			return range.getBoundingClientRect();
		};
		const name = document.querySelector(".workspace .wordmark span");
		const rooms = document.querySelector(".workspace .wordmark small");
		const mark = document.querySelector("#railToggle");
		const gear = document.querySelector("#settingsBtn");
		if (name == null || rooms == null || mark == null || gear == null) return null;
		if (gear.closest(".workspace") == null) return { home: "topbar" as const };
		const a = glyphs(name), b = glyphs(rooms);
		const ink = {
			left: Math.min(a.left, b.left),
			right: Math.max(a.right, b.right),
			top: Math.min(a.top, b.top),
			bottom: Math.max(a.bottom, b.bottom),
		};
		const markBox = mark.getBoundingClientRect();
		const gearBox = gear.getBoundingClientRect();
		return {
			home: "rail" as const,
			nameEye: glyphs(name, 6, 7),
			roomsEye: glyphs(rooms, 4, 5),
			inkMidX: (ink.left + ink.right) / 2,
			inkMidY: (ink.top + ink.bottom) / 2,
			gapMidX: (markBox.right + gearBox.left) / 2,
			btnMidY: (markBox.top + markBox.bottom) / 2,
		};
	});
	if (title == null) fail("the rail title is not glowcap plus rooms");
	if (title.home !== "rail") fail("Settings is not in the rail's title bar");
	// The lockup is baseline-true: ROOMS shares glowcap's baseline, feet
	// level within a pixel. Owner-tuned; every lifted variant read as
	// floating, and the metrics are the fixed pixels of the .wordmark
	// logotype contract in mark.css.
	if (Math.abs(title.nameEye.bottom - title.roomsEye.bottom) > 1) {
		fail(
			`ROOMS does not sit on glowcap's baseline: glowcap foot ${title.nameEye.bottom.toFixed(1)} vs rooms ${
				title.roomsEye.bottom.toFixed(1)
			}`,
		);
	}
	if (Math.abs(title.inkMidX - title.gapMidX) > 1) {
		fail(
			`the rail title is not centred between the mark and Settings: ink ${title.inkMidX.toFixed(1)} vs gap ${
				title.gapMidX.toFixed(1)
			}`,
		);
	}
	if (Math.abs(title.inkMidY - title.btnMidY) > 1) {
		fail(
			`the rail title is not vertically centred with its buttons: ink ${title.inkMidY.toFixed(1)} vs buttons ${
				title.btnMidY.toFixed(1)
			}`,
		);
	}

	const railHeld = await markBox("#railToggle");
	await tab.click("#railToggle");
	await tab.waitForSelector("#backBtn", { state: "visible", timeout: 5_000 })
		.catch(() => fail("collapsing the rail beside the conversation left no way back"));
	sameMark("beside the conversation", railHeld, await markBox("#backBtn"));
	const trailing = await tab.evaluate(() => {
		const gear = document.querySelector("#settingsBtn");
		const standing = document.querySelector("#roomStanding");
		const members = document.querySelector("#membersToggle");
		if (gear == null || standing == null || members == null || gear.closest(".topbar") == null) {
			return null;
		}
		const a = gear.getBoundingClientRect();
		const b = standing.getBoundingClientRect();
		const c = members.getBoundingClientRect();
		return { settings: a.left, standing: b.left, members: c.left };
	});
	if (
		trailing == null || !(trailing.settings < trailing.standing && trailing.standing < trailing.members)
	) {
		fail("Settings did not sit to the left of standing once the rail was away");
	}
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
				// The mark is its four animated pieces; each paints currentColor,
				// so the brand check reads a piece's fill.
				rail: getComputedStyle(document.querySelector("#railToggle .mark-piece")!).backgroundColor,
				bar: getComputedStyle(document.querySelector("#backBtn .mark-piece")!).backgroundColor,
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
	return descendersIntact;
}
