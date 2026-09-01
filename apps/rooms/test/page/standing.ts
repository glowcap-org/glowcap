// Where a reader stands, what this tab holds, and a rail under a finger.
//
// Standing has three levels that fall through to each other, so what is checked
// is that setting one moves exactly the rooms taking their answer from it.

import type { Browser, Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { fail, fillSettled, reachDirectoryOnCard } from "./harness.ts";
import { namedDirectRow } from "../support/conversation_row.ts";

export async function run(
	tab: Page,
	foreignLocator: string,
	httpPort: number,
	browser: Browser,
	second: Page,
): Promise<void> {
	// ── Where you are ────────────────────────────────────────────────────
	// One word said at three levels, each falling through to the next: the
	// reader, a directory, a room. The part worth proving is the falling
	// through, which a page with one level could fake — so this sets the
	// outermost, watches a room that has no word of its own take it, gives that
	// room its own word, and watches the outermost stop reaching it.
	{
		await tab.setViewportSize({ width: 1280, height: 800 });
		// The foot is one lockup now: the reader's name over a state row, and the
		// whole thing is the trigger. With the connection settled and nothing
		// said, the state row rests on "here".
		const said = () => tab.locator("#standingBtn #status").textContent();
		const here = await said();
		if (here !== "here") fail(`the foot of the rail says "${here}" before anyone has stepped anywhere`);

		// Said once, everywhere. The room hears it, which is the only reason the
		// roster can show it: what a member's row says is the room's word about
		// them, not this tab's intention.
		await tab.click("#standingBtn");
		const identity = ((await tab.getAttribute("#standingBtn", "aria-label")) ?? "").split(" — where")[0];
		// Every row the menu holds, compared whole rather than filtered: one
		// reading of the reader first, then exactly one release per live grant.
		// Whole, because a filter would let a junk row in beside the ones it
		// keeps, and the count of releases is half of what this proves.
		const menuRows = (await tab.locator(".standing-actions [role=menuitem]").allTextContents())
			.map((row) => row.trim());
		const expectedRows = ["About you…"].concat(
			identity === "" ? [] : identity.split(", ").map((grant) => `Release ${grant}`),
		);
		if (JSON.stringify(menuRows) !== JSON.stringify(expectedRows)) {
			fail(
				`the identity menu does not match its live directory grants: ` +
					JSON.stringify({ identity, menuRows, expectedRows }),
			);
		}
		// Typed a character at a time, not filled: a menu holding a field
		// re-renders on every keystroke, and a row that takes the keyboard as the
		// menu opens will take it again on each of those renders unless it is
		// asked once. Filling the field is one event and never sees it.
		await tab.click(".standing-why input");
		await tab.type(".standing-why input", "back in ten", { delay: 10 });
		const typing = await tab.evaluate(() => ({
			focused: document.activeElement?.closest(".standing-why") !== null,
			value: (document.querySelector(".standing-why input") as HTMLInputElement | null)?.value ?? "",
		}));
		if (!typing.focused || typing.value !== "back in ten") {
			fail(
				`the reason field does not keep the keyboard while a reason is typed into it: ${
					JSON.stringify(typing)
				}`,
			);
		}
		await tab.press(".standing-why input", "Enter");
		await tab.waitForFunction(
			() => (document.querySelector("#members")?.textContent ?? "").includes("back in ten"),
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("saying where you are everywhere never reached the room you are in"));

		// The room is following, and says which level is answering for it rather
		// than showing an answer of its own.
		await tab.click("#roomStanding");
		const follows = await tab.evaluate(() => {
			const rows = [...document.querySelectorAll(".standing-menu [role=menuitemradio]")];
			const ticked = rows.find((row) => row.getAttribute("aria-checked") === "true");
			return { rows: rows.map((row) => row.textContent?.trim()), ticked: ticked?.textContent?.trim() ?? null };
		});
		if (follows.ticked === null || !follows.ticked.startsWith("Follow")) {
			fail(`a room with no word of its own does not say it is following one: ${JSON.stringify(follows)}`);
		}

		// The arrows walk it, and walking means moving: a row already has the
		// keyboard when the menu opens, so asking only where focus ended up is a
		// question that answers itself. A menu that chooses between states
		// carries a different row role from one that performs actions, and that
		// is the half a menu of actions cannot prove.
		const focused = () =>
			tab.evaluate(() => {
				const at = document.activeElement;
				return {
					said: at?.textContent?.trim() ?? null,
					role: at?.getAttribute("role") ?? null,
					inMenu: at?.closest(".standing-menu") !== null,
				};
			});
		const before = await focused();
		await tab.keyboard.press("ArrowDown");
		const after = await focused();
		if (!after.inMenu || after.role !== "menuitemradio" || after.said === before.said) {
			fail(
				`the arrows do not walk a menu that chooses between states: ` +
					`${JSON.stringify(before)} then ${JSON.stringify(after)}`,
			);
		}

		// Give this room its own word. The reader is still away everywhere else,
		// which is the whole point of there being more than one level.
		const rows = tab.locator(".standing-menu [role=menuitemradio]");
		await rows.filter({ hasText: "Here" }).first().click();
		await tab.waitForFunction(
			() => {
				const roster = document.querySelector("#members")?.textContent ?? "";
				const foot = document.querySelector("#standingBtn #status")?.textContent ?? "";
				return !roster.includes("back in ten") && foot === "back in ten";
			},
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const state = await tab.evaluate(() => ({
				roster: document.querySelector("#members")?.textContent?.slice(0, 80) ?? "",
				foot: document.querySelector("#standingBtn #status")?.textContent ?? "",
			}));
			fail(`a room given its own word did not keep it apart from the reader's: ${JSON.stringify(state)}`);
		});

		// And `/away` writes where the answer is already coming from: this room has
		// its own now, so the command moves that and leaves the reader's alone.
		await tab.fill("#line", "/away");
		await tab.press("#line", "Enter");
		await tab.waitForFunction(
			() => {
				const roster = document.querySelector("#members")?.textContent ?? "";
				const foot = document.querySelector("#standingBtn #status")?.textContent ?? "";
				return roster.includes("away") && foot === "back in ten";
			},
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const state = await tab.evaluate(() => ({
				roster: document.querySelector("#members")?.textContent?.slice(0, 80) ?? "",
				foot: document.querySelector("#standingBtn #status")?.textContent ?? "",
			}));
			fail(`/away did not write where this room's answer comes from: ${JSON.stringify(state)}`);
		});

		// Everything back where it was, so what follows reads a page nobody has
		// stepped out of.
		await tab.click("#roomStanding");
		await tab.locator(".standing-menu [role=menuitemradio]").filter({ hasText: "Follow" }).first().click();
		await tab.click("#standingBtn");
		await tab.locator(".standing-menu [role=menuitemradio]").filter({ hasText: "Here" }).first().click();
		await tab.waitForFunction(
			() => (document.querySelector("#members")?.textContent ?? "").includes("away") === false,
			undefined,
			{ timeout: 30_000 },
		).catch(() => fail("coming back everywhere did not reach the room"));
	}

	// ── Asking about the places this tab holds ───────────────────────────
	// Two directories are open by now, which is what makes these worth asking:
	// one lists the rooms on whichever directory is named, and the other says
	// what this tab is holding at all — including the locator, which the page
	// had nowhere a reader could read.
	{
		// Asked from a room on the page's own directory, because a bare /list is
		// about the directory the reader is in and the section above left them
		// somewhere else.
		await tab.locator('#roomList li:has-text("lobby") .room-open').first().click();
		await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
		// Waited for in the whole log rather than read off the last line: a room
		// with people in it is saying things of its own, and the newest line when
		// an answer arrives is not always the answer.
		const answered = async (typed: string, wants: readonly string[], what: string): Promise<void> => {
			await tab.fill("#line", typed);
			await tab.press("#line", "Enter");
			await tab.waitForFunction(
				(texts) =>
					[...document.querySelectorAll("#log .sys")].some((line) =>
						texts.every((text) => (line.textContent ?? "").includes(text))
					),
				wants,
				{ timeout: 30_000 },
			).catch(async () => {
				const log = (await tab.textContent("#log").catch(() => "?")) ?? "?";
				fail(`${what}; ${typed} left the log saying ${JSON.stringify(log.slice(-200))}`);
			});
		};

		await answered("/list", ["#lobby: "], "/list did not name the room this tab is in");
		await answered(
			`/list ${foreignLocator}`,
			["#elsewhere: "],
			"/list did not answer about the directory it was pointed at",
		);
		await answered(
			"/list nowhere-at-all",
			["No directory here"],
			"/list on a name nothing matches did not say so",
		);
		// One line naming a directory and how to reach it: the address is what a
		// reader would pass to somebody else, and the reason this command exists.
		// Both facts on one line, so neither can be satisfied by something else the
		// room happened to say.
		await answered(
			"/directories",
			["room advertised", foreignLocator],
			"/directories did not say how to reach the directory typed in",
		);
		await answered(
			"/directories",
			["room advertised", "this directory"],
			"/directories did not name the page's own directory",
		);
	}

	// ── A rail under a finger ────────────────────────────────────────────
	// Where there is no pointer, the count and the leave mark are both simply
	// there: nothing reveals under a finger, so neither borrows the other's slot
	// the way they do on the pointer side. That layout has a shape of its own and
	// nothing else here exercises it — resizing the window does not make a
	// browser coarse-pointed, so every check above ran against the hover layout.
	{
		const touch = await browser.newContext({
			viewport: { width: 390, height: 844 },
			hasTouch: true,
			isMobile: true,
		});
		try {
			const finger = await touch.newPage();
			await finger.goto(`http://127.0.0.1:${httpPort}/`);
			await establishLocalSession(finger);
			await finger.fill("#nick", "touchy");
			await finger.fill("#room", "lobby");
			await finger.click("#joinBtn");
			await finger.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
			await finger.click("#backBtn");
			await finger.waitForSelector("#roomList li", { timeout: 10_000 })
				.catch(() => fail("the rooms list never opened under a finger"));
			const row = await finger.evaluate(() => {
				const li = document.querySelector("#roomList li");
				const count = li?.querySelector(".rcount");
				const leave = li?.querySelector(".room-leave");
				if (li == null || count == null || leave == null) return null;
				const between = leave.getBoundingClientRect().left - count.getBoundingClientRect().right;
				return {
					between: Math.round(between),
					countShown: getComputedStyle(count).opacity,
					leaveShown: getComputedStyle(leave).opacity,
					width: Math.round(li.getBoundingClientRect().width),
				};
			});
			if (row === null) fail("a room row under a finger draws no count or no way to leave");
			// Both out at once is the whole point of this layout.
			else if (row.countShown !== "1" || row.leaveShown !== "1") {
				fail(`a room row under a finger hides one of its marks: ${JSON.stringify(row)}`);
			} // Held open to the width of a mark, the count floated in nine pixels of
			// slack with the mark a further gap beyond it, and a 390-wide screen
			// spent a quarter of the row on two small things.
			else if (row.between > 12) {
				fail(`the count and the way out sit ${row.between}px apart under a finger: ${JSON.stringify(row)}`);
			}

			// And the line under a name runs the whole row, under the mark that
			// leaves it as well as under the name. On the pointer side that mark
			// borrows the count's slot inside the room's own button, so a caption
			// held to the first column already ends where the row's content ends.
			// Here the mark has a column of its own beside that one, and a caption
			// left in the first column stops a mark's width short of the line it
			// belongs to. It reads as the row having been nudged, and only a
			// coarse-pointed browser draws it, so nothing on the pointer side can
			// see it.
			//
			// A caption needs a directory worth naming, which needs a second one to
			// tell it from, so the tab reaches one: a room named in the rail, then
			// sent to the other server from the panel's own destination line.
			await finger.click("#newRoomBtn");
			await finger.fill("#newRoomInput", "faraway");
			await finger.focus("#newRoomElsewhere");
			await finger.press("#newRoomElsewhere", "Enter");
			await finger.waitForSelector("#joinForm", { timeout: 10_000 })
				.catch(() => fail("the rail under a finger offered no way to reach another directory"));
			await fillSettled(finger, "#locator", foreignLocator);
			await reachDirectoryOnCard(finger);
			await finger.click("#joinBtn");
			await finger.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
				.catch(() => fail("the tab under a finger could not reach a room on the second directory"));
			await finger.click("#backBtn");
			await finger.waitForSelector("#roomList li .rwhere", { timeout: 20_000 })
				.catch(() => fail("holding two directories under a finger put no directory line on a room row"));
			const caption = await finger.evaluate(() => {
				const li = document.querySelector("#roomList li:has(.rwhere)");
				const line = li?.querySelector(".rwhere");
				const open = li?.querySelector(".room-open");
				const leave = li?.querySelector(".room-leave");
				if (li == null || line == null || open == null || leave == null) return null;
				const c = line.getBoundingClientRect();
				const o = open.getBoundingClientRect();
				const m = leave.getBoundingClientRect();
				return {
					// The two facts, each on its own: the mark stands beside the
					// room's button rather than inside it, and the line under them
					// runs past that button's edge to where the mark ends.
					markIsBesideTheButton: Math.round(m.left - o.right),
					endsWhereTheMarkEnds: Math.abs(c.right - m.right),
					stopsAtTheButton: Math.abs(c.right - o.right),
				};
			});
			if (caption === null) fail("no room row under a finger carried a directory line beside a way to leave");
			else if (caption.markIsBesideTheButton < 0) {
				fail(`the way out is inside the room's own button under a finger: ${JSON.stringify(caption)}`);
			} else if (caption.endsWhereTheMarkEnds > 1) {
				fail(
					`a row's directory line stops ${caption.endsWhereTheMarkEnds.toFixed(1)}px short of the mark ` +
						`that leaves the room, so it is pinned into the name's column: ${JSON.stringify(caption)}`,
				);
			} else if (caption.stopsAtTheButton <= 1) {
				fail(
					"a row's directory line ends where the room's button ends, so it never reached the mark beside it",
				);
			}
		} finally {
			await touch.close();
		}
	}

	// ── A person, not just a socket ──────────────────────────────────────
	// A direct line is to a person, and the rooms already say where that person
	// stands: away is a word they said to a room both tabs share, so the direct
	// row and the conversation's own header can relay it. Proven here rather
	// than assumed, because the chip read "online" for years while the roster
	// beside it said "away" about the same human.
	{
		// The second peer stepped out of the room several scenes ago, so first
		// walk them back in; the directory grants whatever name is free, so the
		// name this block selects by is read off their own roster row rather
		// than assumed.
		await second.fill("#room", "lobby");
		await second.click("#joinBtn");
		await second.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
			.catch(() => fail("the second peer could not walk back into the room"));
		const who = await second.evaluate(() => {
			const own = [...document.querySelectorAll("#members .name")]
				.map((el) => el.textContent ?? "")
				.find((name) => name.endsWith(" (you)"));
			return own === undefined ? "" : own.slice(0, -" (you)".length);
		});
		if (who === "") fail("the second peer's own roster row never said which name it was granted");
		await tab.waitForSelector(`#members li:has(.name:text-is(${JSON.stringify(who)})) .dm-btn`, { timeout: 30_000 })
			.catch(async () => {
				const roster = await tab.evaluate(() =>
					[...document.querySelectorAll("#members li")].map((li) => ({
						name: li.querySelector(".name")?.textContent ?? "",
						cls: li.className,
						dm: li.querySelector(".dm-btn") !== null,
					}))
				);
				fail(`no direct-line button for ${JSON.stringify(who)}; the roster holds ${JSON.stringify(roster)}`);
			});
		await tab.click(`#members li:has(.name:text-is(${JSON.stringify(who)})) .dm-btn`);
		const dmRow = namedDirectRow(tab, who);
		await dmRow.waitFor({ timeout: 10_000 })
			.catch(() => fail("opening a direct line did not put a row for it in the rail"));
		await second.fill("#line", "/away fetching coffee");
		await second.press("#line", "Enter");
		const awayPip = dmRow.locator(".avatar-presence.away .presence-pip");
		await awayPip.waitFor({ timeout: 30_000 })
			.catch(() => fail("the direct row's chip did not pick up the away the shared room was told"));
		const pipSaid = await awayPip.getAttribute("title");
		if (pipSaid !== "away: fetching coffee") {
			fail(`the direct row's pip does not carry the reason: ${JSON.stringify(pipSaid)}`);
		}
		const header = await tab.evaluate(() => document.querySelector("#roomSigil .avatar-presence.away") !== null);
		if (!header) {
			fail("the direct conversation's own header chip did not say its person is away");
		}
		// And back: away is a state, not a scar.
		await second.fill("#line", "/away");
		await second.press("#line", "Enter");
		await awayPip.waitFor({ state: "detached", timeout: 30_000 })
			.catch(() => fail("coming back did not clear the direct row's away"));
	}
}
