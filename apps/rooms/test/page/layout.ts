// Multiple rooms retain independent delivery, history, drafts and membership.
import type { Page } from "playwright";
import { namedRoomRow } from "../support/conversation_row.ts";
import { fail } from "./harness.ts";
import { run as narrow } from "./layout/narrow.ts";

export async function run(
	tab: Page,
	second: Page,
	descendersIntact: (where: string) => Promise<void>,
): Promise<void> {
	await narrow(tab, descendersIntact);
	// ── Two rooms at once ────────────────────────────────────────────────
	// Entering a room does not give one up, so the rail's "+" puts a second
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

	// In this room alice is alone, and that is what tells the two `@` completions
	// apart. A mention reaches somebody present, so `@bar` here offers nobody,
	// bartholomew is reachable but not in annex. `/invite`'s target is somebody
	// to bring in, so its `@bar` offers exactly the reachable person the members
	// list leaves out. The bug this closes: /invite completed against the room,
	// so the one command whose argument is by definition not here could only
	// suggest the people who already were.
	await tab.waitForFunction(
		() => document.querySelector("#roomName")?.textContent === "annex",
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the tab did not settle in the annex room"));
	await tab.fill("#line", "@bar");
	await tab.waitForTimeout(150);
	const mentionOffers = await tab.evaluate(() =>
		[...document.querySelectorAll("#completePop [role=option]")].map((row) => row.textContent ?? "")
	);
	if (mentionOffers.some((row) => row.includes("bartholomew"))) {
		fail(`a plain mention offered somebody not in the room: ${JSON.stringify(mentionOffers)}`);
	}
	await tab.fill("#line", "/invite @bar");
	await tab.waitForFunction(
		() =>
			[...document.querySelectorAll("#completePop [role=option]")].some((row) =>
				(row.textContent ?? "").includes("bartholomew")
			),
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const offers = await tab.evaluate(() =>
			[...document.querySelectorAll("#completePop [role=option]")].map((row) => row.textContent ?? "")
		);
		fail(`/invite did not offer a reachable person who is not in the room: ${JSON.stringify(offers)}`);
	});
	await tab.fill("#line", "");

	// A name at the longest the field will take, because the middle of the range
	// is the one length a layout is never wrong about. The rail is a fixed narrow
	// column, so this is where truncation actually happens, and truncation that
	// keeps no copy of what it cut is a name a reader cannot read.
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
		.catch(async () =>
			fail(
				`the second room did not echo its own line back: ${await tab.locator("body")
					.innerText()}; draft=${await tab.locator("#line").inputValue()}`,
			)
		);

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

	// Every message carries a menu, and what is in it is the difference: copying
	// is about the words and belongs on anybody's line, while changing and taking
	// back are the reference this tab holds and belong only on its own.
	//
	// Asked here because this is the first moment both tabs hold lines from each
	// other: before the exchange above, each had only its own, and "none of
	// somebody else's offered to change it" was true because there were none to
	// ask. A check that passes for want of anything to look at is not a check,
	// and this one would say nothing twice.
	{
		// One line from each, so what each tab is asked about is a plain posted line
		// rather than whatever happened to be last: a message carrying files is
		// answered with nothing to hold, and a menu is right to offer less on it.
		const said = { first: "a line to ask the menu about", second: "and one from the other tab" };
		for (const [page, text] of [[tab, said.first], [second, said.second]] as const) {
			await page.fill("#line", text);
			await page.press("#line", "Enter");
		}
		for (const page of [tab, second]) {
			for (const text of [said.first, said.second]) {
				await page.waitForSelector(`.bubble:has-text("${text}")`, { timeout: 30_000 })
					.catch(() => fail(`a line the menu check is about never reached both tabs: ${text}`));
				// The optimistic gesture and its receipt settle independently of
				// the peer's echo. Measure one confirmed bubble's final geometry.
				await page.waitForFunction((text) => {
					const lines = [...document.querySelectorAll(".bubble")].filter((node) =>
						node.textContent?.includes(text)
					);
					return lines.length === 1 && !lines[0].matches(".sending, .failed, .unconfirmed");
				}, text).catch(() => fail(`the menu's line never settled to one confirmed bubble: ${text}`));
			}
		}

		// A speaker's identity and a message are siblings, not one shared pill.
		// Prove the layout rule with a synthetic row so the test can isolate one
		// short bubble without waiting for the grouping clock to start a new row.
		// The long identity includes the kind of origin label an IRC speaker wears;
		// it may widen its stack, but must never stretch the short message under it.
		const identityStretchedBubble = await tab.evaluate(() => {
			const row = document.createElement("div");
			row.className = "row them";
			const stack = document.createElement("div");
			stack.className = "stack";
			const who = document.createElement("div");
			who.className = "who";
			who.textContent = "a-very-long-network-display-name-with-an-origin-label IRC";
			const bubble = document.createElement("div");
			bubble.className = "bubble";
			bubble.textContent = "ok";
			stack.append(who, bubble);
			row.append(stack);
			document.querySelector("#log")?.append(row);
			const identityWidth = who.getBoundingClientRect().width;
			const bubbleWidth = bubble.getBoundingClientRect().width;
			row.remove();
			return { identityWidth, bubbleWidth };
		});
		if (identityStretchedBubble.bubbleWidth >= identityStretchedBubble.identityWidth - 20) {
			fail(
				`a ${identityStretchedBubble.identityWidth}px speaker identity stretched its short message to ` +
					`${identityStretchedBubble.bubbleWidth}px, instead of letting the bubble hug its own text`,
			);
		}

		// Reaching the mark with a pointer, the way a hand does it: across the space
		// between the bubble and the mark rather than teleported onto it. That space
		// hovered neither of them, so the mark a reader was reaching for went away
		// while they reached, and there was no way to open the menu with a mouse at
		// all. A click here would not have caught it, Playwright puts the pointer
		// straight onto what it clicks.
		{
			const bubble = tab.locator(`.bubble:has-text("${said.first}")`).last();
			await bubble.hover();
			const boxes = await tab.evaluate((text) => {
				const found = [...document.querySelectorAll(".bubble")]
					.find((candidate) => (candidate.textContent ?? "").includes(text));
				const mark = found?.querySelector(".line-acts");
				if (found == null || mark == null) return null;
				const b = found.getBoundingClientRect();
				const m = mark.getBoundingClientRect();
				return { bubbleLeft: b.left, markRight: m.right, y: Math.round(m.top + m.height / 2) };
			}, said.first);
			if (boxes === null) fail("a message drew no mark to open its menu");
			else {
				// Halfway across the space between them.
				await tab.mouse.move(Math.round((boxes.bubbleLeft + boxes.markRight) / 2), boxes.y);
				const stillThere = await tab.evaluate((text) => {
					const found = [...document.querySelectorAll(".bubble")]
						.find((candidate) => (candidate.textContent ?? "").includes(text));
					const mark = found?.querySelector(".line-acts");
					return mark === null || mark === undefined ? false : getComputedStyle(mark).display !== "none";
				}, said.first);
				if (!stillThere) fail("the mark that opens a message's menu vanishes on the way to it");

				// And it meets a pointer that never touches the message at all. The
				// mark is out in the margin, so that is where a hand aims, and
				// aiming there must hover something, though the only thing that
				// summons the mark is the message it sits beside.
				await tab.mouse.move(10, 10);
				await tab.mouse.move(Math.round(boxes.bubbleLeft - 20), boxes.y);
				const met = await tab.evaluate((text) => {
					const found = [...document.querySelectorAll(".bubble")]
						.find((candidate) => (candidate.textContent ?? "").includes(text));
					const mark = found?.querySelector(".line-acts");
					return mark == null ? false : getComputedStyle(mark).display !== "none";
				}, said.first);
				if (!met) {
					const current = await tab.evaluate(({ text, x, y }) => ({
						point: document.elementFromPoint(x, y)?.outerHTML,
						bubbles: [...document.querySelectorAll(".bubble")].filter((node) =>
							node.textContent?.includes(text)
						)
							.map((node) => ({ classes: node.className, box: node.getBoundingClientRect().toJSON() })),
					}), { text: said.first, x: Math.round(boxes.bubbleLeft - 20), y: boxes.y });
					fail(
						`coming at the mark from the margin, where it lives, reaches nothing: ${
							JSON.stringify({ boxes, current })
						}`,
					);
				}
			}
		}

		// An open menu stays over the mark it was opened from, with the pointer
		// nowhere near either. The menu is drawn in the top layer rather than
		// inside the bubble, so opening one takes the focus out of the bubble's
		// `:focus-within` and walking into it takes the pointer out of its
		// `:hover`. The strip went back to `display: none` under the reader, an
		// element with no box measures 0,0,0,0, and the observer that keeps the
		// menu over its mark believed that and put the menu in the corner of the
		// page.
		{
			const bubble = tab.locator(`.bubble:has-text("${said.first}")`).last();
			await bubble.hover();
			await bubble.getByLabel(/More for this message/).click();
			await tab.waitForSelector(".line-menu", { timeout: 10_000 })
				.catch(() => fail("a message menu would not open"));
			await tab.mouse.move(10, 10);
			const placed = await tab.evaluate(() => {
				const menu = document.querySelector(".line-menu");
				const mark = document.querySelector(".line-acts.open");
				if (menu == null || mark == null) return null;
				const m = menu.getBoundingClientRect();
				const a = mark.getBoundingClientRect();
				return {
					// The menu is wider than the strip it hangs from and pinned to one of
					// its edges, so it reaches past the mark on the far side; and it opens
					// upward when the line is low on the screen. What says it is still
					// placed against the mark is that the two share a column, and that
					// they are touching on one edge or the other.
					overlaps: m.right > a.left && m.left < a.right,
					gap: m.top >= a.bottom ? m.top - a.bottom : a.top >= m.bottom ? a.top - m.bottom : 0,
					shown: getComputedStyle(mark).display !== "none",
					where: `menu ${Math.round(m.left)},${Math.round(m.top)} mark ${Math.round(a.left)},${
						Math.round(a.top)
					}`,
				};
			});
			if (placed === null) fail("an open message menu lost the mark it was opened from");
			else {
				if (!placed.shown) fail("the mark that opens a message's menu goes away under its own open menu");
				if (!placed.overlaps || placed.gap > 40) {
					fail(`an open message menu left its mark when the pointer did: ${placed.where}`);
				}
			}
			await tab.keyboard.press("Escape");
			await tab.waitForSelector(".line-menu", { state: "detached", timeout: 10_000 })
				.catch(() => fail("a message menu would not close on Escape"));
		}

		const items = async (page: Page, text: string) => {
			const bubble = page.locator(`.bubble:has-text("${text}")`).last();
			await bubble.hover();
			await bubble.getByLabel(/More for this message/).click();
			const said = await page.locator(".line-menu [role=menuitem]").allTextContents();
			// A menu says it is one, and software that announces it tells its reader
			// to walk it with the arrows. Opening puts focus on the first item, so
			// one press down lands on the second.
			if (said.length > 1) {
				await page.keyboard.press("ArrowDown");
				const on = await page.evaluate(() => document.activeElement?.textContent?.trim() ?? "(nothing)");
				if (on !== said[1].trim()) {
					fail(
						`a menu that says it is one does not walk with the arrows: down landed on ${
							JSON.stringify(on)
						}`,
					);
				}
			}
			await page.keyboard.press("Escape");
			await page.waitForSelector(".line-menu", { state: "detached", timeout: 10_000 })
				.catch(() => fail("a message menu would not close on Escape"));
			return said.join("|");
		};
		for (const [who, page] of [["the first tab", tab], ["the second", second]] as const) {
			const counted = await page.evaluate(() => ({
				own: document.querySelectorAll(".row.mine .bubble").length,
				others: document.querySelectorAll(".row.them .bubble").length,
			}));
			if (counted.own === 0 || counted.others === 0) {
				fail(`${who} cannot answer the question: it holds ${JSON.stringify(counted)}`);
			}
			const own = page === tab ? said.first : said.second;
			const mine = await items(page, own);
			if (!mine.includes("Copy") || !mine.includes("Edit") || !mine.includes("Withdraw")) {
				fail(`${who} was not offered everything on a line of its own; the menu said ${JSON.stringify(mine)}`);
			}
			const theirs = await items(page, page === tab ? said.second : said.first);
			if (!theirs.includes("Copy")) {
				fail(`${who} could not copy somebody else's line; the menu said ${JSON.stringify(theirs)}`);
			}
			if (theirs.includes("Edit") || theirs.includes("Withdraw")) {
				fail(`${who} was offered to change somebody else's line; the menu said ${JSON.stringify(theirs)}`);
			}
		}
	}
	// Having just watched this same log paint an arriving line, its silence about
	// the other room's line means the two histories are separate.
	const bled = await tab.locator(`.bubble:has-text("${annexLine}")`).count();
	if (bled !== 0) fail("a line from the annex was drawn in the first room's log");
	await tab.waitForSelector('.bubble:has-text("hello from a browser peer")', { timeout: 10_000 })
		.catch(() => fail("the first room lost the history it had before the second room was entered"));

	// The badge and roster both describe current room membership. A departure
	// removes the member while their messages remain in the conversation.
	{
		// No click to get here: this tab is already reading the lobby, and pressing
		// the room you are already in is how a reader puts the rail away.
		const lobby = namedRoomRow(tab, "lobby");
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
		const theirs = namedRoomRow(second, "lobby");
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
		const summary = (await tab.textContent("#presenceSummary")) ?? "";
		if (summary.trim() !== "1 here" || await tab.locator('#members li:has-text("bartholomew")').count() !== 0) {
			fail(`the roster retained a departed member: ${JSON.stringify(summary)}`);
		}
	}

	// A half-written line belongs to the conversation it was written in.
	//
	// Two rooms are open, so switching between them is something a reader does
	// constantly, to check one thing before finishing a sentence in the other.
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
		.catch(async () =>
			fail(
				`leaving one of two rooms left the reader with nowhere to type; ${await tab.locator("body")
					.innerText()}`,
			)
		);

	// Every row carries its own way out and its own badge. Both are keyed on the
	// row rather than on a membership class, because every room listed here is one
	// you are in, so a class on membership means nothing and a selector built on
	// it matches nothing, as the leave mark and its hover swap show.
	const rowParts = await tab.evaluate(() => {
		const row = document.querySelector("#roomList li");
		if (row === null) return null;
		const leave = row.querySelector<HTMLElement>(".room-leave");
		const badge = row.querySelector<HTMLElement>(".rcount");
		return {
			leave: leave === null ? null : leave.getAttribute("aria-label"),
			// Existing is not the same as reachable. The mark is drawn at zero
			// opacity and revealed under the pointer, so the reveal rule matching
			// nothing leaves a control that is present, findable, and invisible,
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
}
